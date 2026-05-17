// Cross-script (Layer 2) analysis: walks all script ASTs in a project, extracts
// inter-script communication primitives, and emits diagnostics for bugs that hide
// in the seams between modules.
//
// What we extract:
//   - link_message emits: llMessageLinked(..., llList2Json(JSON_OBJECT, ["type", "X", ...]), ...)
//   - link_message handlers: string equality checks inside link_message event bodies
//   - LSD writes/reads/deletes: llLinksetData*("key", ...)  (literal or prefix+var)
//
// LSD-owner annotations
// ---------------------
// Some projects use a single-writer architecture for a known set of LSD keys —
// one script receives write requests over a bus and is the sole `llLinksetDataWrite`
// caller. The actual write site uses a dynamic key parsed at runtime, which is
// invisible to static analysis. To bridge this gap, a script may declare itself
// the authoritative writer for a set of keys with one of two annotation forms:
//
// Form A — anchored on a global `list` (when the list is already used at runtime):
//
//     // @lsl-ide lsd-owner
//     list MANAGED_KEYS = [
//         "foo.alpha",
//         "foo.beta"
//     ];
//
// The annotation must be a line comment within 5 lines preceding a global `list`
// declaration whose elements are string literals.
//
// Form B — inline comment (documentation-only, no runtime variable):
//
//     // @lsl-ide lsd-owns: foo.alpha, *.cache, prefix.*
//
// A comma-separated list of literal keys or simple patterns (prefix `*` or suffix `*`).
//
// Both forms synthesize "write" entries in the cross-script graph attributed to
// the declaring script, eliminating false-positive XSL004 reports for keys with
// a documented owner.
//
// Rule family XSL00*:
//   XSL001  emit with no handler anywhere
//   XSL002  handler matched on a type no script emits
//   XSL003  LSD key written by >1 script
//   XSL004  LSD key read but never written by any script

import type { ScriptUnit } from './project.js';
import type { Position } from '../parser/tokens.js';
import type { Diagnostic } from './diagnostic.js';
import { basename } from 'node:path';

export interface Span { start: Position; end: Position; }

export interface MessageEmit {
    file: string;
    span: Span;
    typeString: string;
}

export interface MessageHandlerType {
    file: string;
    span: Span;
    typeString: string;
    // Body span of the enclosing if/else-if when the type-comparison is in
    // its test. Populated when discoverable; absent if the comparison is
    // outside an if-test (rare). Used by the flow tracer to find downstream
    // emits from the same handler arm.
    bodySpan?: Span;
}

export interface LsdAccess {
    file: string;
    span: Span;
    key: string;            // exact key, or "prefix*" pattern when concatenated with a var
    kind: 'write' | 'read' | 'delete';
    isPattern: boolean;     // true → key ends with '*' and matches any suffix
}

export interface ProjectGraph {
    emits: MessageEmit[];
    handlers: MessageHandlerType[];
    lsdAccesses: LsdAccess[];
    emitsByType: Map<string, MessageEmit[]>;
    handlersByType: Map<string, MessageHandlerType[]>;
    lsdWrites: LsdAccess[];
    lsdReads: LsdAccess[];
}

// --- Extraction ------------------------------------------------------------

export function buildProjectGraph(units: ScriptUnit[]): ProjectGraph {
    const emits: MessageEmit[] = [];
    const handlers: MessageHandlerType[] = [];
    const lsdAccesses: LsdAccess[] = [];

    for (const unit of units) {
        const consts = buildGlobalStringConstants(unit);
        extractEmits(unit, emits, consts);
        extractHandlers(unit, handlers);
        extractLsdAccesses(unit, lsdAccesses, consts);
    }

    return {
        emits, handlers, lsdAccesses,
        emitsByType: groupBy(emits, e => e.typeString),
        handlersByType: groupBy(handlers, h => h.typeString),
        lsdWrites: lsdAccesses.filter(a => a.kind === 'write'),
        lsdReads: lsdAccesses.filter(a => a.kind === 'read'),
    };
}

// Resolves identifier names referring to globals like `string KEY_X = "literal";` to
// their literal values. Used for LSD key extraction (LSL projects commonly name
// each key via a string constant) and JSON-object payload type extraction.
function buildGlobalStringConstants(unit: ScriptUnit): Map<string, string> {
    const map = new Map<string, string>();
    for (const g of unit.script.globals) {
        if (g.type !== 'string' || !g.initializer) continue;
        const init = unwrap(g.initializer);
        if (init.kind === 'StringLiteral') map.set(g.name.name, init.value);
    }
    return map;
}

const CHAT_DISPATCHERS = new Set([
    'llRegionSay', 'llRegionSayTo', 'llSay', 'llShout', 'llWhisper', 'llInstantMessage',
]);

// Pre-scans a handler body to classify its dispatch mode:
//   'link'    — contains an llMessageLinked call (regardless of any chat calls)
//   'chat'    — contains chat dispatchers but no llMessageLinked
//   'neither' — pure helper (no dispatch); JSON construction here is presumed for a caller
function classifyDispatch(body: any): 'link' | 'chat' | 'neither' {
    let sawLink = false;
    let sawChat = false;
    const visit = (n: any): void => {
        if (!n || typeof n !== 'object') return;
        if (n.kind === 'CallExpression' && n.callee?.kind === 'IdentifierExpression') {
            if (n.callee.name === 'llMessageLinked') sawLink = true;
            else if (CHAT_DISPATCHERS.has(n.callee.name)) sawChat = true;
        }
        for (const key of Object.keys(n)) {
            if (key === 'start' || key === 'end' || key === 'kind') continue;
            const v = (n as any)[key];
            if (Array.isArray(v)) v.forEach(visit);
            else if (v && typeof v === 'object') visit(v);
        }
    };
    visit(body);
    if (sawLink) return 'link';
    if (sawChat) return 'chat';
    return 'neither';
}

function extractEmits(unit: ScriptUnit, out: MessageEmit[], consts: Map<string, string>): void {
    // We extract at the JSON-construction site rather than the dispatch site, because
    // this codebase uses templates and branched assignments that defeat direct tracing.
    // But "JSON with a 'type' field" is ambiguous between link_messages and the
    // inter-prim chat protocols (leash holder, external HUD ACL, remote-scan...), so
    // we use the enclosing dispatch context to disambiguate:
    //
    //   - In a handler that dispatches via llMessageLinked → link_message emit
    //   - In a handler that dispatches only via chat (llRegionSay/llRegionSayTo/...) → skip
    //   - In a pure helper or global initializer → record (caller will dispatch)
    //
    // The `looksLikeType` filter (dotted identifier form) further excludes obvious
    // non-types.
    const recordJsons = (body: any) => {
        const visit = (n: any): void => {
            if (!n || typeof n !== 'object') return;
            if (n.kind === 'CallExpression'
                && n.callee?.kind === 'IdentifierExpression'
                && n.callee.name === 'llList2Json') {
                const t = extractTypeFromJsonObject(n, consts);
                if (t !== null && looksLikeType(t)) {
                    out.push({ file: unit.file, span: { start: n.start, end: n.end }, typeString: t });
                }
            }
            for (const key of Object.keys(n)) {
                if (key === 'start' || key === 'end' || key === 'kind') continue;
                const v = (n as any)[key];
                if (Array.isArray(v)) v.forEach(visit);
                else if (v && typeof v === 'object') visit(v);
            }
        };
        visit(body);
    };

    // Globals (template assignments at file scope): always record.
    for (const g of unit.script.globals) {
        if (g.initializer) recordJsons(g.initializer);
    }

    // Functions and event handlers: classify dispatch and record accordingly.
    const handle = (handler: any) => {
        const mode = classifyDispatch(handler.body);
        if (mode === 'chat') return;
        recordJsons(handler.body);
    };
    for (const fn of unit.script.functions) handle(fn);
    for (const st of unit.script.states) {
        for (const ev of st.events) handle(ev);
    }
}

// llList2Json(JSON_OBJECT, ["type", "<value>", ...]) — pull "<value>" out. The value
// may be a string literal or a global string constant (resolved via `consts`).
function extractTypeFromJsonObject(expr: any, consts: Map<string, string>): string | null {
    if (!expr || expr.kind !== 'CallExpression') return null;
    if (expr.callee?.kind !== 'IdentifierExpression' || expr.callee.name !== 'llList2Json') return null;
    if (expr.args.length < 2) return null;
    const tag = unwrap(expr.args[0]);
    if (tag.kind !== 'IdentifierExpression' || tag.name !== 'JSON_OBJECT') return null;
    const kv = unwrap(expr.args[1]);
    if (kv.kind !== 'ListLiteral') return null;
    for (let i = 0; i + 1 < kv.elements.length; i += 2) {
        const k = unwrap(kv.elements[i]);
        const v = unwrap(kv.elements[i + 1]);
        if (k.kind !== 'StringLiteral' || k.value !== 'type') continue;
        if (v.kind === 'StringLiteral') return v.value;
        if (v.kind === 'IdentifierExpression') {
            const resolved = consts.get(v.name);
            if (resolved !== undefined) return resolved;
        }
    }
    return null;
}

function extractHandlers(unit: ScriptUnit, out: MessageHandlerType[]): void {
    for (const state of unit.script.states) {
        for (const ev of state.events) {
            if (ev.name.name !== 'link_message') continue;

            // First pass: walk IfStatements to map literal-comparison spans
            // to their if-body spans. Used to enrich each handler entry
            // with the body the handler arm executes — the flow tracer
            // needs this to find downstream emits from this handler arm.
            const bodySpans = new Map<string, Span>();
            const ifVisit = (n: any): void => {
                if (!n || typeof n !== 'object') return;
                if (n.kind === 'IfStatement') {
                    const tv = (t: any): void => {
                        if (!t || typeof t !== 'object') return;
                        if (t.kind === 'BinaryExpression' && t.operator === '==') {
                            const lit = stringLiteralSide(t.left, t.right);
                            if (lit) {
                                const key = `${lit.start.line}:${lit.start.column}`;
                                bodySpans.set(key, { start: n.consequent.start, end: n.consequent.end });
                            }
                        }
                        for (const k of Object.keys(t)) {
                            if (k === 'start' || k === 'end' || k === 'kind') continue;
                            const v = (t as any)[k];
                            if (Array.isArray(v)) v.forEach(tv);
                            else if (v && typeof v === 'object') tv(v);
                        }
                    };
                    tv(n.test);
                }
                for (const k of Object.keys(n)) {
                    if (k === 'start' || k === 'end' || k === 'kind') continue;
                    const v = (n as any)[k];
                    if (Array.isArray(v)) v.forEach(ifVisit);
                    else if (v && typeof v === 'object') ifVisit(v);
                }
            };
            ifVisit(ev.body);

            // Second pass: collect every string-literal `==` comparison.
            // Enrich with bodySpan when one was discovered above.
            const visit = (n: any): void => {
                if (!n || typeof n !== 'object') return;
                if (n.kind === 'BinaryExpression' && n.operator === '==') {
                    const lit = stringLiteralSide(n.left, n.right);
                    if (lit && lit.value.length > 0 && looksLikeType(lit.value)) {
                        const key = `${lit.start.line}:${lit.start.column}`;
                        const handler: MessageHandlerType = {
                            file: unit.file,
                            span: { start: lit.start, end: lit.end },
                            typeString: lit.value,
                        };
                        const bs = bodySpans.get(key);
                        if (bs) handler.bodySpan = bs;
                        out.push(handler);
                    }
                }
                for (const key of Object.keys(n)) {
                    if (key === 'start' || key === 'end' || key === 'kind') continue;
                    const v = (n as any)[key];
                    if (Array.isArray(v)) v.forEach(visit);
                    else if (v && typeof v === 'object') visit(v);
                }
            };
            visit(ev.body);
        }
    }
}

function stringLiteralSide(a: any, b: any): { value: string; start: Position; end: Position } | null {
    const ua = unwrap(a);
    const ub = unwrap(b);
    if (ua.kind === 'StringLiteral') return { value: ua.value, start: ua.start, end: ua.end };
    if (ub.kind === 'StringLiteral') return { value: ub.value, start: ub.start, end: ub.end };
    return null;
}

// Filter: a message-type string almost always looks like "foo.bar" or "foo.bar.baz" —
// dotted, no spaces. Reject obvious non-types (sentences, single words like "yes").
function looksLikeType(s: string): boolean {
    if (s.includes(' ')) return false;
    if (s.length > 80) return false;
    return /^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$/i.test(s);
}

const LSD_OWNER_ANNOTATION_RE = /^\s*\/\/\s*@lsl-ide\s+lsd-owner\s*$/;
const LSD_OWNS_INLINE_RE = /^\s*\/\/\s*@lsl-ide\s+lsd-owns:\s*(.+?)\s*$/;
const LSD_OWNER_LOOKAHEAD_LINES = 5;

// Detects both LSD-owner annotation forms (see top-of-file docs). Form A
// (`@lsl-ide lsd-owner` above a list literal) and Form B (`@lsl-ide lsd-owns:`
// inline). Returns one entry per declared key, each with a span pointing at
// the annotation site so the synthetic write is attributable in diagnostics.
function findOwnedLsdKeys(unit: ScriptUnit): Array<{ key: string; span: Span }> {
    const result: Array<{ key: string; span: Span }> = [];
    const lines = unit.source.split('\n');

    // Form B — `@lsl-ide lsd-owns: key1, key2, ...`
    for (let i = 0; i < lines.length; i++) {
        const m = lines[i]!.match(LSD_OWNS_INLINE_RE);
        if (!m) continue;
        const lineNum = i + 1;
        const span: Span = {
            start: { line: lineNum, column: 1, offset: 0 },
            end: { line: lineNum, column: lines[i]!.length + 1, offset: 0 },
        };
        for (const part of m[1]!.split(',')) {
            const cleaned = part.trim().replace(/^["']|["']$/g, '');
            if (cleaned.length > 0) result.push({ key: cleaned, span });
        }
    }

    // Form A — `@lsl-ide lsd-owner` above a list literal
    const annotatedLines = new Set<number>();
    for (let i = 0; i < lines.length; i++) {
        if (LSD_OWNER_ANNOTATION_RE.test(lines[i]!)) annotatedLines.add(i + 1);
    }
    if (annotatedLines.size > 0) {
        for (const g of unit.script.globals) {
            if (g.type !== 'list' || !g.initializer) continue;
            const declLine = g.start.line;
            let annotated = false;
            for (const aLine of annotatedLines) {
                if (aLine < declLine && declLine - aLine <= LSD_OWNER_LOOKAHEAD_LINES) {
                    annotated = true;
                    break;
                }
            }
            if (!annotated) continue;
            const init = unwrap(g.initializer);
            if (init.kind !== 'ListLiteral') continue;
            for (const el of init.elements) {
                const e = unwrap(el);
                if (e.kind === 'StringLiteral') {
                    result.push({ key: e.value, span: { start: g.start, end: g.end } });
                }
            }
        }
    }

    return result;
}

// LSD access extraction with constant propagation. Resolves the key expression
// against three levels of context in order:
//   (1) Global string constants     (`string KEY = "literal";` at file scope)
//   (2) Local-variable assignments  (`string k = KEY;` then `llLinksetData...(k)`)
//   (3) Function parameters         (helper like `lsd_int(string key, ...)` called
//                                    elsewhere as `lsd_int(KEY_OWNER, ...)` — fans
//                                    out to one synthetic access per distinct
//                                    caller-site argument value)
//
// Dynamic origins that cannot be statically resolved (e.g. `string k =
// llList2String(parts, 1);` — a key parsed from runtime input) yield no access.
// For those, the script may declare itself the authoritative writer via the
// `// @lsl-ide lsd-owner` / `// @lsl-ide lsd-owns:` annotations documented above.
function extractLsdAccesses(unit: ScriptUnit, out: LsdAccess[], consts: Map<string, string>): void {
    const callSites = buildCallSitesIndex(unit);

    for (const fn of unit.script.functions) {
        processHandlerLsd(unit.file, fn, consts, callSites, out);
    }
    for (const st of unit.script.states) {
        for (const ev of st.events) {
            processHandlerLsd(unit.file, ev, consts, callSites, out);
        }
    }

    // Synthetic writes from @lsl-ide lsd-owner annotated lists.
    for (const { key, span } of findOwnedLsdKeys(unit)) {
        out.push({ file: unit.file, span, key, kind: 'write', isPattern: false });
    }
}

// Indexes every CallExpression whose callee is a simple identifier, by callee
// name. Used to find every call site of a user function so we can expand its
// parameters to literal values.
function buildCallSitesIndex(unit: ScriptUnit): Map<string, any[]> {
    const map = new Map<string, any[]>();
    const visit = (n: any): void => {
        if (!n || typeof n !== 'object') return;
        if (n.kind === 'CallExpression' && n.callee?.kind === 'IdentifierExpression') {
            const arr = map.get(n.callee.name);
            if (arr) arr.push(n);
            else map.set(n.callee.name, [n]);
        }
        for (const key of Object.keys(n)) {
            if (key === 'start' || key === 'end' || key === 'kind') continue;
            const v = (n as any)[key];
            if (Array.isArray(v)) v.forEach(visit);
            else if (v && typeof v === 'object') visit(v);
        }
    };
    visit(unit.script);
    return map;
}

// First-assignment-wins scan: for each local variable in a handler body, records
// the literal value from the FIRST `LocalVariable` initializer or
// `AssignmentExpression`. Later reassignments are ignored. Only string literals
// and global-constant identifiers resolve; dynamic RHS (function calls,
// expressions) is skipped.
function buildLocalConstants(handlerBody: any, consts: Map<string, string>): Map<string, string> {
    const locals = new Map<string, string>();
    const visit = (n: any): void => {
        if (!n || typeof n !== 'object') return;
        if (n.kind === 'LocalVariable' && n.initializer && !locals.has(n.name.name)) {
            const lit = resolveStaticLiteral(n.initializer, consts, locals);
            if (lit !== null) locals.set(n.name.name, lit);
        }
        if (n.kind === 'AssignmentExpression'
            && n.target?.kind === 'IdentifierExpression'
            && !locals.has(n.target.name)) {
            const lit = resolveStaticLiteral(n.value, consts, locals);
            if (lit !== null) locals.set(n.target.name, lit);
        }
        for (const key of Object.keys(n)) {
            if (key === 'start' || key === 'end' || key === 'kind') continue;
            const v = (n as any)[key];
            if (Array.isArray(v)) v.forEach(visit);
            else if (v && typeof v === 'object') visit(v);
        }
    };
    visit(handlerBody);
    return locals;
}

// For each parameter of a user function, find all call sites and gather the
// distinct literal values passed at that position. The result lets a single LSD
// access inside the function fan out to one synthetic record per resolved value.
function expandFunctionParameters(
    fn: any,
    callSites: Map<string, any[]>,
    consts: Map<string, string>,
): Map<string, string[]> {
    const map = new Map<string, string[]>();
    const sites = callSites.get(fn.name.name);
    if (!sites || sites.length === 0) return map;

    for (let pi = 0; pi < fn.params.length; pi++) {
        const param = fn.params[pi];
        const values = new Set<string>();
        for (const site of sites) {
            const arg = site.args[pi];
            if (!arg) continue;
            // Caller-site resolution: literal or global constant only.
            // Cross-handler local resolution would be the next step up; not
            // implemented to avoid chicken-and-egg with helper-of-helper chains.
            const lit = resolveStaticLiteral(arg, consts, null);
            if (lit !== null) values.add(lit);
        }
        if (values.size > 0) map.set(param.name.name, [...values]);
    }
    return map;
}

// Single-level literal resolver: StringLiteral, global constant, or (optionally)
// local-variable assignment within the current handler.
function resolveStaticLiteral(
    expr: any,
    consts: Map<string, string>,
    locals: Map<string, string> | null,
): string | null {
    const e = unwrap(expr);
    if (e.kind === 'StringLiteral') return e.value;
    if (e.kind === 'IdentifierExpression') {
        const g = consts.get(e.name);
        if (g !== undefined) return g;
        if (locals) {
            const l = locals.get(e.name);
            if (l !== undefined) return l;
        }
    }
    return null;
}

function processHandlerLsd(
    file: string,
    handler: any,
    consts: Map<string, string>,
    callSites: Map<string, any[]>,
    out: LsdAccess[],
): void {
    const locals = buildLocalConstants(handler.body, consts);
    const params = handler.kind === 'FunctionDeclaration'
        ? expandFunctionParameters(handler, callSites, consts)
        : new Map<string, string[]>();

    const visit = (n: any): void => {
        if (!n || typeof n !== 'object') return;
        if (n.kind === 'CallExpression' && n.callee?.kind === 'IdentifierExpression') {
            const fname = n.callee.name;
            let kind: LsdAccess['kind'] | null = null;
            if (fname === 'llLinksetDataWrite' || fname === 'llLinksetDataWriteProtected') kind = 'write';
            else if (fname === 'llLinksetDataRead' || fname === 'llLinksetDataReadProtected') kind = 'read';
            else if (fname === 'llLinksetDataDelete' || fname === 'llLinksetDataDeleteProtected') kind = 'delete';
            if (kind && n.args.length >= 1) {
                const resolved = extractLsdKeyFanout(unwrap(n.args[0]), consts, locals, params);
                for (const r of resolved) {
                    out.push({
                        file,
                        span: { start: n.start, end: n.end },
                        key: r.key,
                        kind,
                        isPattern: r.isPattern,
                    });
                }
            }
        }
        for (const key of Object.keys(n)) {
            if (key === 'start' || key === 'end' || key === 'kind') continue;
            const v = (n as any)[key];
            if (Array.isArray(v)) v.forEach(visit);
            else if (v && typeof v === 'object') visit(v);
        }
    };
    visit(handler.body);
}

// Returns ZERO or more resolved keys. Multiple keys appear only when the access
// is parametrised — e.g. a helper `lsd_int(string key, ...)` called from N
// different sites with N different literal keys fans out to N records.
function extractLsdKeyFanout(
    expr: any,
    consts: Map<string, string>,
    locals: Map<string, string>,
    params: Map<string, string[]>,
): Array<{ key: string; isPattern: boolean }> {
    if (expr.kind === 'StringLiteral') {
        return [{ key: expr.value, isPattern: false }];
    }
    if (expr.kind === 'IdentifierExpression') {
        const g = consts.get(expr.name);
        if (g !== undefined) return [{ key: g, isPattern: false }];
        const l = locals.get(expr.name);
        if (l !== undefined) return [{ key: l, isPattern: false }];
        const p = params.get(expr.name);
        if (p !== undefined) return p.map(k => ({ key: k, isPattern: false }));
    }
    if (expr.kind === 'BinaryExpression' && expr.operator === '+') {
        const left = resolveStaticLiteral(expr.left, consts, locals);
        const right = resolveStaticLiteral(expr.right, consts, locals);
        if (left !== null && right !== null) return [{ key: left + right, isPattern: false }];
        if (left !== null) return [{ key: left + '*', isPattern: true }];
        if (right !== null) return [{ key: '*' + right, isPattern: true }];
    }
    return [];
}

function unwrap(e: any): any {
    if (e && e.kind === 'ParenthesizedExpression') return unwrap(e.expression);
    return e;
}

function groupBy<T, K>(items: T[], keyFn: (t: T) => K): Map<K, T[]> {
    const m = new Map<K, T[]>();
    for (const item of items) {
        const k = keyFn(item);
        const arr = m.get(k);
        if (arr) arr.push(item);
        else m.set(k, [item]);
    }
    return m;
}

// --- Cross-script rules ----------------------------------------------------

export function runCrossScriptRules(graph: ProjectGraph): Diagnostic[] {
    const out: Diagnostic[] = [];
    out.push(...xsl001OrphanEmit(graph));
    out.push(...xsl002DeadHandler(graph));
    out.push(...xsl003LsdConflict(graph));
    out.push(...xsl004OrphanRead(graph));
    return out;
}

// XSL001: a link_message type is emitted but no script in the project handles it.
function xsl001OrphanEmit(graph: ProjectGraph): Diagnostic[] {
    const out: Diagnostic[] = [];
    for (const [type, emits] of graph.emitsByType) {
        if (graph.handlersByType.has(type)) continue;
        for (const e of emits) {
            out.push({
                ruleId: 'XSL001',
                category: 'Lint warning',
                severity: 'warning',
                file: e.file,
                start: e.span.start,
                end: e.span.end,
                message: `link_message type "${type}" is emitted here but no script in the project handles it — dead emit or missing handler`,
            });
        }
    }
    return out;
}

// XSL002: a link_message handler checks for a type that no script ever emits.
function xsl002DeadHandler(graph: ProjectGraph): Diagnostic[] {
    const out: Diagnostic[] = [];
    for (const [type, handlers] of graph.handlersByType) {
        if (graph.emitsByType.has(type)) continue;
        for (const h of handlers) {
            out.push({
                ruleId: 'XSL002',
                category: 'Lint warning',
                severity: 'warning',
                file: h.file,
                start: h.span.start,
                end: h.span.end,
                message: `link_message type "${type}" is handled here but no script in the project emits it — dead branch or stale code`,
            });
        }
    }
    return out;
}

// XSL003: an LSD key is written by more than one script (potential ownership conflict).
// We only flag LITERAL key conflicts — pattern keys (`prefix*` from `"prefix" + var`)
// commonly have per-script unique suffixes (e.g. each plugin writes `plugin.reg.<own_ctx>`),
// so grouping by the prefix alone produces false positives. Pattern-key conflicts can
// only be assessed with constant resolution, which we defer.
function xsl003LsdConflict(graph: ProjectGraph): Diagnostic[] {
    const out: Diagnostic[] = [];
    const literalWrites = graph.lsdWrites.filter(w => !w.isPattern);
    const writesByKey = groupBy(literalWrites, w => w.key);
    for (const [key, writes] of writesByKey) {
        const distinctFiles = new Set(writes.map(w => w.file));
        if (distinctFiles.size < 2) continue;
        const others = [...distinctFiles];
        for (const w of writes) {
            const co = others.filter(f => f !== w.file).map(f => basename(f));
            out.push({
                ruleId: 'XSL003',
                category: 'Lint warning',
                severity: 'warning',
                file: w.file,
                start: w.span.start,
                end: w.span.end,
                message: `LSD key "${key}" is also written by: ${co.join(', ')} — coordinate ownership or rename`,
            });
        }
    }
    return out;
}

// XSL004: an LSD key is read but no script writes it. Pattern reads (prefix*) are
// satisfied by any matching write.
function xsl004OrphanRead(graph: ProjectGraph): Diagnostic[] {
    const out: Diagnostic[] = [];
    const writePatterns = graph.lsdWrites.map(w => w.key);

    for (const r of graph.lsdReads) {
        if (anyWriteMatches(r.key, writePatterns)) continue;
        out.push({
            ruleId: 'XSL004',
            category: 'Lint warning',
            severity: 'warning',
            file: r.file,
            start: r.span.start,
            end: r.span.end,
            message: `LSD key "${r.key}" is read here but no script in the project writes it — typo or missing producer`,
        });
    }
    return out;
}

// Pattern match: `prefix*` writes match any read of `prefix...` (and vice versa).
function anyWriteMatches(readKey: string, writeKeys: string[]): boolean {
    for (const wk of writeKeys) {
        if (wk === readKey) return true;
        if (wk.endsWith('*') && readKey.startsWith(wk.slice(0, -1))) return true;
        if (readKey.endsWith('*') && wk.startsWith(readKey.slice(0, -1))) return true;
        if (wk.startsWith('*') && readKey.endsWith(wk.slice(1))) return true;
        if (readKey.startsWith('*') && wk.endsWith(readKey.slice(1))) return true;
    }
    return false;
}
