import {
    Token, TokenKind, Position, KEYWORDS,
} from './tokens.js';
import * as ast from './ast.js';

export type ParseErrorCategory = 'Syntax error' | 'Naming error' | 'Unsupported feature';

export class ParseError extends Error {
    constructor(
        message: string,
        public readonly position: Position,
        public readonly category: ParseErrorCategory = 'Syntax error',
    ) {
        super(message);
    }
}

export interface ParseDiagnostic {
    category: ParseErrorCategory;
    message: string;
    start: Position;
    end: Position;
    severity: 'error' | 'warning';
}

export interface ParseResult {
    script: ast.Script;
    diagnostics: ParseDiagnostic[];
}

const TYPE_TOKENS: ReadonlySet<TokenKind> = new Set([
    TokenKind.Integer, TokenKind.Float, TokenKind.String, TokenKind.Key,
    TokenKind.Vector, TokenKind.Rotation, TokenKind.Quaternion, TokenKind.List,
]);

function describeToken(t: Token): string {
    if (t.kind === TokenKind.EOF) return 'end of file';
    return `'${t.text}'`;
}

function tokenToType(kind: TokenKind): ast.LslType {
    switch (kind) {
        case TokenKind.Integer: return 'integer';
        case TokenKind.Float: return 'float';
        case TokenKind.String: return 'string';
        case TokenKind.Key: return 'key';
        case TokenKind.Vector: return 'vector';
        case TokenKind.Rotation: return 'rotation';
        case TokenKind.Quaternion: return 'rotation';
        case TokenKind.List: return 'list';
        default: throw new Error(`tokenToType called on non-type token ${TokenKind[kind]}`);
    }
}

export class Parser {
    private pos = 0;
    private readonly diagnostics: ParseDiagnostic[] = [];

    constructor(private readonly tokens: Token[]) {}

    static parse(tokens: Token[]): ParseResult {
        const p = new Parser(tokens);
        const script = p.parseScript();
        return { script, diagnostics: p.diagnostics };
    }

    private peek(offset = 0): Token {
        return this.tokens[this.pos + offset] ?? this.tokens[this.tokens.length - 1]!;
    }

    private consume(): Token {
        const t = this.tokens[this.pos]!;
        if (t.kind !== TokenKind.EOF) this.pos += 1;
        return t;
    }

    private check(kind: TokenKind): boolean {
        return this.peek().kind === kind;
    }

    private match(kind: TokenKind): Token | null {
        if (this.check(kind)) return this.consume();
        return null;
    }

    private expect(kind: TokenKind, what: string): Token {
        if (this.check(kind)) return this.consume();
        const t = this.peek();
        throw new ParseError(`expected ${what}, got ${describeToken(t)}`, t.start);
    }

    // Helpers that produce contextual messages for the most common missing-token cases.
    private expectSemicolon(after: string): Token {
        if (this.check(TokenKind.Semicolon)) return this.consume();
        const t = this.peek();
        throw new ParseError(`missing ';' after ${after} (got ${describeToken(t)})`, t.start);
    }

    private expectCloseBrace(closing: string): Token {
        if (this.check(TokenKind.RBrace)) return this.consume();
        const t = this.peek();
        throw new ParseError(`missing '}' to close ${closing} (got ${describeToken(t)})`, t.start);
    }

    private expectCloseParen(closing: string): Token {
        if (this.check(TokenKind.RParen)) return this.consume();
        const t = this.peek();
        throw new ParseError(`missing ')' to close ${closing} (got ${describeToken(t)})`, t.start);
    }

    private expectOpenBrace(opening: string): Token {
        if (this.check(TokenKind.LBrace)) return this.consume();
        const t = this.peek();
        throw new ParseError(`missing '{' to begin ${opening} body (got ${describeToken(t)})`, t.start);
    }

    private expectOpenParen(opening: string): Token {
        if (this.check(TokenKind.LParen)) return this.consume();
        const t = this.peek();
        throw new ParseError(`missing '(' after ${opening} (got ${describeToken(t)})`, t.start);
    }

    private expectCloseBracket(closing: string): Token {
        if (this.check(TokenKind.RBracket)) return this.consume();
        const t = this.peek();
        throw new ParseError(`missing ']' to close ${closing} (got ${describeToken(t)})`, t.start);
    }

    // Accepts an Identifier or any keyword token, treating its text as a name.
    // This lets declarations like `integer key = 5;` parse cleanly so LSL001 can
    // flag the reserved-word collision instead of the parser dying first.
    private isNameLikeToken(t: Token): boolean {
        return t.kind === TokenKind.Identifier || KEYWORDS.has(t.text);
    }

    private parseDeclName(what: string): ast.Identifier {
        const t = this.peek();
        if (this.isNameLikeToken(t)) {
            this.consume();
            return { kind: 'Identifier', name: t.text, start: t.start, end: t.end };
        }
        throw new ParseError(`expected a ${what}, got ${describeToken(t)}`, t.start);
    }

    private report(
        message: string,
        start: Position,
        end: Position,
        category: ParseErrorCategory = 'Syntax error',
        severity: 'error' | 'warning' = 'error',
    ): void {
        this.diagnostics.push({ category, message, start, end, severity });
    }

    // --- Top level ---

    private parseScript(): ast.Script {
        const start = this.peek().start;
        const globals: ast.GlobalVariable[] = [];
        const functions: ast.FunctionDeclaration[] = [];
        const states: ast.StateDeclaration[] = [];

        while (!this.check(TokenKind.EOF)) {
            try {
                this.parseTopLevel(globals, functions, states);
            } catch (e) {
                if (e instanceof ParseError) {
                    this.report(e.message, e.position, e.position, e.category);
                    this.recoverToTopLevel();
                } else {
                    throw e;
                }
            }
        }

        const end = this.peek().end;
        return { kind: 'Script', start, end, globals, functions, states };
    }

    private parseTopLevel(
        globals: ast.GlobalVariable[],
        functions: ast.FunctionDeclaration[],
        states: ast.StateDeclaration[],
    ): void {
        const t = this.peek();
        if (t.kind === TokenKind.Default || t.kind === TokenKind.State) {
            states.push(this.parseStateDeclaration());
            return;
        }
        // Function with explicit return type, or global variable.
        if (TYPE_TOKENS.has(t.kind)) {
            const typeTok = this.consume();
            const type = tokenToType(typeTok.kind);
            const name = this.parseDeclName('identifier');
            if (this.check(TokenKind.LParen)) {
                functions.push(this.parseFunctionTail(typeTok.start, type, name));
            } else {
                globals.push(this.parseGlobalVariableTail(typeTok.start, type, name));
            }
            return;
        }
        // Function with no return type (void): NAME '(' ...
        if (this.isNameLikeToken(t) && this.peek(1).kind === TokenKind.LParen) {
            const nameTok = this.consume();
            const name: ast.Identifier = { kind: 'Identifier', name: nameTok.text, start: nameTok.start, end: nameTok.end };
            functions.push(this.parseFunctionTail(nameTok.start, null, name));
            return;
        }
        throw new ParseError(`unexpected ${describeToken(t)} at file scope; expected a global variable, function, or state declaration`, t.start);
    }

    private parseGlobalVariableTail(start: Position, type: ast.LslType, name: ast.Identifier): ast.GlobalVariable {
        let initializer: ast.Expression | null = null;
        if (this.match(TokenKind.Assign)) {
            initializer = this.parseExpression();
        }
        const semi = this.expectSemicolon('global variable declaration');
        return { kind: 'GlobalVariable', start, end: semi.end, type, name, initializer };
    }

    private parseFunctionTail(start: Position, returnType: ast.LslType | null, name: ast.Identifier): ast.FunctionDeclaration {
        this.expectOpenParen(`function '${name.name}'`);
        const params = this.parseParameters();
        this.expectCloseParen(`function '${name.name}' parameter list`);
        const body = this.parseBlock();
        return { kind: 'FunctionDeclaration', start, end: body.end, returnType, name, params, body };
    }

    private parseParameters(): ast.Parameter[] {
        const params: ast.Parameter[] = [];
        if (this.check(TokenKind.RParen)) return params;
        params.push(this.parseParameter());
        while (this.match(TokenKind.Comma)) {
            params.push(this.parseParameter());
        }
        return params;
    }

    private parseParameter(): ast.Parameter {
        const t = this.peek();
        if (!TYPE_TOKENS.has(t.kind)) {
            throw new ParseError(
                `parameter must declare a type (integer, float, string, key, vector, rotation, list); got ${describeToken(t)}`,
                t.start,
            );
        }
        const typeTok = this.consume();
        const type = tokenToType(typeTok.kind);
        const name = this.parseDeclName('parameter name');
        return { kind: 'Parameter', start: typeTok.start, end: name.end, type, name };
    }

    private parseStateDeclaration(): ast.StateDeclaration {
        const head = this.consume(); // 'default' or 'state'
        const isDefault = head.kind === TokenKind.Default;
        let name: ast.Identifier;
        if (isDefault) {
            name = { kind: 'Identifier', name: 'default', start: head.start, end: head.end };
        } else {
            name = this.parseDeclName('state name');
        }
        this.expectOpenBrace(isDefault ? "'default' state" : `state '${name.name}'`);
        const events: ast.EventHandler[] = [];
        while (!this.check(TokenKind.RBrace) && !this.check(TokenKind.EOF)) {
            try {
                events.push(this.parseEventHandler());
            } catch (e) {
                if (e instanceof ParseError) {
                    this.report(e.message, e.position, e.position, e.category);
                    this.recoverInsideState();
                } else {
                    throw e;
                }
            }
        }
        const close = this.expectCloseBrace(isDefault ? "'default' state body" : `state '${name.name}' body`);
        return { kind: 'StateDeclaration', start: head.start, end: close.end, name, isDefault, events };
    }

    private parseEventHandler(): ast.EventHandler {
        const t = this.peek();
        if (!this.isNameLikeToken(t)) {
            throw new ParseError(
                `expected an event handler name (e.g. state_entry, touch_start, listen); got ${describeToken(t)}`,
                t.start,
            );
        }
        const nameTok = this.consume();
        const name: ast.Identifier = { kind: 'Identifier', name: nameTok.text, start: nameTok.start, end: nameTok.end };
        this.expectOpenParen(`event handler '${name.name}'`);
        const params = this.parseParameters();
        this.expectCloseParen(`event handler '${name.name}' parameter list`);
        const body = this.parseBlock();
        return { kind: 'EventHandler', start: nameTok.start, end: body.end, name, params, body };
    }

    // --- Statements ---

    private parseBlock(): ast.Block {
        const open = this.expectOpenBrace('block');
        const statements: ast.Statement[] = [];
        while (!this.check(TokenKind.RBrace) && !this.check(TokenKind.EOF)) {
            try {
                statements.push(this.parseStatement());
            } catch (e) {
                if (e instanceof ParseError) {
                    this.report(e.message, e.position, e.position, e.category);
                    this.recoverToStatementBoundary();
                } else {
                    throw e;
                }
            }
        }
        const close = this.expectCloseBrace('block');
        return { kind: 'Block', start: open.start, end: close.end, statements };
    }

    private parseStatement(): ast.Statement {
        const t = this.peek();

        if (t.kind === TokenKind.LBrace) return this.parseBlock();
        if (t.kind === TokenKind.Semicolon) {
            const s = this.consume();
            return { kind: 'EmptyStatement', start: s.start, end: s.end };
        }
        if (t.kind === TokenKind.If) return this.parseIf();
        if (t.kind === TokenKind.While) return this.parseWhile();
        if (t.kind === TokenKind.Do) return this.parseDoWhile();
        if (t.kind === TokenKind.For) return this.parseFor();
        if (t.kind === TokenKind.Jump) return this.parseJump();
        if (t.kind === TokenKind.Return) return this.parseReturn();
        if (t.kind === TokenKind.At) return this.parseLabel();
        if (t.kind === TokenKind.State) return this.parseStateChange();

        // Local variable: TYPE NAME [= expr] ;
        if (TYPE_TOKENS.has(t.kind) && this.isNameLikeToken(this.peek(1))
            && (this.peek(2).kind === TokenKind.Assign || this.peek(2).kind === TokenKind.Semicolon)) {
            return this.parseLocalVariable();
        }

        return this.parseExpressionStatement();
    }

    private parseLocalVariable(): ast.LocalVariable {
        const typeTok = this.consume();
        const type = tokenToType(typeTok.kind);
        const name = this.parseDeclName('variable name');
        let initializer: ast.Expression | null = null;
        if (this.match(TokenKind.Assign)) {
            initializer = this.parseExpression();
        }
        const semi = this.expectSemicolon('local variable declaration');
        return { kind: 'LocalVariable', start: typeTok.start, end: semi.end, type, name, initializer };
    }

    private parseExpressionStatement(): ast.ExpressionStatement {
        const expr = this.parseExpression();
        const semi = this.expectSemicolon('statement');
        return { kind: 'ExpressionStatement', start: expr.start, end: semi.end, expression: expr };
    }

    private parseIf(): ast.IfStatement {
        const head = this.consume();
        this.expectOpenParen("'if'");
        const test = this.parseExpression();
        this.expectCloseParen("'if' condition");
        const consequent = this.parseStatement();
        let alternate: ast.Statement | null = null;
        if (this.match(TokenKind.Else)) {
            alternate = this.parseStatement();
        }
        const end = alternate ? alternate.end : consequent.end;
        return { kind: 'IfStatement', start: head.start, end, test, consequent, alternate };
    }

    private parseWhile(): ast.WhileStatement {
        const head = this.consume();
        this.expectOpenParen("'while'");
        const test = this.parseExpression();
        this.expectCloseParen("'while' condition");
        const body = this.parseStatement();
        return { kind: 'WhileStatement', start: head.start, end: body.end, test, body };
    }

    private parseDoWhile(): ast.DoWhileStatement {
        const head = this.consume();
        const body = this.parseStatement();
        if (!this.check(TokenKind.While)) {
            const t = this.peek();
            throw new ParseError(`'do' loop must be followed by 'while (...)'; got ${describeToken(t)}`, t.start);
        }
        this.consume();
        this.expectOpenParen("'while'");
        const test = this.parseExpression();
        this.expectCloseParen("'while' condition");
        const semi = this.expectSemicolon('do-while loop');
        return { kind: 'DoWhileStatement', start: head.start, end: semi.end, body, test };
    }

    private parseFor(): ast.ForStatement {
        const head = this.consume();
        this.expectOpenParen("'for'");
        const init = this.parseExpressionList(TokenKind.Semicolon);
        this.expectSemicolon("'for' loop initializer");
        const test = this.check(TokenKind.Semicolon) ? null : this.parseExpression();
        this.expectSemicolon("'for' loop condition");
        const update = this.parseExpressionList(TokenKind.RParen);
        this.expectCloseParen("'for' loop header");
        const body = this.parseStatement();
        return { kind: 'ForStatement', start: head.start, end: body.end, init, test, update, body };
    }

    private parseExpressionList(terminator: TokenKind): ast.Expression[] {
        const exprs: ast.Expression[] = [];
        if (this.check(terminator)) return exprs;
        exprs.push(this.parseExpression());
        while (this.match(TokenKind.Comma)) exprs.push(this.parseExpression());
        return exprs;
    }

    private parseJump(): ast.JumpStatement {
        const head = this.consume();
        const label = this.parseDeclName('label name');
        const semi = this.expectSemicolon("'jump' statement");
        return { kind: 'JumpStatement', start: head.start, end: semi.end, label };
    }

    private parseLabel(): ast.LabelStatement {
        const at = this.consume();
        const name = this.parseDeclName('label name');
        const semi = this.expectSemicolon('label declaration');
        return { kind: 'LabelStatement', start: at.start, end: semi.end, name };
    }

    private parseReturn(): ast.ReturnStatement {
        const head = this.consume();
        let value: ast.Expression | null = null;
        if (!this.check(TokenKind.Semicolon)) value = this.parseExpression();
        const semi = this.expectSemicolon("'return' statement");
        return { kind: 'ReturnStatement', start: head.start, end: semi.end, value };
    }

    private parseStateChange(): ast.StateChangeStatement {
        const head = this.consume();
        const targetTok = this.peek();
        let target: ast.Identifier;
        if (targetTok.kind === TokenKind.Default) {
            const t = this.consume();
            target = { kind: 'Identifier', name: 'default', start: t.start, end: t.end };
        } else if (this.isNameLikeToken(targetTok)) {
            const t = this.consume();
            target = { kind: 'Identifier', name: t.text, start: t.start, end: t.end };
        } else {
            throw new ParseError(`'state' must be followed by a target state name; got ${describeToken(targetTok)}`, targetTok.start);
        }
        const semi = this.expectSemicolon('state change');
        return { kind: 'StateChangeStatement', start: head.start, end: semi.end, target };
    }

    // --- Expressions (Pratt / precedence climbing) ---
    // Precedence levels (low → high):
    //   1 assignment (right-assoc)
    //   2 ||
    //   3 &&
    //   4 |
    //   5 ^
    //   6 &
    //   7 == !=
    //   8 < > <= >=
    //   9 << >>
    //  10 + -
    //  11 * / %
    //  12 unary prefix
    //  13 postfix / call / index / member

    private parseExpression(): ast.Expression {
        return this.parseAssignment();
    }

    private parseAssignment(): ast.Expression {
        const left = this.parseBinary(2);
        const t = this.peek();
        if (this.isAssignOp(t.kind)) {
            this.consume();
            const right = this.parseAssignment();
            return {
                kind: 'AssignmentExpression',
                start: left.start, end: right.end,
                operator: t.text, target: left, value: right,
            };
        }
        return left;
    }

    private isAssignOp(k: TokenKind): boolean {
        return k === TokenKind.Assign || k === TokenKind.PlusAssign || k === TokenKind.MinusAssign
            || k === TokenKind.StarAssign || k === TokenKind.SlashAssign || k === TokenKind.PercentAssign;
    }

    // Returns the precedence of a binary operator token, or 0 if not a binary operator at the given floor.
    private binaryPrecedence(k: TokenKind): number {
        switch (k) {
            case TokenKind.LogicalOr: return 2;
            case TokenKind.LogicalAnd: return 3;
            case TokenKind.BitwiseOr: return 4;
            case TokenKind.BitwiseXor: return 5;
            case TokenKind.BitwiseAnd: return 6;
            case TokenKind.Equal: case TokenKind.NotEqual: return 7;
            case TokenKind.Less: case TokenKind.Greater: case TokenKind.LessEqual: case TokenKind.GreaterEqual: return 8;
            case TokenKind.LeftShift: case TokenKind.RightShift: return 9;
            case TokenKind.Plus: case TokenKind.Minus: return 10;
            case TokenKind.Star: case TokenKind.Slash: case TokenKind.Percent: return 11;
            default: return 0;
        }
    }

    private parseBinary(minPrec: number): ast.Expression {
        let left = this.parseUnary();
        while (true) {
            const t = this.peek();
            // Detect ternary (illegal in LSL — record it so LSL002 can flag it).
            if (t.kind === TokenKind.Question) {
                this.consume();
                const consequent = this.parseAssignment();
                this.match(TokenKind.Colon); // tolerate missing colon for recovery
                const alternate = this.parseAssignment();
                left = { kind: 'TernaryExpression', start: left.start, end: alternate.end, test: left, consequent, alternate };
                continue;
            }
            const prec = this.binaryPrecedence(t.kind);
            if (prec === 0 || prec < minPrec) break;
            this.consume();
            const right = this.parseBinary(prec + 1); // left-assoc
            left = { kind: 'BinaryExpression', start: left.start, end: right.end, operator: t.text, left, right };
        }
        return left;
    }

    private parseUnary(): ast.Expression {
        const t = this.peek();
        if (t.kind === TokenKind.Minus || t.kind === TokenKind.Plus
            || t.kind === TokenKind.LogicalNot || t.kind === TokenKind.BitwiseNot) {
            this.consume();
            const operand = this.parseUnary();
            return { kind: 'UnaryExpression', start: t.start, end: operand.end, operator: t.text as any, operand };
        }
        if (t.kind === TokenKind.Increment || t.kind === TokenKind.Decrement) {
            this.consume();
            const operand = this.parseUnary();
            return { kind: 'UnaryExpression', start: t.start, end: operand.end, operator: t.text as '++' | '--', operand };
        }
        // Cast: '(' TYPE ')' unary
        if (t.kind === TokenKind.LParen && TYPE_TOKENS.has(this.peek(1).kind) && this.peek(2).kind === TokenKind.RParen) {
            const lp = this.consume();
            const typeTok = this.consume();
            this.consume(); // ')'
            const operand = this.parseUnary();
            return { kind: 'CastExpression', start: lp.start, end: operand.end, targetType: tokenToType(typeTok.kind), operand };
        }
        return this.parsePostfix();
    }

    private parsePostfix(): ast.Expression {
        let expr = this.parsePrimary();
        while (true) {
            const t = this.peek();
            if (t.kind === TokenKind.Increment || t.kind === TokenKind.Decrement) {
                this.consume();
                expr = { kind: 'PostfixExpression', start: expr.start, end: t.end, operator: t.text as '++' | '--', operand: expr };
                continue;
            }
            if (t.kind === TokenKind.LParen) {
                this.consume();
                const args = this.parseExpressionList(TokenKind.RParen);
                const close = this.expectCloseParen('function call argument list');
                expr = { kind: 'CallExpression', start: expr.start, end: close.end, callee: expr, args };
                continue;
            }
            if (t.kind === TokenKind.LBracket) {
                this.consume();
                const index = this.parseExpression();
                const close = this.expectCloseBracket('index expression');
                expr = { kind: 'IndexExpression', start: expr.start, end: close.end, object: expr, index };
                continue;
            }
            if (t.kind === TokenKind.Dot) {
                this.consume();
                const memberTok = this.expect(TokenKind.Identifier, "member name (e.g. .x, .y, .z, .s)");
                const member: ast.Identifier = { kind: 'Identifier', name: memberTok.text, start: memberTok.start, end: memberTok.end };
                expr = { kind: 'MemberExpression', start: expr.start, end: memberTok.end, object: expr, member };
                continue;
            }
            return expr;
        }
    }

    private parsePrimary(): ast.Expression {
        const t = this.peek();
        if (t.kind === TokenKind.IntegerLiteral) {
            this.consume();
            return { kind: 'IntegerLiteral', start: t.start, end: t.end, value: parseInt(t.text, t.text.startsWith('0x') ? 16 : 10), raw: t.text };
        }
        if (t.kind === TokenKind.FloatLiteral) {
            this.consume();
            return { kind: 'FloatLiteral', start: t.start, end: t.end, value: parseFloat(t.text), raw: t.text };
        }
        if (t.kind === TokenKind.StringLiteral) {
            this.consume();
            // Strip surrounding quotes for `value`; leave escapes as-is for v1.
            const value = t.text.slice(1, -1);
            return { kind: 'StringLiteral', start: t.start, end: t.end, value, raw: t.text };
        }
        if (t.kind === TokenKind.Identifier) {
            this.consume();
            return { kind: 'IdentifierExpression', start: t.start, end: t.end, name: t.text };
        }
        if (t.kind === TokenKind.LParen) {
            this.consume();
            const inner = this.parseExpression();
            const close = this.expectCloseParen('parenthesized expression');
            return { kind: 'ParenthesizedExpression', start: t.start, end: close.end, expression: inner };
        }
        if (t.kind === TokenKind.LBracket) {
            this.consume();
            const elements = this.parseExpressionList(TokenKind.RBracket);
            const close = this.expectCloseBracket('list literal');
            return { kind: 'ListLiteral', start: t.start, end: close.end, elements };
        }
        if (t.kind === TokenKind.Less) {
            return this.parseVectorOrRotation();
        }
        throw new ParseError(`unexpected ${describeToken(t)} where an expression was expected`, t.start);
    }

    // <a, b, c> or <a, b, c, d>. Components parsed at additive precedence so `>` is not consumed
    // as a comparison operator inside the literal.
    private parseVectorOrRotation(): ast.Expression {
        const open = this.consume(); // '<'
        const x = this.parseBinary(10);
        this.expectCommaInVector(1);
        const y = this.parseBinary(10);
        this.expectCommaInVector(2);
        const z = this.parseBinary(10);
        if (this.match(TokenKind.Comma)) {
            const s = this.parseBinary(10);
            const close = this.expectVectorClose('rotation literal');
            return { kind: 'RotationLiteral', start: open.start, end: close.end, x, y, z, s };
        }
        const close = this.expectVectorClose('vector literal');
        return { kind: 'VectorLiteral', start: open.start, end: close.end, x, y, z };
    }

    private expectCommaInVector(componentIndex: number): void {
        if (this.check(TokenKind.Comma)) { this.consume(); return; }
        const t = this.peek();
        throw new ParseError(
            `missing ',' between vector/rotation components (after component ${componentIndex}, got ${describeToken(t)})`,
            t.start,
        );
    }

    private expectVectorClose(what: string): Token {
        if (this.check(TokenKind.Greater)) return this.consume();
        const t = this.peek();
        throw new ParseError(`missing '>' to close ${what} (got ${describeToken(t)})`, t.start);
    }

    // --- Recovery ---

    private recoverToTopLevel(): void {
        while (!this.check(TokenKind.EOF)) {
            const t = this.peek();
            if (t.kind === TokenKind.Default || t.kind === TokenKind.State) return;
            if (TYPE_TOKENS.has(t.kind) && this.peek(1).kind === TokenKind.Identifier) return;
            if (t.kind === TokenKind.Identifier && this.peek(1).kind === TokenKind.LParen) return;
            this.consume();
        }
    }

    private recoverInsideState(): void {
        let depth = 0;
        while (!this.check(TokenKind.EOF)) {
            const t = this.peek();
            if (depth === 0 && t.kind === TokenKind.RBrace) return;
            if (depth === 0 && t.kind === TokenKind.Identifier && this.peek(1).kind === TokenKind.LParen) return;
            if (t.kind === TokenKind.LBrace) depth += 1;
            if (t.kind === TokenKind.RBrace) depth -= 1;
            this.consume();
        }
    }

    private recoverToStatementBoundary(): void {
        let depth = 0;
        while (!this.check(TokenKind.EOF)) {
            const t = this.peek();
            if (depth === 0 && (t.kind === TokenKind.Semicolon || t.kind === TokenKind.RBrace)) {
                if (t.kind === TokenKind.Semicolon) this.consume();
                return;
            }
            if (t.kind === TokenKind.LBrace) depth += 1;
            if (t.kind === TokenKind.RBrace) depth -= 1;
            this.consume();
        }
    }
}
