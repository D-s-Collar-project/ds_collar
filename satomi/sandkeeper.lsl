//message map
integer CMD_SWD = 5;
integer CMD_REFRESH = 9;

integer CMD_SENDRLVR = 41;
integer CMD_RECVRLVR = 42;
integer CMD_LISTEN = 45;

// sandkeeper messages (for !x-delay)
integer CMD_DELAY_ADD = 110;
integer CMD_DELAY_CLEAR = 111;
// integer CMD_DELAYED_COMMAND = 112;  <- not needed CMD_RECVRLVR should be used instead
integer CMD_REALDELAY_ADD = 113;
//integer CMD_REALDELAY_CLEAR = 114;
 
list online_event_queue; //scheduled events, online time
list real_event_queue; //scheduled events, real time

integer last_time_worn;

float refresh_rate = 60.;  // rate at which remaining time should be saved (for resuming time on relog)
integer next_is_online;
integer next_is_real;

refresh()
{
    last_time_worn = llGetUnixTime();

    integer has_real = (real_event_queue != []);
    integer has_online = (online_event_queue != []);
    float next_online_event = (llList2Integer(online_event_queue,0) - llGetUnixTime());
    float next_real_event = (llList2Integer(real_event_queue,0) - llGetUnixTime());    

    if (!has_online)
    {
        next_is_real = TRUE;
        next_is_online = FALSE;
        if (!has_real) llSetTimerEvent(0);
        else llSetTimerEvent(next_real_event);
        return;
    }
    
    float next_event = refresh_rate;    
    if (has_online && next_event > next_online_event) next_event = next_online_event;
    if (has_real && next_event > next_real_event) next_event = next_real_event;    
    next_is_online = (has_online && next_event == next_online_event);
    next_is_real = (has_real && next_event == next_real_event);
    llSetTimerEvent(next_event);
}

schedule_online(string evt, key source)
{
    list args = llParseString2List(evt, [","], []);
    integer time = llList2Integer(args, 0) + llGetUnixTime();
    integer i = 0;
    while (i<llGetListLength(online_event_queue) && llList2Integer(online_event_queue,i) < time) i+=4;
    online_event_queue = llListInsertList(online_event_queue, [time, source]+llList2List(args,1,2), i);
}

schedule_real(string evt, key source)
{
    list args = llParseString2List(evt, [","], []);
    integer time = llList2Integer(args, 0) + llGetUnixTime();
    integer i = 0;
    while (i<llGetListLength(real_event_queue) && llList2Integer(real_event_queue,i) < time) i+=4;
    real_event_queue = llListInsertList(real_event_queue, [time, source]+llList2List(args,1,2), i);
}

start_online_event()
{
    // update queue and timers
    key source = llList2Key(online_event_queue,1);
    string ident = llList2String(online_event_queue,2);
    string command = llList2String(online_event_queue,3);
    online_event_queue = llDeleteSubList(online_event_queue,0,3);
    if (llListFindList(online_event_queue + real_event_queue, [source]) == -1) llMessageLinked(LINK_THIS, CMD_REFRESH, "", source);
    
    // handle event
    llMessageLinked(LINK_THIS, CMD_RECVRLVR, ident+","+command, source);
}

start_real_event()
{
    // update queue and timers
    key source = llList2Key(real_event_queue,1);
    string ident = llList2String(real_event_queue,2);
    string command = llList2String(real_event_queue,3);
    online_event_queue = llDeleteSubList(real_event_queue,0,3);
    if (llListFindList(online_event_queue + real_event_queue, [source]) == -1) llMessageLinked(LINK_THIS, CMD_REFRESH, "", source);
    
    // handle event
    llMessageLinked(LINK_THIS, CMD_RECVRLVR, ident+","+command, source);
}

clear_online(string pattern, key source)
{
    integer i = 0;
    integer total = llGetListLength(online_event_queue);
    while (i < total)
    {
        if ( llList2Key(online_event_queue, i+1) == source && llSubStringIndex(llList2String(online_event_queue, i+2), pattern) != -1 )
        {
            online_event_queue = llDeleteSubList(online_event_queue, i, i+3);
            total -= 4;
        }
    }
    if (llListFindList(online_event_queue+real_event_queue, [source]) == -1) llMessageLinked(LINK_THIS, CMD_REFRESH, "", source);
}

clear_real(string pattern, key source)
{
    integer i = 0;
    integer total = llGetListLength(real_event_queue);
    while (i < total)
    {
        if ( llList2Key(real_event_queue, i+1) == source && llSubStringIndex(llList2String(real_event_queue, i+2), pattern) != -1 )
        {
            real_event_queue = llDeleteSubList(real_event_queue, i, i+3);
            total -= 4;
        }
    }
    if (llListFindList(real_event_queue+online_event_queue, [source]) == -1) llMessageLinked(LINK_THIS, CMD_REFRESH, "", source);
}

shift_online_queue()
{
    integer shift = llGetUnixTime() - last_time_worn;
    integer i;
    for (i=0; i < llGetListLength(online_event_queue); i+=4)
    {
        online_event_queue = llListReplaceList(online_event_queue, [llList2Integer(online_event_queue, i) + shift], i, i);
    }
}

clean_real_queue()
{
    integer now = llGetUnixTime();
    while (real_event_queue != [] && llList2Integer(real_event_queue, 0) <= now) start_real_event();
}

default
{
    state_entry()
    {
    }

    link_message(integer link, integer num, string msg, key id)
    {// llOwnerSay("LM in sandkeeper: "+(string) num);
        if (num == CMD_DELAY_ADD)
        {// llOwnerSay("toschedule: "+msg);
            schedule_online(msg, id);
            refresh();
        }
        else if (num == CMD_REALDELAY_ADD)
        {
            schedule_real(msg, id);
            refresh();
        }
        else if (num == CMD_DELAY_CLEAR)
        {
            clear_online(msg, id);
            clear_real(msg, id);
            refresh();
        }
/*
        else if (num == CMD_REALDELAY_CLEAR)
        {
            clear_real(msg, id);
            refresh();
        }
*/
        else if (num == CMD_SWD)
        {
            if (id == NULL_KEY) llResetScript();
            else
            {
                clear_online(id, "");
                clear_real(id, "");
                refresh();
            }
        }
        else if (num ==  CMD_SENDRLVR && msg == "ping,ping,ping")
        {
            if (llListFindList(online_event_queue + real_event_queue, [id]) != -1)  llMessageLinked(LINK_THIS, CMD_RECVRLVR, "ping,!pong", id); // <-- cheat gatekeeper!
        }
    }
    
    timer()
    {
        if (next_is_online) start_online_event();
        if (next_is_real) start_real_event();
        refresh();
    }
    
    attach(key id)
    {
        if (id == NULL_KEY)
        {  //warning: in contrary to what the wiki says, this is not triggered when the wearer logs out.
            last_time_worn = llGetUnixTime();
        }
        else
        {
            shift_online_queue();
            clean_real_queue();
            refresh();
        }
    }
    
    
}
