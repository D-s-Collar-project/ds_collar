import { describe, it, expect } from 'vitest';
import { Lexer } from '../../src/parser/lexer.js';
import { Parser } from '../../src/parser/parser.js';
import { runRules } from '../../src/analyzer/runner.js';

function lint(source: string) {
    const tokens = Lexer.lex(source);
    const { script, diagnostics: parseDiags } = Parser.parse(tokens);
    const ruleDiags = runRules({ file: 'test.lsl', source, tokens, script });
    return [
        ...parseDiags.map(d => ({
            category: d.category,
            severity: d.severity,
            message: d.message,
            file: 'test.lsl',
            start: d.start,
            end: d.end,
        })),
        ...ruleDiags,
    ];
}

describe('LSL001 — reserved identifiers', () => {
    it('flags a reserved type name used as a global variable', () => {
        const diags = lint('integer key = 5;');
        expect(diags.some(d => d.ruleId === 'LSL001' && d.message.includes("'key'"))).toBe(true);
    });

    it('flags a reserved event name used as a parameter', () => {
        const diags = lint('do_thing(integer timer) { timer = 1; }');
        expect(diags.some(d => d.ruleId === 'LSL001' && d.message.includes("'timer'"))).toBe(true);
    });

    it('flags a reserved constant used as a local', () => {
        const diags = lint('default { state_entry() { integer TRUE = 0; } }');
        expect(diags.some(d => d.ruleId === 'LSL001' && d.message.includes("'TRUE'"))).toBe(true);
    });

    it('does not flag legal user identifiers', () => {
        const diags = lint('integer my_counter = 0;');
        expect(diags.filter(d => d.ruleId === 'LSL001')).toEqual([]);
    });
});

describe('LSL002 — ternary', () => {
    it('flags ?:', () => {
        const diags = lint('integer x = 1 ? 2 : 3;');
        expect(diags.some(d => d.ruleId === 'LSL002')).toBe(true);
    });
});

describe('LSL003 — switch/break/continue', () => {
    it('flags switch as an expression statement', () => {
        const diags = lint('default { state_entry() { switch(x); } }');
        expect(diags.some(d => d.ruleId === 'LSL003')).toBe(true);
    });
    it('flags bare break/continue', () => {
        const diags = lint('default { state_entry() { break; continue; } }');
        const lsl003 = diags.filter(d => d.ruleId === 'LSL003');
        expect(lsl003.length).toBeGreaterThanOrEqual(2);
    });
});

describe('LSL004 — user function with ll prefix', () => {
    it('flags a function named llHelper', () => {
        const diags = lint('integer llHelper() { return 0; }');
        expect(diags.some(d => d.ruleId === 'LSL004')).toBe(true);
    });
    it('does not flag a function whose name happens to contain ll later', () => {
        const diags = lint('integer myHelper() { return 0; }');
        expect(diags.filter(d => d.ruleId === 'LSL004')).toEqual([]);
    });
});

describe('LSL026 — literal type mismatch', () => {
    it('flags integer literal initializing a string', () => {
        const diags = lint('string s = 5;');
        const lsl026 = diags.filter(d => d.ruleId === 'LSL026');
        expect(lsl026.length).toBe(1);
        expect(lsl026[0]!.category).toBe('Type error');
        expect(lsl026[0]!.message).toContain('an integer literal');
    });
    it('flags float literal initializing an integer', () => {
        const diags = lint('integer x = 1.5;');
        expect(diags.some(d => d.ruleId === 'LSL026')).toBe(true);
    });
    it('does not flag integer literal initializing a float (implicit promotion)', () => {
        const diags = lint('float y = 3;');
        expect(diags.filter(d => d.ruleId === 'LSL026')).toEqual([]);
    });
    it('does not flag string literal initializing a key', () => {
        const diags = lint('key k = "abc";');
        expect(diags.filter(d => d.ruleId === 'LSL026')).toEqual([]);
    });
    it('does not flag identifier initializers (constants like NULL_KEY)', () => {
        const diags = lint('key k = NULL_KEY;');
        expect(diags.filter(d => d.ruleId === 'LSL026')).toEqual([]);
    });
});

describe('parser — categorized error messages', () => {
    it('reports a missing semicolon with context', () => {
        const diags = lint('integer x = 5');
        const syntax = diags.filter(d => d.category === 'Syntax error');
        expect(syntax.length).toBeGreaterThanOrEqual(1);
        expect(syntax[0]!.message).toContain("missing ';'");
        expect(syntax[0]!.message).toContain('global variable declaration');
    });
    it('reports a missing close brace with state context', () => {
        const diags = lint('default { state_entry() {} ');
        expect(diags.some(d =>
            d.category === 'Syntax error' && d.message.includes("missing '}'"))).toBe(true);
    });
    it('reports unexpected token at file scope', () => {
        const diags = lint('5;');
        expect(diags.some(d =>
            d.category === 'Syntax error' && d.message.includes('file scope'))).toBe(true);
    });
});
