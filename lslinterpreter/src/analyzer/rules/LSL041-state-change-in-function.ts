import type { Rule } from '../runner.js';

// `state X;` inside a user-defined function is legal in LSL but
// surprising: the remainder of the function still executes, and the
// state transition takes effect only after the function returns. Most
// authors expect immediate transition. Code reviewers also tend to miss
// the deferred semantics. Recommend issuing the state change directly
// from the calling event handler instead.

export const LSL041_stateChangeInFunction: Rule = {
    id: 'LSL041',
    description: '`state X;` inside a user function — state change is deferred until the function returns. Move the transition into the caller event handler.',
    check(ctx) {
        for (const fn of ctx.script.functions) {
            const visit = (n: any): void => {
                if (!n || typeof n !== 'object') return;
                if (n.kind === 'StateChangeStatement') {
                    ctx.report({
                        ruleId: 'LSL041',
                        category: 'Lint warning',
                        severity: 'warning',
                        message: `'state ${n.target.name};' inside user function ${fn.name.name} — the rest of the function still runs; the state change is deferred until the function returns. Move the transition into the calling event handler for clarity.`,
                        start: n.start,
                        end: n.end,
                    });
                }
                for (const key of Object.keys(n)) {
                    if (key === 'start' || key === 'end' || key === 'kind') continue;
                    const v = (n as any)[key];
                    if (Array.isArray(v)) v.forEach(visit);
                    else if (v && typeof v === 'object') visit(v);
                }
            };
            visit(fn.body);
        }
    },
};
