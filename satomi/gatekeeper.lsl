integer MENU_CHANNEL;
integer AUTH_MENU_CHANNEL;
integer LIST_MENU_CHANNEL;
integer LIST_CHANNEL;
integer SIT_CHANNEL;
string PROTOCOL_VERSION = "1100"; //with some additions, but backward compatible, nonetheless
string ORG_VERSIONS = "ORG=0003/who=001/handover=001/email=005/channel=001/ack=002/delay=003";///http=001";
string IMPL_VERSION = "Satomi's Multi-Relay";

integer commandChannel = 99;

string mode="ask";
integer safe=TRUE;
integer enhanced_safe=TRUE;
//integer restraining=TRUE;
integer playful=FALSE;
integer locked=FALSE;   // manual locking
integer outfitkeeper=FALSE;

list sources=[];
key lastuser=NULL_KEY;
list tempwhitelist=[];
list tempblacklist=[];
list tempuserwhitelist=[];
list tempuserblacklist=[];
list objwhitelist=[];
list objblacklist=[];
list avwhitelist=[];
list avblacklist=[];
list objwhitelistnames=[];
list objblacklistnames=[];
list avwhitelistnames=[];
list avblacklistnames=[];

integer listPrinted=FALSE;
integer listPage=0;

list queue=[];
integer QSTRIDES=3;
integer listener=0;
integer authlistener=0;
string timertype="";
string listtype;
integer MAXLOAD=8;    //prevents stack-heap collisions due to malicious devices

//message map
integer CMD_ADD = 1;
integer CMD_REM = 2;
integer CMD_CLR = 3;
integer CMD_RES = 4;
integer CMD_SWD = 5;
integer CMD_SEND = 6;
integer CMD_LISTOBJ = 7;
integer CMD_HANDOVER = 8;
integer CMD_REFRESH = 9;

integer CMD_ADDSRC = 11;
integer CMD_REMSRC = 12;
integer CMD_REMALLSRC = 13;
integer CMD_MANUAL_LOCK = 14;

integer CMD_STATUS = 21;

integer CMD_SENDRLVR = 41;
integer CMD_RECVRLVR = 42;
integer CMD_LISTEN = 45;
integer CMD_ACKPOLICY = 46;

// pigeonkeeper messages (for !x-email)
integer CMD_EMAIL_INIT = 50;
integer CMD_NEWKEY = 51;
integer CMD_URL = 55;

//integer EMAIL1 = 70;


integer CMD_REQSAFEWORD = 81;
integer CMD_ADD_BLOCKER = 82;

integer CMD_SHOW_PENDING = 91;


// sandkeeper messages (for !x-delay)
integer CMD_DELAY_ADD = 110;
integer CMD_DELAY_CLEAR = 111;
// integer CMD_DELAYED_COMMAND = 112;  <- not needed CMD_RECVRLVR should be used instead
integer CMD_REALDELAY_ADD = 113;
//integer CMD_REALDELAY_CLEAR = 114;


integer CMD_FOLDERMODE=9000;

// dialog buttons
// main dialog
string B_SAFEWORD           = "⚐SAFEWORD⚐";
string B_SAFEWORD_ENABLED   = "Safeword ☑";
string B_SAFEWORD_DISABLED  = "Safeword ☐";
string B_SAFEWORD_EVIL      = "Safeword ☠";
string B_REFRESH            = "♽ Refresh ♽";
string B_RELAY_STATE        = "Grabbed by";
string B_PLAYFUL_ENABLED    = "Playful ☑";
string B_PLAYFUL_DISABLED   = "Playful ☐";
string B_PENDING            = "⁂ Pending ⁂";
string B_ACCESS             = "Access lists";
string B_HELP               = "⁈ Help ⁈";
string B_MODE_OFF           = "Mode: Off";
string B_MODE_RESTR         = "Mode: Restr";
string B_MODE_ASK           = "Mode: Ask";
string B_MODE_AUTO          = "Mode: Auto";
string B_UNLOCKED           = "Locked ☐";
string B_LOCKED             = "Locked ☑";
//string B_DNS_ENABLED = "DNS ☑ (on)";
//string B_DNS_DISABLED = "DNS ☐ (off)";
string B_OUTFITKEEPER_ON    = "Sm. Strip ☑";
string B_OUTFITKEEPER_OFF   = "Sm. Strip ☐";

string END = "$$";
//http-in
/*
string url="ko";
integer dns = FALSE;
key reqid;
string DNS="http://witchy-app.appspot.com/relaydb/";
*/

manual_lock(integer yes)
{
    if (!locked && yes) llOwnerSay("Your relay is now locked on.");
    else if (locked && !yes) llOwnerSay("Your relay is now unlocked.");
    locked=yes;
    llMessageLinked(LINK_THIS,CMD_MANUAL_LOCK,(string) locked,NULL_KEY);
}

sendrlvr(string ident, key id, string com, string ack)
{
    llMessageLinked(LINK_THIS, CMD_SENDRLVR, ident+","+com+","+ack, id);
}

integer ischannelcommand(string cmd)
{
    return (llSubStringIndex(cmd,"@version")==0)||(llSubStringIndex(cmd,"@get")==0)||(llSubStringIndex(cmd,"@findfolder")==0);
}

integer iswho(string cmd)
{
    return llGetSubString(cmd,0,4)=="!who/"||llGetSubString(cmd,0,6)=="!x-who/";
}
key getwho(string cmd)
{
    integer index=llSubStringIndex(cmd,"who/")+4;
    if (iswho(cmd)) return (key)llGetSubString(cmd,index,index+35);
    else return NULL_KEY;
}

integer auth(key object, key user)
{
    integer auth=1;
    //object auth
    integer source_index=llListFindList(sources,[object]);
    if (source_index!=-1) {}
    else if (llListFindList(tempblacklist+objblacklist,[object])!=-1) return -1;
    else if (llListFindList(avblacklist,[llGetOwnerKey(object)])!=-1) return -1;
    else if (llListFindList(tempwhitelist+objwhitelist,[object])!=-1) {}
    else if (llListFindList(avwhitelist,[llGetOwnerKey(object)])!=-1) {}
    else if (mode=="auto") {}
    else if (mode=="restricted") return -1;
    else auth=0;
    //user auth
    if (user==NULL_KEY) {}
//    else if (source_index!=-1&&user==(key)llList2String(users,source_index)) {}
    else if (user==lastuser) {}
    else if (llListFindList(avblacklist+tempuserblacklist,[user])!=-1) return -1;
    else if (llListFindList(avwhitelist+tempuserwhitelist,[user])!=-1) {}
    else if (mode=="auto") {}
    else if (mode=="restricted") return -1;
    else return 0;

    return auth;
}

//--- queue and command handling functions section---//
string getqident(integer i)
{
    return llList2String(queue,QSTRIDES*i);
}

key getqobj(integer i)
{
    return (key)llList2String(queue,QSTRIDES*i+1);
}

string getqcom(integer i)
{
    return llList2String(queue,QSTRIDES*i+2);
}

deleteqitem(integer i)
{
    queue=llDeleteSubList(queue,i,i+QSTRIDES-1);
}

integer getqlength()
{
    return llGetListLength(queue)/QSTRIDES;
}


enqueue(string  msg, key id)
{
    if (msg=="ping,!pong") return;
    list args=llParseString2List(msg,[","],[]);
    msg = "";  // free up memory in case of large messages
    string ident=llList2String(args,0);
    string command=llToLower(llList2String(args,1))+"|"+END;
    args = [];  // free up memory in case of large messages
    //debug(msg);
    integer auth=auth(id,getwho(command));
    if (auth==1) handlecommand(ident,id,command,TRUE);
    else if (auth!=-1&&getqlength()<MAXLOAD) //keeps margin for this event + next arriving chat message
    { //debug("queue/ask: "+command);
        queue+=[ident, id, command];
        if (authlistener==0) dequeue();
    }
    else
    {
        sendrlvr(ident,id,command,"ko");
        sendrlvr(ident,id,END,"");
    }
    //else debug("rejected: "+command);
}

dequeue()
{
    string command = "";
    string curident;
    key curid;
    while (command=="")
    {
        if (queue==[])
        {
            llMessageLinked(LINK_SET,CMD_STATUS,"idle",NULL_KEY);
            timertype="expire";
            llSetTimerEvent(5);
            return;
        }
        curident=getqident(0);
        curid=getqobj(0);
        command=handlecommand(curident,curid,getqcom(0),FALSE);
        deleteqitem(0);
    }
    queue=[curident,curid,command]+queue;
    timertype="authmenu";
    llSetTimerEvent(120);
    AUTH_MENU_CHANNEL=-9999 - llFloor(llFrand(9999999.0));
    list buttons=["Yes","No","Trust Object","Ban Object","Trust Owner","Ban Owner"];
    string owner=llKey2Name(llGetOwnerKey(curid));
    if (owner!="") owner= ", owned by "+owner+",";
    string prompt=llKey2Name(curid)+owner+" wants to control your viewer.";
    if (iswho(command))
    {
        buttons+=["Trust User","Ban User"];
        prompt+="\n"+llKey2Name(getwho(command))+" is currently using this device.";
    }
    prompt+="\nDo you want to allow this?";
    authlistener=llListen(AUTH_MENU_CHANNEL,"",llGetOwner(),"");    
    llMessageLinked(LINK_SET,CMD_STATUS,"pending", curid);
    llDialog(llGetOwner(),prompt,buttons,AUTH_MENU_CHANNEL);
}



//cleans newly authed events, while preserving the order of arrival for every device
cleanqueue()
{
    list on_hold=[];
    integer i=0;
    while (i<getqlength())
    {
        string ident=getqident(0);
        key object=getqobj(0);
        string command=getqcom(0);
        key user=getwho(command);
        integer auth=auth(object,user);
        if(llListFindList(on_hold,[object])!=-1) i++;
        else if(auth==1)
        {
          deleteqitem(i);
          handlecommand(ident,object,command,TRUE);
        }
        else if(auth==-1)
        {
            deleteqitem(i);
            list commands = llParseString2List(command,["|"],[]);
            integer j;
            for (j=0;j<llGetListLength(commands);j++)
            sendrlvr(ident,object,llList2String(commands,j),"ko");
        }
        else
        {
            i++;
            on_hold+=[object];
        }
    }
}

string meta_handover(key source, string msg)
{
    integer index = llListFindList(sources, [source]);
    if (index==-1) return "ko";
    list args = llParseString2List(msg, ["/"], []);
    if (llGetListLength(args) < 3) return "ko";
    key target = llList2Key(args, 1);
    if (target) {} else return "ko";
    integer keep = llList2Integer(args, 2);
    if (keep)
    {
        sources = llListReplaceList(sources,[target],index,index);
        llMessageLinked(LINK_THIS,CMD_HANDOVER,(string)target,source);
    }
    else {llMessageLinked(LINK_THIS,CMD_SWD,"",source); tempwhitelist+=[target];}
    return "ok";
}

meta_channel(string ident, key source, string msg)
{
    list args = llParseString2List(msg, ["/"], []);
    if (llGetListLength(args) >= 2)
    {
        integer channel = llList2Integer(args, 1);
        if (channel <= -1000)
        {
            sendrlvr(ident, source, msg, "ok");
            llMessageLinked(LINK_THIS,CMD_LISTEN,(string) channel,source);
            return;
        }
    }
    sendrlvr(ident,source, msg,"ko");    
}

string handlecommand(string ident, key id, string com, integer auth)
{
    list commands=llParseString2List(com,["|"],[]);
    integer i;
    for (i=0;i<llGetListLength(commands);i++)
    {
        string command=llList2String(commands,i);
        integer wrong=FALSE;
        list subargs=llParseString2List(command,["="],[]);
        string val=llList2String(subargs,1);
        string ack="ok";
        if (command == END)
        {
            sendrlvr(ident,id,END,END);
            return "";
        }
        else if (command=="!release") llMessageLinked(LINK_THIS,CMD_SWD,"",id);
        else if (command=="!version") ack=PROTOCOL_VERSION;
        else if (command=="!implversion") ack=IMPL_VERSION;
        else if (command=="!x-orgversions") ack=ORG_VERSIONS;
        else if (iswho(command)) {if (auth) lastuser=getwho(com);}
        else if (llGetSubString(command,0,10)=="!x-handover")
        {
            meta_handover(id, command);
            return "";
        }
        else if (llGetSubString(command,0,9)=="!x-channel")
        {
            meta_channel(ident, id, command);
            return "";
//                       ack="ko";

        }
        else if (command=="!x-email")
        {
            ack="ok";
            llMessageLinked(LINK_THIS, CMD_EMAIL_INIT, "", id);
        }
//        else if (command=="!x-http") ack = url;
        else if (llGetSubString(command,0,6)=="!x-ack/")
        {
            ack="ok";
            string ackMode = llGetSubString(command,7,-1);
            llMessageLinked(LINK_THIS, CMD_ACKPOLICY, ackMode, id);
        }
        else if (llGetSubString(command,0,8)=="!x-delay/")
        {
            list delayArgs = llParseString2List(command, ["/"], []);
            string delayedIdent = ident;
            integer CMD = CMD_DELAY_ADD;
            if (llGetListLength(delayArgs) >= 3 && llList2String(delayArgs,2) != "") delayedIdent = llList2String(delayArgs,2);
            if (llGetListLength(delayArgs) >= 4 && llList2String(delayArgs,3) == "real") CMD = CMD_REALDELAY_ADD;
            llMessageLinked(LINK_THIS, CMD, llList2String(delayArgs,1)+","+delayedIdent+","+llDumpList2String(llDeleteSubList(commands, 0, i),"|"), id);
            sendrlvr(ident,id,command,"ok");
            return "";
        }
        else  if (llGetSubString(command,0,12)=="!x-delayclear")
        {
            list delayArgs = llParseString2List(command, ["/"], []);
            string pattern = "";
            if (llGetListLength(delayArgs) >= 2) pattern = llList2String(delayArgs,1);
            llMessageLinked(LINK_THIS, CMD_DELAY_CLEAR, pattern, id);
            ack="ok";
        }
        else if (llGetSubString(command,0,0)=="!") ack="ko"; // ko unknown meta-commands
        else if (llGetSubString(command,0,0)!="@")
        {
            if (iswho(com)) return llList2String(commands,0)+"|"+llDumpList2String(llList2List(commands,i,-1),"|");
            else return llDumpList2String(llList2List(commands,i,-1),"|");
        }//probably an ill-formed command, not answering
        else if (ischannelcommand(command))
        {
            if ((integer)val>0) llMessageLinked(LINK_THIS,CMD_SEND, llGetSubString(command,1,-1), id);
            else ack="ko"; // refuse non-positive channels
        }
        else if (playful&&val!="n"&&val!="add")
            llMessageLinked(LINK_THIS, CMD_SEND, llGetSubString(command,1,-1), id);
        else if (command=="@clear") llMessageLinked(LINK_THIS,CMD_CLR,"",id);
        else if (!auth)
        {
            //returns the rest of the commands along with the !x-who data
            if (iswho(com)) return llList2String(commands,0)+"|"+llDumpList2String(llList2List(commands,i,-1),"|");
            else return llDumpList2String(llList2List(commands,i,-1),"|");
        }
        else if (llGetListLength(subargs)==2)
        {
            string behav=llGetSubString(llList2String(subargs,0),1,-1);
            if (val=="force")
            {
                llMessageLinked(LINK_THIS,CMD_SEND,behav+"="+val,id);
            }
            else if (val=="n"||val=="add")
            {
                llMessageLinked(LINK_THIS,CMD_ADD,behav,id);
            }
            else if (val=="y"||val=="rem")
            {
                llMessageLinked(LINK_THIS,CMD_REM,behav,id);
            }
            else if (behav == "clear") llMessageLinked(LINK_THIS,CMD_CLR, val, id);
            else ack="ko";
        }
        else
        {
            if (iswho(com)) return llList2String(commands,0)+"|"+llDumpList2String(llList2List(commands,i,-1),"|");
            else return llDumpList2String(llList2List(commands,i,-1),"|");
        }//probably an ill-formed command, not answering
        sendrlvr(ident,id,command,ack);
    }
    return "";
}

debug (string msg)
{
    llInstantMessage(llGetOwner(),msg);
}

ask_safeword(key id)
{
    if (safe)
    {
        if (enhanced_safe) llMessageLinked(LINK_THIS, CMD_REQSAFEWORD, "", id); 
        else llMessageLinked(LINK_THIS, CMD_SWD, "user safeword", id);
    }
    else llOwnerSay("Sorry, you disabled safewording, remember? Now get what you deserve!");
}

safeword (key id)
{
    if (id == NULL_KEY)
    {
        llOwnerSay("You have safeworded");
        tempblacklist=[];
        tempwhitelist=[];
        tempuserblacklist=[];
        tempuserwhitelist=[];
        integer i;
        //verboseAcks = [];
        for (i=0;i<llGetListLength(sources);i++)
        {
            sendrlvr("release",llList2Key(sources,i),"!release","ok");
        }
        sources=[];
    }
    llMessageLinked(LINK_THIS, CMD_STATUS, "off", NULL_KEY);
    timertype="safeword";
    llSetTimerEvent(5.);
}

//----Menu functions section---//
menu()
{
        timertype="menu";
        llSetTimerEvent(120);
        string prompt="";        
        list buttons=[];
        prompt+="\nCurrent mode is: "+mode;
//        if (restraining) prompt+=", restraining";
//        else prompt+=", non-restraining";
        if (mode == "auto") buttons+= [B_MODE_AUTO];
        else if (mode == "ask") buttons+= [B_MODE_ASK];
        else if (mode == "restricted") buttons+= [B_MODE_RESTR];
        else if (mode == "off") buttons += [B_MODE_OFF];
        if (sources == [] && mode != "off")
        {
            if (safe)
            {
                if (enhanced_safe) buttons+=[B_SAFEWORD_EVIL];
                else buttons+=[B_SAFEWORD_ENABLED];
            }
            else buttons+=[B_SAFEWORD_DISABLED];
        }
        else buttons += [" "];
        if (mode == "restricted" || mode == "ask")
        {
            if (playful)
            {
                prompt+=", playful";
                buttons+=[B_PLAYFUL_ENABLED];
            }
            else
            {
                buttons+=[B_PLAYFUL_DISABLED];
                prompt+=", not playful";
            }                
        }
        else buttons += [" "];
        if (sources!=[])
        {
            prompt+="\nYou are currently grabbed by "+(string)llGetListLength(sources)+" object";
            if (llGetListLength(sources)==1) prompt+=".";
            else prompt+="s.";
            buttons+=[B_RELAY_STATE];
            if (safe) buttons+=[B_SAFEWORD];
            else buttons += [" "];
            buttons+=[B_REFRESH];
        }
        else buttons += [" ", " ", " " ];
        if (mode != "off")
        {
            if (safe)
            {
                if (enhanced_safe) prompt+=", with evil safeword";
                else prompt+=", with safeword";
            }
            else prompt+=", without safeword";
        }
        prompt += ".";
        if (queue!=[])
        {
            prompt+="\nYou have pending requests.";
            buttons+=[B_PENDING];
        }
        else buttons+= [" "];
        //buttons+=[" "];
        if (outfitkeeper)
        {
            buttons+=[B_OUTFITKEEPER_ON];
            prompt+="\nSmartStrip is on. ";
        }
        else 
        {
            buttons+=[B_OUTFITKEEPER_OFF];
            prompt+="\nSmartStrip is off. ";
        }
/*        if (dns)
        {
            prompt+="\nDNS is enabled";
            buttons += [B_DNS_ENABLED];
        }
        else 
        {
            prompt+="\DNS is disabled";
            buttons += [B_DNS_DISABLED];
        }
*/
        buttons+=[" "]; //to remove when http is put back
        buttons+=[B_HELP];
        if(sources!=[])
        {
            buttons+=[" "];
        }
        else if(locked)
        {
            buttons+=[B_LOCKED];
        }
        else
        {
            buttons+=[B_UNLOCKED];
        }
        
        buttons+=[B_ACCESS];
        prompt+="\n\nMake a choice:";
        listener=llListen(MENU_CHANNEL,"",llGetOwner(),"");
        llDialog(llGetOwner(),prompt,buttons,MENU_CHANNEL);
}

listsmenu()
{
        string prompt="What list do you want to remove items from?";
        list buttons=["Trusted Object","Banned Object","Trusted Avatar","Banned Avatar"];
        prompt+="\n\nMake a choice:";
        listener=llListen(LIST_MENU_CHANNEL,"",llGetOwner(),"");    
        llDialog(llGetOwner(),prompt,buttons,LIST_MENU_CHANNEL);
}

plistmenu(string msg)
{
    list olist;
    list olistnames;
    string prompt;
    if (msg=="Trusted Object")
    {
        olist=objwhitelist;
        olistnames=objwhitelistnames;
        prompt="What object do you want to stop trusting?";
    }
    else if (msg=="Banned Object")
    {
        olist=objblacklist;
        olistnames=objblacklistnames;
        prompt="What object do you want not to ban anymore?";
    }
    else if (msg=="Trusted Avatar")
    {
        olist=avwhitelist;
        olistnames=avwhitelistnames;
        prompt="What avatar do you want to stop trusting?";
    }
    else if (msg=="Banned Avatar")
    {
        olist=avblacklist;
        olistnames=avblacklistnames;
        prompt="What avatar do you want not to ban anymore?";
    }
    else return;
    listtype=msg;

    list buttons=["All"];
    integer numOfEntries=llGetListLength(olist);
    integer numOfButtons=numOfEntries;
    integer startEntry=0;
    if(numOfEntries>11)
    {
        integer pages=(numOfEntries-1)/9;
        if(listPage==-1)
        {
            listPage=pages;
        }
        else if(listPage>pages)
        {
            listPage=0;
        }

        numOfButtons=9;
        if(listPage*9+9>numOfEntries)
        {
            numOfButtons=numOfEntries % 9;
        }
        startEntry=listPage*9;
        buttons=["<<","All",">>"];
    }

    prompt+="\n";
    integer i;
    for (i=0;i<numOfButtons;i++)
    {
        buttons+=(string)(startEntry+i+1);
        prompt+="\n"+(string)(startEntry+i+1)+": "+llList2String(olistnames,i);
    }
    if(!listPrinted)
    {
        for (i=0;i<numOfEntries;i++)
        {
            listPrinted=TRUE;
            llOwnerSay((string)(i+1)+": "+llList2String(olistnames,i)+", "+llList2String(olist,i));
        }
    }
    listener=llListen(LIST_CHANNEL,"",llGetOwner(),"");    
    llDialog(llGetOwner(),llGetSubString(prompt,0,511),buttons,LIST_CHANNEL);
}

remlistitem(string msg)
{
    integer i=((integer) msg) -1;
    if (listtype=="Trusted Object")
    {
        if (msg=="All") {objwhitelist=[];objwhitelistnames=[];return;}
        if  (i<llGetListLength(objwhitelist))
        {
            objwhitelist=llDeleteSubList(objwhitelist,i,i);
            objwhitelistnames=llDeleteSubList(objwhitelistnames,i,i);
        }
    }
    else if (listtype=="Banned Object")
    {
        if (msg=="All") {objblacklist=[];objblacklistnames=[];return;}
        if  (i<llGetListLength(objblacklist))
        {
            objblacklist=llDeleteSubList(objblacklist,i,i);
            objblacklistnames=llDeleteSubList(objblacklistnames,i,i);
        }
    }
    else if (listtype=="Trusted Avatar")
    {
        if (msg=="All") {avwhitelist=[];avwhitelistnames=[];return;}
        if  (i<llGetListLength(avwhitelist)) 
        { 
            avwhitelist=llDeleteSubList(avwhitelist,i,i);
            avwhitelistnames=llDeleteSubList(avwhitelistnames,i,i);
        }
    }
    else if (listtype=="Banned Avatar")
    {
        if (msg=="All") {avblacklist=[];avblacklistnames=[];return;}
        if  (i<llGetListLength(avblacklist))
        { 
            avblacklist=llDeleteSubList(avblacklist,i,i);
            avblacklistnames=llDeleteSubList(avblacklistnames,i,i);
        }
    }
    
}


default
{
    on_rez(integer dummy)
    {
        manual_lock(locked);
    }

    state_entry()
    {
        MENU_CHANNEL=-9999 - llFloor(llFrand(9999999.0));
        LIST_MENU_CHANNEL=-9999 - llFloor(llFrand(9999999.0));
        LIST_CHANNEL=-9999 - llFloor(llFrand(9999999.0));
        SIT_CHANNEL=9999 + llFloor(llFrand(9999999.0));
        llMessageLinked(LINK_THIS, CMD_STATUS, mode, NULL_KEY);
        llListen(commandChannel, "", llGetOwner(), "relay");
    }

    touch_start(integer total_number)
    {
        menu();
    }
    
    listen(integer chan, string who, key id, string msg)
    {
        if (chan == commandChannel) menu();
        else if (chan==MENU_CHANNEL)
        {
            llListenRemove(listener);
            llSetTimerEvent(0);
            if (msg==B_SAFEWORD) ask_safeword(NULL_KEY);
            else if (msg==B_OUTFITKEEPER_OFF)
            {
                outfitkeeper=TRUE;
                llMessageLinked(LINK_THIS,CMD_FOLDERMODE,"on",NULL_KEY);
                llOwnerSay("Switching smart strip on. When items are removed that are in your shared folders, everything in the same folder will also come off.");
            }
            else if (msg==B_OUTFITKEEPER_ON)
            {
                outfitkeeper=FALSE;
                llMessageLinked(LINK_THIS,CMD_FOLDERMODE,"off",NULL_KEY);
                llOwnerSay("Switching SmartStrip off");
            }
            else if (msg== B_SAFEWORD_DISABLED)
            {
                if (sources==[]) 
                {
                    safe=TRUE;
                    enhanced_safe=FALSE;
                    llOwnerSay("Oh come on! No fun! Well, at least you are kinda safe now.");
                }
                else llOwnerSay("Nice try. Unfortunately, it is too late to change that now!");
            }
            else if (msg== B_SAFEWORD_EVIL)
            {
                safe=FALSE;
                enhanced_safe=FALSE;
                llOwnerSay("Ok, safewording is disabled now. Hope you know what you are doing! (sadistic laughters!)");
            }
            else if (msg== B_SAFEWORD_ENABLED)
            {
                if (sources==[]) 
                {
                    safe=TRUE;
                    enhanced_safe=TRUE;
                    llOwnerSay("OK, a bit more fun! Especially when you are not alone!");
                }
                else llOwnerSay("Nice try. Unfortunately, it is too late to change that now!");
            }                
            else if (msg==B_MODE_AUTO)
            {
                if (sources==[])
                {
                    mode="off";
                    llOwnerSay("Oh come on! No fun! Ok, I'll stop bugging you for now.");
                }
                else
                {
                    mode="restricted";
                    llOwnerSay("Nice try. Unfortunately, the relay is currently locked. The best we can do is switch to Restricted mode.");
                }
            }
            else if (msg==B_MODE_RESTR)
            {
                mode="ask";
                llOwnerSay("The relay is now working in Ask mode. You will be asked for authorization from unknown sources.");
            }
            else if (msg==B_MODE_ASK)
            {
                mode="auto";
                llOwnerSay("The relay is now working in Auto mode. All requests will be accepted except explicitly forbidden ones.");
            }
            else if (msg==B_MODE_OFF)
            {
                mode="restricted";
                llOwnerSay("The relay is now working in Restricted mode. All requests will be denied except the explictly allowed ones.");
            }
//            else if (msg=="+NoRestraint")
//            {
//                if (sources==[])
//                {
//                    restraining=FALSE;
//                }
//                else llOwnerSay("Sorry, you will have to endure those restraints a little longer.");
//            }
//            else if (msg=="-NoRestraint")
//            {
//                restraining=TRUE;
//            }
            else if (msg== B_PLAYFUL_DISABLED)
            {
                playful=TRUE;
                llOwnerSay("Playful mode enbled. Every one-shot (non-restricting) command is accepted.");
            }
            else if (msg== B_PLAYFUL_ENABLED)
            {
                playful=FALSE;
                llOwnerSay("Playful mode disabled. Tired of being played with? Ok, you'll be left alone now.");
            }
            else if (msg== B_RELAY_STATE)
            {
                llMessageLinked(LINK_THIS,CMD_LISTOBJ,"","");
            }
            else if (msg== B_PENDING)
            {
                dequeue();
                return;
            }
            else if (msg== B_REFRESH)
            {
                llMessageLinked(LINK_THIS, CMD_REFRESH, "", NULL_KEY);
                llOwnerSay("Verifying that every device controlling the relay is reachable. Restrictions from unreachable devices will be cleared in a few seconds.");
            }
            else if (msg== B_ACCESS)
            {
                listsmenu();
                return;
            }
            else if (msg== B_UNLOCKED)
            {
                manual_lock(TRUE);
            }
            else if (msg== B_LOCKED)
            {
                manual_lock(FALSE);
            }
            else if (msg== B_HELP)
            {
                llGiveInventory(id,"Satomi's MultiRelay - Help");
            }
/*            else if (msg== B_DNS_ENABLED)
            {
                dns = FALSE;
                llOwnerSay("Unregistering: "+url);
                reqid = llHTTPRequest(DNS+"?type=remove",[],"");
            }
            else if (msg== B_DNS_DISABLED)
            {
                llOwnerSay("Registering: "+url);
                reqid = llHTTPRequest(DNS+"?type=add&url="+llEscapeURL(url),[],"");
                dns = TRUE;
            }
*/            else return;
            llMessageLinked(LINK_THIS,CMD_STATUS,mode,id);
            menu();
        }
        else if (chan==LIST_MENU_CHANNEL)
        {
            listPrinted=FALSE;
            llSetTimerEvent(0);
            llListenRemove(listener);
            plistmenu(msg);
        }
        else if (chan==LIST_CHANNEL)
        {
            llSetTimerEvent(0);
            llListenRemove(listener);
            if(msg=="<<")
            {
                listPage--;
                plistmenu(listtype);
            }
            else if(msg==">>")
            {
                listPage++;
                plistmenu(listtype);
            }
            else
            {
                remlistitem(msg);
            }
        }
        else if (chan==AUTH_MENU_CHANNEL)
        {
            llListenRemove(authlistener);
            llSetTimerEvent(0);
            authlistener=0;
            key curid=getqobj(0);
            key user=getwho(getqcom(0));
            if (msg=="Yes")
            {
                tempwhitelist+=[curid];
                if (user) tempuserwhitelist+=[user];
            }
            else if (msg=="No")
            {
                tempblacklist+=[curid];
                if (user) tempuserblacklist+=[user];
            }
            else if (msg=="Trust Object")
            {
                objwhitelist+=[curid];
                objwhitelistnames+=[llKey2Name(curid)];
            }
            else if (msg=="Ban Object")
            {
                objblacklist+=[curid];
                objblacklistnames+=[llKey2Name(curid)];
            }
            else if (msg=="Trust Owner")
            {
                avwhitelist+=[llGetOwnerKey(curid)];
                avwhitelistnames+=[llKey2Name(llGetOwnerKey(curid))];
            }
            else if (msg=="Ban Owner")
            {
                avblacklist+=[llGetOwnerKey(curid)];
                avblacklistnames+=[llKey2Name(llGetOwnerKey(curid))];
            }
            else if (msg=="Trust User")
            {
                avwhitelist+=[user];
                avwhitelistnames+=[llKey2Name(user)];
            }
            else if (msg=="Ban User")
            {
                avblacklist+=[user];
                avblacklistnames+=[llKey2Name(user)];
            }
            cleanqueue();
            dequeue();
        }
    }
        
    timer()
    {
        llSetTimerEvent(0);
        if (timertype=="authmenu")
        {
            llListenRemove(authlistener);
            authlistener=0;
            //dequeue();
        }
        else if (timertype=="menu")
        {
            llListenRemove(listener);
        }
        else if (timertype=="safeword")
        {
            llMessageLinked(LINK_THIS, CMD_STATUS, mode, NULL_KEY);
        }
        timertype="";
        tempblacklist=[];
        tempwhitelist=[];
        tempuserblacklist=[];
        tempuserwhitelist=[];
    }
    
    link_message(integer sender_num, integer num, string str, key id )
    {
        if (num==CMD_RECVRLVR)
        {
            if (timertype!="safeword") enqueue(str,id);
        }
        if (num==CMD_ADDSRC)
        {
            sources+=[id];
            //verboseAcks+=[TRUE];
//            users+=[lastuser];
            if(!enhanced_safe) return;
            if(llListFindList(objwhitelist,[id])!=-1 ||
               llListFindList(avwhitelist,[llGetOwnerKey(id)])!=-1
              )
            {
                llMessageLinked(LINK_THIS, CMD_ADD_BLOCKER, "", id);
            }
        }
        else if (num==CMD_REMSRC)
        {
            integer i= llListFindList(sources,[id]);
            if (i!=-1)
            {
                sources=llDeleteSubList(sources,i,i);
                //verboseAcks=llDeleteSubList(verboseAcks,i,i);
//                users=llDeleteSubList(users,i,i);
            }
        }
        else if (num==CMD_REMALLSRC)
        {
            sources = [];
            //verboseAcks = [];
        }
        else if (num==CMD_NEWKEY)
        {
            integer index = llListFindList(sources, [id]);
            if (index!=-1) sources = llListReplaceList(sources,[(key)str],index,index);
            index = llListFindList(tempwhitelist, [id]);
            if (index!=-1) tempwhitelist = llListReplaceList(tempwhitelist,[(key)str],index,index);
        }
        else if (num == CMD_SWD) {if (str=="user safeword") safeword(id);}
        else if (num == CMD_SHOW_PENDING)
        {
            dequeue();
        }
/*        else if (num == CMD_URL)
        {
            url = str;
            if (dns)
            {
                reqid = llHTTPRequest(DNS+"?type=add&url="+llEscapeURL(url),[],"");
                llOwnerSay("Updating URL on DNS.");                
            }
        }
*/    }
    
    changed(integer change)
    {
        if (change & CHANGED_OWNER) llResetScript();
    }
    
/*    http_response(key req, integer status, list metadata, string body)
    {
        if (req==reqid) llOwnerSay(body);
    }
*/
}
