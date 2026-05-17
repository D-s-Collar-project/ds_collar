import type { Rule } from '../runner.js';
import type { Expression, GlobalVariable, LocalVariable, LslType } from '../../parser/ast.js';

// Maps a declared LSL type to the literal kinds that may directly initialize it.
// Anything else (a different literal kind) is a clear mismatch.
//
// Notes:
//  - Identifier expressions (constants like NULL_KEY, ZERO_VECTOR) are skipped — we don't
//    track constant types yet. Only literal-vs-declared mismatches are flagged.
//  - LSL allows implicit integer→float promotion at assignment, hence integer literals are
//    accepted for float declarations.
//  - LSL allows string-literal initialization of `key` (for UUID strings), so StringLiteral
//    is accepted for both `string` and `key`.
const LITERAL_COMPAT: Record<LslType, ReadonlySet<string>> = {
    integer:  new Set(['IntegerLiteral']),
    float:    new Set(['IntegerLiteral', 'FloatLiteral']),
    string:   new Set(['StringLiteral']),
    key:      new Set(['StringLiteral']),
    vector:   new Set(['VectorLiteral']),
    rotation: new Set(['RotationLiteral']),
    list:     new Set(['ListLiteral']),
};

export const LSL026_typeMismatch: Rule = {
    id: 'LSL026',
    description: 'Literal initializer in a variable declaration does not match the declared type.',
    check(ctx) {
        const visit = (n: any): void => {
            if (!n || typeof n !== 'object') return;
            if (n.kind === 'GlobalVariable' || n.kind === 'LocalVariable') {
                checkDecl(n);
            }
            for (const key of Object.keys(n)) {
                if (key === 'start' || key === 'end' || key === 'kind') continue;
                const v = (n as any)[key];
                if (Array.isArray(v)) v.forEach(visit);
                else if (v && typeof v === 'object') visit(v);
            }
        };

        const checkDecl = (decl: GlobalVariable | LocalVariable): void => {
            const init = decl.initializer;
            if (!init) return;
            if (!isLiteral(init)) return;       // skip non-literal initializers
            const allowed = LITERAL_COMPAT[decl.type];
            if (allowed.has(init.kind)) return;
            ctx.report({
                ruleId: 'LSL026',
                category: 'Type error',
                severity: 'error',
                message: `cannot initialize ${decl.type} '${decl.name.name}' with ${describeLiteral(init)}`,
                start: init.start,
                end: init.end,
            });
        };

        visit(ctx.script);
    },
};

const LITERAL_KINDS = new Set([
    'IntegerLiteral', 'FloatLiteral', 'StringLiteral',
    'VectorLiteral', 'RotationLiteral', 'ListLiteral',
]);

function isLiteral(e: Expression): boolean {
    return LITERAL_KINDS.has(e.kind);
}

function describeLiteral(e: Expression): string {
    switch (e.kind) {
        case 'IntegerLiteral': return 'an integer literal';
        case 'FloatLiteral': return 'a float literal';
        case 'StringLiteral': return 'a string literal';
        case 'VectorLiteral': return 'a vector literal';
        case 'RotationLiteral': return 'a rotation literal';
        case 'ListLiteral': return 'a list literal';
        default: return e.kind;
    }
}
