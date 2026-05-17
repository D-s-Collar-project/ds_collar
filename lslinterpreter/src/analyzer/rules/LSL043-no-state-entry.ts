import type { Rule } from '../runner.js';

// In a multi-state script, the LSL runtime clears all listeners when
// transitioning between states. A state without a state_entry handler
// can't (re-)open the listeners or arm the timer it needs. Single-state
// scripts (only `default`) don't have transitions and so don't need
// state_entry — this rule only fires in multi-state scripts.
//
// Info severity, not warning: legitimate "passive" states do exist
// (a state that just holds and waits for an event). The author should
// confirm intent.

export const LSL043_noStateEntry: Rule = {
    id: 'LSL043',
    description: 'state declares no state_entry handler — listeners and timers from the prior state are cleared on transition.',
    check(ctx) {
        if (ctx.script.states.length < 2) return;
        for (const st of ctx.script.states) {
            const hasEntry = st.events.some(ev => ev.name.name === 'state_entry');
            if (!hasEntry) {
                const stateName = st.isDefault ? 'default' : st.name.name;
                ctx.report({
                    ruleId: 'LSL043',
                    category: 'Lint info',
                    severity: 'info',
                    message: `state ${stateName} has no state_entry handler — listeners, timers, and at_target/at_rot_target registrations from the prior state are cleared on transition. If this state needs any of those, add a state_entry to set them up.`,
                    start: st.start,
                    end: st.end,
                });
            }
        }
    },
};
