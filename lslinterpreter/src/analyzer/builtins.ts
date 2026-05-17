// Catalog of LSL builtin functions, events, and constants. Generated from lslint's
// `builtins.txt` via `npm run build:builtins`. The JSON is checked in so the analyzer
// runs without the lslint binary being present at the time of analysis.

import data from '../builtins.json' with { type: 'json' };

export type LslValueType = 'integer' | 'float' | 'string' | 'key' | 'vector' | 'rotation' | 'list';
export type LslReturnType = LslValueType | 'void';

export interface BuiltinParam { name: string; type: LslValueType; }
export interface BuiltinFunction { name: string; returnType: LslReturnType; params: BuiltinParam[]; }
export interface BuiltinEvent { name: string; params: BuiltinParam[]; }
export interface BuiltinConstant { name: string; type: LslValueType; value: string; }

export interface BuiltinCatalog {
    version: string;
    functions: Map<string, BuiltinFunction>;
    events: Map<string, BuiltinEvent>;
    constants: Map<string, BuiltinConstant>;
    isBuiltinFunction(name: string): boolean;
    isBuiltinConstant(name: string): boolean;
    isBuiltinEvent(name: string): boolean;
}

const raw = data as unknown as {
    version: string;
    functions: BuiltinFunction[];
    events: BuiltinEvent[];
    constants: BuiltinConstant[];
};

const functions = new Map<string, BuiltinFunction>(raw.functions.map(f => [f.name, f]));
const events = new Map<string, BuiltinEvent>(raw.events.map(e => [e.name, e]));
const constants = new Map<string, BuiltinConstant>(raw.constants.map(c => [c.name, c]));

export const BUILTINS: BuiltinCatalog = {
    version: raw.version,
    functions,
    events,
    constants,
    isBuiltinFunction(n) { return functions.has(n); },
    isBuiltinConstant(n) { return constants.has(n); },
    isBuiltinEvent(n) { return events.has(n); },
};
