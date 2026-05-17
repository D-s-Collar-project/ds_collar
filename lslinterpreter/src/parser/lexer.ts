import { TokenKind, Token, Position, KEYWORDS } from './tokens.js';

export class LexerError extends Error {
    constructor(message: string, public readonly position: Position) {
        super(message);
    }
}

export class Lexer {
    private offset = 0;
    private line = 1;
    private column = 1;
    private readonly tokens: Token[] = [];

    constructor(private readonly source: string) {}

    static lex(source: string): Token[] {
        return new Lexer(source).run();
    }

    private run(): Token[] {
        while (this.offset < this.source.length) {
            this.scanToken();
        }
        this.tokens.push({ kind: TokenKind.EOF, text: '', start: this.pos(), end: this.pos() });
        return this.tokens;
    }

    private pos(): Position {
        return { line: this.line, column: this.column, offset: this.offset };
    }

    private peek(offset = 0): string {
        return this.source[this.offset + offset] ?? '';
    }

    private advance(): string {
        const ch = this.source[this.offset]!;
        this.offset += 1;
        if (ch === '\n') {
            this.line += 1;
            this.column = 1;
        } else {
            this.column += 1;
        }
        return ch;
    }

    private match(expected: string): boolean {
        if (this.peek() !== expected) return false;
        this.advance();
        return true;
    }

    private push(kind: TokenKind, text: string, start: Position): void {
        this.tokens.push({ kind, text, start, end: this.pos() });
    }

    private scanToken(): void {
        const start = this.pos();
        const ch = this.advance();

        if (ch === ' ' || ch === '\t' || ch === '\r' || ch === '\n') return;

        // Line comment
        if (ch === '/' && this.peek() === '/') {
            this.advance();
            while (this.offset < this.source.length && this.peek() !== '\n') this.advance();
            return;
        }
        // Block comment
        if (ch === '/' && this.peek() === '*') {
            this.advance();
            while (this.offset < this.source.length && !(this.peek() === '*' && this.peek(1) === '/')) {
                this.advance();
            }
            if (this.offset < this.source.length) { this.advance(); this.advance(); }
            return;
        }

        switch (ch) {
            case '(': return this.push(TokenKind.LParen, '(', start);
            case ')': return this.push(TokenKind.RParen, ')', start);
            case '{': return this.push(TokenKind.LBrace, '{', start);
            case '}': return this.push(TokenKind.RBrace, '}', start);
            case '[': return this.push(TokenKind.LBracket, '[', start);
            case ']': return this.push(TokenKind.RBracket, ']', start);
            case ';': return this.push(TokenKind.Semicolon, ';', start);
            case ',': return this.push(TokenKind.Comma, ',', start);
            case '.': {
                if (this.isDigit(this.peek())) return this.scanNumber(ch, start);
                return this.push(TokenKind.Dot, '.', start);
            }
            case '@': return this.push(TokenKind.At, '@', start);
            case '?': return this.push(TokenKind.Question, '?', start);
            case ':': return this.push(TokenKind.Colon, ':', start);
            case '~': return this.push(TokenKind.BitwiseNot, '~', start);
            case '^': return this.push(TokenKind.BitwiseXor, '^', start);
        }

        if (ch === '+') {
            if (this.match('+')) return this.push(TokenKind.Increment, '++', start);
            if (this.match('=')) return this.push(TokenKind.PlusAssign, '+=', start);
            return this.push(TokenKind.Plus, '+', start);
        }
        if (ch === '-') {
            if (this.match('-')) return this.push(TokenKind.Decrement, '--', start);
            if (this.match('=')) return this.push(TokenKind.MinusAssign, '-=', start);
            return this.push(TokenKind.Minus, '-', start);
        }
        if (ch === '*') {
            if (this.match('=')) return this.push(TokenKind.StarAssign, '*=', start);
            return this.push(TokenKind.Star, '*', start);
        }
        if (ch === '/') {
            if (this.match('=')) return this.push(TokenKind.SlashAssign, '/=', start);
            return this.push(TokenKind.Slash, '/', start);
        }
        if (ch === '%') {
            if (this.match('=')) return this.push(TokenKind.PercentAssign, '%=', start);
            return this.push(TokenKind.Percent, '%', start);
        }
        if (ch === '=') {
            if (this.match('=')) return this.push(TokenKind.Equal, '==', start);
            return this.push(TokenKind.Assign, '=', start);
        }
        if (ch === '!') {
            if (this.match('=')) return this.push(TokenKind.NotEqual, '!=', start);
            return this.push(TokenKind.LogicalNot, '!', start);
        }
        if (ch === '<') {
            if (this.match('=')) return this.push(TokenKind.LessEqual, '<=', start);
            if (this.match('<')) return this.push(TokenKind.LeftShift, '<<', start);
            return this.push(TokenKind.Less, '<', start);
        }
        if (ch === '>') {
            if (this.match('=')) return this.push(TokenKind.GreaterEqual, '>=', start);
            if (this.match('>')) return this.push(TokenKind.RightShift, '>>', start);
            return this.push(TokenKind.Greater, '>', start);
        }
        if (ch === '&') {
            if (this.match('&')) return this.push(TokenKind.LogicalAnd, '&&', start);
            return this.push(TokenKind.BitwiseAnd, '&', start);
        }
        if (ch === '|') {
            if (this.match('|')) return this.push(TokenKind.LogicalOr, '||', start);
            return this.push(TokenKind.BitwiseOr, '|', start);
        }

        if (ch === '"') return this.scanString(start);
        if (this.isDigit(ch)) return this.scanNumber(ch, start);
        if (this.isIdentStart(ch)) return this.scanIdentifier(ch, start);

        throw new LexerError(`unexpected character ${JSON.stringify(ch)}`, start);
    }

    private scanString(start: Position): void {
        let text = '"';
        while (this.offset < this.source.length && this.peek() !== '"') {
            const c = this.advance();
            text += c;
            if (c === '\\' && this.offset < this.source.length) {
                text += this.advance();
            }
        }
        if (this.offset >= this.source.length) {
            throw new LexerError('unterminated string literal', start);
        }
        this.advance();
        text += '"';
        this.push(TokenKind.StringLiteral, text, start);
    }

    private scanNumber(first: string, start: Position): void {
        let text = first;
        let isFloat = first === '.';

        if (first === '0' && (this.peek() === 'x' || this.peek() === 'X')) {
            text += this.advance();
            while (this.isHex(this.peek())) text += this.advance();
            this.push(TokenKind.IntegerLiteral, text, start);
            return;
        }

        while (this.isDigit(this.peek())) text += this.advance();

        if (!isFloat && this.peek() === '.') {
            isFloat = true;
            text += this.advance();
            while (this.isDigit(this.peek())) text += this.advance();
        }

        if (this.peek() === 'e' || this.peek() === 'E') {
            isFloat = true;
            text += this.advance();
            if (this.peek() === '+' || this.peek() === '-') text += this.advance();
            while (this.isDigit(this.peek())) text += this.advance();
        }

        this.push(isFloat ? TokenKind.FloatLiteral : TokenKind.IntegerLiteral, text, start);
    }

    private scanIdentifier(first: string, start: Position): void {
        let text = first;
        while (this.isIdentCont(this.peek())) text += this.advance();
        const kw = KEYWORDS.get(text);
        this.push(kw ?? TokenKind.Identifier, text, start);
    }

    private isDigit(c: string): boolean { return c >= '0' && c <= '9'; }
    private isHex(c: string): boolean {
        return this.isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    }
    private isIdentStart(c: string): boolean {
        return c === '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    }
    private isIdentCont(c: string): boolean {
        return this.isIdentStart(c) || this.isDigit(c);
    }
}
