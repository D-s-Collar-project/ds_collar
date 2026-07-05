/* ---------------------------------------------------------------
   fixture_relay_trap.lsl — smoketest fixture (TEST REGIONS ONLY)

   Rez this object near the collar wearer when running the SmokeTest
   relay suite. It emulates an RLV-relay "trap": on command it sends
   standard relay restrictions at the wearer on the relay channel and
   releases them again.

   The scripted agents cannot chat on negative channels, so they
   command this fixture on a positive channel (FIXTURE_CMD_CHAN,
   default 907001 — must match FixtureCommandChannel in
   smoketest.json). Commands, avatar speakers only:

     ping               -> replies "fixture:pong" on channel 0
     capture <uuid>     -> relay @sendchat=n at <uuid>
     release <uuid>     -> relay @sendchat=y + !release at <uuid>
     clear <uuid>       -> relay @clear at <uuid>

   Wire grammar (MR relay): "<ident>,<target-uuid>,<command>"
   --------------------------------------------------------------- */

integer FIXTURE_CMD_CHAN = 907001;
integer RELAY_CHANNEL    = -1812221819;

string  RELAY_IDENT      = "SmokeTrap";

integer gListen = 0;

/* Fixture is test-only: always chatty so the run log shows relay traffic. */
integer logd(string s) {
    llOwnerSay("[fixture] " + s);
    return 0;
}

integer relay_send(key target, string command) {
    string wire = RELAY_IDENT + "," + (string)target + "," + command;
    llRegionSay(RELAY_CHANNEL, wire);
    logd("relay >> " + wire);
    return 0;
}

integer valid_key(string s) {
    if (llStringLength(s) != 36) return FALSE;
    if (llGetSubString(s, 8, 8) != "-") return FALSE;
    return TRUE;
}

default
{
    state_entry() {
        if (gListen) llListenRemove(gListen);
        gListen = llListen(FIXTURE_CMD_CHAN, "", NULL_KEY, "");
        logd("ready on channel " + (string)FIXTURE_CMD_CHAN);
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    listen(integer channel, string name, key id, string message) {
        /* avatar speakers only — objects have llGetOwnerKey(id) != id */
        if (llGetOwnerKey(id) != id) return;

        list parts = llParseString2List(message, [" "], []);
        string verb = llToLower(llList2String(parts, 0));
        string arg = llList2String(parts, 1);

        if (verb == "ping") {
            llRegionSayTo(id, 0, "fixture:pong");
            return;
        }

        if (verb == "capture") {
            if (!valid_key(arg)) {
                llRegionSayTo(id, 0, "fixture:error bad uuid");
                return;
            }
            relay_send((key)arg, "@sendchat=n");
            llRegionSayTo(id, 0, "fixture:captured " + arg);
            return;
        }

        if (verb == "release") {
            if (!valid_key(arg)) {
                llRegionSayTo(id, 0, "fixture:error bad uuid");
                return;
            }
            relay_send((key)arg, "@sendchat=y");
            relay_send((key)arg, "!release");
            llRegionSayTo(id, 0, "fixture:released " + arg);
            return;
        }

        if (verb == "clear") {
            if (!valid_key(arg)) {
                llRegionSayTo(id, 0, "fixture:error bad uuid");
                return;
            }
            relay_send((key)arg, "@clear");
            llRegionSayTo(id, 0, "fixture:cleared " + arg);
            return;
        }
    }
}
