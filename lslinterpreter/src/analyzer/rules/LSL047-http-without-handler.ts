import type { Rule } from '../runner.js';

// llHTTPRequest fires asynchronously — the response arrives in a
// http_response event handler. A script that calls llHTTPRequest but
// declares no http_response handler can dispatch the request but never
// observe the result. Same shape as LSL017 (permissions without handler).

export const LSL047_httpWithoutHandler: Rule = {
    id: 'LSL047',
    description: 'llHTTPRequest called but no http_response event handler defined — the response cannot be observed.',
    check(ctx) {
        const requestSites: any[] = [];
        let hasHandler = false;

        const visit = (n: any): void => {
            if (!n || typeof n !== 'object') return;
            if (n.kind === 'CallExpression'
                && n.callee?.kind === 'IdentifierExpression'
                && n.callee.name === 'llHTTPRequest') {
                requestSites.push(n);
            }
            if (n.kind === 'EventHandler' && n.name.name === 'http_response') {
                hasHandler = true;
            }
            for (const key of Object.keys(n)) {
                if (key === 'start' || key === 'end' || key === 'kind') continue;
                const v = (n as any)[key];
                if (Array.isArray(v)) v.forEach(visit);
                else if (v && typeof v === 'object') visit(v);
            }
        };
        visit(ctx.script);

        if (requestSites.length === 0 || hasHandler) return;

        const first = requestSites[0];
        ctx.report({
            ruleId: 'LSL047',
            category: 'Lint warning',
            severity: 'warning',
            message: `llHTTPRequest called (${requestSites.length} site${requestSites.length === 1 ? '' : 's'}) but no http_response handler — responses will arrive nowhere`,
            start: first.start,
            end: first.end,
        });
    },
};
