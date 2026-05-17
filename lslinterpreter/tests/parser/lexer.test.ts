import { describe, it, expect } from 'vitest';
import { Lexer } from '../../src/parser/lexer.js';
import { TokenKind } from '../../src/parser/tokens.js';

describe('Lexer', () => {
    it('lexes basic keywords and identifiers', () => {
        const tokens = Lexer.lex('integer x = 5;');
        expect(tokens.map(t => t.kind)).toEqual([
            TokenKind.Integer,
            TokenKind.Identifier,
            TokenKind.Assign,
            TokenKind.IntegerLiteral,
            TokenKind.Semicolon,
            TokenKind.EOF,
        ]);
    });

    it('handles line and block comments', () => {
        const src = `// line comment\n/* block\ncomment */integer y;`;
        const tokens = Lexer.lex(src);
        expect(tokens.map(t => t.kind)).toEqual([
            TokenKind.Integer, TokenKind.Identifier, TokenKind.Semicolon, TokenKind.EOF,
        ]);
    });

    it('lexes the question mark even though it is illegal in LSL', () => {
        // Needed for LSL002 to flag ternary.
        const tokens = Lexer.lex('a ? b : c');
        expect(tokens.some(t => t.kind === TokenKind.Question)).toBe(true);
    });

    it('lexes float and hex integer literals', () => {
        const tokens = Lexer.lex('3.14 0xFF .5 1.0e3');
        const literals = tokens.filter(t =>
            t.kind === TokenKind.FloatLiteral || t.kind === TokenKind.IntegerLiteral
        );
        expect(literals.map(t => t.text)).toEqual(['3.14', '0xFF', '.5', '1.0e3']);
    });

    it('tracks line and column positions', () => {
        const tokens = Lexer.lex('integer\n  x;');
        const xTok = tokens.find(t => t.text === 'x')!;
        expect(xTok.start.line).toBe(2);
        expect(xTok.start.column).toBe(3);
    });

    it('tokenizes string literals with escapes', () => {
        const tokens = Lexer.lex('"hello \\"world\\""');
        expect(tokens[0]!.kind).toBe(TokenKind.StringLiteral);
        expect(tokens[0]!.text).toBe('"hello \\"world\\""');
    });
});
