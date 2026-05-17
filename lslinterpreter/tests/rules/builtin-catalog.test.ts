import { describe, it, expect } from 'vitest';
import { Lexer } from '../../src/parser/lexer.js';
import { Parser } from '../../src/parser/parser.js';
import { runRules } from '../../src/analyzer/runner.js';
import { BUILTINS } from '../../src/analyzer/builtins.js';

function lint(source: string) {
    const tokens = Lexer.lex(source);
    const { script } = Parser.parse(tokens);
    return runRules({ file: 'test.lsl', source, tokens, script });
}

describe('Builtin catalog loaded', () => {
    it('contains expected functions, events, and constants', () => {
        expect(BUILTINS.isBuiltinFunction('llSay')).toBe(true);
        expect(BUILTINS.isBuiltinFunction('llGetOwner')).toBe(true);
        expect(BUILTINS.isBuiltinEvent('state_entry')).toBe(true);
        expect(BUILTINS.isBuiltinConstant('TRUE')).toBe(true);
        expect(BUILTINS.isBuiltinConstant('PERMISSION_TRIGGER_ANIMATION')).toBe(true);
        expect(BUILTINS.isBuiltinFunction('NOT_A_REAL_FUNCTION')).toBe(false);
    });

    it('records correct signatures for key functions', () => {
        const llSay = BUILTINS.functions.get('llSay');
        expect(llSay).toBeDefined();
        expect(llSay!.returnType).toBe('void');
        expect(llSay!.params.length).toBe(2);
        expect(llSay!.params[0]!.type).toBe('integer');
        expect(llSay!.params[1]!.type).toBe('string');
    });
});

describe('LSL030 — undeclared identifier', () => {
    it('flags a typo for an LSL builtin', () => {
        const src = `default { state_entry() { llRegonSayTo(llGetOwner(), 0, "hi"); } }`;
        const diags = lint(src).filter(d => d.ruleId === 'LSL030');
        expect(diags.some(d => d.message.includes('llRegonSayTo'))).toBe(true);
    });

    it('does not flag a correctly named builtin', () => {
        const src = `default { state_entry() { llRegionSayTo(llGetOwner(), 0, "hi"); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL030')).toEqual([]);
    });

    it('does not flag user-declared globals or functions', () => {
        const src = `
            integer Count = 0;
            integer add(integer a, integer b) { return a + b; }
            default { state_entry() { Count = add(1, 2); } }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL030')).toEqual([]);
    });

    it('does not flag LSL constants', () => {
        const src = `default { state_entry() { llSay(0, (string)PERMISSION_TRIGGER_ANIMATION); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL030')).toEqual([]);
    });

    it('flags an unknown identifier in an expression', () => {
        const src = `default { state_entry() { integer x = unknown_var + 1; } }`;
        const diags = lint(src).filter(d => d.ruleId === 'LSL030');
        expect(diags.some(d => d.message.includes('unknown_var'))).toBe(true);
    });
});

describe('LSL034 — wrong argument count', () => {
    it('flags llSay with too few args', () => {
        const src = `default { state_entry() { llSay(0); } }`;
        const diags = lint(src).filter(d => d.ruleId === 'LSL034');
        expect(diags.length).toBe(1);
        expect(diags[0]!.message).toContain('expects 2');
    });

    it('flags llSay with too many args', () => {
        const src = `default { state_entry() { llSay(0, "hi", "extra"); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL034').length).toBe(1);
    });

    it('does not flag correct call', () => {
        const src = `default { state_entry() { llSay(0, "hi"); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL034')).toEqual([]);
    });

    it('flags user function with wrong arg count', () => {
        const src = `integer add(integer a, integer b) { return a + b; } default { state_entry() { add(1); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL034').length).toBe(1);
    });
});

describe('LSL035 — wrong argument type', () => {
    it('flags string passed where integer expected', () => {
        const src = `default { state_entry() { llSay("not a channel", "hi"); } }`;
        const diags = lint(src).filter(d => d.ruleId === 'LSL035');
        expect(diags.length).toBe(1);
        expect(diags[0]!.message).toContain('expects integer, got string');
    });

    it('flags vector passed where string expected', () => {
        const src = `default { state_entry() { llSay(0, <1, 2, 3>); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL035').length).toBe(1);
    });

    it('allows integer where float expected (implicit promotion)', () => {
        const src = `default { state_entry() { llSetTimerEvent(1); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL035')).toEqual([]);
    });

    it('allows string where key expected', () => {
        const src = `default { state_entry() { llKey2Name("abc"); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL035')).toEqual([]);
    });

    it('uses declared variable type for inference', () => {
        const src = `string Msg = "hi"; default { state_entry() { llSay(Msg, "x"); } }`;
        const diags = lint(src).filter(d => d.ruleId === 'LSL035');
        expect(diags.length).toBe(1);
        expect(diags[0]!.message).toContain('expects integer, got string');
    });

    it('skips arg whose type cannot be inferred', () => {
        // call result of a user fn whose return is unknown — actually we DO infer it,
        // so this tests that we don't flag a correctly-typed inferred value.
        const src = `
            integer chan() { return -1; }
            default { state_entry() { llSay(chan(), "hi"); } }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL035')).toEqual([]);
    });
});
