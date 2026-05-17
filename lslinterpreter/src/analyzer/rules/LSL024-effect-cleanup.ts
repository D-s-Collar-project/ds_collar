import type { Rule } from '../runner.js';

// Started effects without any stop call → effects persist after the user navigates
// away or the script detaches. Pairs we check:
//
//   llParticleSystem(non-empty)  ↔  llParticleSystem([])  (or llLinkParticleSystem variants)
//   llStartAnimation             ↔  llStopAnimation
//   llPlaySound / llLoopSound    ↔  llStopSound
//
// Each missing stop is a separate diagnostic so the user can fix them independently.

interface Pair {
    starter: string;
    stopperPredicate: (call: any) => boolean;
    label: string;
}

const PAIRS: Pair[] = [
    {
        starter: 'llParticleSystem',
        stopperPredicate: (call) => call.callee?.name === 'llParticleSystem'
            && call.args.length >= 1
            && call.args[0].kind === 'ListLiteral'
            && call.args[0].elements.length === 0,
        label: 'particles (llParticleSystem with non-empty rules)',
    },
    {
        starter: 'llLinkParticleSystem',
        stopperPredicate: (call) => call.callee?.name === 'llLinkParticleSystem'
            && call.args.length >= 2
            && call.args[1].kind === 'ListLiteral'
            && call.args[1].elements.length === 0,
        label: 'link particles (llLinkParticleSystem with non-empty rules)',
    },
    {
        starter: 'llStartAnimation',
        stopperPredicate: (call) => call.callee?.name === 'llStopAnimation',
        label: 'animations (llStartAnimation)',
    },
    {
        starter: 'llLoopSound',
        stopperPredicate: (call) => call.callee?.name === 'llStopSound',
        label: 'looped sounds (llLoopSound)',
    },
];

export const LSL024_effectCleanup: Rule = {
    id: 'LSL024',
    description: 'Effects (particles, animations, looped sounds) started without any stop call — effects persist across detach/state-change/script-reset.',
    check(ctx) {
        const allCalls: any[] = [];
        const visit = (n: any): void => {
            if (!n || typeof n !== 'object') return;
            if (n.kind === 'CallExpression' && n.callee?.kind === 'IdentifierExpression') {
                allCalls.push(n);
            }
            for (const key of Object.keys(n)) {
                if (key === 'start' || key === 'end' || key === 'kind') continue;
                const v = (n as any)[key];
                if (Array.isArray(v)) v.forEach(visit);
                else if (v && typeof v === 'object') visit(v);
            }
        };
        visit(ctx.script);

        for (const pair of PAIRS) {
            const starts = allCalls.filter(c => {
                if (c.callee?.name !== pair.starter) return false;
                // For particles: empty-list call IS the stopper, not a start. Filter those out.
                if (pair.starter === 'llParticleSystem') {
                    return !(c.args[0]?.kind === 'ListLiteral' && c.args[0].elements.length === 0);
                }
                if (pair.starter === 'llLinkParticleSystem') {
                    return !(c.args[1]?.kind === 'ListLiteral' && c.args[1].elements.length === 0);
                }
                return true;
            });
            if (starts.length === 0) continue;

            const stops = allCalls.filter(pair.stopperPredicate);
            if (stops.length > 0) continue;

            const first = starts[0];
            ctx.report({
                ruleId: 'LSL024',
                category: 'Lint warning',
                severity: 'warning',
                message: `${pair.label} started ${starts.length}× but never stopped — effect persists after detach or state change`,
                start: first.start,
                end: first.end,
            });
        }
    },
};
