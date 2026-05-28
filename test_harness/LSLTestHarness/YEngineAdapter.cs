using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace LSLTestHarness
{
    /// <summary>
    /// Clean, minimal YEngineAdapter implementation for testing.
    /// Conservative interpreter for harness tests (no LSL files changed).
    /// </summary>
    public class YEngineAdapter
    {
        private readonly MockLSLApi _api;
        private readonly string _scriptCode;
        private readonly Dictionary<string, string> _functionBodies = new();
        private readonly Dictionary<string, string> _constants = new();
        private readonly Dictionary<string, string> _globals = new();
        private readonly Dictionary<string, string> _runtimeGlobals = new();
        private readonly List<string> _executionContextKeys = new();

        private int _recursionDepth = 0;
        private const int MAX_RECURSION = 20;
        private string _lastReturnValue = string.Empty;

        public YEngineAdapter(MockLSLApi api, string scriptCode)
        {
            _api = api ?? throw new ArgumentNullException(nameof(api));
            _scriptCode = scriptCode ?? string.Empty;
            ParseScript();

            TestLogger.D("[YEngineAdapter] Parsed function count=" + _functionBodies.Count);
            // Optionally print function names for debugging
            try { TestLogger.D("[YEngineAdapter] Functions: " + string.Join(",", _functionBodies.Keys)); } catch { }

            foreach (var kv in _globals) _runtimeGlobals[kv.Key] = kv.Value;
            // Populate reasonable defaults for ALLOWED_ACL_* used by plugins/tests.
            if (!_runtimeGlobals.ContainsKey("ALLOWED_ACL_VIEW")) _runtimeGlobals["ALLOWED_ACL_VIEW"] = "[1,2,3,4,5]";
            if (!_runtimeGlobals.ContainsKey("ALLOWED_ACL_FULL")) _runtimeGlobals["ALLOWED_ACL_FULL"] = "[1,2,3,4,5]";
            if (!_runtimeGlobals.ContainsKey("ALLOWED_ACL_LEVELS")) _runtimeGlobals["ALLOWED_ACL_LEVELS"] = "[1,2,3,4,5]";
        }

        public void SetRuntimeGlobal(string name, string value) => _runtimeGlobals[name] = value;
        public string GetRuntimeGlobal(string name) => _runtimeGlobals.TryGetValue(name, out var v) ? v : string.Empty;
        public string? GetConstant(string name) => _constants.TryGetValue(name, out var v) ? v : null;
        public bool HasFunction(string name) => _functionBodies.ContainsKey(name);

        // Execution context helpers used by EventInjector
        public void SetExecutionContext(string key, string value)
        {
            SetRuntimeGlobal(key, value);
            if (!_executionContextKeys.Contains(key)) _executionContextKeys.Add(key);
        }

        public void ClearExecutionContext()
        {
            foreach (var k in _executionContextKeys) _runtimeGlobals.Remove(k);
            _executionContextKeys.Clear();
        }

        private void ParseScript()
        {
            try
            {
                var constPattern = new Regex(@"\b(integer|float|string|key|list)\s+([A-Z_][A-Z0-9_]*)\s*=\s*([^;]+);", RegexOptions.Multiline);
                foreach (Match m in constPattern.Matches(_scriptCode)) _constants[m.Groups[2].Value.Trim()] = m.Groups[3].Value.Trim();

                var globalPattern = new Regex(@"^\s*(integer|float|string|key|list|vector|rotation)\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*([^;]+);", RegexOptions.Multiline);
                foreach (Match m in globalPattern.Matches(_scriptCode))
                {
                    var name = m.Groups[2].Value.Trim();
                    if (!_constants.ContainsKey(name)) _globals[name] = m.Groups[3].Value.Trim();
                }

                int defaultPos = _scriptCode.IndexOf("default", StringComparison.Ordinal);
                var funcPattern = new Regex(@"^\s*(?:integer|float|string|key|list|vector|rotation\s+)?(\w+)\s*\(([^)]*)\)\s*\{", RegexOptions.Multiline);
                foreach (Match m in funcPattern.Matches(_scriptCode))
                {
                    var fn = m.Groups[1].Value;
                    int idx = m.Index;
                    if (defaultPos >= 0 && idx > defaultPos) continue;
                    int braceStart = _scriptCode.IndexOf('{', idx);
                    if (braceStart < 0) continue;
                    int braceCount = 1; int pos = braceStart + 1;
                    while (pos < _scriptCode.Length && braceCount > 0)
                    {
                        if (_scriptCode[pos] == '{') braceCount++; else if (_scriptCode[pos] == '}') braceCount--;
                        pos++;
                    }
                    if (braceCount == 0) _functionBodies[fn] = _scriptCode.Substring(braceStart + 1, pos - braceStart - 2);
                }
            }
            catch (Exception)
            {
                // Best-effort parse to avoid blowing up harness setup
            }
        }

        public void ExecuteFunction(string functionName, params string[] args)
        {
            if (string.IsNullOrEmpty(functionName)) return;
            // Ensure function is parsed (some helpers may not have been picked up by initial parse)
            EnsureFunctionParsed(functionName);
            if (!_functionBodies.TryGetValue(functionName, out var body)) return;
            if (_recursionDepth >= MAX_RECURSION) return;
            _recursionDepth++;
            try
            {
                TestLogger.D("[YEngineAdapter] ExecuteFunction: " + functionName + " args=[" + string.Join(",", args) + "]");
                if (string.Equals(functionName, "handle_acl_result", StringComparison.OrdinalIgnoreCase))
                {
                    TestLogger.D("[YEngineAdapter] handle_acl_result body:\n" + body);
                }
                var locals = new Dictionary<string, string>(StringComparer.Ordinal);
                // Bind args to the function's actual parameter names so the
                // body's references to `outfit_name`, `user`, etc. resolve
                // correctly. Keep the arg0/arg1 aliases for any handler that
                // happens to use them (legacy harness convention).
                var paramNames = ExtractFunctionParameterNames(functionName);
                for (int i = 0; i < args.Length; i++)
                {
                    locals[$"arg{i}"] = args[i];
                    if (i < paramNames.Count)
                    {
                        var pname = paramNames[i];
                        if (!string.IsNullOrEmpty(pname)) locals[pname] = args[i];
                    }
                }
                ExecuteFunctionBody(body, locals);
            }
            finally { _recursionDepth--; }
        }

        // Pull the parameter NAMES (not types) out of a function declaration.
        // Reuses the same regex shape as EnsureFunctionParsed; tokenizes the
        // captured param string and drops type prefixes so `string outfit_name`
        // yields ["outfit_name"]. Returns empty list if the function isn't
        // found in the source — caller falls back to arg0/arg1 binding.
        private List<string> ExtractFunctionParameterNames(string functionName)
        {
            var names = new List<string>();
            if (string.IsNullOrEmpty(functionName) || string.IsNullOrEmpty(_scriptCode)) return names;
            try
            {
                var pattern = new Regex($@"(?:integer|float|string|key|list|vector|rotation\s+)?{Regex.Escape(functionName)}\s*\(([^)]*)\)\s*\{{", RegexOptions.Multiline);
                var m = pattern.Match(_scriptCode);
                if (!m.Success) return names;
                var paramRaw = m.Groups[1].Value.Trim();
                if (paramRaw.Length == 0) return names;
                var parts = paramRaw.Split(',');
                foreach (var p in parts)
                {
                    var trimmed = p.Trim();
                    if (trimmed.Length == 0) continue;
                    // "string outfit_name" → take last whitespace-delimited token
                    var pieces = Regex.Split(trimmed, @"\s+");
                    if (pieces.Length == 0) continue;
                    names.Add(pieces[pieces.Length - 1]);
                }
            }
            catch { }
            return names;
        }

        private void EnsureFunctionParsed(string functionName)
        {
            if (string.IsNullOrEmpty(functionName)) return;
            if (_functionBodies.ContainsKey(functionName)) return;
            try
            {
                // Look for a function definition for the exact name in the script source
                var pattern = new Regex($@"(?:integer|float|string|key|list|vector|rotation\s+)?{Regex.Escape(functionName)}\s*\(([^)]*)\)\s*\{{", RegexOptions.Multiline);
                var m = pattern.Match(_scriptCode);
                if (!m.Success) return;
                int idx = m.Index;
                int braceStart = _scriptCode.IndexOf('{', idx);
                if (braceStart < 0) return;
                int braceCount = 1; int pos = braceStart + 1;
                while (pos < _scriptCode.Length && braceCount > 0)
                {
                    if (_scriptCode[pos] == '{') braceCount++; else if (_scriptCode[pos] == '}') braceCount--;
                    pos++;
                }
                if (braceCount == 0)
                {
                    var body = _scriptCode.Substring(braceStart + 1, pos - braceStart - 2);
                    _functionBodies[functionName] = body;
                    TestLogger.D($"[YEngineAdapter] EnsureFunctionParsed: added function '{functionName}' from source");
                }
            }
            catch (Exception ex)
            {
                TestLogger.D($"[YEngineAdapter] EnsureFunctionParsed error for '{functionName}': {ex.Message}");
            }
        }

        private bool ExecuteFunctionBody(string body, Dictionary<string, string>? locals)
        {
            if (locals == null) locals = new Dictionary<string, string>(StringComparer.Ordinal);
            var lines = CombineMultilineStatements(body).Split(new[] { '\n' }, StringSplitOptions.None);
            for (int i = 0; i < lines.Length; i++)
            {
                var line = lines[i].Trim();
                TestLogger.D($"[YEngineAdapter] ExecLine[{i}]: {line}");
                if (string.IsNullOrEmpty(line) || line.StartsWith("//")) continue;

                if (line.StartsWith("return", StringComparison.Ordinal))
                {
                    var retExpr = line.Substring(6).Trim();
                    if (retExpr.StartsWith("(" ) && retExpr.EndsWith(")")) retExpr = retExpr.Substring(1, retExpr.Length - 2).Trim();
                    if (!string.IsNullOrEmpty(retExpr)) _lastReturnValue = ResolveString(retExpr, locals);
                    else _lastReturnValue = string.Empty;
                    return true;
                }

                if (line.StartsWith("if", StringComparison.Ordinal))
                {
                    // Capture only the condition inside the first closing paren to avoid
                    // grabbing trailing closing parens from function calls inside the block.
                    var ifMatch = Regex.Match(line, "if\\s*\\(([^\\)]*)\\)\\s*(\\{)?");
                    var cond = ifMatch.Success ? ifMatch.Groups[1].Value.Trim() : string.Empty;
                    // Fallback: if regex couldn't capture condition (e.g. closing paren got moved),
                    // but there is a '{' after the '(', extract between '(' and '{'.
                    if (string.IsNullOrEmpty(cond) && line.Contains("(") && line.Contains("{") )
                    {
                        int p1 = line.IndexOf('(');
                        int p2 = line.IndexOf('{');
                        if (p2 > p1) cond = line.Substring(p1 + 1, p2 - p1 - 1).Trim();
                    }
                    bool hasInlineBlock = ifMatch.Success && ifMatch.Groups.Count > 2 && ifMatch.Groups[2].Value == "{";
                    bool condResult = EvaluateCondition(cond, locals);
                    TestLogger.D($"[YEngineAdapter] IF '{cond}' => {condResult}");

                    // Robust handling: if the if-line contains a block opener, treat it as a block
                    // and scan until the matching closing brace. This ensures that multi-line blocks
                    // are associated with the if even when parentheses parsing was imperfect.
                    if (line.Contains("{"))
                    {
                        // If the opening brace and first statements are on the same line, include
                        // the remainder of that line as the first block statement so ordering is preserved.
                        int openIdx = line.IndexOf('{');
                        string afterFirst = (openIdx >= 0 && openIdx + 1 < line.Length) ? line.Substring(openIdx + 1).Trim() : string.Empty;
                        int blockStartLine2 = i + 1; // subsequent lines start here
                        int brace2 = 1; int j2 = blockStartLine2;
                        for (; j2 < lines.Length; j2++) { brace2 += CountChar(lines[j2], '{'); brace2 -= CountChar(lines[j2], '}'); if (brace2 == 0) break; }
                        int blockEndLine2 = j2;
                        TestLogger.D($"[YEngineAdapter] IF(block-early) blockStartLine={blockStartLine2} blockEndLine={blockEndLine2} brace={brace2}");
                        if (condResult)
                        {
                            var blockLines = new List<string>();
                            if (!string.IsNullOrEmpty(afterFirst)) blockLines.Add(afterFirst);
                            if (blockStartLine2 <= blockEndLine2 - 1) blockLines.AddRange(lines[(blockStartLine2)..blockEndLine2]);
                            var blockText = string.Join('\n', blockLines);
                            if (ExecuteFunctionBody(blockText, new Dictionary<string, string>(locals))) return true;
                        }
                        i = blockEndLine2;
                        continue;
                    }

                    if (!hasInlineBlock)
                    {
                        int closeParen = line.IndexOf(')');
                        if (closeParen >= 0 && closeParen + 1 < line.Length)
                        {
                            var tail = line.Substring(closeParen + 1).Trim();
                            if (tail.StartsWith("return", StringComparison.Ordinal)) { if (condResult) return true; else continue; }
                            // If the tail begins with a block opener, let the subsequent block-scanning logic
                            // handle the statements inside the braces. This helps when parentheses parsing
                            // is imperfect and the opening brace appears immediately after the condition.
                            if (tail.StartsWith("{"))
                            {
                                // fall through to block scanning
                            }
                            else
                            {
                                if (condResult) ExecuteStatement(tail, locals);
                                continue;
                            }
                        }
                    }

                    // Special-case: single-line block like: if (cond) { stmt1; stmt2; }
                    if (line.Contains("{") && line.Contains("}"))
                    {
                        var openIdx = line.IndexOf('{');
                        var closeIdx = line.IndexOf('}', openIdx + 1);
                        if (openIdx >= 0 && closeIdx > openIdx)
                        {
                            var inlineBlock = line.Substring(openIdx + 1, closeIdx - openIdx - 1).Trim();
                            if (condResult)
                            {
                                // Execute the inline block's statements
                                ExecuteFunctionBody(inlineBlock, new Dictionary<string, string>(locals));
                            }
                            // Skip any further block scanning for this if
                            continue;
                        }
                    }

                    // If the block starts on the same line ("if (...) { stmt..."), execute the remainder
                    if (line.Contains("{") && !line.Contains("}"))
                    {
                        var after = line.Substring(line.IndexOf('{') + 1).Trim();
                        if (!string.IsNullOrEmpty(after))
                        {
                            if (condResult)
                            {
                                ExecuteFunctionBody(after, new Dictionary<string, string>(locals));
                            }
                            // Continue to process the following lines inside the block normally
                        }
                    }

                    int blockStartLine = i; if (line.Contains("{")) blockStartLine = i + 1;
                    int brace = line.Contains("{") ? 1 : 0; int j = blockStartLine;
                    for (; j < lines.Length; j++) { brace += CountChar(lines[j], '{'); brace -= CountChar(lines[j], '}'); if (brace == 0) break; }
                    int blockEndLine = j;
                    TestLogger.D($"[YEngineAdapter] IF blockStartLine={blockStartLine} blockEndLine={blockEndLine} brace={brace}");
                    if (condResult)
                    {
                        var blockText = string.Join('\n', lines[(blockStartLine)..blockEndLine]);
                        if (ExecuteFunctionBody(blockText, new Dictionary<string, string>(locals))) return true;
                    }
                    i = blockEndLine;

                    int nextIdx = i + 1; while (nextIdx < lines.Length && string.IsNullOrWhiteSpace(lines[nextIdx])) nextIdx++;
                    if (nextIdx < lines.Length && lines[nextIdx].TrimStart().StartsWith("else", StringComparison.Ordinal))
                    {
                        var elseLine = lines[nextIdx].Trim();
                        bool elseHasBlock = elseLine.Contains("{") || (nextIdx + 1 < lines.Length && lines[nextIdx + 1].TrimStart().StartsWith("{"));
                        if (!condResult && elseHasBlock)
                        {
                            int elseStart = elseLine.Contains("{") ? nextIdx + 1 : nextIdx + 2;
                            int b = elseLine.Contains("{") ? 1 : 0; int k = elseStart;
                            for (; k < lines.Length; k++) { b += CountChar(lines[k], '{'); b -= CountChar(lines[k], '}'); if (b == 0) break; }
                            var elseBlock = string.Join('\n', lines[elseStart..k]);
                            if (ExecuteFunctionBody(elseBlock, new Dictionary<string, string>(locals))) return true;
                            i = k;
                        }
                        else { i = nextIdx; }
                    }
                    continue;
                }

                ExecuteStatement(line, locals);
            }
            return false;
        }

        private void ExecuteStatement(string stmt, Dictionary<string, string> locals)
        {
            var s = stmt.Trim().TrimEnd(';').Trim(); if (string.IsNullOrEmpty(s)) return;
            var assign = Regex.Match(s, "^(?:(?:integer|float|string|key|list|vector|rotation)\\s+)?([a-zA-Z_][a-zA-Z0-9_]*)\\s*=\\s*(.+)$");
            if (assign.Success)
            {
                var varName = assign.Groups[1].Value;
                var varExpr = assign.Groups[2].Value.Trim();
                var resolved = ResolveString(varExpr, locals);
                locals[varName] = resolved;
                TestLogger.D($"[YEngineAdapter] Assign: {varName} = '{resolved}'");
                return;
            }
            var callMatch = Regex.Match(s, "^(\\w+)\\s*\\((.*)\\)$");
            if (!callMatch.Success) return;
            var fname = callMatch.Groups[1].Value; var argsRaw = callMatch.Groups[2].Value.Trim(); var args = ParseArguments(argsRaw, locals);

            switch (fname)
            {
                case "llDialog":
                    {
                        var a0 = args.Count > 0 ? args[0] : "";
                        var a1 = args.Count > 1 ? args[1] : "";
                        var a2 = args.Count > 2 ? args[2] : "";
                        var a3 = args.Count > 3 && int.TryParse(args[3], out var ch) ? ch : 0;
                        TestLogger.D($"[YEngineAdapter] llDialog -> avatar='{a0}' message='{a1}' buttons='{a2}' channel={a3}");
                        _api.llDialog(a0, a1, a2, a3);
                        return;
                    }
                case "llMessageLinked":
                    {
                        // llMessageLinked(linkNum, num, msg, id)
                        int linkNum = 0;
                        int numVal = 0;
                        string msgVal = "";
                        string idVal = "";

                        if (args.Count > 0)
                        {
                            var a0 = args[0];
                            if (string.Equals(a0, "LINK_SET", StringComparison.OrdinalIgnoreCase)) linkNum = MockLSLApi.LINK_SET;
                            else if (!int.TryParse(a0, out linkNum)) linkNum = 0;
                        }

                        if (args.Count > 1)
                        {
                            var a1 = args[1];
                            if (!int.TryParse(a1, out numVal)) numVal = 0;
                        }

                        if (args.Count > 2) msgVal = args[2];
                        if (args.Count > 3) idVal = args[3];

                        TestLogger.D($"[YEngineAdapter] llMessageLinked -> linkNum={linkNum} num={numVal} msg='{msgVal}' id='{idVal}'");
                        _api.llMessageLinked(linkNum, numVal, msgVal, idVal);
                        return;
                    }
                case "llJsonGetValue":
                    {
                        var p0 = args.Count > 0 ? args[0] : "";
                        var p1 = args.Count > 1 ? args[1] : "";
                        TestLogger.D($"[YEngineAdapter] llJsonGetValue -> json='{p0}' path='{p1}'");
                        _api.llJsonGetValue(p0, p1);
                        return;
                    }
                case "llRegionSayTo":
                    {
                        var target = args.Count > 0 ? args[0] : "";
                        var channel = args.Count > 1 && int.TryParse(args[1], out var ch) ? ch : 0;
                        var message = args.Count > 2 ? args[2] : "";
                        TestLogger.D($"[YEngineAdapter] llRegionSayTo -> target='{target}' channel={channel} msg='{message}'");
                        _api.llRegionSayTo(target, channel, message);
                        return;
                    }
                case "llOwnerSay":
                    {
                        var message = args.Count > 0 ? args[0] : "";
                        TestLogger.D($"[YEngineAdapter] llOwnerSay -> '{message}'");
                        _api.llOwnerSay(message);
                        return;
                    }
                case "llSay":
                case "llRegionSay":
                    {
                        var channel = args.Count > 0 && int.TryParse(args[0], out var ch2) ? ch2 : 0;
                        var message = args.Count > 1 ? args[1] : args.Count > 0 ? args[0] : "";
                        TestLogger.D($"[YEngineAdapter] llSay/llRegionSay -> channel={channel} msg='{message}'");
                        // Capture as owner say for tests
                        _api.llOwnerSay($"[Say ch:{channel}] {message}");
                        return;
                    }
                default:
                    // Trigger lazy parse so functions defined AFTER `default {`
                    // — or AFTER the first stray "default" token in a comment,
                    // which is what IndexOf picks up — can still be invoked.
                    // Without this, calls like rlv_force(...) inside apply_wear
                    // are silently no-oped because rlv_force never got parsed.
                    EnsureFunctionParsed(fname);
                    if (_functionBodies.ContainsKey(fname))
                    {
                        TestLogger.D($"[YEngineAdapter] Calling function '{fname}'");
                        ExecuteFunction(fname, args.ToArray());
                    }
                    return;
            }
        }

        private List<string> ParseArguments(string raw, Dictionary<string, string> locals)
        {
            // Track quote state AND nesting depth across (), [], <> so that a
            // comma inside a nested call/list/vector doesn't split the parent
            // argument. Without depth tracking, an expression like
            //   llMessageLinked(LINK_SET, 500, llList2Json(JSON_OBJECT, ["type", "x"]), NULL_KEY)
            // splits at every comma and passes garbage to llMessageLinked's
            // msg argument. ResolveString then can't evaluate the partial
            // text and the captured link message is unusable for assertions.
            var list = new List<string>(); if (string.IsNullOrWhiteSpace(raw)) return list;
            var cur = new System.Text.StringBuilder();
            bool inQuote = false;
            int parenDepth  = 0;  // ( )
            int squareDepth = 0;  // [ ]
            int angleDepth  = 0;  // < > (LSL vectors / rotations)
            for (int i = 0; i < raw.Length; i++)
            {
                char c = raw[i];
                if (c == '"') { inQuote = !inQuote; cur.Append(c); continue; }
                if (!inQuote)
                {
                    if      (c == '(') parenDepth++;
                    else if (c == ')') parenDepth--;
                    else if (c == '[') squareDepth++;
                    else if (c == ']') squareDepth--;
                    else if (c == '<') angleDepth++;
                    else if (c == '>') angleDepth--;
                    else if (c == ',' && parenDepth == 0 && squareDepth == 0 && angleDepth == 0)
                    {
                        var part = cur.ToString().Trim();
                        if (part.Length > 0) list.Add(ResolveString(part, locals));
                        cur.Clear();
                        continue;
                    }
                }
                cur.Append(c);
            }
            if (cur.Length > 0) list.Add(ResolveString(cur.ToString().Trim(), locals));
            return list;
        }

        private string ResolveString(string expr, Dictionary<string, string> localVars)
        {
            if (string.IsNullOrWhiteSpace(expr)) return string.Empty;
            TestLogger.D($"[YEngineAdapter] ResolveString ENTRY -> '{expr}'");
            var t = expr.Trim();
            // Strip simple casts like (key), (integer), (string) at start
            if (t.StartsWith("(") )
            {
                int idx = t.IndexOf(')');
                if (idx > 0) { t = t.Substring(idx + 1).Trim(); }
            }
            // Strip surrounding quotes ONLY for true single-string literals.
            // A concatenation like `"@detachallthis:" + OUTFITS_ROOT + "=force"`
            // also starts and ends with `"` but isn't a single literal —
            // detect that by counting unescaped quote chars (a single literal
            // has exactly 2 at positions 0 and length-1).
            if ((t.StartsWith("\"") && t.EndsWith("\"")) || (t.StartsWith("'") && t.EndsWith("'")))
            {
                char qc = t[0];
                int unescapedQuoteCount = 0;
                for (int qi = 0; qi < t.Length; qi++)
                {
                    if (t[qi] == qc && (qi == 0 || t[qi - 1] != '\\')) unescapedQuoteCount++;
                }
                if (unescapedQuoteCount == 2) return t.Substring(1, t.Length - 2);
                // Otherwise fall through — it's a multi-segment expression
                // (concat / mixed literals + identifiers).
            }
            if (int.TryParse(t, out _)) return t;
            if (localVars != null && localVars.TryGetValue(t, out var lv)) return lv;
            if (_runtimeGlobals.TryGetValue(t, out var gv)) return gv;
            if (_constants.TryGetValue(t, out var cv)) return cv;

            if (t.EndsWith("()", StringComparison.Ordinal))
            {
                var funcName = t.Substring(0, t.Length - 2);
                if (funcName == "llGetUnixTime") return DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString();
            }
            // Targeted replacement: if the expression contains ALLOWED_ACL_* identifiers,
            // substitute them with the runtime or constant list literal so downstream
            // evaluation (for example, llListFindList(ALLOWED_ACL_LEVELS, [level]))
            // receives a concrete JSON/list literal.
            try
            {
                t = Regex.Replace(t, "\\b(ALLOWED_ACL_VIEW|ALLOWED_ACL_FULL|ALLOWED_ACL_LEVELS)\\b", m =>
                {
                    var name = m.Groups[1].Value;
                    var rv = GetRuntimeGlobal(name);
                    if (!string.IsNullOrEmpty(rv)) return rv;
                    var cv = GetConstant(name);
                    if (!string.IsNullOrEmpty(cv)) return cv;
                    return "[]";
                });
                if (t.Contains("ALLOWED_ACL_")) TestLogger.D($"[YEngineAdapter] ResolveString after ALLOWED_ACL replacement -> {t}");
            }
            catch { }

            // Special-case: handle in_allowed_levels even if the closing paren was stripped
            if (t.IndexOf("in_allowed_levels", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                int p = t.IndexOf('(');
                var innerRaw = p >= 0 ? t.Substring(p + 1).Trim() : string.Empty;
                // strip any trailing ')' if present
                innerRaw = innerRaw.TrimEnd(')');
                var parts = SplitTopLevelArgs(innerRaw);
                var levelVal = parts.Count > 0 ? ResolveString(parts[0].Trim(), localVars) : "0";
                var allowedList = GetConstant("ALLOWED_ACL_LEVELS") ?? GetRuntimeGlobal("ALLOWED_ACL_LEVELS") ?? "[]";
                string sublistJson = "[" + (int.TryParse(levelVal, out var pl) ? pl.ToString() : JsonStringEscape(levelVal)) + "]";
                try
                {
                    TestLogger.D($"[YEngineAdapter] in_allowed_levels: allowedList='{allowedList}' sublist='{sublistJson}'");
                    var idx = _api.llListFindList(allowedList, sublistJson);
                    TestLogger.D($"[YEngineAdapter] in_allowed_levels -> llListFindList returned {idx}");
                    return (idx != -1) ? "1" : "0";
                }
                catch { return "0"; }
            }

            // If this is a user-defined function call, execute it and return its last return value
            var fnCallMatch = Regex.Match(t, "^(\\w+)\\s*\\((.*)\\)$");
                if (fnCallMatch.Success)
                {
                    var fn = fnCallMatch.Groups[1].Value;
                    var inner = fnCallMatch.Groups[2].Value.Trim();

                    // Handle some common ll* helpers directly
                    if (string.Equals(fn, "llGetUnixTime", StringComparison.OrdinalIgnoreCase))
                    {
                        return _api.llGetUnixTime().ToString();
                    }
                    if (string.Equals(fn, "llGetScriptName", StringComparison.OrdinalIgnoreCase))
                    {
                        return _api.llGetScriptName();
                    }
                    if (string.Equals(fn, "llGetKey", StringComparison.OrdinalIgnoreCase))
                    {
                        var ctx = _api.GetScriptContext();
                        if (!string.IsNullOrEmpty(ctx)) return ctx;
                        return MockLSLApi.NULL_KEY;
                    }

                    // If this is a user-defined function call, ensure it's parsed, execute it and return its last return value
                    EnsureFunctionParsed(fn);
                    if (_functionBodies.ContainsKey(fn))
                    {
                        var parsedArgs = new List<string>();
                        var argParts = SplitTopLevelArgs(inner);
                        foreach (var p in argParts) parsedArgs.Add(ResolveString(p.Trim(), localVars));
                        // reset last return value, execute, and return captured value
                        _lastReturnValue = string.Empty;
                        ExecuteFunction(fn, parsedArgs.ToArray());
                        return _lastReturnValue ?? string.Empty;
                    }

                    // Special-case: in_allowed_levels(level) may be defined in script but not parsed reliably
                    if (string.Equals(fn, "in_allowed_levels", StringComparison.OrdinalIgnoreCase))
                    {
                        var parts = SplitTopLevelArgs(inner);
                        var levelVal = parts.Count > 0 ? ResolveString(parts[0].Trim(), localVars) : "0";
                        var allowedList = GetConstant("ALLOWED_ACL_LEVELS") ?? GetRuntimeGlobal("ALLOWED_ACL_LEVELS") ?? "[]";
                        // Ensure sublist JSON
                        string sublistJson = "[" + (int.TryParse(levelVal, out var parsedLevel) ? parsedLevel.ToString() : JsonStringEscape(levelVal)) + "]";
                        try
                        {
                            var idx = _api.llListFindList(allowedList, sublistJson);
                            return (idx != -1) ? "1" : "0";
                        }
                        catch
                        {
                            return "0";
                        }
                    }

                    // Fallback emulation for common helper functions that may not be parsed
                    if (string.Equals(fn, "generate_session_id", StringComparison.OrdinalIgnoreCase))
                    {
                        // Use PLUGIN_CONTEXT if available, otherwise fallback
                        var ctx = GetConstant("PLUGIN_CONTEXT") ?? GetRuntimeGlobal("PLUGIN_CONTEXT") ?? "plugin";
                        // Strip surrounding quotes if script declared it as a quoted string
                        if (!string.IsNullOrEmpty(ctx) && ((ctx.StartsWith("\"") && ctx.EndsWith("\"")) || (ctx.StartsWith("'") && ctx.EndsWith("'"))))
                        {
                            ctx = ctx.Substring(1, ctx.Length - 2);
                        }
                        var sid = ctx + "_" + DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString();
                        TestLogger.D($"[YEngineAdapter] Emulated generate_session_id() -> {sid}");
                        return sid;
                    }

                // Handle simple ll* helper calls with arguments that produce string results,
                // e.g. llList2Json(JSON_OBJECT, [...])
                if (string.Equals(fn, "llList2Json", StringComparison.Ordinal))
                {
                    // split inner into two top-level args: type, listJson
                    var parts = SplitTopLevelArgs(inner);
                    var typeArg = parts.Count > 0 ? ResolveString(parts[0].Trim(), localVars) : "";
                    var rawListArg = parts.Count > 1 ? parts[1].Trim() : "[]";
                    // If building an object, reconstruct the list as a concrete JSON array by resolving each element
                    if (string.Equals(typeArg, "JSON_OBJECT", StringComparison.OrdinalIgnoreCase))
                    {
                        try
                        {
                            string listJson;
                            if (rawListArg.StartsWith("["))
                            {
                                var innerContent = rawListArg.Substring(1, rawListArg.Length - 2);
                                var rawElems = SplitTopLevelArgs(innerContent);
                                var tokens = new List<string>();
                                foreach (var raw in rawElems)
                                {
                                    var rtrim = raw.Trim();
                                    bool quoted = (rtrim.StartsWith("\"") || rtrim.StartsWith("'"));
                                    var resolved = ResolveString(rtrim, localVars);
                                    string token;
                                    if (quoted)
                                    {
                                        token = JsonStringEscape(resolved);
                                    }
                                    else if (!string.IsNullOrEmpty(resolved) && (resolved.StartsWith("[") || resolved.StartsWith("{")))
                                    {
                                        token = resolved;
                                    }
                                    else if (int.TryParse(resolved, out _))
                                    {
                                        token = resolved;
                                    }
                                    else if (string.Equals(resolved, "TRUE", StringComparison.OrdinalIgnoreCase))
                                    {
                                        token = "1";
                                    }
                                    else if (string.Equals(resolved, "FALSE", StringComparison.OrdinalIgnoreCase))
                                    {
                                        token = "0";
                                    }
                                    else
                                    {
                                        token = JsonStringEscape(resolved);
                                    }
                                    tokens.Add(token);
                                }
                                listJson = "[" + string.Join(",", tokens) + "]";
                            }
                            else
                            {
                                // not a literal: resolve and if it's already a JSON array, use it; otherwise wrap single value
                                var resolved = ResolveString(rawListArg, localVars);
                                if (!string.IsNullOrEmpty(resolved) && resolved.StartsWith("[")) listJson = resolved;
                                else listJson = "[" + JsonStringEscape(resolved) + "]";
                            }

                            TestLogger.D($"[YEngineAdapter] Debug llList2Json INPUT(rebuilt) -> type='{typeArg}' list='{listJson}'");
                            var res = _api.llList2Json(typeArg, listJson);
                            TestLogger.D($"[YEngineAdapter] Debug llList2Json OUTPUT -> {res}");
                            return res;
                        }
                        catch (Exception ex)
                        {
                            TestLogger.D($"[YEngineAdapter] Debug llList2Json ERROR rebuilding JSON_OBJECT: {ex}");
                            return "JSON_INVALID";
                        }
                    }
                    else
                    {
                        // If JSON_ARRAY and literal, rebuild elements
                        if (string.Equals(typeArg, "JSON_ARRAY", StringComparison.OrdinalIgnoreCase) && rawListArg.StartsWith("["))
                        {
                            try
                            {
                                var innerContent = rawListArg.Substring(1, rawListArg.Length - 2);
                                var rawElems = SplitTopLevelArgs(innerContent);
                                var tokens = new List<string>();
                                foreach (var raw in rawElems)
                                {
                                    var rtrim = raw.Trim();
                                    var resolved = ResolveString(rtrim, localVars);
                                    if (!string.IsNullOrEmpty(resolved) && (resolved.StartsWith("[") || resolved.StartsWith("{"))) tokens.Add(resolved);
                                    else if (int.TryParse(resolved, out _)) tokens.Add(resolved);
                                    else if (string.Equals(resolved, "TRUE", StringComparison.OrdinalIgnoreCase)) tokens.Add("1");
                                    else if (string.Equals(resolved, "FALSE", StringComparison.OrdinalIgnoreCase)) tokens.Add("0");
                                    else tokens.Add(JsonStringEscape(resolved));
                                }
                                var rebuilt = "[" + string.Join(",", tokens) + "]";
                                TestLogger.D($"[YEngineAdapter] Debug llList2Json INPUT(rebuilt-array) -> type='{typeArg}' list='{rebuilt}'");
                                var res = _api.llList2Json(typeArg, rebuilt);
                                TestLogger.D($"[YEngineAdapter] Debug llList2Json OUTPUT -> {res}");
                                return res;
                            }
                            catch { /* fallthrough to generic */ }
                        }

                        var listArg = ResolveString(rawListArg, localVars);
                        TestLogger.D($"[YEngineAdapter] Debug llList2Json INPUT -> type='{typeArg}' list='{listArg}'");
                        try { var res = _api.llList2Json(typeArg, listArg); TestLogger.D($"[YEngineAdapter] Debug llList2Json OUTPUT -> {res}"); return res; } catch { TestLogger.D($"[YEngineAdapter] Debug llList2Json FAILED for type='{typeArg}'"); return t; }
                    }
                }
                if (string.Equals(fn, "llJsonGetValue", StringComparison.Ordinal))
                {
                    var parts = SplitTopLevelArgs(inner);
                    var json = parts.Count > 0 ? ResolveString(parts[0].Trim(), localVars) : "";
                    var path = parts.Count > 1 ? ResolveString(parts[1].Trim(), localVars) : "";
                    TestLogger.D($"[YEngineAdapter] Debug llJsonGetValue INPUT -> json='{json}' path='{path}'");
                    try { var outv = _api.llJsonGetValue(json, path); TestLogger.D($"[YEngineAdapter] Debug llJsonGetValue OUTPUT -> {outv}"); return outv; } catch { TestLogger.D($"[YEngineAdapter] Debug llJsonGetValue FAILED"); return t; }
                }
            }

                // If expression is a JSON-like list literal, resolve each element and return a concrete JSON array
            if (t.StartsWith("[") && t.EndsWith("]"))
            {
                TestLogger.D($"[YEngineAdapter] ResolveString list-literal -> {t}");
                var inner = t.Substring(1, t.Length - 2);
                var elems = SplitTopLevelArgs(inner);
                var tokens = new List<string>();
                foreach (var e in elems)
                {
                    var trimmed = e.Trim();
                    var rv = ResolveString(trimmed, localVars);
                    TestLogger.D($"[YEngineAdapter] ResolveString list-element -> raw='{trimmed}' resolved='{rv}'");
                    // If the resolved value looks like JSON (array/object), insert as-is
                    if (!string.IsNullOrEmpty(rv) && (rv.StartsWith("[") || rv.StartsWith("{"))) tokens.Add(rv);
                    else if (int.TryParse(rv, out _)) tokens.Add(rv);
                    else if (string.Equals(rv, "TRUE", StringComparison.OrdinalIgnoreCase)) tokens.Add("1");
                    else if (string.Equals(rv, "FALSE", StringComparison.OrdinalIgnoreCase)) tokens.Add("0");
                    else tokens.Add(JsonStringEscape(rv));
                }
                var combined = "[" + string.Join(",", tokens) + "]";
                    TestLogger.D($"[YEngineAdapter] ResolveString list-literal-resolved -> {combined}");
                return combined;
            }

            // Handle top-level concatenation with +
            var plusParts = SplitTopLevelConcat(t);
            if (plusParts.Count > 1)
            {
                TestLogger.D($"[YEngineAdapter] ResolveString plus-concat parts -> [{string.Join(",", plusParts)}]");
                bool looksLikeListConcat = false;
                foreach (var p in plusParts) if (p.Trim().StartsWith("[")) { looksLikeListConcat = true; break; }

                if (looksLikeListConcat)
                {
                    // Perform list concatenation: flatten elements into one JSON array
                    var innerParts = new List<string>();
                    foreach (var p in plusParts)
                    {
                        var rv = ResolveString(p.Trim(), localVars);
                        if (rv.StartsWith("[") && rv.EndsWith("]"))
                        {
                            var inner = rv.Substring(1, rv.Length - 2).Trim();
                            if (!string.IsNullOrEmpty(inner)) innerParts.Add(inner);
                        }
                        else
                        {
                            innerParts.Add(JsonStringEscape(rv));
                        }
                    }
                    var combined = "[" + string.Join(",", innerParts) + "]";
                    TestLogger.D($"[YEngineAdapter] ResolveString list-concat -> {combined}");
                    return combined;
                }
                else
                {
                    // String concatenation: join resolved parts into a single string
                    var sb = new System.Text.StringBuilder();
                    foreach (var p in plusParts)
                    {
                        var rv = ResolveString(p.Trim(), localVars);
                        // Strip surrounding quotes if present
                        if ((rv.StartsWith("\"") && rv.EndsWith("\"")) || (rv.StartsWith("'") && rv.EndsWith("'"))) sb.Append(rv.Substring(1, rv.Length - 2));
                        else sb.Append(rv);
                    }
                    var result = sb.ToString();
                    TestLogger.D($"[YEngineAdapter] ResolveString string-concat -> '{result}'");
                    return result;
                }
            }

            // Support a few more ll* helpers inline so list operations work
            var simpleFnMatch = Regex.Match(t, "^(\\w+)\\s*\\((.*)\\)$");
            if (simpleFnMatch.Success)
            {
                var sf = simpleFnMatch.Groups[1].Value;
                var innerArgs = SplitTopLevelArgs(simpleFnMatch.Groups[2].Value);
                if (string.Equals(sf, "llGetListLength", StringComparison.Ordinal))
                {
                    var listJson = innerArgs.Count > 0 ? ResolveString(innerArgs[0].Trim(), localVars) : "[]";
                    TestLogger.D($"[YEngineAdapter] Debug llGetListLength INPUT -> {listJson}");
                    try { var outv = _api.llGetListLength(listJson).ToString(); TestLogger.D($"[YEngineAdapter] Debug llGetListLength OUTPUT -> {outv}"); return outv; } catch { TestLogger.D($"[YEngineAdapter] Debug llGetListLength FAILED"); return "0"; }
                }
                if (string.Equals(sf, "llList2String", StringComparison.Ordinal))
                {
                    var listJson = innerArgs.Count > 0 ? ResolveString(innerArgs[0].Trim(), localVars) : "[]";
                    var idx = innerArgs.Count > 1 && int.TryParse(ResolveString(innerArgs[1].Trim(), localVars), out var ii) ? ii : 0;
                    TestLogger.D($"[YEngineAdapter] Debug llList2String INPUT -> list={listJson} idx={idx}");
                    try { var outv = _api.llList2String(listJson, idx); TestLogger.D($"[YEngineAdapter] Debug llList2String OUTPUT -> {outv}"); return outv; } catch { TestLogger.D($"[YEngineAdapter] Debug llList2String FAILED"); return string.Empty; }
                }
                if (string.Equals(sf, "llList2Integer", StringComparison.Ordinal))
                {
                    var listJson = innerArgs.Count > 0 ? ResolveString(innerArgs[0].Trim(), localVars) : "[]";
                    var idx = innerArgs.Count > 1 && int.TryParse(ResolveString(innerArgs[1].Trim(), localVars), out var ii2) ? ii2 : 0;
                    TestLogger.D($"[YEngineAdapter] Debug llList2Integer INPUT -> list={listJson} idx={idx}");
                    try { var outv = _api.llList2Integer(listJson, idx).ToString(); TestLogger.D($"[YEngineAdapter] Debug llList2Integer OUTPUT -> {outv}"); return outv; } catch { TestLogger.D($"[YEngineAdapter] Debug llList2Integer FAILED"); return "0"; }
                }
            }

            TestLogger.D($"[YEngineAdapter] ResolveString fallback -> '{t}'");

            return t;
        }

        private bool EvaluateCondition(string cond, Dictionary<string, string> localVars)
        {
            if (string.IsNullOrWhiteSpace(cond)) return false;
            cond = cond.Trim();
            TestLogger.D($"[YEngineAdapter] EvaluateCondition input='{cond}'");
            if (cond.StartsWith("!")) return !EvaluateCondition(cond.Substring(1).Trim(), localVars);

            var comp = Regex.Match(cond, "^(.+?)(==|!=|<=|>=|<|>)(.+)$");
            if (comp.Success)
            {
                var left = ResolveString(comp.Groups[1].Value.Trim(), localVars);
                var op = comp.Groups[2].Value;
                var right = ResolveString(comp.Groups[3].Value.Trim(), localVars);
                if (int.TryParse(left, out var li) && int.TryParse(right, out var ri))
                {
                    var result = op switch
                    {
                        "==" => li == ri,
                        "!=" => li != ri,
                        "<" => li < ri,
                        ">" => li > ri,
                        "<=" => li <= ri,
                        ">=" => li >= ri,
                        _ => false,
                    };
                    TestLogger.D($"[YEngineAdapter] EvalCondition numeric: '{left}' {op} '{right}' => {result} (li={li}, ri={ri})");
                    return result;
                }
                var strResult = op switch { "==" => left == right, "!=" => left != right, _ => false };
                TestLogger.D($"[YEngineAdapter] EvalCondition string: '{left}' {op} '{right}' => {strResult}");
                return strResult;
            }

            var r = ResolveString(cond, localVars);
            if (string.IsNullOrEmpty(r)) return false;
            if (int.TryParse(r, out var n)) return n != 0;
            if (string.Equals(r, "TRUE", StringComparison.OrdinalIgnoreCase) || string.Equals(r, "1", StringComparison.OrdinalIgnoreCase)) return true;
            if (string.Equals(r, "FALSE", StringComparison.OrdinalIgnoreCase) || string.Equals(r, "0", StringComparison.OrdinalIgnoreCase)) return false;
            return true;
        }

        private static int CountChar(string s, char c) { if (string.IsNullOrEmpty(s)) return 0; int ct = 0; foreach (var ch in s) if (ch == c) ct++; return ct; }

        private static string CombineMultilineStatements(string body)
        {
            var lines = body.Replace("\r\n", "\n").Replace("\r", "\n").Split('\n');
            var outLines = new List<string>();
            string buffer = string.Empty;
            foreach (var raw in lines)
            {
                var l = raw.TrimEnd();
                if (string.IsNullOrWhiteSpace(l)) continue;
                // Keep comment lines separate so they don't get concatenated with following code
                if (l.TrimStart().StartsWith("//"))
                {
                    if (!string.IsNullOrEmpty(buffer)) { outLines.Add(buffer); buffer = string.Empty; }
                    outLines.Add(l.Trim());
                    continue;
                }
                buffer += (buffer.Length == 0 ? "" : " ") + l.Trim();
                if (l.TrimEnd().EndsWith(";") || l.TrimEnd().EndsWith("}")) { outLines.Add(buffer); buffer = string.Empty; }
            }
            if (!string.IsNullOrEmpty(buffer)) outLines.Add(buffer);
            return string.Join('\n', outLines);
        }

        private static List<string> SplitTopLevelArgs(string raw)
        {
            var parts = new List<string>(); if (string.IsNullOrWhiteSpace(raw)) return parts;
            var cur = new System.Text.StringBuilder(); int depth = 0; bool inQuote = false;
            for (int i = 0; i < raw.Length; i++)
            {
                char c = raw[i];
                if (c == '"') { inQuote = !inQuote; cur.Append(c); continue; }
                if (!inQuote)
                {
                    if (c == '(' || c == '[') { depth++; cur.Append(c); continue; }
                    if (c == ')' || c == ']') { depth = Math.Max(0, depth - 1); cur.Append(c); continue; }
                    if (c == ',' && depth == 0) { parts.Add(cur.ToString()); cur.Clear(); continue; }
                }
                cur.Append(c);
            }
            if (cur.Length > 0) parts.Add(cur.ToString());
            return parts;
        }

        private static List<string> SplitTopLevelConcat(string raw)
        {
            var parts = new List<string>(); if (string.IsNullOrWhiteSpace(raw)) return parts;
            var cur = new System.Text.StringBuilder(); int depth = 0; bool inQuote = false;
            for (int i = 0; i < raw.Length; i++)
            {
                char c = raw[i];
                if (c == '"') { inQuote = !inQuote; cur.Append(c); continue; }
                if (!inQuote)
                {
                    if (c == '(' || c == '[') { depth++; cur.Append(c); continue; }
                    if (c == ')' || c == ']') { depth = Math.Max(0, depth - 1); cur.Append(c); continue; }
                    if (c == '+' && depth == 0) { parts.Add(cur.ToString()); cur.Clear(); continue; }
                }
                cur.Append(c);
            }
            if (cur.Length > 0) parts.Add(cur.ToString());
            return parts;
        }

        private static string JsonStringEscape(string s)
        {
            if (s == null) s = "";
            s = s.Replace("\\", "\\\\");
            s = s.Replace("\"", "\\\"");
            return "\"" + s + "\"";
        }
    }
}
