import { describe, it, expect } from 'vitest';
import { Lexer } from '../../src/parser/lexer.js';
import { Parser } from '../../src/parser/parser.js';
import { runRules } from '../../src/analyzer/runner.js';

function lint(source: string, enable: string[] = []) {
    const tokens = Lexer.lex(source);
    const { script } = Parser.parse(tokens);
    return runRules({ file: 'test.lsl', source, tokens, script }, { enable: new Set(enable) });
}

describe('LSL013 — listener leak', () => {
    it('flags llListen with no llListenRemove anywhere', () => {
        const src = `default { state_entry() { llListen(0, "", NULL_KEY, ""); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL013').length).toBe(1);
    });
    it('does not flag if llListenRemove is called somewhere', () => {
        const src = `
            integer g = 0;
            default {
                state_entry() { g = llListen(0, "", NULL_KEY, ""); }
                touch_start(integer n) { llListenRemove(g); }
            }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL013')).toEqual([]);
    });
});

describe('LSL015 — JSON_INVALID unchecked', () => {
    it('flags llJsonGetValue with no JSON_INVALID compare anywhere', () => {
        const src = `default { state_entry() { string v = llJsonGetValue("{\\"a\\":1}", ["a"]); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL015').length).toBe(1);
    });
    it('does not flag if JSON_INVALID appears anywhere', () => {
        const src = `
            default {
                state_entry() {
                    string v = llJsonGetValue("{}", ["a"]);
                    if (v == JSON_INVALID) v = "default";
                }
            }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL015')).toEqual([]);
    });
});

describe('LSL016 — llOwnerSay non-RLV (opt-in)', () => {
    it('is OFF by default — does not flag llOwnerSay even with a non-@ literal', () => {
        const src = `default { state_entry() { llOwnerSay("Hello world"); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL016')).toEqual([]);
    });
    it('flags llOwnerSay with non-@ literal when explicitly enabled', () => {
        const src = `default { state_entry() { llOwnerSay("Hello world"); } }`;
        expect(lint(src, ['LSL016']).filter(d => d.ruleId === 'LSL016').length).toBe(1);
    });
    it('does not flag @-prefixed literal (even when enabled)', () => {
        const src = `default { state_entry() { llOwnerSay("@detach=n"); } }`;
        expect(lint(src, ['LSL016']).filter(d => d.ruleId === 'LSL016')).toEqual([]);
    });
    it('does not flag non-literal arg (even when enabled)', () => {
        const src = `string m = "@detach=n"; default { state_entry() { llOwnerSay(m); } }`;
        expect(lint(src, ['LSL016']).filter(d => d.ruleId === 'LSL016')).toEqual([]);
    });
});

describe('LSL017 — permissions without handler', () => {
    it('flags when llRequestPermissions has no run_time_permissions handler', () => {
        const src = `default { state_entry() { llRequestPermissions(llGetOwner(), PERMISSION_TRIGGER_ANIMATION); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL017').length).toBe(1);
    });
    it('does not flag when handler exists', () => {
        const src = `
            default {
                state_entry() { llRequestPermissions(llGetOwner(), PERMISSION_TRIGGER_ANIMATION); }
                run_time_permissions(integer p) {}
            }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL017')).toEqual([]);
    });
});

describe('LSL018 — open llListen', () => {
    it('flags NULL_KEY id', () => {
        const src = `default { state_entry() { llListen(-5, "", NULL_KEY, ""); llListenRemove(0); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL018').length).toBe(1);
    });
    it('flags empty-string id', () => {
        const src = `default { state_entry() { llListen(-5, "", "", ""); llListenRemove(0); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL018').length).toBe(1);
    });
    it('does not flag scoped id', () => {
        const src = `default { state_entry() { llListen(-5, "", llGetOwner(), ""); llListenRemove(0); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL018')).toEqual([]);
    });
});

describe('LSL020 — state change in state_exit', () => {
    it('flags state X; inside state_exit', () => {
        const src = `
            default {
                state_exit() { state other; }
            }
            state other { state_entry() {} }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL020').length).toBe(1);
    });
    it('does not flag state change in state_entry', () => {
        const src = `
            default { state_entry() { state other; } }
            state other { state_entry() {} }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL020')).toEqual([]);
    });
});

describe('LSL021 — unreachable code', () => {
    it('flags statement after return', () => {
        const src = `integer f() { return 1; return 2; }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL021').length).toBe(1);
    });
    it('flags statement after state change', () => {
        const src = `
            default { state_entry() { state other; llOwnerSay("@x=n"); } }
            state other { state_entry() {} }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL021').length).toBe(1);
    });
    it('treats labels as reachable so subsequent code is not flagged', () => {
        // `return 1` IS unreachable (skipped by jump); `return 2` is reachable via @end.
        const src = `integer f() { jump end; return 1; @end; return 2; }`;
        const diags = lint(src).filter(d => d.ruleId === 'LSL021');
        expect(diags.length).toBe(1);
        expect(diags[0]!.message).toContain('jump end');
    });
});

describe('LSL023 — timer re-arm', () => {
    it('flags llSetTimerEvent(1.0) inside timer()', () => {
        const src = `default { timer() { llSetTimerEvent(1.0); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL023').length).toBe(1);
    });
    it('does not flag llSetTimerEvent(0) (disarm)', () => {
        const src = `default { timer() { llSetTimerEvent(0); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL023')).toEqual([]);
    });
    it('does not flag llSetTimerEvent outside timer()', () => {
        const src = `default { state_entry() { llSetTimerEvent(1.0); } timer() {} }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL023')).toEqual([]);
    });
});

describe('LSL024 — effect cleanup', () => {
    it('flags llStartAnimation without llStopAnimation', () => {
        const src = `default { state_entry() { llStartAnimation("sit"); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL024').length).toBe(1);
    });
    it('does not flag if llStopAnimation appears', () => {
        const src = `
            default {
                state_entry() { llStartAnimation("sit"); }
                touch_start(integer n) { llStopAnimation("sit"); }
            }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL024')).toEqual([]);
    });
    it('flags llParticleSystem with non-empty rules and no clearing call', () => {
        const src = `default { state_entry() { llParticleSystem([PSYS_PART_FLAGS, 0]); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL024').length).toBe(1);
    });
    it('does not flag if llParticleSystem([]) appears', () => {
        const src = `
            default {
                state_entry() { llParticleSystem([PSYS_PART_FLAGS, 0]); }
                touch_start(integer n) { llParticleSystem([]); }
            }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL024')).toEqual([]);
    });
});
