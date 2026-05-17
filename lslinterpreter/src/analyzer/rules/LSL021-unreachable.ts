import type { Rule } from '../runner.js';

// Simple unreachable-code detector: within any Block, statements after an unconditional
// terminator (return, jump, state change) can never execute. We skip LabelStatement —
// those are jump targets and reachable independently.
//
// Doesn't yet handle: returns inside both branches of if/else, or after a break-like
// pattern emulated by `jump end`. Those need a control-flow graph.

const TERMINATOR_KINDS = new Set(['ReturnStatement', 'JumpStatement', 'StateChangeStatement']);

export const LSL021_unreachable: Rule = {
    id: 'LSL021',
    description: 'Code after an unconditional return/jump/state change is unreachable.',
    check(ctx) {
        const visit = (n: any): void => {
            if (!n || typeof n !== 'object') return;
            if (n.kind === 'Block') {
                let terminated: any = null;
                for (const stmt of n.statements) {
                    // A label is reachable via `jump`, so it resets reachability.
                    if (stmt.kind === 'LabelStatement') {
                        terminated = null;
                        continue;
                    }
                    if (terminated) {
                        ctx.report({
                            ruleId: 'LSL021',
                            category: 'Lint warning',
                            severity: 'warning',
                            message: `unreachable code — preceded by ${describeTerminator(terminated)} on line ${terminated.start.line}`,
                            start: stmt.start,
                            end: stmt.end,
                        });
                        // Don't flag every following statement; one is enough.
                        terminated = null;
                    }
                    if (TERMINATOR_KINDS.has(stmt.kind)) terminated = stmt;
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

function describeTerminator(n: any): string {
    switch (n.kind) {
        case 'ReturnStatement': return 'return';
        case 'JumpStatement': return `jump ${n.label.name}`;
        case 'StateChangeStatement': return `state ${n.target.name}`;
        default: return 'unconditional terminator';
    }
}
