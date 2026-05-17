import { describe, it, expect } from 'vitest';
import { Lexer } from '../../src/parser/lexer.js';
import { Parser } from '../../src/parser/parser.js';
import { runRules } from '../../src/analyzer/runner.js';

function lint(source: string) {
    const tokens = Lexer.lex(source);
    const { script } = Parser.parse(tokens);
    return runRules({ file: 'test.lsl', source, tokens, script });
}

describe('LSL027 — unbounded global growth', () => {
    it('flags a global list that only grows', () => {
        const src = `
            list gHistory = [];
            default {
                touch_start(integer n) {
                    gHistory += [llDetectedKey(0)];
                }
            }
        `;
        const diags = lint(src).filter(d => d.ruleId === 'LSL027');
        expect(diags.length).toBe(1);
        expect(diags[0]!.message).toContain('gHistory');
        expect(diags[0]!.category).toBe('Memory warning');
    });

    it('does not flag a global list that is reset elsewhere', () => {
        const src = `
            list gHistory = [];
            default {
                touch_start(integer n) {
                    gHistory += [llDetectedKey(0)];
                }
                timer() {
                    gHistory = [];
                }
            }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL027')).toEqual([]);
    });

    it('flags a string global that grows via +=', () => {
        const src = `
            string gLog = "";
            default {
                listen(integer c, string n, key id, string m) {
                    gLog += m;
                }
            }
        `;
        const diags = lint(src).filter(d => d.ruleId === 'LSL027');
        expect(diags.length).toBe(1);
        expect(diags[0]!.message).toContain('gLog');
    });

    it('flags g = g + x form', () => {
        const src = `
            list gItems = [];
            default {
                touch_start(integer n) {
                    gItems = gItems + [1];
                }
            }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL027').length).toBe(1);
    });

    it('does not flag globals that are not list/string', () => {
        const src = `integer gCount = 0; default { touch_start(integer n) { gCount += 1; } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL027')).toEqual([]);
    });
});

describe('LSL028 — concat in loop', () => {
    it('flags += inside a for loop on a global list', () => {
        const src = `
            list gOut = [];
            default {
                state_entry() {
                    integer i;
                    for (i = 0; i < 10; ++i) {
                        gOut += [i];
                    }
                }
            }
        `;
        const diags = lint(src).filter(d => d.ruleId === 'LSL028');
        expect(diags.length).toBe(1);
        expect(diags[0]!.message).toContain('gOut');
    });

    it('flags string += inside a while loop', () => {
        const src = `
            string gBuf = "";
            default {
                state_entry() {
                    integer i = 0;
                    while (i < 10) { gBuf += "x"; i = i + 1; }
                }
            }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL028').length).toBe(1);
    });

    it('does not flag concat outside a loop', () => {
        const src = `
            list gOut = [];
            default { state_entry() { gOut += [1]; } }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL028')).toEqual([]);
    });
});

describe('LSL029 — direct recursion', () => {
    it('flags a function that calls itself', () => {
        const src = `integer fact(integer n) { if (n < 2) return 1; return n * fact(n - 1); }`;
        const diags = lint(src).filter(d => d.ruleId === 'LSL029');
        expect(diags.length).toBe(1);
        expect(diags[0]!.message).toContain('fact');
        expect(diags[0]!.category).toBe('Memory warning');
    });

    it('does not flag non-recursive functions', () => {
        const src = `integer add(integer a, integer b) { return a + b; }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL029')).toEqual([]);
    });

    it('does not flag a function that calls a same-named LSL builtin look-alike from a different fn', () => {
        const src = `
            integer add(integer a, integer b) { return a + b; }
            integer caller() { return add(1, 2); }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL029')).toEqual([]);
    });
});
