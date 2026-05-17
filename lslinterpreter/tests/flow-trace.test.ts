import { describe, it, expect } from 'vitest';
import { Lexer } from '../src/parser/lexer.js';
import { Parser } from '../src/parser/parser.js';
import { buildProjectGraph } from '../src/analyzer/cross-script.js';
import { traceFlow } from '../src/analyzer/flow-trace.js';
import type { ScriptUnit } from '../src/analyzer/project.js';

function makeUnit(file: string, source: string): ScriptUnit {
    const tokens = Lexer.lex(source);
    const { script } = Parser.parse(tokens);
    return { file, source, tokens, script };
}

describe('flow tracer — basic shape', () => {
    it('returns a single node with no handler when no script handles the type', () => {
        const a = makeUnit('a.lsl', `
            default { state_entry() {
                llMessageLinked(LINK_SET, 0, llList2Json(JSON_OBJECT, ["type", "ghost.event"]), NULL_KEY);
            } }
        `);
        const graph = buildProjectGraph([a]);
        const trace = traceFlow(graph, [a], 'ghost.event');
        expect(trace.length).toBe(1);
        expect(trace[0]!.type).toBe('ghost.event');
        expect(trace[0]!.handlers.length).toBe(0);
    });

    it('finds a single handler at depth 0 with no downstream emits', () => {
        const a = makeUnit('a.lsl', `
            default {
                link_message(integer s, integer n, string m, key i) {
                    string t = llJsonGetValue(m, ["type"]);
                    if (t == "evt.foo") { llOwnerSay("got foo"); }
                }
            }
        `);
        const graph = buildProjectGraph([a]);
        const trace = traceFlow(graph, [a], 'evt.foo');
        expect(trace.length).toBe(1);
        expect(trace[0]!.handlers.length).toBe(1);
        expect(trace[0]!.handlers[0]!.outgoing).toEqual([]);
    });
});

describe('flow tracer — direct emits in handler arm', () => {
    it('captures direct downstream emits and traces them', () => {
        const emitter = makeUnit('emit.lsl', `
            default {
                link_message(integer s, integer n, string m, key i) {
                    string t = llJsonGetValue(m, ["type"]);
                    if (t == "evt.alpha") {
                        llMessageLinked(LINK_SET, 0, llList2Json(JSON_OBJECT, ["type", "evt.beta"]), NULL_KEY);
                    }
                }
            }
        `);
        const handler = makeUnit('handle.lsl', `
            default {
                link_message(integer s, integer n, string m, key i) {
                    string t = llJsonGetValue(m, ["type"]);
                    if (t == "evt.beta") { llOwnerSay("beta"); }
                }
            }
        `);
        const graph = buildProjectGraph([emitter, handler]);
        const trace = traceFlow(graph, [emitter, handler], 'evt.alpha');
        const types = trace.map(n => n.type);
        expect(types).toContain('evt.alpha');
        expect(types).toContain('evt.beta');
        const alpha = trace.find(n => n.type === 'evt.alpha')!;
        expect(alpha.handlers[0]!.outgoing).toContain('evt.beta');
    });
});

describe('flow tracer — emits via helper functions', () => {
    it('follows user-function calls inside handler arm', () => {
        const a = makeUnit('a.lsl', `
            send_beta() {
                llMessageLinked(LINK_SET, 0, llList2Json(JSON_OBJECT, ["type", "evt.beta"]), NULL_KEY);
            }
            default {
                link_message(integer s, integer n, string m, key i) {
                    string t = llJsonGetValue(m, ["type"]);
                    if (t == "evt.alpha") { send_beta(); }
                }
            }
        `);
        const graph = buildProjectGraph([a]);
        const trace = traceFlow(graph, [a], 'evt.alpha');
        const alpha = trace.find(n => n.type === 'evt.alpha')!;
        expect(alpha.handlers[0]!.outgoing).toContain('evt.beta');
    });

    it('follows transitively (helper-of-helper)', () => {
        const a = makeUnit('a.lsl', `
            inner() {
                llMessageLinked(LINK_SET, 0, llList2Json(JSON_OBJECT, ["type", "evt.deep"]), NULL_KEY);
            }
            outer() { inner(); }
            default {
                link_message(integer s, integer n, string m, key i) {
                    string t = llJsonGetValue(m, ["type"]);
                    if (t == "evt.start") { outer(); }
                }
            }
        `);
        const graph = buildProjectGraph([a]);
        const trace = traceFlow(graph, [a], 'evt.start');
        const start = trace.find(n => n.type === 'evt.start')!;
        expect(start.handlers[0]!.outgoing).toContain('evt.deep');
    });

    it('breaks function-call cycles without infinite loop', () => {
        const a = makeUnit('a.lsl', `
            f1() { f2(); }
            f2() {
                llMessageLinked(LINK_SET, 0, llList2Json(JSON_OBJECT, ["type", "evt.cycled"]), NULL_KEY);
                f1();
            }
            default {
                link_message(integer s, integer n, string m, key i) {
                    string t = llJsonGetValue(m, ["type"]);
                    if (t == "evt.start") { f1(); }
                }
            }
        `);
        const graph = buildProjectGraph([a]);
        const trace = traceFlow(graph, [a], 'evt.start');
        const start = trace.find(n => n.type === 'evt.start')!;
        expect(start.handlers[0]!.outgoing).toContain('evt.cycled');
    });
});

describe('flow tracer — type-level cycle detection', () => {
    it('marks a type that re-emits itself as a cycle on second appearance', () => {
        const a = makeUnit('a.lsl', `
            default {
                link_message(integer s, integer n, string m, key i) {
                    string t = llJsonGetValue(m, ["type"]);
                    if (t == "evt.loop") {
                        llMessageLinked(LINK_SET, 0, llList2Json(JSON_OBJECT, ["type", "evt.loop"]), NULL_KEY);
                    }
                }
            }
        `);
        const graph = buildProjectGraph([a]);
        const trace = traceFlow(graph, [a], 'evt.loop');
        const cycleNode = trace.find(n => n.cycle === true);
        expect(cycleNode).toBeDefined();
        expect(cycleNode!.type).toBe('evt.loop');
    });
});

describe('flow tracer — depth limit', () => {
    it('stops queueing new types at maxDepth', () => {
        const a = makeUnit('a.lsl', `
            default {
                link_message(integer s, integer n, string m, key i) {
                    string t = llJsonGetValue(m, ["type"]);
                    if (t == "evt.a") { llMessageLinked(LINK_SET, 0, llList2Json(JSON_OBJECT, ["type", "evt.b"]), NULL_KEY); }
                    else if (t == "evt.b") { llMessageLinked(LINK_SET, 0, llList2Json(JSON_OBJECT, ["type", "evt.c"]), NULL_KEY); }
                    else if (t == "evt.c") { llMessageLinked(LINK_SET, 0, llList2Json(JSON_OBJECT, ["type", "evt.d"]), NULL_KEY); }
                }
            }
        `);
        const graph = buildProjectGraph([a]);
        const traceShallow = traceFlow(graph, [a], 'evt.a', 1);
        // depth 0 = a; depth 1 = b; b's outgoing (c) is NOT queued because depth 1 == maxDepth
        const types = traceShallow.map(n => n.type);
        expect(types).toContain('evt.a');
        expect(types).toContain('evt.b');
        expect(types).not.toContain('evt.c');

        const traceDeep = traceFlow(graph, [a], 'evt.a', 5);
        const typesDeep = traceDeep.map(n => n.type);
        expect(typesDeep).toContain('evt.c');
    });
});
