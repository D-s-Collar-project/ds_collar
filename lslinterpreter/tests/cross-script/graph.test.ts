import { describe, it, expect } from 'vitest';
import { Lexer } from '../../src/parser/lexer.js';
import { Parser } from '../../src/parser/parser.js';
import type { ScriptUnit } from '../../src/analyzer/project.js';
import { buildProjectGraph, runCrossScriptRules } from '../../src/analyzer/cross-script.js';

function makeUnit(file: string, source: string): ScriptUnit {
    const tokens = Lexer.lex(source);
    const { script } = Parser.parse(tokens);
    return { file, source, tokens, script };
}

describe('Project graph extraction', () => {
    it('extracts a link_message emit type from llList2Json payload', () => {
        const sender = makeUnit('a.lsl', `
            integer KERNEL_LIFECYCLE = 500;
            default {
                state_entry() {
                    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE,
                        llList2Json(JSON_OBJECT, ["type", "kernel.register.declare", "ctx", "x"]),
                        NULL_KEY);
                }
            }
        `);
        const g = buildProjectGraph([sender]);
        expect(g.emits.length).toBe(1);
        expect(g.emits[0]!.typeString).toBe('kernel.register.declare');
    });

    it('extracts a link_message handler type from msg_type ==', () => {
        const handler = makeUnit('b.lsl', `
            integer KERNEL_LIFECYCLE = 500;
            default {
                link_message(integer s, integer n, string msg, key id) {
                    if (n != KERNEL_LIFECYCLE) return;
                    string msg_type = llJsonGetValue(msg, ["type"]);
                    if (msg_type == "kernel.register.declare") {
                        llSay(0, "got it");
                    }
                }
            }
        `);
        const g = buildProjectGraph([handler]);
        expect(g.handlers.length).toBe(1);
        expect(g.handlers[0]!.typeString).toBe('kernel.register.declare');
    });

    it('extracts LSD writes and reads as literal keys', () => {
        const u = makeUnit('c.lsl', `
            default {
                state_entry() {
                    llLinksetDataWrite("kernel.lifecycle.phase", "running");
                    string p = llLinksetDataRead("kernel.lifecycle.phase");
                }
            }
        `);
        const g = buildProjectGraph([u]);
        expect(g.lsdWrites.length).toBe(1);
        expect(g.lsdWrites[0]!.key).toBe('kernel.lifecycle.phase');
        expect(g.lsdReads.length).toBe(1);
        expect(g.lsdReads[0]!.key).toBe('kernel.lifecycle.phase');
    });

    it('resolves global string constants in LSD keys to their literal value', () => {
        const u = makeUnit('d.lsl', `
            string KEY_OWNER = "access.owner";
            string PREFIX = "plugin.reg.";
            string SUFFIX = "ui.core.animate";
            default {
                state_entry() {
                    llLinksetDataWrite(KEY_OWNER, "uuid");
                    llLinksetDataWrite(PREFIX + SUFFIX, "x");
                }
            }
        `);
        const g = buildProjectGraph([u]);
        expect(g.lsdWrites.length).toBe(2);
        expect(g.lsdWrites[0]!.key).toBe('access.owner');
        expect(g.lsdWrites[0]!.isPattern).toBe(false);
        expect(g.lsdWrites[1]!.key).toBe('plugin.reg.ui.core.animate');
        expect(g.lsdWrites[1]!.isPattern).toBe(false);
    });

    it('resolves local-variable assignments with literal RHS to the full literal key', () => {
        // Fix B: when `ctx` has a literal initializer, the concat resolves fully.
        const u = makeUnit('e.lsl', `
            default {
                state_entry() {
                    string ctx = "ui.core.animate";
                    llLinksetDataWrite("plugin.reg." + ctx, "x");
                    string p = llLinksetDataRead("plugin.reg." + ctx);
                }
            }
        `);
        const g = buildProjectGraph([u]);
        expect(g.lsdWrites[0]!.key).toBe('plugin.reg.ui.core.animate');
        expect(g.lsdWrites[0]!.isPattern).toBe(false);
        expect(g.lsdReads[0]!.key).toBe('plugin.reg.ui.core.animate');
    });

    it('records prefix patterns when the variable part is truly dynamic (function-call RHS)', () => {
        // `ctx` is assigned from a builtin call — no static value, so the concat
        // falls back to a `prefix*` pattern.
        const u = makeUnit('f.lsl', `
            default {
                state_entry() {
                    string ctx = llKey2Name(llGetOwner());
                    llLinksetDataWrite("plugin.reg." + ctx, "x");
                }
            }
        `);
        const g = buildProjectGraph([u]);
        expect(g.lsdWrites[0]!.key).toBe('plugin.reg.*');
        expect(g.lsdWrites[0]!.isPattern).toBe(true);
    });

    it('treats `@lsl-ide lsd-owner` annotated lists as synthetic writes', () => {
        // Single-writer architecture: a script declares the keys it owns via
        // annotation, and the actual write site is dynamic (parsed from
        // runtime input). Without the annotation, readers of these keys
        // would XSL004-flag because no static write resolves to them.
        const owner = makeUnit('owner.lsl', `
            // @lsl-ide lsd-owner
            list MANAGED_KEYS = [
                "foo.alpha",
                "foo.beta"
            ];
            default {
                state_entry() {
                    string k = "foo.alpha";
                    llLinksetDataWrite(k, "x");
                }
            }
        `);
        const reader = makeUnit('reader.lsl', `
            default {
                state_entry() {
                    string a = llLinksetDataRead("foo.alpha");
                    string b = llLinksetDataRead("foo.beta");
                }
            }
        `);
        const g = buildProjectGraph([owner, reader]);
        const writeKeys = g.lsdWrites.map(w => w.key).sort();
        expect(writeKeys).toContain('foo.alpha');
        expect(writeKeys).toContain('foo.beta');
        expect(runCrossScriptRules(g).filter(d => d.ruleId === 'XSL004')).toEqual([]);
    });

    it('treats `@lsl-ide lsd-owns:` inline comments as synthetic writes', () => {
        // No runtime list needed — keys come from the comment itself.
        const owner = makeUnit('owner.lsl', `
            // @lsl-ide lsd-owns: foo.alpha, *.cache, bar.beta
            default {
                state_entry() {
                    string k = "acl." + (string)llGetOwner() + ".cache";
                    llLinksetDataWrite(k, "x");
                }
            }
        `);
        const reader = makeUnit('reader.lsl', `
            default {
                state_entry() {
                    string a = llLinksetDataRead("foo.alpha");
                    string b = llLinksetDataRead("bar.beta");
                    string c = llLinksetDataRead("acl.abc-def.cache");
                }
            }
        `);
        const g = buildProjectGraph([owner, reader]);
        const writeKeys = g.lsdWrites.map(w => w.key).sort();
        expect(writeKeys).toContain('foo.alpha');
        expect(writeKeys).toContain('*.cache');
        expect(writeKeys).toContain('bar.beta');
        // `acl.abc-def.cache` read matches the `*.cache` pattern → no XSL004.
        expect(runCrossScriptRules(g).filter(d => d.ruleId === 'XSL004')).toEqual([]);
    });

    it('ignores list globals without the lsd-owner annotation', () => {
        const u = makeUnit('plain.lsl', `
            list MENU_LABELS = ["one", "two"];
        `);
        const g = buildProjectGraph([u]);
        expect(g.lsdWrites.length).toBe(0);
    });

    it('resolves function parameters to literal values via call-site tracing', () => {
        // Helper `lsd_int(key, fb)` does the LSD read; callers pass literal keys.
        // The single llLinksetDataRead inside lsd_int fans out to one access per
        // distinct caller-site argument value.
        const u = makeUnit('h.lsl', `
            string KEY_ONE = "alpha.one";
            string KEY_TWO = "alpha.two";
            integer lsd_int(string lsd_key, integer fb) {
                string v = llLinksetDataRead(lsd_key);
                return (integer)v;
            }
            default {
                state_entry() {
                    integer a = lsd_int(KEY_ONE, 0);
                    integer b = lsd_int(KEY_TWO, 0);
                }
            }
        `);
        const g = buildProjectGraph([u]);
        const reads = g.lsdReads.map(r => r.key).sort();
        expect(reads).toEqual(['alpha.one', 'alpha.two']);
    });
});

describe('XSL001 — orphan link_message emit', () => {
    it('flags an emit with no handler', () => {
        const a = makeUnit('a.lsl', `
            integer NUM = 500;
            default { state_entry() {
                llMessageLinked(LINK_SET, NUM,
                    llList2Json(JSON_OBJECT, ["type", "orphaned.message"]),
                    NULL_KEY);
            } }
        `);
        const b = makeUnit('b.lsl', `default { link_message(integer s, integer n, string m, key i) { } }`);
        const g = buildProjectGraph([a, b]);
        const diags = runCrossScriptRules(g).filter(d => d.ruleId === 'XSL001');
        expect(diags.length).toBe(1);
        expect(diags[0]!.message).toContain('orphaned.message');
        expect(diags[0]!.file).toBe('a.lsl');
    });

    it('does not flag when a handler exists', () => {
        const a = makeUnit('a.lsl', `
            integer NUM = 500;
            default { state_entry() {
                llMessageLinked(LINK_SET, NUM,
                    llList2Json(JSON_OBJECT, ["type", "test.message"]),
                    NULL_KEY);
            } }
        `);
        const b = makeUnit('b.lsl', `
            default { link_message(integer s, integer n, string m, key i) {
                string t = llJsonGetValue(m, ["type"]);
                if (t == "test.message") { }
            } }
        `);
        const g = buildProjectGraph([a, b]);
        expect(runCrossScriptRules(g).filter(d => d.ruleId === 'XSL001')).toEqual([]);
    });
});

describe('XSL002 — dead link_message handler', () => {
    it('flags a handler matching a type that no script emits', () => {
        const a = makeUnit('a.lsl', `
            default { link_message(integer s, integer n, string m, key i) {
                string t = llJsonGetValue(m, ["type"]);
                if (t == "ghost.message") { }
            } }
        `);
        const g = buildProjectGraph([a]);
        const diags = runCrossScriptRules(g).filter(d => d.ruleId === 'XSL002');
        expect(diags.length).toBe(1);
        expect(diags[0]!.message).toContain('ghost.message');
    });
});

describe('XSL003 — LSD key written by multiple scripts', () => {
    it('flags when two scripts write the same literal key', () => {
        const a = makeUnit('a.lsl', `default { state_entry() { llLinksetDataWrite("shared.key", "x"); } }`);
        const b = makeUnit('b.lsl', `default { state_entry() { llLinksetDataWrite("shared.key", "y"); } }`);
        const g = buildProjectGraph([a, b]);
        const diags = runCrossScriptRules(g).filter(d => d.ruleId === 'XSL003');
        expect(diags.length).toBe(2); // one per writer
        expect(diags.every(d => d.message.includes('shared.key'))).toBe(true);
    });

    it('does not flag when only one script writes the key', () => {
        const a = makeUnit('a.lsl', `default { state_entry() { llLinksetDataWrite("solo.key", "x"); } }`);
        const b = makeUnit('b.lsl', `default { state_entry() { llLinksetDataWrite("a.lsl.different", "y"); } }`);
        const g = buildProjectGraph([a, b]);
        expect(runCrossScriptRules(g).filter(d => d.ruleId === 'XSL003')).toEqual([]);
    });
});

describe('XSL004 — LSD key read but never written', () => {
    it('flags read with no producer', () => {
        const a = makeUnit('a.lsl', `default { state_entry() { string v = llLinksetDataRead("phantom.key"); } }`);
        const g = buildProjectGraph([a]);
        const diags = runCrossScriptRules(g).filter(d => d.ruleId === 'XSL004');
        expect(diags.length).toBe(1);
        expect(diags[0]!.message).toContain('phantom.key');
    });

    it('does not flag when a write exists somewhere', () => {
        const a = makeUnit('a.lsl', `default { state_entry() { llLinksetDataWrite("key.a", "v"); } }`);
        const b = makeUnit('b.lsl', `default { state_entry() { string v = llLinksetDataRead("key.a"); } }`);
        const g = buildProjectGraph([a, b]);
        expect(runCrossScriptRules(g).filter(d => d.ruleId === 'XSL004')).toEqual([]);
    });

    it('matches prefix patterns against literal reads (variable part is truly dynamic)', () => {
        // Writer uses a DYNAMIC local (function-call RHS) → falls back to a
        // "plugin.reg.*" pattern. Reader uses a literal in the same family →
        // pattern matches the literal and XSL004 stays silent.
        const writer = makeUnit('w.lsl', `
            default { state_entry() {
                string ctx = llKey2Name(llGetOwner());
                llLinksetDataWrite("plugin.reg." + ctx, "v");
            } }
        `);
        const reader = makeUnit('r.lsl', `default { state_entry() { string v = llLinksetDataRead("plugin.reg.something"); } }`);
        const g = buildProjectGraph([writer, reader]);
        expect(runCrossScriptRules(g).filter(d => d.ruleId === 'XSL004')).toEqual([]);
    });
});
