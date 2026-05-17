// Cross-script flow tracer. Given a starting link_message type, walks
// the emit-handler graph: for each handler of the type, finds outgoing
// emits within the handler arm AND within helper functions transitively
// called from that arm, queues those types for the next depth, returns
// a flat list of (type, handlers, outgoing) records.
//
// Why callgraph traversal: handlers in real LSL projects routinely
// dispatch to helper functions (`requestAclForAction(...)`, `claimLeash(...)`,
// etc.) where the actual `llMessageLinked` lives. Tracing only direct
// emits in the if-body would miss most of the IPC graph.
//
// Cycle detection: each *type* is processed at most once across the
// trace; subsequent occurrences are marked `cycle: true`. Function
// callgraph cycles are also broken via a per-handler visited set.
//
// Depth limit: prevents runaway traversal. Default 5; usually plenty.

import type { ProjectGraph, MessageHandlerType, Span } from './cross-script.js';
import type { Position } from '../parser/tokens.js';
import type { ScriptUnit } from './project.js';

export interface FlowHandlerInfo {
    file: string;
    span: Span;            // span of the type-literal in the if-test
    bodySpan?: Span;       // span of the if-body (when discoverable)
    outgoing: string[];    // unique downstream type strings (direct + via helpers)
}

export interface FlowNode {
    type: string;
    depth: number;
    handlers: FlowHandlerInfo[];
    cycle?: boolean;       // true → already traced earlier in this trace
}

export function traceFlow(
    graph: ProjectGraph,
    units: ScriptUnit[],
    startType: string,
    maxDepth: number = 5,
): FlowNode[] {
    const visited = new Set<string>();
    const queue: Array<{ type: string; depth: number }> = [{ type: startType, depth: 0 }];
    const result: FlowNode[] = [];

    while (queue.length) {
        const { type, depth } = queue.shift()!;

        if (visited.has(type)) {
            result.push({ type, depth, handlers: [], cycle: true });
            continue;
        }
        visited.add(type);

        const rawHandlers = graph.handlersByType.get(type) || [];
        const handlers: FlowHandlerInfo[] = rawHandlers.map(h => buildHandlerInfo(graph, units, h));

        result.push({ type, depth, handlers });

        if (depth < maxDepth) {
            // Always queue; cycle is detected on dequeue via the visited
            // check above. Pre-checking here would silently skip self-loops
            // (handler emits its own type), losing the cycle marker.
            for (const hi of handlers) {
                for (const t of hi.outgoing) {
                    queue.push({ type: t, depth: depth + 1 });
                }
            }
        }
    }

    return result;
}

function buildHandlerInfo(graph: ProjectGraph, units: ScriptUnit[], h: MessageHandlerType): FlowHandlerInfo {
    const info: FlowHandlerInfo = { file: h.file, span: h.span, outgoing: [] };
    if (h.bodySpan) {
        info.bodySpan = h.bodySpan;
        info.outgoing = [...findReachableEmits(graph, units, h.file, h.bodySpan)].sort();
    }
    return info;
}

// Direct emits in the body span PLUS emits in any user function transitively
// called from the body span. Function callgraph traversal stays inside the
// owning script (LSL has no cross-script function calls).
function findReachableEmits(
    graph: ProjectGraph,
    units: ScriptUnit[],
    file: string,
    bodySpan: Span,
): Set<string> {
    const result = new Set<string>();
    const unit = units.find(u => u.file === file);
    if (!unit) return result;

    const userFnNames = new Set(unit.script.functions.map((f: any) => f.name.name));

    // Direct emits within bodySpan.
    for (const e of graph.emits) {
        if (e.file === file && spanContains(bodySpan, e.span)) {
            result.add(e.typeString);
        }
    }

    // Walk helper function calls reachable from bodySpan.
    const visitedFns = new Set<string>();
    const queue: string[] = collectCallsInSpan(unit, bodySpan, userFnNames);

    while (queue.length) {
        const fnName = queue.shift()!;
        if (visitedFns.has(fnName)) continue;
        visitedFns.add(fnName);

        const fn = unit.script.functions.find((f: any) => f.name.name === fnName);
        if (!fn) continue;

        const fnBodySpan: Span = { start: fn.body.start, end: fn.body.end };
        for (const e of graph.emits) {
            if (e.file === file && spanContains(fnBodySpan, e.span)) {
                result.add(e.typeString);
            }
        }
        for (const c of collectCallsInSpan(unit, fnBodySpan, userFnNames)) {
            if (!visitedFns.has(c)) queue.push(c);
        }
    }

    return result;
}

function collectCallsInSpan(unit: ScriptUnit, span: Span, userFnNames: Set<string>): string[] {
    const calls: string[] = [];
    const visit = (n: any): void => {
        if (!n || typeof n !== 'object') return;
        // Quick prune: skip nodes entirely outside our span.
        if (n.start && n.end && !spanOverlap(span, n.start, n.end)) return;

        if (n.kind === 'CallExpression' && n.callee?.kind === 'IdentifierExpression') {
            if (n.start && n.end
                && spanContains(span, { start: n.start, end: n.end })
                && userFnNames.has(n.callee.name)) {
                calls.push(n.callee.name);
            }
        }
        for (const k of Object.keys(n)) {
            if (k === 'start' || k === 'end' || k === 'kind') continue;
            const v = (n as any)[k];
            if (Array.isArray(v)) v.forEach(visit);
            else if (v && typeof v === 'object') visit(v);
        }
    };
    visit(unit.script);
    return calls;
}

function spanContains(outer: Span, inner: Span): boolean {
    return positionLeq(outer.start, inner.start) && positionLeq(inner.end, outer.end);
}

function spanOverlap(a: Span, bStart: Position, bEnd: Position): boolean {
    // True if [a.start, a.end] and [bStart, bEnd] overlap at all.
    return !(positionLess(a.end, bStart) || positionLess(bEnd, a.start));
}

function positionLeq(a: Position, b: Position): boolean {
    if (a.line !== b.line) return a.line < b.line;
    return a.column <= b.column;
}

function positionLess(a: Position, b: Position): boolean {
    if (a.line !== b.line) return a.line < b.line;
    return a.column < b.column;
}

/* -------------------- formatter -------------------- */

export function formatFlowTrace(nodes: FlowNode[], startType: string): string {
    const lines: string[] = [];
    lines.push(`Flow trace from "${startType}":`);
    lines.push('');

    for (const node of nodes) {
        const indent = '  '.repeat(node.depth);
        if (node.cycle) {
            lines.push(`${indent}${node.type}  (cycle — already traced above)`);
            continue;
        }
        if (node.handlers.length === 0) {
            lines.push(`${indent}${node.type}  ⚠ no handler found`);
            continue;
        }
        lines.push(`${indent}${node.type}`);
        for (const h of node.handlers) {
            const loc = `${h.file}:${h.span.start.line}`;
            const outgoing = h.outgoing.length > 0
                ? ` → emits: ${h.outgoing.join(', ')}`
                : (h.bodySpan ? '  (terminal — no further emits)' : '  (handler body unresolvable; downstream emits not traced)');
            lines.push(`${indent}  → ${loc}${outgoing}`);
        }
    }
    return lines.join('\n');
}
