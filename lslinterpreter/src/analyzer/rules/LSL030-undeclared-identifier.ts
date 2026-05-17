import type { Rule } from '../runner.js';
import { isReservedIdentifier } from '../../parser/tokens.js';

// Catches typos (`llRegonSayTo`), missing globals, references to functions defined
// in other scripts. Walks every IdentifierExpression and checks against the union of:
//   - user globals, user function names, parameters (any handler), all locals (any
//     handler — Mono flattens locals per function so this is the right scope shape),
//     all label names
//   - LSL builtin functions and constants (520 + 968 from the lslint catalog)
//   - LSL reserved identifiers (keywords, type names, event names — see tokens.ts)
//
// Note: per LSL semantics, locals are visible across the whole function body even
// when declared inside nested blocks, so a flat per-function set matches reality.

export const LSL030_undeclared: Rule = {
    id: 'LSL030',
    description: 'Identifier used but not declared as a global, function, parameter, local, label, or LSL builtin / constant.',
    check(ctx) {
        const userNames = new Set<string>();
        for (const g of ctx.script.globals) userNames.add(g.name.name);
        for (const fn of ctx.script.functions) {
            userNames.add(fn.name.name);
            for (const p of fn.params) userNames.add(p.name.name);
        }
        for (const [handler, locals] of ctx.symbols.locals) {
            for (const p of handler.params) userNames.add(p.name.name);
            for (const local of locals) userNames.add(local.name.name);
        }
        for (const [, labels] of ctx.symbols.labels) {
            for (const lbl of labels) userNames.add(lbl.name.name);
        }

        const visit = (n: any): void => {
            if (!n || typeof n !== 'object') return;
            if (n.kind === 'IdentifierExpression') {
                const name = n.name;
                if (!userNames.has(name)
                    && !ctx.builtins.isBuiltinFunction(name)
                    && !ctx.builtins.isBuiltinConstant(name)
                    && !isReservedIdentifier(name)) {
                    ctx.report({
                        ruleId: 'LSL030',
                        category: 'Naming error',
                        severity: 'error',
                        message: `undeclared identifier '${name}' — not a global, function, parameter, local, or LSL builtin/constant. Check spelling or add a declaration`,
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
