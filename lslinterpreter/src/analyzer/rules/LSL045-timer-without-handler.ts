import type { Rule } from '../runner.js';

// A state that arms the timer (`llSetTimerEvent` with a non-zero arg)
// but doesn't declare a timer() event handler: the timer fires into the
// void. Counterpart is fine for `llSetTimerEvent(0)` (disarming) — that's
// always safe regardless of whether a handler exists.
//
// Detection: walk each state's event bodies for direct llSetTimerEvent
// calls with a non-zero literal first arg. Skip when the arg is variable
// (could be 0 at runtime — over-conservative but avoids false positives).
// Skip the call entirely when the arg is exactly 0.

function isZeroLiteral(arg: any): boolean {
    if (!arg) return false;
    const a = arg.kind === 'ParenExpression' ? arg.expression : arg;
    if (a.kind === 'IntegerLiteral' && a.value === 0) return true;
    if (a.kind === 'FloatLiteral' && a.value === 0) return true;
    return false;
}

export const LSL045_timerWithoutHandler: Rule = {
    id: 'LSL045',
    description: 'state arms the timer with `llSetTimerEvent(>0)` but declares no timer() event handler — timer fires into the void.',
    check(ctx) {
        for (const st of ctx.script.states) {
            const hasTimer = st.events.some(ev => ev.name.name === 'timer');
            if (hasTimer) continue;

            const stateName = st.isDefault ? 'default' : st.name.name;
            for (const ev of st.events) {
                const visit = (n: any): void => {
                    if (!n || typeof n !== 'object') return;
                    if (n.kind === 'CallExpression'
                        && n.callee?.kind === 'IdentifierExpression'
                        && n.callee.name === 'llSetTimerEvent'
                        && n.args.length >= 1
                        && !isZeroLiteral(n.args[0])) {
                        ctx.report({
                            ruleId: 'LSL045',
                            category: 'Lint warning',
                            severity: 'warning',
                            message: `llSetTimerEvent in state ${stateName} (event ${ev.name.name}) but no timer() handler in this state — timer will fire and find no handler.`,
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
