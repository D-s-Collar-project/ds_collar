import type { Rule } from '../runner.js';

// llSensor (and llSensorRepeat) deliver results in sensor() / no_sensor()
// events. A script that fires a sensor scan but declares neither handler
// dispatches the scan and never observes results.
//
// The sensor and no_sensor events are complementary: sensor() fires when
// at least one match is found; no_sensor() fires when zero matches found.
// Either handler is sufficient for the script to observe the scan
// outcome (typical scripts care about one direction or the other).

export const LSL048_sensorWithoutHandler: Rule = {
    id: 'LSL048',
    description: 'llSensor or llSensorRepeat called but neither sensor() nor no_sensor() handler defined — scan results cannot be observed.',
    check(ctx) {
        const sensorSites: any[] = [];
        let hasSensorHandler = false;
        let hasNoSensorHandler = false;

        const visit = (n: any): void => {
            if (!n || typeof n !== 'object') return;
            if (n.kind === 'CallExpression'
                && n.callee?.kind === 'IdentifierExpression'
                && (n.callee.name === 'llSensor' || n.callee.name === 'llSensorRepeat')) {
                sensorSites.push(n);
            }
            if (n.kind === 'EventHandler') {
                if (n.name.name === 'sensor') hasSensorHandler = true;
                else if (n.name.name === 'no_sensor') hasNoSensorHandler = true;
            }
            for (const key of Object.keys(n)) {
                if (key === 'start' || key === 'end' || key === 'kind') continue;
                const v = (n as any)[key];
                if (Array.isArray(v)) v.forEach(visit);
                else if (v && typeof v === 'object') visit(v);
            }
        };
        visit(ctx.script);

        if (sensorSites.length === 0) return;
        if (hasSensorHandler || hasNoSensorHandler) return;

        const first = sensorSites[0];
        ctx.report({
            ruleId: 'LSL048',
            category: 'Lint warning',
            severity: 'warning',
            message: `llSensor / llSensorRepeat called (${sensorSites.length} site${sensorSites.length === 1 ? '' : 's'}) but neither sensor() nor no_sensor() handler — scan results will arrive nowhere`,
            start: first.start,
            end: first.end,
        });
    },
};
