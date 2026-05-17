import type { Rule } from '../runner.js';

// A state that registers an llListen but doesn't declare a listen() event
// handler is broken: the listener is active (consumes a listen slot) but
// nothing in this state will receive its events. Almost always a bug —
// either the handler was forgotten, or the llListen was misplaced.
//
// Detection: walk each state's event bodies for direct llListen calls.
// If any are found and the state has no listen handler, flag the
// llListen call site. Indirect calls (llListen inside a helper called
// from state_entry) aren't traced — would need a callgraph pass.

export const LSL044_listenerWithoutHandler: Rule = {
    id: 'LSL044',
    description: 'state opens an llListen but declares no listen() event handler — registered listener consumes a slot and delivers events into the void.',
    check(ctx) {
        for (const st of ctx.script.states) {
            const hasListen = st.events.some(ev => ev.name.name === 'listen');
            if (hasListen) continue;

            const stateName = st.isDefault ? 'default' : st.name.name;
            for (const ev of st.events) {
                const visit = (n: any): void => {
                    if (!n || typeof n !== 'object') return;
                    if (n.kind === 'CallExpression'
                        && n.callee?.kind === 'IdentifierExpression'
                        && n.callee.name === 'llListen') {
                        ctx.report({
                            ruleId: 'LSL044',
                            category: 'Lint warning',
                            severity: 'warning',
                            message: `llListen in state ${stateName} (event ${ev.name.name}) but no listen() handler in this state — the listener will consume a slot and deliver events nowhere.`,
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
