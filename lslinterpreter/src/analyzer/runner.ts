import type { Script } from '../parser/ast.js';
import type { Token } from '../parser/tokens.js';
import type { Diagnostic } from './diagnostic.js';
import { buildScriptSymbols, ScriptSymbols } from './symbols.js';
import { BUILTINS, BuiltinCatalog } from './builtins.js';
import { allRules } from './rules/index.js';

export interface RuleContext {
    file: string;
    source: string;
    tokens: Token[];
    script: Script;
    symbols: ScriptSymbols;
    builtins: BuiltinCatalog;
    report(d: Omit<Diagnostic, 'file'>): void;
}

export interface Rule {
    id: string;
    description: string;
    /**
     * Whether the rule fires by default. Default-off rules encode project-specific
     * conventions (e.g. RLV-only `llOwnerSay`) that would false-positive on general
     * LSL code. Opt in with `--enable <ID>` on the CLI.
     */
    defaultEnabled?: boolean;
    check(ctx: RuleContext): void;
}

export interface RunRulesOptions {
    /** Rule IDs explicitly enabled (overrides defaultEnabled=false). */
    enable?: Set<string>;
    /** Rule IDs explicitly disabled (overrides defaultEnabled=true). */
    disable?: Set<string>;
}

export function runRules(input: {
    file: string;
    source: string;
    tokens: Token[];
    script: Script;
}, options: RunRulesOptions = {}): Diagnostic[] {
    const diagnostics: Diagnostic[] = [];
    const symbols = buildScriptSymbols(input.script);
    const ctx: RuleContext = {
        ...input,
        symbols,
        builtins: BUILTINS,
        report(d) {
            diagnostics.push({ ...d, file: input.file });
        },
    };
    for (const rule of allRules) {
        if (!isRuleEnabled(rule, options)) continue;
        try {
            rule.check(ctx);
        } catch (e) {
            // A rule that throws shouldn't kill the whole run. Surface it as an error diagnostic
            // so the user can see which rule misbehaved.
            const msg = e instanceof Error ? e.message : String(e);
            diagnostics.push({
                ruleId: rule.id,
                category: 'Internal error',
                severity: 'error',
                message: `rule ${rule.id} crashed: ${msg}`,
                file: input.file,
                start: { line: 1, column: 1, offset: 0 },
                end: { line: 1, column: 1, offset: 0 },
            });
        }
    }
    return diagnostics;
}

export function isRuleEnabled(rule: Rule, options: RunRulesOptions): boolean {
    if (options.disable?.has(rule.id)) return false;
    if (options.enable?.has(rule.id)) return true;
    return rule.defaultEnabled !== false;     // default-on unless explicitly opted out
}
