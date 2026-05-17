import type { Rule } from '../runner.js';

// LSL scripts begin in `default`. Any other state can only be entered
// via an explicit `state X;` somewhere in the script. A non-default
// state with no incoming transition is dead code — either an oversight
// (forgot to wire up the transition) or a typo in a state-change call
// site that targets a different (likely non-existent) name.

export const LSL042_unreachableState: Rule = {
    id: 'LSL042',
    description: 'state declared but no `state X;` transition into it exists — only default runs on script start, so this state is unreachable.',
    check(ctx) {
        // Collect all state-change targets across functions and event bodies.
        const targets = new Set<string>();
        const collect = (n: any): void => {
            if (!n || typeof n !== 'object') return;
            if (n.kind === 'StateChangeStatement') {
                targets.add(n.target.name);
            }
            for (const key of Object.keys(n)) {
                if (key === 'start' || key === 'end' || key === 'kind') continue;
                const v = (n as any)[key];
                if (Array.isArray(v)) v.forEach(collect);
                else if (v && typeof v === 'object') collect(v);
            }
        };
        for (const fn of ctx.script.functions) collect(fn.body);
        for (const st of ctx.script.states) {
            for (const ev of st.events) collect(ev.body);
        }

        for (const st of ctx.script.states) {
            if (st.isDefault) continue;
            if (!targets.has(st.name.name)) {
                ctx.report({
                    ruleId: 'LSL042',
                    category: 'Lint info',
                    severity: 'info',
                    message: `state ${st.name.name} is declared but no 'state ${st.name.name};' transition into it exists — only default runs on script start, so this state is unreachable. Either dead code or a typo in a state-change call site.`,
                    start: st.start,
                    end: st.end,
                });
            }
        }
    },
};
