import type { Rule } from '../runner.js';
import { startsWithLindenPrefix } from '../../parser/tokens.js';

export const LSL004_userFunctionLlPrefix: Rule = {
    id: 'LSL004',
    description: 'User-defined function names starting with "ll" are reserved for the Linden Library.',
    check(ctx) {
        for (const fn of ctx.script.functions) {
            if (startsWithLindenPrefix(fn.name.name)) {
                ctx.report({
                    ruleId: 'LSL004',
                    category: 'Naming error',
                    severity: 'error',
                    message: `user function '${fn.name.name}' uses reserved 'll' prefix (Linden Library namespace)`,
                    start: fn.name.start,
                    end: fn.name.end,
                });
            }
        }
    },
};
