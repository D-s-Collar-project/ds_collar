import type { Position } from '../parser/tokens.js';

export type Severity = 'error' | 'warning' | 'info';

// User-facing category labels. These appear directly in the output and should read
// naturally — e.g. "Syntax error", "Memory warning". The category encodes both
// the kind of problem and (where it's fixed) the severity word.
export type DiagnosticCategory =
    | 'Syntax error'
    | 'Naming error'
    | 'Unsupported feature'
    | 'Type error'
    | 'Memory error'
    | 'Memory warning'
    | 'Memory info'
    | 'Lint warning'
    | 'Lint info'
    | 'Lexer error'
    | 'I/O error'
    | 'Internal error';

export interface Diagnostic {
    category: DiagnosticCategory;
    severity: Severity;
    message: string;
    file: string;
    start: Position;
    end: Position;
    ruleId?: string;        // optional internal ID (e.g., 'LSL001'); not surfaced by default
}

// Default friendly format: `file:line: Category - description`.
// Matches gcc/clang style for editor jump-to-source.
export function formatDiagnostic(d: Diagnostic): string {
    return `${d.file}:${d.start.line}: ${d.category} - ${d.message}`;
}

// Verbose variant adds column and rule ID for tooling.
export function formatDiagnosticVerbose(d: Diagnostic): string {
    const id = d.ruleId ? ` [${d.ruleId}]` : '';
    return `${d.file}:${d.start.line}:${d.start.column}: ${d.category}${id} - ${d.message}`;
}
