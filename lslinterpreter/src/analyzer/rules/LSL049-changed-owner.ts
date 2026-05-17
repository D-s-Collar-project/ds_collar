import type { Rule } from '../runner.js';

// Most scripts intended for use as user attachments need to handle
// CHANGED_OWNER — when the wearer transfers the object to another user,
// any cached owner-specific state (UUIDs, names, permissions) becomes
// stale and the script should reset.
//
// Heuristic detection: the script declares a `changed()` event but the
// body never references CHANGED_OWNER. False positives possible — some
// scripts genuinely don't need to react to ownership transfer (purely
// stateless utilities). Info severity to keep noise low; the author
// confirms intent.
//
// Doesn't fire if no `changed()` event exists at all (the script may be
// genuinely uninterested in any change events). Doesn't fire if the
// constant CHANGED_OWNER appears anywhere in the script (covers the
// pattern where the changed handler dispatches via a shared mask check).

export const LSL049_missingChangedOwner: Rule = {
    id: 'LSL049',
    description: 'changed() handler exists but does not reference CHANGED_OWNER — owner transfer leaves cached state stale.',
    check(ctx) {
        let hasChangedHandler = false;
        let referencesChangedOwner = false;

        const visit = (n: any): void => {
            if (!n || typeof n !== 'object') return;
            if (n.kind === 'EventHandler' && n.name.name === 'changed') {
                hasChangedHandler = true;
            }
            if (n.kind === 'IdentifierExpression' && n.name === 'CHANGED_OWNER') {
                referencesChangedOwner = true;
            }
            for (const key of Object.keys(n)) {
                if (key === 'start' || key === 'end' || key === 'kind') continue;
                const v = (n as any)[key];
                if (Array.isArray(v)) v.forEach(visit);
                else if (v && typeof v === 'object') visit(v);
            }
        };
        visit(ctx.script);

        if (!hasChangedHandler || referencesChangedOwner) return;

        // Find the first changed handler to attribute the warning to.
        for (const st of ctx.script.states) {
            for (const ev of st.events) {
                if (ev.name.name !== 'changed') continue;
                ctx.report({
                    ruleId: 'LSL049',
                    category: 'Lint info',
                    severity: 'info',
                    message: `changed() handler does not reference CHANGED_OWNER — if the script caches owner-specific state (UUIDs, names, permissions), an owner transfer will leave that state stale. Consider 'if (change & CHANGED_OWNER) llResetScript();'`,
                    start: ev.start,
                    end: ev.end,
                });
                return;
            }
        }
    },
};
