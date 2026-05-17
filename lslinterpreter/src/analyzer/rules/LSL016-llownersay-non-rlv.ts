import type { Rule } from '../runner.js';

// Opt-in convention check. Some RLV-heavy projects reserve `llOwnerSay` exclusively
// for RLV commands (strings starting with `@`) and route user-facing messages
// through `llRegionSayTo(wearer, 0, ...)` to keep the owner channel "clean."
// General LSL does NOT impose this convention — `llOwnerSay` is the standard way to
// send owner-only messages — so this rule is OFF by default. Enable per project
// with `--enable LSL016` if your codebase follows the RLV-only convention.
//
// Only string LITERALS are flagged. Non-literal arguments (variables, concats) are
// skipped — they might dynamically build an @-prefixed string.

export const LSL016_llOwnerSayNonRlv: Rule = {
    id: 'LSL016',
    description: 'llOwnerSay called with a literal that does not begin with @ (RLV-only-llOwnerSay convention). Opt-in via --enable LSL016.',
    defaultEnabled: false,
    check(ctx) {
        const visit = (n: any): void => {
            if (!n || typeof n !== 'object') return;
            if (n.kind === 'CallExpression'
                && n.callee?.kind === 'IdentifierExpression'
                && n.callee.name === 'llOwnerSay') {
                const arg = n.args[0];
                if (arg?.kind === 'StringLiteral' && !arg.value.startsWith('@')) {
                    ctx.report({
                        ruleId: 'LSL016',
                        category: 'Lint warning',
                        severity: 'warning',
                        message: `llOwnerSay with non-RLV literal ${JSON.stringify(arg.value.slice(0, 40))} — project convention reserves llOwnerSay for RLV; use llRegionSayTo(recipient, 0, ...) for user chat`,
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
        visit(ctx.script);
    },
};
