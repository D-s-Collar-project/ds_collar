import type { Rule } from '../runner.js';

// LSL requires globals and global-constant assignments to be declared before use.
// Functions are effectively hoisted (forward references work), but variables are
// strictly top-down. This rule walks every IdentifierExpression and flags any
// reference to a global name whose declaration line is later than the use site.

export const LSL011_useBeforeDecl: Rule = {
    id: 'LSL011',
    description: 'Global variable referenced before its declaration line — LSL parses top-down for variables (functions hoist, globals do not).',
    check(ctx) {
        // Track BOTH the declaration line (for the message) and the offset (for ordering
        // within the same line — `integer B = A; integer A = 5;` is illegal even
        // though both are on line 1).
        const declSite = new Map<string, { line: number; offset: number }>();
        for (const g of ctx.symbols.globals) {
            declSite.set(g.name.name, { line: g.name.start.line, offset: g.name.start.offset });
        }
        if (declSite.size === 0) return;

        const visit = (n: any): void => {
            if (!n || typeof n !== 'object') return;
            if (n.kind === 'IdentifierExpression') {
                const site = declSite.get(n.name);
                if (site !== undefined && n.start.offset < site.offset) {
                    ctx.report({
                        ruleId: 'LSL011',
                        category: 'Syntax error',
                        severity: 'error',
                        message: `global '${n.name}' is used here but declared later on line ${site.line} — move the declaration above this use`,
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
