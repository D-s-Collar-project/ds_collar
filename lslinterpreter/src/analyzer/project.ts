// A Project is a set of LSL scripts analyzed together for cross-script issues
// (orphan link_messages, LSD ownership conflicts, etc.). Each unit holds the parsed
// AST and original source so per-file rules and cross-script rules share the same
// in-memory data.

import { readFileSync } from 'node:fs';
import type { Script } from '../parser/ast.js';
import type { Token } from '../parser/tokens.js';
import { Lexer } from '../parser/lexer.js';
import { Parser } from '../parser/parser.js';

export interface ScriptUnit {
    file: string;
    source: string;
    tokens: Token[];
    script: Script;
}

export function loadScriptUnit(filePath: string): ScriptUnit {
    const source = readFileSync(filePath, 'utf8');
    const tokens = Lexer.lex(source);
    const { script } = Parser.parse(tokens);
    return { file: filePath, source, tokens, script };
}
