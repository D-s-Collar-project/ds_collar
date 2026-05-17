import type { Rule } from '../runner.js';

// llListen(integer channel, string name, key id, string msg) — when the `id` filter is
// NULL_KEY or an empty string, the listener receives messages from EVERY avatar/object,
// which is both a security and performance footgun. Scope to a specific key whenever
// possible (typically llGetOwner() or the avatar in the current dialog session).

export const LSL018_openListen: Rule = {
    id: 'LSL018',
    description: 'llListen with NULL_KEY or empty-string id filter — wide-open listener; scope to a specific key.',
    check(ctx) {
        const visit = (n: any): void => {
            if (!n || typeof n !== 'object') return;
            if (n.kind === 'CallExpression'
                && n.callee?.kind === 'IdentifierExpression'
                && n.callee.name === 'llListen'
                && n.args.length >= 3) {
                const idArg = n.args[2];
                const isOpen = (idArg.kind === 'IdentifierExpression' && idArg.name === 'NULL_KEY')
                    || (idArg.kind === 'StringLiteral' && idArg.value === '');
                if (isOpen) {
                    ctx.report({
                        ruleId: 'LSL018',
                        category: 'Lint warning',
                        severity: 'warning',
                        message: `llListen with open id filter (${idArg.kind === 'IdentifierExpression' ? 'NULL_KEY' : 'empty string'}) — receives messages from every source; scope to llGetOwner() or the dialog avatar`,
                        start: n.start,
                        end: n.end,
                    });
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
    },
};
