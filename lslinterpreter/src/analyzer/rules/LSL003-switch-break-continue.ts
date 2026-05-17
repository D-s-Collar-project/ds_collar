import type { Rule } from '../runner.js';

const ILLEGAL_KEYWORDS = new Set(['switch', 'case', 'break', 'continue']);

export const LSL003_switchBreakContinue: Rule = {
    id: 'LSL003',
    description: 'switch/case/break/continue do not exist in LSL. Use if/else and structured logic or jump labels.',
    check(ctx) {
        // Walk every node, looking for IdentifierExpression with these names in statement position.
        // We treat any occurrence as suspect — false positives only happen if someone has named a
        // variable `break` etc., which is itself bad practice and worth flagging.
        const visit = (node: any, inStatementPosition: boolean): void => {
            if (!node || typeof node !== 'object') return;

            if (node.kind === 'ExpressionStatement') {
                const expr = node.expression;
                if (expr?.kind === 'IdentifierExpression' && ILLEGAL_KEYWORDS.has(expr.name)) {
                    ctx.report({
                        ruleId: 'LSL003',
                        category: 'Unsupported feature',
                        severity: 'error',
                        message: `'${expr.name}' does not exist in LSL — use structured if/else or 'jump' labels`,
                        start: expr.start,
                        end: expr.end,
                    });
                }
                if (expr?.kind === 'CallExpression'
                    && expr.callee?.kind === 'IdentifierExpression'
                    && ILLEGAL_KEYWORDS.has(expr.callee.name)) {
                    ctx.report({
                        ruleId: 'LSL003',
                        category: 'Unsupported feature',
                        severity: 'error',
                        message: `'${expr.callee.name}' does not exist in LSL — rewrite using if/else ladders`,
                        start: expr.callee.start,
                        end: expr.callee.end,
                    });
                }
            }

            for (const key of Object.keys(node)) {
                if (key === 'start' || key === 'end' || key === 'kind') continue;
                const v = (node as any)[key];
                if (Array.isArray(v)) v.forEach(c => visit(c, false));
                else if (v && typeof v === 'object') visit(v, false);
            }
        };

        visit(ctx.script, false);
    },
};
