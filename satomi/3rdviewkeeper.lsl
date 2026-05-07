integer CMD_ADD = 1;
integer CMD_REM = 2;
integer CMD_SWD = 5;
integer CMD_SEND = 6;
integer CMD_ML=31;

list sources;

integer enabled = FALSE;

disable()
{
    enabled = FALSE;
    llMessageLinked(LINK_THIS, CMD_REM, "setenv", NULL_KEY); // this should restore environment in RLVa
    llMessageLinked(LINK_THIS, CMD_REM, "setdebug", NULL_KEY);
    llMessageLinked(LINK_THIS, CMD_SEND, "setdebug_renderresolutiondivisor:1=force", NULL_KEY); //env not restored here (could interfere with user settings or other RLV devices)
}

enable()
{
    enabled = TRUE;
    llMessageLinked(LINK_THIS, CMD_ADD, "setenv", NULL_KEY);
    llMessageLinked(LINK_THIS, CMD_ADD, "setdebug", NULL_KEY);
    llMessageLinked(LINK_THIS, CMD_SEND, "setdebug_renderresolutiondivisor:128=force,setenv_scenegamma:0.0=force", NULL_KEY); // send it to bookkeeper in order to preserve order of execution
    llInstantMessage(llGetOwner(),"Now go to mouselook or remain in the dark!");
}


default
{
    state_entry()
    {
    }
    
    link_message(integer sender_num, integer num, string str, key id )
    {
        if (num==CMD_ML)
        {
            if (str=="on")
            {
                integer index = llListFindList(sources, [id]);
                if (index == -1) sources += id;
                llSetTimerEvent(1.0);
            }
            else if (str="off")
            {
                integer index = llListFindList(sources, [id]);
                if (index != -1) sources == llDeleteSubList(sources, index, index);
                if (sources == []) { llSetTimerEvent(0); disable();}
            }
        }
        if (num==CMD_SWD) {sources = []; llSetTimerEvent(0); disable();}
    }
    
    timer()
    {
        integer toEnable = (0 == (llGetAgentInfo(llGetOwner()) & AGENT_MOUSELOOK));
        if (toEnable && !enabled ) enable();
        else if (!toEnable && enabled) disable();
    }
}
