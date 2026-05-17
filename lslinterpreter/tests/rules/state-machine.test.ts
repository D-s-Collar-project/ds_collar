import { describe, it, expect } from 'vitest';
import { Lexer } from '../../src/parser/lexer.js';
import { Parser } from '../../src/parser/parser.js';
import { runRules } from '../../src/analyzer/runner.js';

function lint(source: string, enable: string[] = []) {
    const tokens = Lexer.lex(source);
    const { script } = Parser.parse(tokens);
    return runRules({ file: 'test.lsl', source, tokens, script }, { enable: new Set(enable) });
}

describe('LSL040 — same-state transition is a no-op', () => {
    it('flags `state default;` inside default state', () => {
        const src = `default { state_entry() { state default; } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL040').length).toBe(1);
    });
    it('flags `state foo;` inside state foo', () => {
        const src = `
            default { state_entry() { state foo; } }
            state foo { timer() { state foo; } }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL040').length).toBe(1);
    });
    it('does not flag transition to a different state', () => {
        const src = `
            default { state_entry() { state foo; } }
            state foo { state_entry() { state default; } }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL040')).toEqual([]);
    });
});

describe('LSL041 — state change inside user function', () => {
    it('flags `state X;` inside a function body', () => {
        const src = `
            helper() { state foo; }
            default { state_entry() { helper(); } }
            state foo { state_entry() {} }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL041').length).toBe(1);
    });
    it('does not flag state change inside event handler', () => {
        const src = `
            default { state_entry() { state foo; } }
            state foo { state_entry() {} }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL041')).toEqual([]);
    });
});

describe('LSL042 — unreachable state', () => {
    it('flags a state with no incoming transition', () => {
        const src = `
            default { state_entry() {} }
            state lonely { state_entry() {} }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL042').length).toBe(1);
    });
    it('does not flag default (always reachable as initial state)', () => {
        const src = `default { state_entry() {} }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL042')).toEqual([]);
    });
    it('does not flag a state targeted from anywhere in the script', () => {
        const src = `
            default { state_entry() { state foo; } }
            state foo { state_entry() {} }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL042')).toEqual([]);
    });
    it('does not flag a state targeted only from a user function', () => {
        const src = `
            go() { state foo; }
            default { state_entry() { go(); } }
            state foo { state_entry() {} }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL042')).toEqual([]);
    });
});

describe('LSL043 — state has no state_entry', () => {
    it('flags a non-default state with no state_entry in a multi-state script', () => {
        const src = `
            default { state_entry() { state foo; } }
            state foo { timer() {} }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL043').length).toBe(1);
    });
    it('does not fire in a single-state (default-only) script', () => {
        const src = `default { link_message(integer s, integer n, string m, key i) {} }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL043')).toEqual([]);
    });
    it('does not flag states that have state_entry', () => {
        const src = `
            default { state_entry() { state foo; } }
            state foo { state_entry() {} }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL043')).toEqual([]);
    });
});
