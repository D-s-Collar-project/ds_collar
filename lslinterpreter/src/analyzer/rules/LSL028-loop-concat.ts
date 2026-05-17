import type { Rule } from '../runner.js';
import type { Expression, LslType } from '../../parser/ast.js';

// Quadratic-time concatenation inside a loop. Each step `x = x + y` (or `x += y`)
// allocates a new list/string that copies x. Doing this N times is O(N²) work AND
// O(N²) peak heap pressure (the previous values stay live until GC catches up).
//
// We need to know the type of the LHS variable. For globals, we read the declared
// type from the script. For locals we'd need a scope tracker — deferred. So this
// rule only flags concatenations to GLOBAL list/string variables for now; local
// concatenation in loops is a known follow-up.

export const LSL028_loopConcat: Rule = {
    id: 'LSL028',
    description: 'String/list concatenation inside a loop is O(n²) — build a list of pieces and join once instead.',
    check(ctx) {
        const globalTypes = new Map<string, LslType>();
        for (const g of ctx.script.globals) {
            if (g.type === 'list' || g.type === 'string') globalTypes.set(g.name.name, g.type);
        }

        const visit = (n: any, inLoop: boolean): void => {
            if (!n || typeof n !== 'object') return;

            const isLoopBody = n.kind === 'ForStatement' || n.kind === 'WhileStatement' || n.kind === 'DoWhileStatement';

            if (inLoop && n.kind === 'AssignmentExpression') {
                const targetName = identifierName(n.target);
                const targetType = targetName ? globalTypes.get(targetName) : undefined;
                if (targetType && (n.operator === '+=' || (n.operator === '=' && isPlusInvolvingSelf(n.value, targetName!)))) {
                    ctx.report({
                        ruleId: 'LSL028',
                        category: 'Memory warning',
                        severity: 'warning',
                        message: `${targetType} '${targetName}' is concatenated inside a loop — O(n²) heap pressure; collect pieces in a local list and join after the loop`,
                        start: n.start,
                        end: n.end,
                    });
                }
            }

            for (const key of Object.keys(n)) {
                if (key === 'start' || key === 'end' || key === 'kind') continue;
                const v = (n as any)[key];
                // Recurse into the loop's body with inLoop=true; everything else inherits.
                const childInLoop = isLoopBody ? (key === 'body') : inLoop;
                if (Array.isArray(v)) v.forEach(c => visit(c, childInLoop));
                else if (v && typeof v === 'object') visit(v, childInLoop);
            }
        };
        visit(ctx.script, false);
    },
};

function identifierName(e: Expression): string | null {
    if (e.kind === 'IdentifierExpression') return e.name;
    if (e.kind === 'ParenthesizedExpression') return identifierName(e.expression);
    return null;
}

function isPlusInvolvingSelf(e: Expression, name: string): boolean {
    const inner = unwrap(e);
    if (inner.kind !== 'BinaryExpression' || inner.operator !== '+') return false;
    return identifierName(inner.left) === name || identifierName(inner.right) === name;
}

function unwrap(e: Expression): Expression {
    return e.kind === 'ParenthesizedExpression' ? unwrap(e.expression) : e;
}
