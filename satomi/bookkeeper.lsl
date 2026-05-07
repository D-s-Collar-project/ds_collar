integer SIT_CHANNEL;

//integer restraining=TRUE;
integer locked=FALSE;       // manual locking

list sources=[];
list restrictions=[];
list old_restrictions;
list old_sources;
list refreshed;

list baked=[];

integer sitlistener;
string timertype="";

key sitter = NULL_KEY;
key sittarget = NULL_KEY;
integer canstand = TRUE;
key handovertarget = NULL_KEY;

//message map

integer CMD_ADD = 1;
integer CMD_REM = 2;
integer CMD_CLR = 3;
//integer CMD_RES = 4;
integer CMD_SWD = 5;
integer CMD_SEND = 6;
integer CMD_LISTOBJ = 7;
integer CMD_HANDOVER = 8;
integer CMD_REFRESH = 9;

integer CMD_ADDSRC = 11;
integer CMD_REMSRC = 12;
integer CMD_REMALLSRC = 13;
integer CMD_MANUAL_LOCK = 14;

integer CMD_ML=31;

integer CMD_SENDRLVR = 41;
integer CMD_RECVRLVR = 42;

integer CMD_NEWKEY = 51;

integer CMD_OUTFITCHANGE=9001;

integer lastdetach;

list localRestrictions;


// sends command to viewer (at this stage, we don't know about sources anymore: the filtering has already been done)
// also handle fake RLV commands (thirdview) and plugin after effects (smart strip)
sendCommand(string cmd)
{
    if (cmd=="thirdview=n")
    {
        llMessageLinked(LINK_THIS,CMD_ML,"on",NULL_KEY);
    }
    else if (cmd=="thirdview=y")
    {
        llMessageLinked(LINK_THIS,CMD_ML,"off",NULL_KEY);
    }
    else if (llGetSubString(cmd,-5,-1)=="force")
    {
        
        integer i=llSubStringIndex(cmd,":");
        string tmps=llGetSubString(cmd,0,i);
        if (tmps=="remattach" || tmps=="attach:" || tmps=="detach:" || tmps=="remoutfit:" || tmps=="addoutfit:")
        {
            llMessageLinked(LINK_THIS,9001,cmd,NULL_KEY);
        }
        else llOwnerSay("@"+cmd);
    }
    else llOwnerSay("@"+cmd);
}

addrestriction(key id, string behav)
{
    integer restr;
    if (id == NULL_KEY)
    { //local restriction
        restr = llListFindList(localRestrictions, [behav]);
        if (restr==-1)
        {
            localRestrictions+= [behav];
            applyadd(behav);
        }
        return;
    }
    integer source=llListFindList(sources,[id]);
    if (source==-1)
    {
        sources+=[id];
        restrictions+=[behav];
        restr=-1;
        llMessageLinked(LINK_THIS, CMD_ADDSRC,"",id);
    }
    else
    {
        list srcrestr = llParseString2List(llList2String(restrictions,source),["/"],[]);
        restr=llListFindList(srcrestr, [behav]);
        if (restr==-1)
        {
            restrictions=llListReplaceList(restrictions,[llDumpList2String(srcrestr+[behav],"/")],source, source);
        }
    }
    if (restr==-1)
    {
        applyadd(behav);
        if (canstand && behav=="unsit")
        {
            timertype = "checksit";
            sitter=id;
            llSetTimerEvent(15); // delay the verification of the sit target
        }
    }
}

applyadd (string behav)
{
    integer restr=llListFindList(baked, [behav]);
    if (restr==-1)
    {
        baked+=[behav];
        /*if (restraining)*/ sendCommand(behav+"=n");
        //debug(behav);
    }
}

remrestriction(key id, string behav)
{
    integer restr;
    if (id == NULL_KEY)
    {
        if (restr != -1)
        {
            localRestrictions = llDeleteSubList(localRestrictions,restr, restr);
            applyrem(behav);
        }
        return;
    }
    integer source=llListFindList(sources,[id]);
    if (source!=-1)
    {
        list srcrestr = llParseString2List(llList2String(restrictions,source),["/"],[]);
        restr=llListFindList(srcrestr,[behav]);
        if (restr!=-1) 
        {
            if (llGetListLength(srcrestr)==1)
            {
                restrictions=llDeleteSubList(restrictions,source, source);
                sources=llDeleteSubList(sources,source, source);
                llMessageLinked(LINK_THIS, CMD_REMSRC,"",id);
            }
            else 
            {
                srcrestr=llDeleteSubList(srcrestr,restr,restr);
                restrictions=llListReplaceList(restrictions,[llDumpList2String(srcrestr,"/")] ,source,source);
            }
            applyrem(behav);
        }
    }
}

applyrem(string behav)
{
    integer restr=llListFindList(baked, [behav]);
    if (restr!=-1)
    {
        integer i;
        integer found=FALSE;
        if (llListFindList(localRestrictions, [behav])!=-1) found=TRUE;
        for (i=0;i<=llGetListLength(restrictions);i++)
        {
            list srcrestr=llParseString2List(llList2String(restrictions,i),["/"],[]);
            if (llListFindList(srcrestr, [behav])!=-1) found=TRUE;
        }
        if (!found)
        {
            baked=llDeleteSubList(baked,restr,restr);
            sendCommand(behav+"=y");
            if (behav == "unsit")
            {
                canstand = TRUE;
                sitter = NULL_KEY;
                sittarget = NULL_KEY;
            }
        }
    }
}

release(key id, string pattern)
{
    integer source=llListFindList(sources,[id]);
    if (source!=-1)
    {
        list srcrestr=llParseString2List(llList2String(restrictions,source),["/"],[]);
        //removing the source (only temporarily if it is @clear=xxx)
        restrictions=llDeleteSubList(restrictions,source, source);
        sources=llDeleteSubList(sources,source, source);
        integer i;
        string restrestr;
        for (i=0;i<=llGetListLength(srcrestr);i++)
        {
            string  behav=llList2String(srcrestr,i);
            if (pattern==""||llSubStringIndex(behav,pattern)!=-1)
            {
                applyrem(behav);
                if (behav=="unsit"&&sitter==id)
                {
                    sitter=NULL_KEY;
                    sittarget=NULL_KEY;
                }
            }
            else restrestr+="/"+behav;
        }
        if (restrestr)
        {        //readding the source
            sources+=id;
            restrictions+=restrestr;
        }
        else
        {   //tell the world the source is gone for good
            llMessageLinked(LINK_THIS, CMD_REMSRC,"",id);
        }

    }
}


debug (string msg)
{
    llInstantMessage(llGetOwner(),msg);
}

safeword ()
{
    clear();
    baked=[];
    sources=[];
    restrictions=[];
    sitter = NULL_KEY;
    sittarget = NULL_KEY;
    canstand = TRUE;
}

ping(key id)
{
    if (id == NULL_KEY)
    {
        integer i;
        for (i=0;i<llGetListLength(sources);i++)
        {
            llMessageLinked(LINK_THIS, CMD_SENDRLVR, "ping,ping,ping", llList2Key(sources,i));
        }
    }
    else  llMessageLinked(LINK_THIS, CMD_SENDRLVR, "ping,ping,ping", id);
}

refresh (key id)
{
    ping(id);
    timertype="refresh";
    refreshed = [];
    llSetTimerEvent(20);
}

clear()
{
    sendCommand("clear");
    addrestriction(NULL_KEY, "sendchannel:99");
    if (locked) addrestriction(NULL_KEY, "detach");
}


default
{
    state_entry()
    {
        SIT_CHANNEL=9999 + llFloor(llFrand(9999999.0));
        clear();
    }

    
    listen(integer chan, string who, key id, string msg)
    {
        if (chan==SIT_CHANNEL)
        {
            sittarget = (key) msg;
            llListenRemove(sitlistener);
        }
    }
    
    link_message(integer sender_num, integer num, string str, key id )
    {
        if (num==CMD_ADD) addrestriction(id,str);
        else if (num==CMD_REM) remrestriction(id,str);
        else if (num==CMD_CLR) release(id,str);
//        else if (num==CMD_RES) restraining=!restraining;
        else if (num==CMD_SWD)
        {
            if (id == NULL_KEY) safeword();
            else release(id,"");
        }
        else if (num==CMD_SEND)
        {
            if (canstand) sendCommand(str); /* filter "unsit=force" when the avatar is prevented from standing.
            This could be seen as  a breach with respect to a strict interpretation of RLVR protocol, as every 
            command is not transmitted to viewer.
            But it is also clear that in a multi-device relay setting, a stupid straightforward interpretation would
            lead to obviously unwanted behaviors (like one device releasing restrictions from another one). So some
            filtering had to take place, anyway.
            So, in this relay, my rule was to simulate as closely as possible what would happen if every controller
            was alone on its relay (assuming the avatar wore several relays each assigned to one controller), which
            should amount to the same as emulating a multi-prim relay.
            
            Unfortunately, some RLV commands make it hard to do in a one-prim relay.
            @unsit=force is one example, as in contrary to most restrictions, it bypasses @unsit=n if it was issued by
            the same prim (unconsistant with @remoutfit=n, for instance).
            
            Making work @unsit=force according to this multi-prim emulation paradigm would require testing whether 
            no other source has a @unsit=n behavior. Arguably it would be a lot of extra computation with
            the only aim of being bug-compatible with the RLV API. So in the current implementation, I just block
            @unsit=force when @unsit=n is set.
            I could change this later though, depending on how people do complain ;-).
            */
            else if (str != "unsit=force") sendCommand(str);
            if (sitter==NULL_KEY&&llGetSubString(str,0,3)=="sit:")
            {
                sitter=id;
                //debug("Sitter:"+(string)(sitter));
                sittarget=(key)llGetSubString(str,4,-1);
                //debug("Sittarget:"+(string)(sittarget));
            }
        }
        else if (num==CMD_LISTOBJ)
        {
            string out="You are being controlled by the following object";
            if (llGetListLength(sources)==1) out+=":";
            else out+="s:";
            integer i;
            for (i=0;i<llGetListLength(sources);i++)
            {
                key obj = llList2Key(sources,i);
                string owner = llKey2Name(llGetOwnerKey(obj));
                if (owner=="") owner = "<not in the region>";
                out+="\n"
                    + (string) (i+1) + ".\t"+llKey2Name(obj) + "\n  \t"
                    +"with key "+(string) obj+"\n  \t"
                    +"owned by "+ owner +"\n  \t"
                    +llList2String(restrictions,i);
            }
            llInstantMessage(llGetOwner(),out);
        }
        else if (num==CMD_HANDOVER)
        {
            integer index = llListFindList(sources, [id]);
            if (index!=-1) sources = llListReplaceList(sources,[(key)str],index,index);
            llMessageLinked(LINK_THIS, CMD_SENDRLVR,"ping,ping,ping",(key)str);        
            timertype = "handover";
            handovertarget = (key) str;
            llSetTimerEvent(10);
        }
        else if (num==CMD_NEWKEY)
        {
            integer index = llListFindList(sources, [id]);
            if (index!=-1) sources = llListReplaceList(sources,[(key)str],index,index);
        }
        else if (num==CMD_RECVRLVR && str == "ping,!pong")
        {
            if (timertype=="pong")
            {
                if (id==sitter) sendCommand("sit:"+(string)sittarget+"=force");
                integer sourcenum=llListFindList(old_sources, [id]);
                integer j;
                list restr=llParseString2List(llList2String(old_restrictions,sourcenum),["/"],[]);
                for (j=0;j<llGetListLength(restr);j++) addrestriction(id,llList2String(restr,j));
            }
            else if (timertype=="handover") {llSetTimerEvent(0); timertype="";}
            else if (timertype=="refresh") refreshed += [id];
        }
        else if( num==CMD_MANUAL_LOCK)
        {
            locked = (integer) str;
            if (locked) addrestriction(NULL_KEY, "detach");
            else if (sources == []) remrestriction(NULL_KEY, "detach");
        }
        else if (num==CMD_REFRESH)
        {
            if (id == NULL_KEY || llListFindList(sources, [id]) != -1) refresh(id);
        }
        else if (num==CMD_ADDSRC)  // warning: this signal is sent from this script, don't make infinite loops!
        {
            addrestriction(NULL_KEY, "detach");        
        }
        else if (num==CMD_REMSRC) // warning: this signal is sent from this script, don't make infinite loops!
        {
            if (sources == [] && !locked) remrestriction(NULL_KEY, "detach");
        }
    }

    attach(key id)    
    {
        if (sources)
        {// there are known restrictions, they must be reinstated on reattach
            if (id)
            { //reattaching meaning here we reinstate restrictions
                // we ping devices anyway (can be useful in gridwide mode for advertising the relay new key)
                ping(NULL_KEY);
                if (llGetUnixTime()-lastdetach < 10)
                { //most likely the relay had been displaced by something llAttachToAvatar or Enable Wear. No need to actually wait for the ping answer
                    integer i;
                    for (i = 0; i < llGetListLength(baked); i++)
                    {
                        sendCommand(llList2String(baked,i)+"=n");
                    }
                    llOwnerSay("The relay has been reattached less than 10 seconds after last detach. Most likely it has been displaced while locked. Restrictions are now being reinstated.");
                }
                else
                { //most likely we just relogged
                    llOwnerSay("Relay reattached after a long time. Probably you just relogged. Pinging in-world objects for possible restriction reinstatement.");
                    refresh(NULL_KEY);
                    llMessageLinked(LINK_THIS, CMD_REMALLSRC, "reattach", NULL_KEY);
                    llSleep(5.); //let some time for the world to rez
                    clear();
                    timertype="pong";
                    old_restrictions=restrictions;
                    old_sources=sources;
                    restrictions=[];
                    sources=[];
                    baked=[];
                    llSetTimerEvent(2);
                }
            } // end of the "attach" case 
            else
            { //relay is being detached while locked. Oh bad!
                lastdetach = llGetUnixTime();
                llOwnerSay("The relay has been detached while locked. Restrictions will be reinstated on reattach.");
            }
        }
    }
    
    timer()
    {
        llSetTimerEvent(0);
        if (timertype=="pong")
        {
            old_sources=[];
            old_restrictions=[];
        }
        else if (timertype=="handover")
        {
            release(handovertarget, "");
        }
        else if (timertype=="refresh")
        {
            integer i;
            for (i=0;i<llGetListLength(sources);i++)
            {
                if (llListFindList(refreshed,llList2List(sources,i,i))==-1)
                {
                    release(llList2String(sources,i),"");
                }
            }
            refreshed = [];
        }
        else if (timertype=="checksit")
        { //check where the avatar is sitting when @unsit=n is issued
            sitlistener=llListen(SIT_CHANNEL,"",llGetOwner(),"");
            sendCommand("getsitid="+(string)SIT_CHANNEL);
            canstand = FALSE;
        }
        timertype="";
    }
}
