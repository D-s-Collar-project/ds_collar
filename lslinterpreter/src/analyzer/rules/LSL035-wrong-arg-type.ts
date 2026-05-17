import type { Rule, RuleContext } from '../runner.js';
import type { LslValueType } from '../builtins.js';
import type { Handler } from '../symbols.js';

// Argument type mismatch — conservative version. We only flag when both sides are
// statically determinable (literal, declared variable, cast result) AND the LSL
// implicit-conversion rules don't permit the assignment.
//
// LSL implicit conversions accepted in argument position:
//   integer → float        (auto-promoted)
//   string  → key          (LSL converts string UUIDs)
//   key     → string       (key auto-stringifies)
// Everything else requires an explicit cast; passing a wrong type silently produces
// junk values (NULL_KEY, 0, ZERO_VECTOR, ...).
//
// If the actual type can't be inferred (call result, complex expression), we skip —
// false negative is preferable to false positive in v1.

export const LSL035_wrongArgType: Rule = {
    id: 'LSL035',
    description: 'Function call passes an argument whose statically known type is incompatible with the parameter.',
    check(ctx) {
        // Shared across all handlers: globals (file scope) and user-function signatures.
        // Per-handler scope adds params + that handler's own locals — flat per-function,
        // matching Mono's locals model — and is rebuilt for each handler to avoid the
        // cross-handler name collision that overwrites types in a global map.
        const globalType = new Map<string, LslValueType>();
        for (const g of ctx.script.globals) globalType.set(g.name.name, g.type);
        const userFunctions = new Map(ctx.script.functions.map(f => [f.name.name, f]));

        for (const fn of ctx.script.functions) checkHandler(fn, globalType, userFunctions, ctx);
        for (const st of ctx.script.states) {
            for (const ev of st.events) checkHandler(ev, globalType, userFunctions, ctx);
        }
    },
};

function checkHandler(
    handler: Handler,
    globalType: Map<string, LslValueType>,
    userFunctions: Map<string, any>,
    ctx: RuleContext,
): void {
    // Per-handler type map. Locals from this handler shadow globals; params shadow
    // both. Other handlers' locals are NOT visible.
    const varType = new Map<string, LslValueType>(globalType);
    for (const p of handler.params) varType.set(p.name.name, p.type);
    const locals = ctx.symbols.locals.get(handler) ?? [];
    for (const local of locals) varType.set(local.name.name, local.type);

    const constantType = (name: string): LslValueType | null => {
        const c = ctx.builtins.constants.get(name);
        return c ? c.type : null;
    };

    const inferType = (expr: any): LslValueType | null => {
        switch (expr.kind) {
            case 'IntegerLiteral': return 'integer';
            case 'FloatLiteral': return 'float';
            case 'StringLiteral': return 'string';
            case 'VectorLiteral': return 'vector';
            case 'RotationLiteral': return 'rotation';
            case 'ListLiteral': return 'list';
            case 'CastExpression': return expr.targetType;
            case 'ParenthesizedExpression': return inferType(expr.expression);
            case 'IdentifierExpression':
                return varType.get(expr.name) ?? constantType(expr.name) ?? null;
            case 'CallExpression': {
                if (expr.callee?.kind === 'IdentifierExpression') {
                    const name = expr.callee.name;
                    const userFn = userFunctions.get(name);
                    if (userFn?.returnType && userFn.returnType !== null) {
                        return userFn.returnType as LslValueType;
                    }
                    const builtin = ctx.builtins.functions.get(name);
                    if (builtin && builtin.returnType !== 'void') return builtin.returnType;
                }
                return null;
            }
            default: return null;
        }
    };

    const compatible = (actual: LslValueType, expected: LslValueType): boolean => {
        if (actual === expected) return true;
        if (expected === 'float' && actual === 'integer') return true;
        if (expected === 'key' && actual === 'string') return true;
        if (expected === 'string' && actual === 'key') return true;
        return false;
    };

    const visit = (n: any): void => {
        if (!n || typeof n !== 'object') return;
        if (n.kind === 'CallExpression' && n.callee?.kind === 'IdentifierExpression') {
            const name = n.callee.name;
            let expectedParams: { name: string; type: LslValueType }[] | null = null;

            const userFn = userFunctions.get(name);
            if (userFn) {
                expectedParams = userFn.params.map((p: any) => ({ name: p.name.name, type: p.type as LslValueType }));
            } else {
                const builtin = ctx.builtins.functions.get(name);
                if (builtin) expectedParams = builtin.params;
            }

            if (expectedParams) {
                const checkCount = Math.min(n.args.length, expectedParams.length);
                for (let i = 0; i < checkCount; i++) {
                    const arg = n.args[i];
                    const actual = inferType(arg);
                    if (actual === null) continue;
                    const expected = expectedParams[i]!.type;
                    if (!compatible(actual, expected)) {
                        ctx.report({
                            ruleId: 'LSL035',
                            category: 'Type error',
                            severity: 'error',
                            message: `${name}(): argument ${i + 1} (${expectedParams[i]!.name}) expects ${expected}, got ${actual}`,
                            start: arg.start,
                            end: arg.end,
                        });
                    }
                }
            }
        }
        for (const key of Object.keys(n)) {
            if (key === 'start' || key === 'end' || key === 'kind') continue;
            const v = (n as any)[key];
            if (Array.isArray(v)) v.forEach(visit);
            else if (v && typeof v === 'object') visit(v);
        }
    };
    visit(handler.body);
}
