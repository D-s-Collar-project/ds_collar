import type { Rule } from '../runner.js';
import { estimateScriptMemory, MEMORY_WARN_BYTES, MEMORY_ERROR_BYTES, MEMORY_LIMIT_BYTES } from '../../memory/estimator.js';

export const LSL025_monoMemory: Rule = {
    id: 'LSL025',
    description: 'Mono VM heap pressure estimator. Warn when conservative static estimate approaches the 64 KB ceiling.',
    check(ctx) {
        const est = estimateScriptMemory(ctx.script);
        const start = ctx.script.start;
        const end = ctx.script.end;

        const summary = `globals=${est.globalsBytes}B  fn-stack=${est.functionsBytes}B  states=${est.statesBytes}B  bytecode=${est.bytecodeBytes}B  base=${est.baseBytes}B  total≈${est.totalBytes}B / ${MEMORY_LIMIT_BYTES}B (${pct(est.totalBytes)}%)`;

        if (est.totalBytes >= MEMORY_ERROR_BYTES) {
            ctx.report({
                ruleId: 'LSL025',
                category: 'Memory error',
                severity: 'error',
                message: `estimate ${est.totalBytes}B exceeds error threshold ${MEMORY_ERROR_BYTES}B (Mono ceiling ${MEMORY_LIMIT_BYTES}B). ${summary}`,
                start, end,
            });
        } else if (est.totalBytes >= MEMORY_WARN_BYTES) {
            ctx.report({
                ruleId: 'LSL025',
                category: 'Memory warning',
                severity: 'warning',
                message: `estimate ${est.totalBytes}B exceeds warn threshold ${MEMORY_WARN_BYTES}B. ${summary}`,
                start, end,
            });
        } else {
            ctx.report({
                ruleId: 'LSL025',
                category: 'Memory info',
                severity: 'info',
                message: summary,
                start, end,
            });
        }
    },
};

function pct(bytes: number): string {
    return ((bytes / MEMORY_LIMIT_BYTES) * 100).toFixed(1);
}
