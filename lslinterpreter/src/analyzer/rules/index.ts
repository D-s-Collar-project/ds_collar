import type { Rule } from '../runner.js';
import { LSL001_reservedWords } from './LSL001-reserved-words.js';
import { LSL002_ternary } from './LSL002-ternary.js';
import { LSL003_switchBreakContinue } from './LSL003-switch-break-continue.js';
import { LSL004_userFunctionLlPrefix } from './LSL004-user-fn-ll-prefix.js';
import { LSL025_monoMemory } from './LSL025-mono-memory.js';
import { LSL026_typeMismatch } from './LSL026-type-mismatch.js';
import { LSL027_unboundedGrowth } from './LSL027-unbounded-growth.js';
import { LSL028_loopConcat } from './LSL028-loop-concat.js';
import { LSL029_recursion } from './LSL029-recursion.js';
import { LSL013_listenerLeak } from './LSL013-listener-leak.js';
import { LSL015_jsonInvalidUnchecked } from './LSL015-json-invalid.js';
import { LSL016_llOwnerSayNonRlv } from './LSL016-llownersay-non-rlv.js';
import { LSL017_permissionsWithoutHandler } from './LSL017-permissions-no-handler.js';
import { LSL018_openListen } from './LSL018-open-listen.js';
import { LSL020_stateInStateExit } from './LSL020-state-in-state-exit.js';
import { LSL021_unreachable } from './LSL021-unreachable.js';
import { LSL023_timerRearm } from './LSL023-timer-rearm.js';
import { LSL024_effectCleanup } from './LSL024-effect-cleanup.js';
import { LSL005_nestedRedecl } from './LSL005-nested-redecl.js';
import { LSL011_useBeforeDecl } from './LSL011-use-before-decl.js';
import { LSL031_missingReturn } from './LSL031-missing-return.js';
import { LSL030_undeclared } from './LSL030-undeclared-identifier.js';
import { LSL034_wrongArgCount } from './LSL034-wrong-arg-count.js';
import { LSL035_wrongArgType } from './LSL035-wrong-arg-type.js';
import { LSL040_sameStateTransition } from './LSL040-same-state-transition.js';
import { LSL041_stateChangeInFunction } from './LSL041-state-change-in-function.js';
import { LSL042_unreachableState } from './LSL042-unreachable-state.js';
import { LSL043_noStateEntry } from './LSL043-no-state-entry.js';
import { LSL044_listenerWithoutHandler } from './LSL044-listener-without-handler.js';
import { LSL045_timerWithoutHandler } from './LSL045-timer-without-handler.js';
import { LSL046_targetEventWithoutCall } from './LSL046-target-event-without-call.js';
import { LSL047_httpWithoutHandler } from './LSL047-http-without-handler.js';
import { LSL048_sensorWithoutHandler } from './LSL048-sensor-without-handler.js';
import { LSL049_missingChangedOwner } from './LSL049-changed-owner.js';

export const allRules: Rule[] = [
    LSL001_reservedWords,
    LSL002_ternary,
    LSL003_switchBreakContinue,
    LSL004_userFunctionLlPrefix,
    LSL005_nestedRedecl,
    LSL011_useBeforeDecl,
    LSL013_listenerLeak,
    LSL015_jsonInvalidUnchecked,
    LSL016_llOwnerSayNonRlv,
    LSL017_permissionsWithoutHandler,
    LSL018_openListen,
    LSL020_stateInStateExit,
    LSL021_unreachable,
    LSL023_timerRearm,
    LSL024_effectCleanup,
    LSL025_monoMemory,
    LSL026_typeMismatch,
    LSL027_unboundedGrowth,
    LSL028_loopConcat,
    LSL029_recursion,
    LSL030_undeclared,
    LSL031_missingReturn,
    LSL034_wrongArgCount,
    LSL035_wrongArgType,
    LSL040_sameStateTransition,
    LSL041_stateChangeInFunction,
    LSL042_unreachableState,
    LSL043_noStateEntry,
    LSL044_listenerWithoutHandler,
    LSL045_timerWithoutHandler,
    LSL046_targetEventWithoutCall,
    LSL047_httpWithoutHandler,
    LSL048_sensorWithoutHandler,
    LSL049_missingChangedOwner,
];
