import type { Rule } from '../runner.js';
import type { Identifier } from '../../parser/ast.js';
import { isReservedIdentifier, categorizeReserved } from '../../parser/tokens.js';

export const LSL001_reservedWords: Rule = {
    id: 'LSL001',
    description: 'LSL reserved identifiers (types, keywords, event names, common constants) must not be used as variable, function, parameter, label, or state names.',
    check(ctx) {
        const flag = (ident: Identifier, role: string) => {
            if (!isReservedIdentifier(ident.name)) return;
            const cat = categorizeReserved(ident.name);
            const detail = cat ? ` (reserved ${cat})` : '';
            ctx.report({
                ruleId: 'LSL001',
                category: 'Naming error',
                severity: 'error',
                message: `'${ident.name}' is a reserved LSL identifier${detail} — cannot be used as a ${role} name`,
                start: ident.start,
                end: ident.end,
            });
        };

        for (const g of ctx.script.globals) flag(g.name, 'global variable');

        for (const fn of ctx.script.functions) {
            flag(fn.name, 'function');
            for (const p of fn.params) flag(p.name, 'parameter');
            walkLocals(fn.body, (id, role) => flag(id, role));
        }

        for (const st of ctx.script.states) {
            if (!st.isDefault) flag(st.name, 'state');
            for (const ev of st.events) {
                // Event handler names are themselves reserved (and required to be reserved
                // — that's how LSL identifies them) — don't flag those.
                for (const p of ev.params) flag(p.name, 'parameter');
                walkLocals(ev.body, (id, role) => flag(id, role));
            }
        }
    },
};

// Walks a function/event body, invoking `cb` for every declaration-position identifier
// (locals, labels). Does not descend into expressions.
function walkLocals(node: any, cb: (id: Identifier, role: string) => void): void {
    if (!node || typeof node !== 'object') return;
    if (node.kind === 'LocalVariable') {
        cb(node.name, 'local variable');
    } else if (node.kind === 'LabelStatement') {
        cb(node.name, 'label');
    }
    for (const key of Object.keys(node)) {
        if (key === 'start' || key === 'end' || key === 'kind') continue;
        const v = (node as any)[key];
        if (Array.isArray(v)) v.forEach(child => walkLocals(child, cb));
        else if (v && typeof v === 'object') walkLocals(v, cb);
    }
}
