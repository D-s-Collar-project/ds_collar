// Minimal symbol-table pass. Produces per-script tables that downstream rules consume
// for scope-aware analysis (nested redeclaration, use-before-declaration, missing
// return paths). Not a full scope tree — LSL's flat-locals-per-function semantics
// mean a list of LocalVariable nodes per function is enough for the rules we're
// adding now.

import type {
    Script, GlobalVariable, FunctionDeclaration, EventHandler,
    LocalVariable, LabelStatement,
} from '../parser/ast.js';

export type Handler = FunctionDeclaration | EventHandler;

export interface ScriptSymbols {
    globals: GlobalVariable[];                          // in declaration order
    functions: Map<string, FunctionDeclaration>;        // by name
    locals: Map<Handler, LocalVariable[]>;              // every local, all nested scopes flattened
    labels: Map<Handler, LabelStatement[]>;             // every label, all nested scopes flattened
}

export function buildScriptSymbols(script: Script): ScriptSymbols {
    const functions = new Map<string, FunctionDeclaration>();
    for (const fn of script.functions) functions.set(fn.name.name, fn);

    const locals = new Map<Handler, LocalVariable[]>();
    const labels = new Map<Handler, LabelStatement[]>();

    const collect = (handler: Handler): void => {
        const ls: LocalVariable[] = [];
        const lbs: LabelStatement[] = [];
        walk(handler.body, ls, lbs);
        locals.set(handler, ls);
        labels.set(handler, lbs);
    };

    for (const fn of script.functions) collect(fn);
    for (const st of script.states) {
        for (const ev of st.events) collect(ev);
    }

    return { globals: script.globals, functions, locals, labels };
}

function walk(node: any, locals: LocalVariable[], labels: LabelStatement[]): void {
    if (!node || typeof node !== 'object') return;
    if (node.kind === 'LocalVariable') locals.push(node);
    if (node.kind === 'LabelStatement') labels.push(node);
    for (const key of Object.keys(node)) {
        if (key === 'start' || key === 'end' || key === 'kind') continue;
        const v = (node as any)[key];
        if (Array.isArray(v)) v.forEach(c => walk(c, locals, labels));
        else if (v && typeof v === 'object') walk(v, locals, labels);
    }
}
