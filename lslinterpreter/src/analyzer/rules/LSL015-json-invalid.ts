import type { Rule } from '../runner.js';

// llJsonGetValue returns the constant JSON_INVALID when the requested path doesn't
// exist. Code that treats the result as a string without checking will silently
// propagate "∞" / undefined values. Heuristic: if llJsonGetValue is called but
// JSON_INVALID never appears anywhere in the script, results aren't being guarded.

export const LSL015_jsonInvalidUnchecked: Rule = {
    id: 'LSL015',
    description: 'llJsonGetValue results not checked against JSON_INVALID — missing-path errors silently propagate.',
    check(ctx) {
        const getValueSites: any[] = [];
        let jsonInvalidRefs = 0;
        const visit = (n: any): void => {
            if (!n || typeof n !== 'object') return;
            if (n.kind === 'CallExpression' && n.callee?.kind === 'IdentifierExpression'
                && n.callee.name === 'llJsonGetValue') {
                getValueSites.push(n);
            }
            if (n.kind === 'IdentifierExpression' && n.name === 'JSON_INVALID') {
                jsonInvalidRefs += 1;
            }
            for (const key of Object.keys(n)) {
                if (key === 'start' || key === 'end' || key === 'kind') continue;
                const v = (n as any)[key];
                if (Array.isArray(v)) v.forEach(visit);
                else if (v && typeof v === 'object') visit(v);
            }
        };
        visit(ctx.script);

        if (getValueSites.length === 0 || jsonInvalidRefs > 0) return;

        const first = getValueSites[0];
        ctx.report({
            ruleId: 'LSL015',
            category: 'Lint warning',
            severity: 'warning',
            message: `${getValueSites.length} llJsonGetValue call${getValueSites.length === 1 ? '' : 's'} but JSON_INVALID never compared — missing paths return the sentinel and silently corrupt downstream logic`,
            start: first.start,
            end: first.end,
        });
    },
};
