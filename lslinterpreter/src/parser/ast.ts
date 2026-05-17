import type { Position } from './tokens.js';

export interface Span {
    start: Position;
    end: Position;
}

// 'quaternion' is normalized to 'rotation' at parse time — they're the same type in LSL.
export type LslType = 'integer' | 'float' | 'string' | 'key' | 'vector' | 'rotation' | 'list';

export interface Identifier extends Span {
    kind: 'Identifier';
    name: string;
}

// Top-level

export interface Script extends Span {
    kind: 'Script';
    globals: GlobalVariable[];
    functions: FunctionDeclaration[];
    states: StateDeclaration[];
}

export interface GlobalVariable extends Span {
    kind: 'GlobalVariable';
    type: LslType;
    name: Identifier;
    initializer: Expression | null;
}

export interface FunctionDeclaration extends Span {
    kind: 'FunctionDeclaration';
    returnType: LslType | null;
    name: Identifier;
    params: Parameter[];
    body: Block;
}

export interface Parameter extends Span {
    kind: 'Parameter';
    type: LslType;
    name: Identifier;
}

export interface StateDeclaration extends Span {
    kind: 'StateDeclaration';
    name: Identifier;
    isDefault: boolean;
    events: EventHandler[];
}

export interface EventHandler extends Span {
    kind: 'EventHandler';
    name: Identifier;
    params: Parameter[];
    body: Block;
}

// Statements

export type Statement =
    | Block
    | LocalVariable
    | ExpressionStatement
    | IfStatement
    | WhileStatement
    | DoWhileStatement
    | ForStatement
    | JumpStatement
    | LabelStatement
    | ReturnStatement
    | StateChangeStatement
    | EmptyStatement;

export interface Block extends Span {
    kind: 'Block';
    statements: Statement[];
}

export interface LocalVariable extends Span {
    kind: 'LocalVariable';
    type: LslType;
    name: Identifier;
    initializer: Expression | null;
}

export interface ExpressionStatement extends Span {
    kind: 'ExpressionStatement';
    expression: Expression;
}

export interface IfStatement extends Span {
    kind: 'IfStatement';
    test: Expression;
    consequent: Statement;
    alternate: Statement | null;
}

export interface WhileStatement extends Span {
    kind: 'WhileStatement';
    test: Expression;
    body: Statement;
}

export interface DoWhileStatement extends Span {
    kind: 'DoWhileStatement';
    body: Statement;
    test: Expression;
}

export interface ForStatement extends Span {
    kind: 'ForStatement';
    init: Expression[];
    test: Expression | null;
    update: Expression[];
    body: Statement;
}

export interface JumpStatement extends Span {
    kind: 'JumpStatement';
    label: Identifier;
}

export interface LabelStatement extends Span {
    kind: 'LabelStatement';
    name: Identifier;
}

export interface ReturnStatement extends Span {
    kind: 'ReturnStatement';
    value: Expression | null;
}

export interface StateChangeStatement extends Span {
    kind: 'StateChangeStatement';
    target: Identifier;
}

export interface EmptyStatement extends Span {
    kind: 'EmptyStatement';
}

// Expressions

export type Expression =
    | IntegerLiteral
    | FloatLiteral
    | StringLiteral
    | IdentifierExpression
    | UnaryExpression
    | PostfixExpression
    | BinaryExpression
    | AssignmentExpression
    | CallExpression
    | IndexExpression
    | MemberExpression
    | VectorLiteral
    | RotationLiteral
    | ListLiteral
    | CastExpression
    | TernaryExpression
    | ParenthesizedExpression;

export interface IntegerLiteral extends Span { kind: 'IntegerLiteral'; value: number; raw: string; }
export interface FloatLiteral extends Span { kind: 'FloatLiteral'; value: number; raw: string; }
export interface StringLiteral extends Span { kind: 'StringLiteral'; value: string; raw: string; }
export interface IdentifierExpression extends Span { kind: 'IdentifierExpression'; name: string; }
export interface UnaryExpression extends Span { kind: 'UnaryExpression'; operator: '+' | '-' | '!' | '~' | '++' | '--'; operand: Expression; }
export interface PostfixExpression extends Span { kind: 'PostfixExpression'; operator: '++' | '--'; operand: Expression; }
export interface BinaryExpression extends Span { kind: 'BinaryExpression'; operator: string; left: Expression; right: Expression; }
export interface AssignmentExpression extends Span { kind: 'AssignmentExpression'; operator: string; target: Expression; value: Expression; }
export interface CallExpression extends Span { kind: 'CallExpression'; callee: Expression; args: Expression[]; }
export interface IndexExpression extends Span { kind: 'IndexExpression'; object: Expression; index: Expression; }
export interface MemberExpression extends Span { kind: 'MemberExpression'; object: Expression; member: Identifier; }
export interface VectorLiteral extends Span { kind: 'VectorLiteral'; x: Expression; y: Expression; z: Expression; }
export interface RotationLiteral extends Span { kind: 'RotationLiteral'; x: Expression; y: Expression; z: Expression; s: Expression; }
export interface ListLiteral extends Span { kind: 'ListLiteral'; elements: Expression[]; }
export interface CastExpression extends Span { kind: 'CastExpression'; targetType: LslType; operand: Expression; }
// LSL has no ternary — present so the parser can record it and a rule can flag it cleanly.
export interface TernaryExpression extends Span { kind: 'TernaryExpression'; test: Expression; consequent: Expression; alternate: Expression; }
export interface ParenthesizedExpression extends Span { kind: 'ParenthesizedExpression'; expression: Expression; }

// Catch-all union of every node kind, useful for visitors.
export type AnyNode =
    | Script | GlobalVariable | FunctionDeclaration | Parameter | StateDeclaration | EventHandler
    | Statement | Expression | Identifier;
