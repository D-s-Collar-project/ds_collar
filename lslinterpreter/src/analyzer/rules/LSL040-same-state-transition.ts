import type { Rule } from '../runner.js';

// `state X;` from within state X is silently treated as a no-op by Mono
// (acts like return). state_exit doesn't fire, state_entry doesn't fire,
// pending events aren't cleared, listeners aren't re-opened. Almost
// always a bug — the writer expected a re-entry side effect that doesn't
// happen. Restart logic should be inlined into the event handler instead.

export const LSL040_sameStateTransition: Rule = {
    id: 'LSL040',
    description: '`state X;` from within state X is a no-op (acts as return). state_entry will not re-run, listeners will not re-open. Inline the restart logic instead.',
    check(ctx) {
        for (const st of ctx.script.states) {
            const containingName = st.isDefault ? 'default' : st.name.name;
            for (const ev of st.events) {
                const visit = (n: any): void => {
                    if (!n || typeof n !== 'object') return;
                    if (n.kind === 'StateChangeStatement' && n.target.name === containingName) {
                        ctx.report({
                            ruleId: 'LSL040',
                            category: 'Lint warning',
                            severity: 'warning',
                            message: `'state ${containingName};' from within state ${containingName} is a no-op (acts as return). state_entry will not re-run, listeners will not re-open. Inline the restart logic instead.`,
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
                visit(ev.body);
            }
        }
    },
};
