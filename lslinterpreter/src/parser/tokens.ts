// Token kinds and the LSL reserved-identifier catalog.
// Reserved-word list mirrors project CLAUDE.md §15.1.

export enum TokenKind {
    // Literals
    IntegerLiteral,
    FloatLiteral,
    StringLiteral,
    Identifier,

    // Flow-control keywords
    Do, Else, For, If, Jump, Return, While,

    // Type keywords
    Float, Integer, Key, List, Quaternion, Rotation, String, Vector,

    // State keywords
    Default, State,

    // Punctuation
    LParen, RParen, LBrace, RBrace, LBracket, RBracket,
    Semicolon, Comma, Dot, At, Colon,

    // Assignment operators
    Assign, PlusAssign, MinusAssign, StarAssign, SlashAssign, PercentAssign,

    // Arithmetic
    Plus, Minus, Star, Slash, Percent, Increment, Decrement,

    // Comparison
    Equal, NotEqual, Less, Greater, LessEqual, GreaterEqual,

    // Logical
    LogicalAnd, LogicalOr, LogicalNot,

    // Bitwise
    BitwiseAnd, BitwiseOr, BitwiseXor, BitwiseNot, LeftShift, RightShift,

    // Illegal in LSL but lexed so the analyzer can flag it (LSL002).
    Question,

    EOF,
}

export interface Position {
    line: number;       // 1-based
    column: number;     // 1-based
    offset: number;     // 0-based byte offset into source
}

export interface Token {
    kind: TokenKind;
    text: string;
    start: Position;
    end: Position;
}

export const KEYWORDS: ReadonlyMap<string, TokenKind> = new Map([
    ['do', TokenKind.Do],
    ['else', TokenKind.Else],
    ['for', TokenKind.For],
    ['if', TokenKind.If],
    ['jump', TokenKind.Jump],
    ['return', TokenKind.Return],
    ['while', TokenKind.While],
    ['float', TokenKind.Float],
    ['integer', TokenKind.Integer],
    ['key', TokenKind.Key],
    ['list', TokenKind.List],
    ['quaternion', TokenKind.Quaternion],
    ['rotation', TokenKind.Rotation],
    ['string', TokenKind.String],
    ['vector', TokenKind.Vector],
    ['default', TokenKind.Default],
    ['state', TokenKind.State],
]);

// Reserved by the language as flow-control / type / state keywords.
export const RESERVED_LANGUAGE: ReadonlySet<string> = new Set([
    'do', 'else', 'for', 'if', 'jump', 'return', 'while',
    'float', 'integer', 'key', 'list', 'quaternion', 'rotation', 'string', 'vector',
    'default', 'state',
]);

// All 44 LSL event handler names — reserved as identifiers everywhere (CLAUDE.md §15.1).
export const RESERVED_EVENTS: ReadonlySet<string> = new Set([
    'at_rot_target', 'at_target', 'attach', 'changed', 'collision', 'collision_end', 'collision_start',
    'control', 'dataserver', 'email', 'experience_permissions', 'experience_permissions_denied',
    'final_damage', 'game_control', 'http_request', 'http_response',
    'land_collision', 'land_collision_end', 'land_collision_start', 'link_message', 'linkset_data', 'listen',
    'money', 'moving_end', 'moving_start', 'no_sensor', 'not_at_rot_target', 'not_at_target',
    'object_rez', 'on_damage', 'on_death', 'on_rez', 'path_update', 'remote_data',
    'run_time_permissions', 'sensor', 'state_entry', 'state_exit',
    'timer', 'touch', 'touch_end', 'touch_start', 'transaction_result',
]);

// High-value subset of LSL built-in constants (the full set is 690+ — full catalog
// will eventually live in builtins.json).
export const RESERVED_CONSTANTS: ReadonlySet<string> = new Set([
    'TRUE', 'FALSE', 'NULL_KEY', 'ZERO_VECTOR', 'ZERO_ROTATION',
    'PI', 'TWO_PI', 'PI_BY_TWO', 'DEG_TO_RAD', 'RAD_TO_DEG', 'SQRT2', 'EOF',
    'JSON_INVALID', 'JSON_TRUE', 'JSON_FALSE', 'JSON_NULL',
    'JSON_ARRAY', 'JSON_OBJECT', 'JSON_STRING', 'JSON_NUMBER',
]);

export const ALL_RESERVED: ReadonlySet<string> = new Set([
    ...RESERVED_LANGUAGE,
    ...RESERVED_EVENTS,
    ...RESERVED_CONSTANTS,
]);

export function isReservedIdentifier(name: string): boolean {
    return ALL_RESERVED.has(name);
}

// All identifiers prefixed with `ll` are reserved for Linden Library functions.
export function startsWithLindenPrefix(name: string): boolean {
    return name.length >= 2 && name[0] === 'l' && name[1] === 'l';
}

// Categorize a reserved identifier for a clearer diagnostic message.
export function categorizeReserved(name: string): 'flow-control' | 'type' | 'state' | 'event' | 'constant' | null {
    if (['do', 'else', 'for', 'if', 'jump', 'return', 'while'].includes(name)) return 'flow-control';
    if (['float', 'integer', 'key', 'list', 'quaternion', 'rotation', 'string', 'vector'].includes(name)) return 'type';
    if (['default', 'state'].includes(name)) return 'state';
    if (RESERVED_EVENTS.has(name)) return 'event';
    if (RESERVED_CONSTANTS.has(name)) return 'constant';
    return null;
}
