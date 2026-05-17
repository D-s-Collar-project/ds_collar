import type { Rule } from '../runner.js';
import { TokenKind } from '../../parser/tokens.js';

export const LSL002_ternary: Rule = {
    id: 'LSL002',
    description: 'LSL has no ternary operator (?:). Use an if/else statement instead.',
    check(ctx) {
        // Token-level scan — catches the ?: even when surrounding parse context is broken.
        for (const tok of ctx.tokens) {
            if (tok.kind === TokenKind.Question) {
                ctx.report({
                    ruleId: 'LSL002',
                    category: 'Unsupported feature',
                    severity: 'error',
                    message: "LSL has no ternary operator '?:' — rewrite as an if/else",
                    start: tok.start,
                    end: tok.end,
                });
            }
        }
    },
};
