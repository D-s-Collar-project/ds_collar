import type { Rule } from '../runner.js';

// Heuristic: if a script calls llListen at all but llListenRemove is never called,
// handles accumulate until the per-script listener cap (~64) is hit. We can't tell
// statically whether handles are stored and removed correctly — that needs flow
// analysis — but the "zero removes" case is a strong leak signal in practice.

export const LSL013_listenerLeak: Rule = {
    id: 'LSL013',
    description: 'llListen called without any llListenRemove anywhere — listener handles accumulate until the per-script cap (~64).',
    check(ctx) {
        const listenSites: any[] = [];
        let removeCount = 0;
        const visit = (n: any): void => {
            if (!n || typeof n !== 'object') return;
            if (n.kind === 'CallExpression' && n.callee?.kind === 'IdentifierExpression') {
                if (n.callee.name === 'llListen') listenSites.push(n);
                if (n.callee.name === 'llListenRemove') removeCount += 1;
            }
            for (const key of Object.keys(n)) {
                if (key === 'start' || key === 'end' || key === 'kind') continue;
                const v = (n as any)[key];
                if (Array.isArray(v)) v.forEach(visit);
                else if (v && typeof v === 'object') visit(v);
            }
        };
        visit(ctx.script);

        if (listenSites.length === 0 || removeCount > 0) return;

        const first = listenSites[0];
        const sites = listenSites.slice(0, 3).map(s => `line ${s.start.line}`).join(', ');
        const more = listenSites.length > 3 ? `, +${listenSites.length - 3} more` : '';
        ctx.report({
            ruleId: 'LSL013',
            category: 'Lint warning',
            severity: 'warning',
            message: `${listenSites.length} llListen call${listenSites.length === 1 ? '' : 's'} (${sites}${more}) but no llListenRemove anywhere — listener handles will accumulate until the per-script cap`,
            start: first.start,
            end: first.end,
        });
    },
};
