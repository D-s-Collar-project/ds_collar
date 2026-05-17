import type { Rule } from '../runner.js';

// If a script calls llRequestPermissions, it must have a run_time_permissions event
// handler somewhere or the granted permissions arrive into a void. Script-level check —
// not scoped per-state because LSL allows a single handler to receive perms granted
// from any state.

export const LSL017_permissionsWithoutHandler: Rule = {
    id: 'LSL017',
    description: 'llRequestPermissions called but no run_time_permissions event handler defined — granted permissions cannot be observed.',
    check(ctx) {
        const requestSites: any[] = [];
        let hasHandler = false;

        const visit = (n: any): void => {
            if (!n || typeof n !== 'object') return;
            if (n.kind === 'CallExpression'
                && n.callee?.kind === 'IdentifierExpression'
                && n.callee.name === 'llRequestPermissions') {
                requestSites.push(n);
            }
            if (n.kind === 'EventHandler' && n.name.name === 'run_time_permissions') {
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
            ruleId: 'LSL017',
            category: 'Lint warning',
            severity: 'warning',
            message: `llRequestPermissions called (${requestSites.length} site${requestSites.length === 1 ? '' : 's'}) but no run_time_permissions handler — permissions granted by the user will never reach a handler`,
            start: first.start,
            end: first.end,
        });
    },
};
