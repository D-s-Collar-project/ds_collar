import type { Rule } from '../runner.js';

// at_target / not_at_target events fire only when llTarget has been
// called to register a position-distance target. A state declaring these
// events without any llTarget call anywhere in the script is dead code:
// the events can never fire.
//
// Whole-script scope: llTarget could legitimately be called from a
// different state (the registration outlives state changes — actually,
// no, llTarget targets are cleared on state change just like listeners
// and timers). But practically, projects often centralize llTarget calls
// in helper functions called from many states, so checking script-wide
// is more useful than per-state. False negatives possible if llTarget is
// in another script's link_message handler... but that's not a thing
// since llTarget is per-script local.

export const LSL046_targetEventWithoutCall: Rule = {
    id: 'LSL046',
    description: 'state declares at_target/not_at_target but no llTarget call exists in this script — the event can never fire.',
    check(ctx) {
        // Scan the entire script for any llTarget call.
        let hasLlTarget = false;
        const scan = (n: any): void => {
            if (hasLlTarget) return;
            if (!n || typeof n !== 'object') return;
            if (n.kind === 'CallExpression'
                && n.callee?.kind === 'IdentifierExpression'
                && n.callee.name === 'llTarget') {
                hasLlTarget = true;
                return;
            }
            for (const key of Object.keys(n)) {
                if (key === 'start' || key === 'end' || key === 'kind') continue;
                const v = (n as any)[key];
                if (Array.isArray(v)) v.forEach(scan);
                else if (v && typeof v === 'object') scan(v);
            }
        };
        scan(ctx.script);
        if (hasLlTarget) return;

        for (const st of ctx.script.states) {
            for (const ev of st.events) {
                if (ev.name.name !== 'at_target' && ev.name.name !== 'not_at_target') continue;
                const stateName = st.isDefault ? 'default' : st.name.name;
                ctx.report({
                    ruleId: 'LSL046',
                    category: 'Lint warning',
                    severity: 'warning',
                    message: `state ${stateName} declares ${ev.name.name}() but no llTarget() call exists in this script — this event can never fire.`,
                    start: ev.start,
                    end: ev.end,
                });
            }
        }
    },
};
