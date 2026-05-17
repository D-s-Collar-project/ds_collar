import type { Rule } from '../runner.js';

// `llSetTimerEvent(nonzero)` inside `timer()` re-arms the timer and causes the handler
// to fire forever (or until something else disarms it). Often intentional, often not —
// the bug is that small mistakes turn a one-shot into an infinite loop. `llSetTimerEvent(0)`
// to disarm is fine and isn't flagged.

export const LSL023_timerRearm: Rule = {
    id: 'LSL023',
    description: 'llSetTimerEvent with a non-zero argument inside a timer() handler — re-arms the timer; intended infinite loops should be explicit.',
    check(ctx) {
        for (const st of ctx.script.states) {
            for (const ev of st.events) {
                if (ev.name.name !== 'timer') continue;
                const visit = (n: any): void => {
                    if (!n || typeof n !== 'object') return;
                    if (n.kind === 'CallExpression'
                        && n.callee?.kind === 'IdentifierExpression'
                        && n.callee.name === 'llSetTimerEvent') {
                        const arg = n.args[0];
                        if (!isZeroLiteral(arg)) {
                            ctx.report({
                                ruleId: 'LSL023',
                                category: 'Lint warning',
                                severity: 'warning',
                                message: `llSetTimerEvent inside timer() re-arms the timer — confirm this is an intended periodic loop, or use llSetTimerEvent(0) to disarm`,
                                start: n.start,
                                end: n.end,
                            });
                        }
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

function isZeroLiteral(e: any): boolean {
    if (!e) return false;
    if (e.kind === 'IntegerLiteral') return e.value === 0;
    if (e.kind === 'FloatLiteral') return e.value === 0;
    return false;
}
