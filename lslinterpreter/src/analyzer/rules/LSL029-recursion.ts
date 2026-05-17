import type { Rule } from '../runner.js';

// Direct recursion: a function calls itself by name. Mono's stack is small (~16 KB
// of the 64 KB script budget) and unbounded recursion will crash. Even bounded
// recursion adds per-frame overhead worth flagging.
//
// Indirect recursion (f → g → f) needs a call graph and is deferred.

export const LSL029_recursion: Rule = {
    id: 'LSL029',
    description: 'User function calls itself directly — Mono stack pressure / risk of stack overflow.',
    check(ctx) {
        for (const fn of ctx.script.functions) {
            const callSites: { line: number; column: number }[] = [];
            const visit = (n: any): void => {
                if (!n || typeof n !== 'object') return;
                if (n.kind === 'CallExpression'
                    && n.callee?.kind === 'IdentifierExpression'
                    && n.callee.name === fn.name.name) {
                    callSites.push({ line: n.start.line, column: n.start.column });
                }
                for (const key of Object.keys(n)) {
                    if (key === 'start' || key === 'end' || key === 'kind') continue;
                    const v = (n as any)[key];
                    if (Array.isArray(v)) v.forEach(visit);
                    else if (v && typeof v === 'object') visit(v);
                }
            };
            visit(fn.body);

            if (callSites.length === 0) continue;

            const sites = callSites.slice(0, 3).map(s => `line ${s.line}`).join(', ');
            const more = callSites.length > 3 ? `, +${callSites.length - 3} more` : '';
            ctx.report({
                ruleId: 'LSL029',
                category: 'Memory warning',
                severity: 'warning',
                message: `function '${fn.name.name}' is recursive (${callSites.length} self-call${callSites.length === 1 ? '' : 's'}: ${sites}${more}) — Mono stack is ~16 KB, prefer iteration`,
                start: fn.name.start,
                end: fn.name.end,
            });
        }
    },
};
