#!/usr/bin/env node
import { readFileSync, statSync, readdirSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { Lexer, LexerError } from './parser/lexer.js';
import { Parser } from './parser/parser.js';
import { runRules } from './analyzer/runner.js';
import { formatDiagnostic, formatDiagnosticVerbose, Diagnostic } from './analyzer/diagnostic.js';
import { estimateScriptMemory, MEMORY_LIMIT_BYTES } from './memory/estimator.js';
import { loadScriptUnit, ScriptUnit } from './analyzer/project.js';
import { buildProjectGraph, runCrossScriptRules } from './analyzer/cross-script.js';
import { traceFlow, formatFlowTrace } from './analyzer/flow-trace.js';
import { extractStateGraph, formatStateGraphText, formatStateGraphMermaid } from './analyzer/state-graph.js';

interface CliOptions {
    files: string[];
    info: boolean;
    verbose: boolean;     // include col + rule ID in output
    memDetail: boolean;   // dump bytecode-component breakdown for calibration
    graphStats: boolean;  // dump project graph counts for cross-script debugging
    traceEmit: string;    // type-string to flow-trace through the project graph
    traceDepth: number;   // max depth for flow trace
    stateGraph: 'text' | 'mermaid' | '';  // dump state graph for each file
    enable: Set<string>;  // rule IDs to enable (overrides defaultEnabled=false)
    disable: Set<string>; // rule IDs to disable (overrides defaultEnabled=true)
}

function parseArgs(argv: string[]): CliOptions {
    const opts: CliOptions = {
        files: [], info: true, verbose: false, memDetail: false, graphStats: false,
        traceEmit: '', traceDepth: 5, stateGraph: '',
        enable: new Set(), disable: new Set(),
    };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i]!;
        if (a === '--no-info') opts.info = false;
        else if (a === '--verbose' || a === '-v') opts.verbose = true;
        else if (a === '--mem-detail') opts.memDetail = true;
        else if (a === '--graph-stats') opts.graphStats = true;
        else if (a === '--trace-emit') {
            const next = argv[++i];
            if (next) opts.traceEmit = next;
        }
        else if (a === '--trace-depth') {
            const next = argv[++i];
            if (next) opts.traceDepth = parseInt(next, 10) || 5;
        }
        else if (a === '--state-graph') {
            opts.stateGraph = 'text';
        }
        else if (a === '--state-graph-mermaid') {
            opts.stateGraph = 'mermaid';
        }
        else if (a === '--enable') {
            const next = argv[++i];
            if (next) for (const id of next.split(',')) opts.enable.add(id.trim());
        }
        else if (a === '--disable') {
            const next = argv[++i];
            if (next) for (const id of next.split(',')) opts.disable.add(id.trim());
        }
        else if (a === '--help' || a === '-h') { printHelp(); process.exit(0); }
        else opts.files.push(a);
    }
    return opts;
}

function printHelp(): void {
    process.stdout.write(
        'lsl-ide — LSL static analyzer, memory estimator, and cross-script graph\n\n' +
        'Usage: lsl-ide [options] <file_or_dir> [<file_or_dir> ...]\n\n' +
        'Options:\n' +
        '  --no-info             suppress info-level diagnostics\n' +
        '  -v, --verbose         include column + rule ID in output\n' +
        '  --enable  <ID[,ID]>   turn ON a rule that is OFF by default (e.g. LSL016)\n' +
        '  --disable <ID[,ID]>   turn OFF a rule that is ON by default\n' +
        '  --mem-detail          dump per-component bytecode breakdown (for calibration)\n' +
        '  --graph-stats         dump cross-script graph counts (for debugging)\n' +
        '  --trace-emit <type>   flow-trace a link_message type through the project graph\n' +
        '                        (handlers + downstream emits, depth-bounded)\n' +
        '  --trace-depth <N>     max depth for --trace-emit (default 5)\n' +
        '  --state-graph         dump per-file state graph (text format)\n' +
        '  --state-graph-mermaid dump per-file state graph as Mermaid stateDiagram-v2\n' +
        '  -h, --help            this message\n\n' +
        'General LSL rules (default-on, applicable to any LSL project):\n' +
        '  Syntax / naming\n' +
        '    LSL001  reserved identifier used as a name\n' +
        '    LSL002  ternary operator (?:) — not supported by LSL\n' +
        '    LSL003  switch / case / break / continue — not supported by LSL\n' +
        '    LSL004  user function name with reserved `ll` prefix\n' +
        '    LSL005  local shadows another local or parameter in same function\n' +
        '    LSL011  global referenced before its declaration line\n' +
        '  Events / listeners / resources\n' +
        '    LSL013  llListen with no matching llListenRemove anywhere\n' +
        '    LSL015  llJsonGetValue result never checked against JSON_INVALID\n' +
        '    LSL017  llRequestPermissions with no run_time_permissions handler\n' +
        '    LSL018  llListen with open id filter (NULL_KEY / empty)\n' +
        '    LSL020  state change inside state_exit (silently ignored by Mono)\n' +
        '    LSL023  llSetTimerEvent with non-zero arg inside timer() (re-arm)\n' +
        '    LSL024  effects (particles / animations / sounds) started but not stopped\n' +
        '    LSL047  llHTTPRequest with no http_response handler\n' +
        '    LSL048  llSensor / llSensorRepeat with no sensor / no_sensor handler\n' +
        '    LSL049  changed() handler does not reference CHANGED_OWNER\n' +
        '  Control flow\n' +
        '    LSL021  unreachable code after return / jump / state change\n' +
        '    LSL029  user function calls itself directly (Mono stack pressure)\n' +
        '    LSL031  non-void function can fall off end without an explicit return\n' +
        '  Memory / heap\n' +
        '    LSL025  Mono memory estimate (info <75%, warn 75–95%, error >95% of 64 KB)\n' +
        '    LSL027  global list/string grows but is never reset (potential leak)\n' +
        '    LSL028  list/string concatenation inside a loop (O(n²))\n' +
        '  Types\n' +
        '    LSL026  literal type mismatch in declaration (e.g. integer x = "foo")\n' +
        '    LSL030  undeclared identifier (not a global, function, param, local, or builtin)\n' +
        '    LSL034  function call passes wrong number of arguments\n' +
        '    LSL035  function call passes argument of statically-wrong type\n' +
        '  State machines\n' +
        '    LSL040  `state X;` from within state X is a no-op (acts as return)\n' +
        '    LSL041  `state X;` inside a user function — transition deferred\n' +
        '    LSL042  state declared but no transition into it (unreachable)\n' +
        '    LSL043  state has no state_entry handler in a multi-state script\n' +
        '    LSL044  state opens llListen but no listen() handler in same state\n' +
        '    LSL045  state arms llSetTimerEvent but no timer() handler in same state\n' +
        '    LSL046  at_target / not_at_target declared but no llTarget call exists\n\n' +
        'Cross-script rules (run when 2+ files are passed):\n' +
        '    XSL001  link_message type emitted but no script handles it\n' +
        '    XSL002  link_message type handled but no script emits it\n' +
        '    XSL003  LSD key written by more than one script (ownership conflict)\n' +
        '    XSL004  LSD key read but no script writes it\n\n' +
        'Opt-in rules (project-convention; OFF by default):\n' +
        '    LSL016  llOwnerSay with literal not starting with @\n' +
        '            (only for projects reserving llOwnerSay exclusively for RLV)\n\n' +
        'Annotations recognized in LSL source comments:\n' +
        '  // @lsl-ide lsd-owner          on the line above a global list of\n' +
        '                                  string literals: this script owns those keys\n' +
        '  // @lsl-ide lsd-owns: a, b, c   inline form, no runtime variable needed\n\n' +
        'Output formats:\n' +
        '  Default:    file.lsl:line: Category - description\n' +
        '  Verbose:    file.lsl:line:col: Category [RULE] - description\n'
    );
}

function lintFile(file: string, info: boolean, ruleOpts: { enable: Set<string>; disable: Set<string> }): { diagnostics: Diagnostic[]; failed: boolean } {
    const absPath = resolve(file);
    let source: string;
    try {
        source = readFileSync(absPath, 'utf8');
    } catch (e) {
        return {
            diagnostics: [{
                category: 'I/O error',
                severity: 'error',
                message: `cannot read file: ${(e as Error).message}`,
                file,
                start: { line: 1, column: 1, offset: 0 },
                end: { line: 1, column: 1, offset: 0 },
            }],
            failed: true,
        };
    }

    let tokens;
    try {
        tokens = Lexer.lex(source);
    } catch (e) {
        if (e instanceof LexerError) {
            return {
                diagnostics: [{
                    category: 'Lexer error',
                    severity: 'error',
                    message: e.message,
                    file,
                    start: e.position,
                    end: e.position,
                }],
                failed: true,
            };
        }
        throw e;
    }

    const { script, diagnostics: parseDiags } = Parser.parse(tokens);
    const all: Diagnostic[] = parseDiags.map(d => ({
        category: d.category,
        severity: d.severity,
        message: d.message,
        file,
        start: d.start,
        end: d.end,
    }));
    all.push(...runRules({ file, source, tokens, script }, ruleOpts));

    const filtered = info ? all : all.filter(d => d.severity !== 'info');
    return { diagnostics: filtered, failed: filtered.some(d => d.severity === 'error') };
}

// Expand directory args into the list of *.lsl files within. Non-directory args pass
// through unchanged. Returns the flattened, deduplicated file list.
function expandPaths(paths: string[]): string[] {
    const out: string[] = [];
    const seen = new Set<string>();
    for (const p of paths) {
        const abs = resolve(p);
        let stat;
        try { stat = statSync(abs); } catch { continue; }
        if (stat.isDirectory()) {
            for (const entry of readdirSync(abs)) {
                if (!entry.endsWith('.lsl')) continue;
                const full = join(abs, entry);
                if (!seen.has(full)) { seen.add(full); out.push(full); }
            }
        } else {
            if (!seen.has(abs)) { seen.add(abs); out.push(abs); }
        }
    }
    return out;
}

function main(): void {
    const argv = process.argv.slice(2);
    const opts = parseArgs(argv);
    if (opts.files.length === 0) {
        printHelp();
        process.exit(64);
    }

    const expanded = expandPaths(opts.files);
    if (expanded.length === 0) {
        process.stderr.write('No .lsl files found at given paths.\n');
        process.exit(64);
    }

    const fmt = opts.verbose ? formatDiagnosticVerbose : formatDiagnostic;
    let anyFailed = false;
    const units: ScriptUnit[] = [];

    for (const file of expanded) {
        if (opts.memDetail) {
            printMemDetail(file);
            continue;
        }
        if (opts.stateGraph) {
            printStateGraph(file, opts.stateGraph);
            continue;
        }
        const { diagnostics, failed } = lintFile(file, opts.info, { enable: opts.enable, disable: opts.disable });
        for (const d of diagnostics) {
            process.stdout.write(fmt(d) + '\n');
        }
        if (failed) anyFailed = true;
        // Re-parse for cross-script analysis only if we have multiple files.
        // (lintFile already parsed, but doesn't return the unit — small re-parse cost.)
    }

    // Cross-script pass: only when multiple files in scope.
    if (!opts.memDetail && expanded.length >= 2) {
        for (const file of expanded) {
            try { units.push(loadScriptUnit(file)); } catch { /* already reported by lintFile */ }
        }
        const graph = buildProjectGraph(units);
        if (opts.graphStats) {
            process.stdout.write(`\n=== PROJECT GRAPH (${units.length} scripts) ===\n`);
            process.stdout.write(`link_message emits:    ${graph.emits.length} (${graph.emitsByType.size} unique types)\n`);
            process.stdout.write(`link_message handlers: ${graph.handlers.length} (${graph.handlersByType.size} unique types)\n`);
            process.stdout.write(`LSD writes:            ${graph.lsdWrites.length}\n`);
            process.stdout.write(`LSD reads:             ${graph.lsdReads.length}\n`);
            const sampleEmits = [...graph.emitsByType.keys()].slice(0, 8);
            const sampleHandlers = [...graph.handlersByType.keys()].slice(0, 8);
            process.stdout.write(`sample emit types:    ${sampleEmits.join(', ')}\n`);
            process.stdout.write(`sample handler types: ${sampleHandlers.join(', ')}\n`);
        }
        const crossDiags = runCrossScriptRules(graph);
        const filtered = opts.info ? crossDiags : crossDiags.filter(d => d.severity !== 'info');
        for (const d of filtered) process.stdout.write(fmt(d) + '\n');
        if (filtered.some(d => d.severity === 'error')) anyFailed = true;

        if (opts.traceEmit) {
            const trace = traceFlow(graph, units, opts.traceEmit, opts.traceDepth);
            process.stdout.write('\n' + formatFlowTrace(trace, opts.traceEmit) + '\n');
        }
    }

    process.exit(anyFailed ? 1 : 0);
}

function printStateGraph(file: string, format: 'text' | 'mermaid'): void {
    const source = readFileSync(resolve(file), 'utf8');
    const tokens = Lexer.lex(source);
    const { script } = Parser.parse(tokens);
    const graph = extractStateGraph(script);
    process.stdout.write(`\n=== ${file} ===\n`);
    if (format === 'mermaid') {
        process.stdout.write(formatStateGraphMermaid(graph) + '\n');
    } else {
        process.stdout.write(formatStateGraphText(graph) + '\n');
    }
}

function printMemDetail(file: string): void {
    const source = readFileSync(resolve(file), 'utf8');
    const tokens = Lexer.lex(source);
    const { script } = Parser.parse(tokens);
    const est = estimateScriptMemory(script);
    const c = est.bytecode.counts;
    const b = est.bytecode.bytes;
    process.stdout.write(`\n${file}\n`);
    process.stdout.write(`  data:    globals=${est.globalsBytes}B  fn-stack=${est.functionsBytes}B  states=${est.statesBytes}B\n`);
    process.stdout.write(`  base:    ${est.baseBytes}B\n`);
    process.stdout.write(`  bytecode breakdown (counts → bytes):\n`);
    process.stdout.write(`    statements:    ${pad(c.statements, 5)} → ${b.statements}B\n`);
    process.stdout.write(`    expressions:   ${pad(c.expressions, 5)} → ${b.expressions}B\n`);
    process.stdout.write(`    calls:         ${pad(c.calls, 5)} → ${b.calls}B\n`);
    process.stdout.write(`    listElements:  ${pad(c.listElements, 5)} → ${b.listElements}B\n`);
    process.stdout.write(`    functions:     ${pad(c.functions, 5)} → ${b.functions}B\n`);
    process.stdout.write(`    events:        ${pad(c.events, 5)} → ${b.events}B\n`);
    process.stdout.write(`    states:        ${pad(c.states, 5)} → ${b.states}B\n`);
    process.stdout.write(`    stringPool:    ${pad(c.uniqueStrings, 5)} unique (${c.totalStringChars} chars) → ${b.stringPool}B\n`);
    process.stdout.write(`  bytecode total: ${est.bytecodeBytes}B\n`);
    process.stdout.write(`  TOTAL: ${est.totalBytes}B / ${MEMORY_LIMIT_BYTES}B\n`);
}

function pad(n: number, width: number): string {
    const s = String(n);
    return s.length >= width ? s : ' '.repeat(width - s.length) + s;
}

main();
