// Mono heap upper-bound estimator for LSL scripts.
//
// LSL's Mono VM gives each script ~64 KB total (65536 bytes). This estimator produces a
// conservative *static* estimate intended to flag scripts approaching the cliff before
// they crash in-world.
//
// Three components contribute:
//   1. data         — globals + worst-case locals (function/event frames)
//   2. bytecode     — compiled IL: per-statement, per-expression, string-literal pool
//   3. base         — fixed Mono runtime/dispatch overhead per script
//
// All cost constants below are TUNABLE and intended to be calibrated against real
// `llGetUsedMemory()` readings. Initial values are best-guess based on community lore
// (empty default-state script ≈ 2.5–3 KB, medium script ≈ 25–45 KB). Expect ±25% drift
// until calibrated. See bottom of file for the calibration TODO.

import type { Script, Expression, GlobalVariable, FunctionDeclaration, StateDeclaration, LslType } from '../parser/ast.js';

export const MEMORY_LIMIT_BYTES = 65536;
export const MEMORY_WARN_BYTES = 49152;   // 75% — "heavy, monitor growth"
export const MEMORY_ERROR_BYTES = 62259;  // 95% — "truly on the cliff; any growth crashes".
// Mono LSL scripts have been observed to run at ≥98% used memory in-world without
// crashing as long as nothing transient pushes them over 64 KB. The 95% error
// threshold is intentionally tight; the 75–95% band is the actionable "watch this
// before it becomes a crisis" zone.

// --- Data costs (per-value, bytes) ---

const TYPE_BASE_BYTES: Record<LslType, number> = {
    integer: 4,
    float: 4,
    vector: 12,
    rotation: 16,
    key: 53,        // 36-char UUID + ~17B string header
    string: 32,     // default for strings without an initializer hint
    list: 32,       // empty-list overhead; per-element cost added separately
};

const PER_LIST_ELEMENT_OVERHEAD = 8;
const PER_FUNCTION_FRAME_OVERHEAD = 32;
const PER_STATE_OVERHEAD = 16;

// --- Bytecode costs (per-AST-node, bytes of compiled IL) ---

const BYTECODE = {
    perStatement: 28,
    perExpression: 6,           // base cost per expression node
    perCall: 22,                // additional, on top of perExpression. See CALIBRATION below.
    perStringLiteralBase: 24,   // intern table overhead per unique string
    perStringLiteralChar: 1,
    perListElement: 6,
    perFunction: 128,           // function metadata + dispatch
    perEventHandler: 192,       // event registration is heavier than a plain function
    perState: 384,              // state metadata + transition table
    baseRuntime: 2048,          // Mono runtime, VM pointers, dispatch table
};

// CALIBRATION HISTORY
// The constants above were initially derived from LSL community lore (empty default
// state ≈ 2.6 KB, medium script ≈ 25–45 KB) and then refined against 3 in-world
// `llGetUsedMemory()` readings from one real codebase (2026-05-10), spread across
// ~27 KB / ~49 KB / ~64 KB sizes. The fit found that builtin-dispatch cost scales
// super-linearly with script complexity — calls/statement ratio rose from 0.36 in
// the smallest script to 0.57 in the largest — so `perCall` was bumped 12 → 22.
// That brought max drift from 10% to ~6% across the three reference readings.
//
// Expect ±20–25% drift for codebases very different from the reference set (heavy
// list manipulation, long string pools, deep recursion). To recalibrate for your
// project: run `lsl-ide --mem-detail <file.lsl>` to dump bytecode-component counts,
// take `llGetUsedMemory()` readings for 3+ scripts spanning your size range, and
// fit `perCall` / `perStatement` / `perStringLiteralBase` to minimize squared error.

export interface BytecodeBreakdown {
    counts: {
        statements: number;
        expressions: number;
        calls: number;
        listElements: number;
        functions: number;
        events: number;
        states: number;
        uniqueStrings: number;
        totalStringChars: number;
    };
    bytes: {
        statements: number;
        expressions: number;
        calls: number;
        listElements: number;
        functions: number;
        events: number;
        states: number;
        stringPool: number;
    };
    totalBytes: number;
}

export interface MemoryEstimate {
    globalsBytes: number;
    functionsBytes: number;
    statesBytes: number;
    bytecodeBytes: number;
    baseBytes: number;
    totalBytes: number;
    bytecode: BytecodeBreakdown;
    breakdown: {
        globals: Array<{ name: string; type: LslType; bytes: number }>;
        functions: Array<{ name: string; bytes: number }>;
        states: Array<{ name: string; bytes: number }>;
    };
}

export function estimateScriptMemory(script: Script): MemoryEstimate {
    const globalRows = script.globals.map(estimateGlobal);
    const globalsBytes = sum(globalRows.map(r => r.bytes));

    const fnRows = script.functions.map(estimateFunction);
    const functionsBytes = sum(fnRows.map(r => r.bytes));

    const stateRows = script.states.map(estimateState);
    const statesBytes = sum(stateRows.map(r => r.bytes));

    const bytecode = estimateBytecodeBreakdown(script);
    const bytecodeBytes = bytecode.totalBytes;
    const baseBytes = BYTECODE.baseRuntime;
    const totalBytes = globalsBytes + functionsBytes + statesBytes + bytecodeBytes + baseBytes;

    return {
        globalsBytes, functionsBytes, statesBytes, bytecodeBytes, baseBytes, totalBytes,
        bytecode,
        breakdown: { globals: globalRows, functions: fnRows, states: stateRows },
    };
}

// Walks the entire AST counting nodes by category, then multiplies by the BYTECODE cost
// table. Strings are deduped by literal text — Mono interns them so the same literal
// appearing in N places only costs once.
export function estimateBytecodeBreakdown(script: Script): BytecodeBreakdown {
    let stmts = 0;
    let exprs = 0;
    let calls = 0;
    let listElements = 0;
    let functions = 0;
    let events = 0;
    let states = 0;
    const internedStrings = new Set<string>();

    const visit = (n: any): void => {
        if (!n || typeof n !== 'object') return;
        switch (n.kind) {
            case 'FunctionDeclaration': functions += 1; break;
            case 'EventHandler': events += 1; break;
            case 'StateDeclaration': states += 1; break;
            case 'StringLiteral': internedStrings.add(n.value); break;
            case 'CallExpression': calls += 1; break;
        }
        // Statement and expression tallies — discriminated by kind suffix patterns.
        if (isStatementKind(n.kind)) stmts += 1;
        if (isExpressionKind(n.kind)) exprs += 1;
        if (n.kind === 'ListLiteral') listElements += n.elements.length;

        for (const key of Object.keys(n)) {
            if (key === 'start' || key === 'end' || key === 'kind') continue;
            const v = (n as any)[key];
            if (Array.isArray(v)) v.forEach(visit);
            else if (v && typeof v === 'object') visit(v);
        }
    };
    visit(script);

    let stringPool = 0;
    let totalChars = 0;
    for (const s of internedStrings) {
        stringPool += BYTECODE.perStringLiteralBase + s.length * BYTECODE.perStringLiteralChar;
        totalChars += s.length;
    }

    const bytes = {
        statements: stmts * BYTECODE.perStatement,
        expressions: exprs * BYTECODE.perExpression,
        calls: calls * BYTECODE.perCall,
        listElements: listElements * BYTECODE.perListElement,
        functions: functions * BYTECODE.perFunction,
        events: events * BYTECODE.perEventHandler,
        states: states * BYTECODE.perState,
        stringPool,
    };

    const totalBytes = bytes.statements + bytes.expressions + bytes.calls + bytes.listElements
        + bytes.functions + bytes.events + bytes.states + bytes.stringPool;

    return {
        counts: {
            statements: stmts, expressions: exprs, calls, listElements,
            functions, events, states,
            uniqueStrings: internedStrings.size, totalStringChars: totalChars,
        },
        bytes,
        totalBytes,
    };
}

const STATEMENT_KINDS = new Set([
    'Block', 'LocalVariable', 'ExpressionStatement', 'IfStatement', 'WhileStatement',
    'DoWhileStatement', 'ForStatement', 'JumpStatement', 'LabelStatement',
    'ReturnStatement', 'StateChangeStatement', 'EmptyStatement',
]);
const EXPRESSION_KINDS = new Set([
    'IntegerLiteral', 'FloatLiteral', 'StringLiteral', 'IdentifierExpression',
    'UnaryExpression', 'PostfixExpression', 'BinaryExpression', 'AssignmentExpression',
    'CallExpression', 'IndexExpression', 'MemberExpression',
    'VectorLiteral', 'RotationLiteral', 'ListLiteral',
    'CastExpression', 'TernaryExpression', 'ParenthesizedExpression',
]);
function isStatementKind(k: string): boolean { return STATEMENT_KINDS.has(k); }
function isExpressionKind(k: string): boolean { return EXPRESSION_KINDS.has(k); }

function estimateGlobal(g: GlobalVariable): { name: string; type: LslType; bytes: number } {
    let bytes = TYPE_BASE_BYTES[g.type];
    // For strings/lists, refine using initializer if available.
    if (g.initializer) {
        if (g.type === 'string' && g.initializer.kind === 'StringLiteral') {
            // Mono strings: ~17B header + 1B per char (UTF-8 lower bound).
            bytes = 17 + g.initializer.value.length;
        } else if (g.type === 'list' && g.initializer.kind === 'ListLiteral') {
            bytes = TYPE_BASE_BYTES.list + g.initializer.elements.length * PER_LIST_ELEMENT_OVERHEAD
                + sum(g.initializer.elements.map(estimateExpressionSize));
        }
    }
    return { name: g.name.name, type: g.type, bytes };
}

function estimateFunction(fn: FunctionDeclaration): { name: string; bytes: number } {
    // Frame overhead + sum of declared local sizes. Locals only live during a call, but for a
    // worst-case static bound we include them — they're what eats stack at deepest call point.
    const localsBytes = sumLocalSizes(fn.body);
    const paramsBytes = sum(fn.params.map(p => TYPE_BASE_BYTES[p.type]));
    return { name: fn.name.name, bytes: PER_FUNCTION_FRAME_OVERHEAD + localsBytes + paramsBytes };
}

function estimateState(st: StateDeclaration): { name: string; bytes: number } {
    let bytes = PER_STATE_OVERHEAD;
    for (const ev of st.events) {
        bytes += PER_FUNCTION_FRAME_OVERHEAD;
        bytes += sum(ev.params.map(p => TYPE_BASE_BYTES[p.type]));
        bytes += sumLocalSizes(ev.body);
    }
    return { name: st.name.name, bytes };
}

function sumLocalSizes(node: any): number {
    let total = 0;
    const visit = (n: any): void => {
        if (!n || typeof n !== 'object') return;
        if (n.kind === 'LocalVariable') {
            total += TYPE_BASE_BYTES[n.type as LslType];
            // Refine string/list locals from initializer if present.
            if (n.type === 'string' && n.initializer?.kind === 'StringLiteral') {
                total -= TYPE_BASE_BYTES.string;
                total += 17 + n.initializer.value.length;
            } else if (n.type === 'list' && n.initializer?.kind === 'ListLiteral') {
                total -= TYPE_BASE_BYTES.list;
                total += TYPE_BASE_BYTES.list + n.initializer.elements.length * PER_LIST_ELEMENT_OVERHEAD;
            }
        }
        for (const key of Object.keys(n)) {
            if (key === 'start' || key === 'end' || key === 'kind') continue;
            const v = (n as any)[key];
            if (Array.isArray(v)) v.forEach(visit);
            else if (v && typeof v === 'object') visit(v);
        }
    };
    visit(node);
    return total;
}

// Conservative size for a value produced by an expression — used inside list literals.
function estimateExpressionSize(e: Expression): number {
    switch (e.kind) {
        case 'IntegerLiteral': return 4;
        case 'FloatLiteral': return 4;
        case 'StringLiteral': return 17 + e.value.length;
        case 'VectorLiteral': return 12;
        case 'RotationLiteral': return 16;
        case 'ListLiteral':
            return TYPE_BASE_BYTES.list + e.elements.length * PER_LIST_ELEMENT_OVERHEAD
                + sum(e.elements.map(estimateExpressionSize));
        default: return 16;
    }
}

function sum(xs: number[]): number {
    let s = 0;
    for (const x of xs) s += x;
    return s;
}

// TODO(memory): calibrate the BYTECODE and TYPE_BASE_BYTES constants against real
// `llGetUsedMemory()` readings. Workflow: take 5+ scripts of varying size, record actual
// in-world memory, run `lsl-ide` on the same files, then solve for the per-AST-node cost
// constants that minimize squared error. Current numbers are guesses calibrated only against
// "empty default state ≈ 2.6 KB" and "medium script ≈ 25–45 KB" lore.
