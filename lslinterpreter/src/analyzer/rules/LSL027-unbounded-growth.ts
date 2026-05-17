import type { Rule } from '../runner.js';
import type { Expression, GlobalVariable, Identifier } from '../../parser/ast.js';

// Heap leak detector for the canonical LSL pattern: a global list or string is appended
// to in an event handler with no reset anywhere in the script. Over time the global grows
// until the script hits the 64 KB Mono ceiling.
//
// Classification of assignments to a tracked global `g`:
//   GROW   — g += x  |  g = g + x  |  g = x + g
//          | g = llListInsertList(g, ...) | g = llJsonSetValue(g, ...)
//   OTHER  — any other assignment whose RHS doesn't reference g in a growing way.
//            Treated as a possible reset (we don't model the RHS deeply — being lenient
//            here keeps false positives down).
//
// We warn only when a global has at least one GROW *and* zero OTHER assignments. That's
// the high-confidence "this never gets cleared" case.

const GROWING_CALLS = new Set(['llListInsertList', 'llJsonSetValue']);

interface MutationSummary { grows: number; others: number; growSites: { line: number; column: number }[]; }

export const LSL027_unboundedGrowth: Rule = {
    id: 'LSL027',
    description: 'Global list/string grows over time with no reset — potential heap leak.',
    check(ctx) {
        const tracked = new Map<string, GlobalVariable>();
        for (const g of ctx.script.globals) {
            if (g.type === 'list' || g.type === 'string') tracked.set(g.name.name, g);
        }
        if (tracked.size === 0) return;

        const summaries = new Map<string, MutationSummary>();
        for (const name of tracked.keys()) summaries.set(name, { grows: 0, others: 0, growSites: [] });

        const visit = (n: any): void => {
            if (!n || typeof n !== 'object') return;
            if (n.kind === 'AssignmentExpression') {
                const targetName = identifierName(n.target);
                if (targetName && tracked.has(targetName)) {
                    const summary = summaries.get(targetName)!;
                    if (isGrowingAssignment(n.operator, n.value, targetName)) {
                        summary.grows += 1;
                        summary.growSites.push({ line: n.start.line, column: n.start.column });
                    } else {
                        summary.others += 1;
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
        visit(ctx.script);

        for (const [name, summary] of summaries) {
            if (summary.grows === 0) continue;
            if (summary.others > 0) continue;
            const decl = tracked.get(name)!;
            const sites = summary.growSites
                .slice(0, 3)
                .map(s => `line ${s.line}`)
                .join(', ');
            const more = summary.growSites.length > 3 ? `, +${summary.growSites.length - 3} more` : '';
            ctx.report({
                ruleId: 'LSL027',
                category: 'Memory warning',
                severity: 'warning',
                message: `${decl.type} '${name}' grows (${summary.grows} site${summary.grows === 1 ? '' : 's'}: ${sites}${more}) but is never reset — potential heap leak`,
                start: decl.name.start,
                end: decl.name.end,
            });
        }
    },
};

function identifierName(e: Expression): string | null {
    if (e.kind === 'IdentifierExpression') return e.name;
    if (e.kind === 'ParenthesizedExpression') return identifierName(e.expression);
    return null;
}

function isGrowingAssignment(operator: string, rhs: Expression, lhsName: string): boolean {
    // `g += x` always grows for list/string.
    if (operator === '+=') return true;
    // `g = g + x` or `g = x + g` — concatenation involving self.
    if (operator === '=' && isPlusInvolvingSelf(rhs, lhsName)) return true;
    // `g = llListInsertList(g, ...)` / `g = llJsonSetValue(g, ...)` — known-growing calls
    // whose first argument is g.
    if (operator === '=' && isGrowingCallOfSelf(rhs, lhsName)) return true;
    return false;
}

function isPlusInvolvingSelf(e: Expression, name: string): boolean {
    const inner = unwrap(e);
    if (inner.kind !== 'BinaryExpression' || inner.operator !== '+') return false;
    return identifierName(inner.left) === name || identifierName(inner.right) === name;
}

function isGrowingCallOfSelf(e: Expression, name: string): boolean {
    const inner = unwrap(e);
    if (inner.kind !== 'CallExpression') return false;
    if (inner.callee.kind !== 'IdentifierExpression') return false;
    if (!GROWING_CALLS.has(inner.callee.name)) return false;
    const first = inner.args[0];
    return first ? identifierName(first) === name : false;
}

function unwrap(e: Expression): Expression {
    return e.kind === 'ParenthesizedExpression' ? unwrap(e.expression) : e;
}
