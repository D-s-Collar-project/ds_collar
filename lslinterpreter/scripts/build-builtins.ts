// Parses lslint's `builtins.txt` and emits `src/builtins.json` for the analyzer
// to consume. Run via `npm run build:builtins`. The default input path is the
// installed lslint fork; pass an explicit path as argv[2] to override.
//
// Input format (one declaration per line, plus // comments):
//   TYPE NAME(TYPE arg1, TYPE arg2, ...)
//   event NAME(TYPE arg1, ...)
//   const TYPE NAME = VALUE

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';

type LslReturnType = 'void' | 'integer' | 'float' | 'string' | 'key' | 'vector' | 'rotation' | 'list';
type LslValueType = Exclude<LslReturnType, 'void'>;

interface Param { name: string; type: LslValueType; }
interface BuiltinFunction { name: string; returnType: LslReturnType; params: Param[]; }
interface BuiltinEvent { name: string; params: Param[]; }
interface BuiltinConstant { name: string; type: LslValueType; value: string; }

const FUNC_RE = /^(void|integer|float|string|key|vector|rotation|list)\s+(\w+)\s*\(\s*(.*?)\s*\)\s*$/;
const EVENT_RE = /^event\s+(\w+)\s*\(\s*(.*?)\s*\)\s*$/;
const CONST_RE = /^const\s+(integer|float|string|key|vector|rotation|list)\s+(\w+)\s*=\s*(.*?)\s*$/;
const VERSION_RE = /Database version:\s*([^\s;]+)/;

function parseParams(raw: string): Param[] {
    const trimmed = raw.trim();
    if (trimmed === '') return [];
    return trimmed.split(',').map(part => {
        const tokens = part.trim().split(/\s+/);
        if (tokens.length < 2) throw new Error(`malformed parameter: ${JSON.stringify(part)}`);
        return { type: tokens[0] as LslValueType, name: tokens[1]! };
    });
}

interface ParsedCatalog {
    version: string;
    functions: BuiltinFunction[];
    events: BuiltinEvent[];
    constants: BuiltinConstant[];
    skipped: string[];
}

function parse(text: string): ParsedCatalog {
    const functions: BuiltinFunction[] = [];
    const events: BuiltinEvent[] = [];
    const constants: BuiltinConstant[] = [];
    const skipped: string[] = [];
    let version = 'unknown';

    for (const rawLine of text.split('\n')) {
        const line = rawLine.trim();
        if (line === '') continue;
        if (line.startsWith('//')) {
            const v = line.match(VERSION_RE);
            if (v) version = v[1]!;
            continue;
        }

        let m = line.match(FUNC_RE);
        if (m) {
            functions.push({ returnType: m[1] as LslReturnType, name: m[2]!, params: parseParams(m[3]!) });
            continue;
        }
        m = line.match(EVENT_RE);
        if (m) {
            events.push({ name: m[1]!, params: parseParams(m[2]!) });
            continue;
        }
        m = line.match(CONST_RE);
        if (m) {
            constants.push({ name: m[2]!, type: m[1] as LslValueType, value: m[3]!.trim() });
            continue;
        }
        skipped.push(line);
    }
    return { version, functions, events, constants, skipped };
}

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, '..');
const defaultInput = join(homedir(), '.lsl-tools', 'lslint', 'builtins.txt');
const inputPath = process.argv[2] ?? defaultInput;
const outputPath = join(projectRoot, 'src', 'builtins.json');

const text = readFileSync(inputPath, 'utf8');
const parsed = parse(text);

const output = {
    version: parsed.version,
    source: inputPath,
    generated: new Date().toISOString(),
    counts: {
        functions: parsed.functions.length,
        events: parsed.events.length,
        constants: parsed.constants.length,
    },
    functions: parsed.functions,
    events: parsed.events,
    constants: parsed.constants,
};

mkdirSync(dirname(outputPath), { recursive: true });
writeFileSync(outputPath, JSON.stringify(output, null, 2) + '\n');

console.log(`Wrote ${outputPath}`);
console.log(`  version:   ${parsed.version}`);
console.log(`  functions: ${parsed.functions.length}`);
console.log(`  events:    ${parsed.events.length}`);
console.log(`  constants: ${parsed.constants.length}`);
if (parsed.skipped.length > 0) {
    console.log(`  skipped:   ${parsed.skipped.length} unrecognized lines`);
    parsed.skipped.slice(0, 5).forEach(s => console.log(`    | ${s}`));
}
