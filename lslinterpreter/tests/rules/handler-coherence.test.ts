import { describe, it, expect } from 'vitest';
import { Lexer } from '../../src/parser/lexer.js';
import { Parser } from '../../src/parser/parser.js';
import { runRules } from '../../src/analyzer/runner.js';

function lint(source: string, enable: string[] = []) {
    const tokens = Lexer.lex(source);
    const { script } = Parser.parse(tokens);
    return runRules({ file: 'test.lsl', source, tokens, script }, { enable: new Set(enable) });
}

describe('LSL044 — listener opened without listen() handler', () => {
    it('flags llListen in state with no listen handler', () => {
        const src = `default { state_entry() { llListen(0, "", NULL_KEY, ""); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL044').length).toBe(1);
    });
    it('does not flag when state has a listen handler', () => {
        const src = `default {
            state_entry() { llListen(0, "", NULL_KEY, ""); }
            listen(integer c, string n, key i, string m) {}
        }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL044')).toEqual([]);
    });
    it('flags per-state independently', () => {
        const src = `
            default { state_entry() { state foo; } }
            state foo {
                state_entry() { llListen(0, "", NULL_KEY, ""); }
            }
        `;
        expect(lint(src).filter(d => d.ruleId === 'LSL044').length).toBe(1);
    });
});

describe('LSL045 — timer armed without timer() handler', () => {
    it('flags llSetTimerEvent(>0) with no timer handler', () => {
        const src = `default { state_entry() { llSetTimerEvent(1.0); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL045').length).toBe(1);
    });
    it('does not flag when llSetTimerEvent(0) (disarm)', () => {
        const src = `default { state_entry() { llSetTimerEvent(0); } }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL045')).toEqual([]);
    });
    it('does not flag when state has a timer handler', () => {
        const src = `default {
            state_entry() { llSetTimerEvent(1.0); }
            timer() {}
        }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL045')).toEqual([]);
    });
});

describe('LSL046 — at_target without llTarget call', () => {
    it('flags at_target when no llTarget call exists', () => {
        const src = `default {
            state_entry() {}
            at_target(integer t, vector tp, vector mp) {}
        }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL046').length).toBe(1);
    });
    it('flags not_at_target the same way', () => {
        const src = `default {
            state_entry() {}
            not_at_target() {}
        }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL046').length).toBe(1);
    });
    it('does not flag when llTarget is called somewhere in the script', () => {
        const src = `default {
            state_entry() { integer h = llTarget(<0,0,0>, 1.0); }
            at_target(integer t, vector tp, vector mp) {}
        }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL046')).toEqual([]);
    });
});

describe('LSL047 — llHTTPRequest with no http_response handler', () => {
    it('flags llHTTPRequest with no handler', () => {
        const src = `default {
            state_entry() { llHTTPRequest("https://x.com/", [], ""); }
        }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL047').length).toBe(1);
    });
    it('does not flag when http_response handler exists', () => {
        const src = `default {
            state_entry() { llHTTPRequest("https://x.com/", [], ""); }
            http_response(key id, integer s, list m, string b) {}
        }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL047')).toEqual([]);
    });
});

describe('LSL048 — llSensor with no sensor/no_sensor handler', () => {
    it('flags llSensor with neither handler', () => {
        const src = `default {
            state_entry() { llSensor("", NULL_KEY, AGENT, 10.0, PI); }
        }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL048').length).toBe(1);
    });
    it('does not flag when sensor handler exists', () => {
        const src = `default {
            state_entry() { llSensor("", NULL_KEY, AGENT, 10.0, PI); }
            sensor(integer n) {}
        }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL048')).toEqual([]);
    });
    it('does not flag when only no_sensor handler exists (sufficient for the negative case)', () => {
        const src = `default {
            state_entry() { llSensor("", NULL_KEY, AGENT, 10.0, PI); }
            no_sensor() {}
        }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL048')).toEqual([]);
    });
    it('also catches llSensorRepeat', () => {
        const src = `default {
            state_entry() { llSensorRepeat("", NULL_KEY, AGENT, 10.0, PI, 5.0); }
        }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL048').length).toBe(1);
    });
});

describe('LSL049 — missing CHANGED_OWNER reference', () => {
    it('flags changed() handler that does not reference CHANGED_OWNER', () => {
        const src = `default {
            state_entry() {}
            changed(integer c) { if (c & CHANGED_LINK) {} }
        }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL049').length).toBe(1);
    });
    it('does not flag when CHANGED_OWNER is referenced', () => {
        const src = `default {
            state_entry() {}
            changed(integer c) { if (c & CHANGED_OWNER) llResetScript(); }
        }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL049')).toEqual([]);
    });
    it('does not flag scripts with no changed() handler at all', () => {
        const src = `default { state_entry() {} }`;
        expect(lint(src).filter(d => d.ruleId === 'LSL049')).toEqual([]);
    });
});
