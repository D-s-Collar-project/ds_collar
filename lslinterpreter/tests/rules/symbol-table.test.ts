import { describe, it, expect } from 'vitest';
import { Lexer } from '../../src/parser/lexer.js';
import { Parser } from '../../src/parser/parser.js';
import { runRules } from '../../src/analyzer/runner.js';

function lint(source: string) {
    const tokens = Lexer.lex(source);
    const { script } = Parser.parse(tokens);
    return runRules({ file: 'test.lsl', source, tokens, script });
}

describe('LSL005 — local shadowing in same function', () => {
    it('does NOT flag same-name locals in non-overlapping sibling blocks (sequential, not shadowing)', () => {
        const src = `
            foo() {
                if (TRUE) {
                    integer x = 1;
                }
                if (TRUE) {
                    integer x = 2;
                }
            }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL005')).toEqual([]);
    });

    it('flags inner local that shadows an outer local still in scope', () => {
        const src = `
            foo() {
                integer x = 1;
                {
                    integer x = 2;
                }
            }
        `;
        const diags = lint(src).filter(d => d.ruleId === 'LSL005');
        expect(diags.length).toBe(1);
        expect(diags[0]!.message).toContain("'x'");
        expect(diags[0]!.message).toContain('shadows');
    });

    it('flags inner local that shadows a parameter', () => {
        const src = `foo(integer x) { { integer x = 2; } }`;
        const diags = lint(src).filter(d => d.ruleId === 'LSL005');
        expect(diags.length).toBe(1);
        expect(diags[0]!.message).toContain('parameter');
    });

    it('flags duplicate in same direct scope', () => {
        const src = `foo() { integer x; integer x; }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL005').length).toBe(1);
    });

    it('does not flag locals in different functions', () => {
        const src = `
            foo() { integer x = 1; }
            bar() { integer x = 2; }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL005')).toEqual([]);
    });

    it('does not flag locals in different event handlers', () => {
        const src = `default { state_entry() { integer x; } touch_start(integer n) { integer x; } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL005')).toEqual([]);
    });

    it('does not flag a local shadowing a global (standard scoping is OK)', () => {
        const src = `integer Count = 0; foo() { integer Count = 5; }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL005')).toEqual([]);
    });
});

describe('LSL011 — global use before declaration', () => {
    it('flags global used in initializer of an earlier global', () => {
        const src = `integer B = A; integer A = 5;`;
        const diags = lint(src).filter(d => d.ruleId === 'LSL011');
        expect(diags.length).toBe(1);
        expect(diags[0]!.message).toContain("'A'");
    });

    it('does not flag if declaration comes first', () => {
        const src = `integer A = 5; integer B = A;`;
        expect(lint(src).filter(d => d.ruleId === 'LSL011')).toEqual([]);
    });

    it('does not flag forward function reference (functions hoist)', () => {
        // f is called before its declaration text-wise — LSL allows this.
        const src = `default { state_entry() { f(); } }  integer f() { return 1; }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL011')).toEqual([]);
    });
});

describe('LSL031 — missing return in non-void function', () => {
    it('flags function that falls off the end', () => {
        const src = `integer f() { integer x = 1; }`;
        const diags = lint(src).filter(d => d.ruleId === 'LSL031');
        expect(diags.length).toBe(1);
        expect(diags[0]!.message).toContain("'f'");
    });

    it('does not flag function that always returns', () => {
        const src = `integer f() { return 1; }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL031')).toEqual([]);
    });

    it('does not flag if both branches of if/else return', () => {
        const src = `integer f(integer n) { if (n > 0) { return 1; } else { return 0; } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL031')).toEqual([]);
    });

    it('flags if only one branch returns', () => {
        const src = `integer f(integer n) { if (n > 0) { return 1; } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL031').length).toBe(1);
    });

    it('does not flag void functions', () => {
        const src = `f() { integer x = 1; }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL031')).toEqual([]);
    });

    it('flags when a while loop is the only "exit"', () => {
        // while body may never execute, so f can fall through with no return.
        const src = `integer f(integer n) { while (n > 0) { return 1; } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL031').length).toBe(1);
    });

    it('does not flag when do-while guarantees a return (body always runs)', () => {
        const src = `integer f() { do { return 1; } while (FALSE); }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL031')).toEqual([]);
    });

    it('does not flag function that ends in state change', () => {
        const src = `
            integer f() { state other; }
            state other { state_entry() {} }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL031')).toEqual([]);
    });
});
