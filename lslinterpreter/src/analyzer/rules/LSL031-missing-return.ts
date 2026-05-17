import type { Rule } from '../runner.js';
import type { Statement, Block } from '../../parser/ast.js';

// Non-void function with a control path that can reach the end without returning.
// LSL doesn't error on fall-off-end — the function silently returns the default value
// of the declared return type (0 / 0.0 / "" / NULL_KEY / <0,0,0> / [] etc.). That's
// almost always a bug.
//
// Control-flow model: a statement "always terminates" if every path through it
// returns or transfers control out of the function. Loops can iterate zero times
// so they don't help (do-while is an exception — body always runs once).

export const LSL031_missingReturn: Rule = {
    id: 'LSL031',
    description: 'Non-void function can fall off the end without returning a value — LSL silently returns the type default, almost always a bug.',
    check(ctx) {
        for (const fn of ctx.script.functions) {
            if (fn.returnType === null) continue;  // void function
            if (alwaysTerminates(fn.body)) continue;
            ctx.report({
                ruleId: 'LSL031',
                category: 'Lint warning',
                severity: 'warning',
                message: `function '${fn.name.name}' returns ${fn.returnType} but can fall off the end without an explicit return; LSL will silently return the type default`,
                start: fn.name.start,
                end: fn.name.end,
            });
        }
    },
};

function alwaysTerminates(stmt: Statement): boolean {
    switch (stmt.kind) {
        case 'ReturnStatement':
        case 'StateChangeStatement':
            return true;
        case 'Block':
            return blockTerminates(stmt);
        case 'IfStatement':
            // Both branches must terminate (and else must exist) for the if to terminate.
            return stmt.alternate !== null
                && alwaysTerminates(stmt.consequent)
                && alwaysTerminates(stmt.alternate);
        case 'DoWhileStatement':
            // Body always runs at least once.
            return alwaysTerminates(stmt.body);
        case 'WhileStatement':
        case 'ForStatement':
            // Body might run zero times.
            return false;
        // JumpStatement: target label may be earlier or later; we can't analyze without
        // a control-flow graph. Treat as non-terminating to be safe.
        default:
            return false;
    }
}

function blockTerminates(block: Block): boolean {
    for (const stmt of block.statements) {
        if (alwaysTerminates(stmt)) return true;
    }
    return false;
}
