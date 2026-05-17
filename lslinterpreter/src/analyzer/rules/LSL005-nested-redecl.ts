import type { Rule, RuleContext } from '../runner.js';
import type { Handler } from '../symbols.js';

// LSL Mono rejects a local that shadows another local OR a parameter currently in
// scope within the same function/event body. lslint misses this — its scope pass
// only checks each block in isolation. We do proper scope-stack tracking: a local
// only conflicts with names that are still in scope at its declaration point.
//
// Sequential (non-overlapping) same-name locals are NOT flagged. E.g.
//
//     foo() {
//         if (a) { integer x; return; }    // x scope ends with return
//         integer x;                        // OK — outer x not in scope
//     }
//
// True shadowing IS flagged:
//
//     foo() {
//         integer x;
//         { integer x; }                    // ERROR — outer x still in scope
//     }

interface ScopedDecl {
    name: string;
    line: number;
    column: number;
    kind: 'param' | 'local';
}

export const LSL005_nestedRedecl: Rule = {
    id: 'LSL005',
    description: 'Local variable shadows another local or parameter still in scope — Mono treats this as a re-declaration conflict; lslint misses it.',
    check(ctx) {
        for (const fn of ctx.script.functions) checkHandler(fn, ctx);
        for (const st of ctx.script.states) {
            for (const ev of st.events) checkHandler(ev, ctx);
        }
    },
};

function checkHandler(handler: Handler, ctx: RuleContext): void {
    const stack: Map<string, ScopedDecl>[] = [new Map()];
    for (const p of handler.params) {
        stack[0]!.set(p.name.name, {
            name: p.name.name,
            line: p.name.start.line,
            column: p.name.start.column,
            kind: 'param',
        });
    }
    walk(handler.body, stack, ctx, handler);
}

function walk(node: any, stack: Map<string, ScopedDecl>[], ctx: RuleContext, handler: Handler): void {
    if (!node || typeof node !== 'object') return;

    if (node.kind === 'Block') {
        stack.push(new Map());
        for (const stmt of node.statements) walk(stmt, stack, ctx, handler);
        stack.pop();
        return;
    }

    if (node.kind === 'LocalVariable') {
        // Search the entire scope stack for an in-scope same-name declaration.
        for (let i = stack.length - 1; i >= 0; i--) {
            const found = stack[i]!.get(node.name.name);
            if (found) {
                const what = handler.kind === 'FunctionDeclaration'
                    ? `function '${handler.name.name}'`
                    : `event '${handler.name.name}'`;
                ctx.report({
                    ruleId: 'LSL005',
                    category: 'Syntax error',
                    severity: 'error',
                    message: `local '${node.name.name}' shadows a ${found.kind === 'param' ? 'parameter' : 'local'} declared on line ${found.line} of ${what} — Mono rejects shadowed locals; rename or reuse the existing variable`,
                    start: node.name.start,
                    end: node.name.end,
                });
                break;
            }
        }
        stack[stack.length - 1]!.set(node.name.name, {
            name: node.name.name,
            line: node.name.start.line,
            column: node.name.start.column,
            kind: 'local',
        });
        return;
    }

    // For if/while/do/for and other compound statements, recurse normally —
    // their `body` will be a Block (or single statement) which pushes its own scope.
    for (const key of Object.keys(node)) {
        if (key === 'start' || key === 'end' || key === 'kind') continue;
        const v = (node as any)[key];
        if (Array.isArray(v)) v.forEach(c => walk(c, stack, ctx, handler));
        else if (v && typeof v === 'object') walk(v, stack, ctx, handler);
    }
}
