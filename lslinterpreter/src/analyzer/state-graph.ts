// State graph extractor / formatter. Walks a single script's AST and
// produces a textual representation of states + transitions — useful for
// review of multi-state scripts.
//
// Output formats:
//   'text'    — indented bullet list, one line per transition
//   'mermaid' — Mermaid stateDiagram-v2 fenced block (drops into Markdown)

import type { Script } from '../parser/ast.js';

export interface StateGraph {
    states: string[];                              // state names in declaration order
    transitions: Array<{ from: string; to: string; eventName: string }>;
}

export function extractStateGraph(script: Script): StateGraph {
    const states: string[] = [];
    const transitions: Array<{ from: string; to: string; eventName: string }> = [];

    for (const st of script.states) {
        const name = st.isDefault ? 'default' : st.name.name;
        states.push(name);
        for (const ev of st.events) {
            const eventName = ev.name.name;
            const visit = (n: any): void => {
                if (!n || typeof n !== 'object') return;
                if (n.kind === 'StateChangeStatement') {
                    transitions.push({ from: name, to: n.target.name, eventName });
                }
                for (const k of Object.keys(n)) {
                    if (k === 'start' || k === 'end' || k === 'kind') continue;
                    const v = (n as any)[k];
                    if (Array.isArray(v)) v.forEach(visit);
                    else if (v && typeof v === 'object') visit(v);
                }
            };
            visit(ev.body);
        }
    }

    // User functions can also issue state changes (LSL041 already warns).
    for (const fn of script.functions) {
        const visit = (n: any): void => {
            if (!n || typeof n !== 'object') return;
            if (n.kind === 'StateChangeStatement') {
                transitions.push({ from: `<fn:${fn.name.name}>`, to: n.target.name, eventName: '(via function)' });
            }
            for (const k of Object.keys(n)) {
                if (k === 'start' || k === 'end' || k === 'kind') continue;
                const v = (n as any)[k];
                if (Array.isArray(v)) v.forEach(visit);
                else if (v && typeof v === 'object') visit(v);
            }
        };
        visit(fn.body);
    }

    return { states, transitions };
}

export function formatStateGraphText(graph: StateGraph): string {
    if (graph.states.length === 0) return '(no states)';
    const lines: string[] = [];
    lines.push(`States (${graph.states.length}): ${graph.states.join(', ')}`);
    if (graph.transitions.length === 0) {
        lines.push('No transitions found.');
        return lines.join('\n');
    }

    // Group transitions by `from` state.
    const byFrom = new Map<string, Array<{ to: string; eventName: string }>>();
    for (const t of graph.transitions) {
        if (!byFrom.has(t.from)) byFrom.set(t.from, []);
        byFrom.get(t.from)!.push({ to: t.to, eventName: t.eventName });
    }

    for (const from of [...byFrom.keys()].sort()) {
        lines.push(`${from}:`);
        for (const t of byFrom.get(from)!) {
            lines.push(`  → ${t.to}  (${t.eventName})`);
        }
    }
    return lines.join('\n');
}

export function formatStateGraphMermaid(graph: StateGraph): string {
    const lines: string[] = [];
    lines.push('```mermaid');
    lines.push('stateDiagram-v2');
    // Mermaid uses [*] as the initial pseudo-state. `default` is always
    // the LSL initial state.
    if (graph.states.includes('default')) {
        lines.push('    [*] --> default');
    }
    const seen = new Set<string>();
    for (const t of graph.transitions) {
        // Skip transitions FROM a function — Mermaid syntax expects a real
        // state on each side. List them as comments instead.
        if (t.from.startsWith('<fn:')) continue;
        const key = `${t.from}|${t.to}|${t.eventName}`;
        if (seen.has(key)) continue;
        seen.add(key);
        lines.push(`    ${t.from} --> ${t.to} : ${t.eventName}`);
    }
    // Function-initiated transitions as comments after the diagram.
    const fnTransitions = graph.transitions.filter(t => t.from.startsWith('<fn:'));
    if (fnTransitions.length > 0) {
        lines.push('');
        lines.push('    %% Function-initiated transitions (LSL allows but discouraged):');
        for (const t of fnTransitions) {
            lines.push(`    %% ${t.from} --> ${t.to}`);
        }
    }
    lines.push('```');
    return lines.join('\n');
}
