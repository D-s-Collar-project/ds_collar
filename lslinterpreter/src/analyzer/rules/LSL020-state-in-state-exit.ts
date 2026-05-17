import type { Rule } from '../runner.js';

// Per LSL semantics, `state X;` inside a state_exit handler is silently ignored.
// The transition is already in progress; the second request becomes a no-op. This is
// a particularly nasty bug because the code LOOKS correct.

export const LSL020_stateInStateExit: Rule = {
    id: 'LSL020',
    description: 'state change inside state_exit handler is silently ignored by Mono.',
    check(ctx) {
        for (const st of ctx.script.states) {
            for (const ev of st.events) {
                if (ev.name.name !== 'state_exit') continue;
                const visit = (n: any): void => {
                    if (!n || typeof n !== 'object') return;
                    if (n.kind === 'StateChangeStatement') {
                        ctx.report({
                            ruleId: 'LSL020',
                            category: 'Lint warning',
                            severity: 'error',
                            message: `'state ${n.target.name};' inside state_exit is silently ignored — fold this transition into the event that triggered the exit`,
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
