import type { Rule } from '../runner.js';

// Function call argument-count mismatch. LSL has no overloading or varargs, so each
// callable (user-defined or builtin) has exactly one fixed arity. Catches calls to
// renamed builtins (e.g. `llSay(0, "hi", "extra")` after a signature change), and
// signature mismatches between caller and a refactored user function.

export const LSL034_wrongArgCount: Rule = {
    id: 'LSL034',
    description: 'Function call passes the wrong number of arguments.',
    check(ctx) {
        const userFunctions = new Map(ctx.script.functions.map(f => [f.name.name, f]));

        const visit = (n: any): void => {
            if (!n || typeof n !== 'object') return;
            if (n.kind === 'CallExpression' && n.callee?.kind === 'IdentifierExpression') {
                const name = n.callee.name;
                const argCount = n.args.length;

                let expectedCount: number | null = null;
                let what: string | null = null;

                const userFn = userFunctions.get(name);
                if (userFn) {
                    expectedCount = userFn.params.length;
                    what = `user function ${name}`;
                } else {
                    const builtin = ctx.builtins.functions.get(name);
                    if (builtin) {
                        expectedCount = builtin.params.length;
                        what = `${name}`;
                    }
                }

                if (expectedCount !== null && expectedCount !== argCount) {
                    ctx.report({
                        ruleId: 'LSL034',
                        category: 'Type error',
                        severity: 'error',
                        message: `${what}() expects ${expectedCount} argument${expectedCount === 1 ? '' : 's'}, got ${argCount}`,
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
