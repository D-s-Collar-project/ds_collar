// enhanced safewording by Vala Vella
// Version 1.0
// based on the safeword function of the Smart Relay V1.2 by Toy Wylie
// This script is open source and may be used and changed by everyone. Just keep it open!

integer CMD_SWD = 5;

integer CMD_REMSRC = 12;
integer CMD_REMALLSRC = 13;

integer CMD_REQSAFEWORD = 81;
integer CMD_ADD_BLOCKER = 82;

integer helpchan;

integer punishBlockTime = 120; //How long the safewording gets blocked when punished
integer reBlockTime = 60; //How long between two uses of the safeword
integer safewordBlocked;

// whitelist blockers
integer numBlockers=0;
list blockers=[];

integer saviorListener;
string relayOwnerName;

key sourceToSafeword;

integer randint(integer max)
{
    integer r;
    do 
    { 
        r = (integer)(llFrand(max));
    } while(r == max);
    return r;
}

safeword(key id)
{
    llMessageLinked(LINK_THIS, CMD_SWD, "user safeword", id);   
    safewordBlocked = 0;
}

default
{
    state_entry()
    {
        relayOwnerName = llKey2Name(llGetOwner());
    }
    
    on_rez(integer num)
    {
        llResetScript();
    }
    
    link_message(integer from, integer num, string msg, key id)
    {
        if (num == CMD_REQSAFEWORD)
        {
            sourceToSafeword = id;
            if(numBlockers)
            {
                string out="Your safeword is still blocked by "+(string) numBlockers+" whitelisted source";
                if(numBlockers>1)
                    out+="s.";
                else
                    out+=".";
                llOwnerSay(out);
            }
            else if (safewordBlocked == 0)
            {
                safewordBlocked = reBlockTime;
                llSetTimerEvent(1.0);
                llSensor("", NULL_KEY, AGENT, 20, PI);
            }
            else
            {
                llOwnerSay("Safeword is blocked for "+(string) safewordBlocked+" seconds.");
            }
        }
        else if(num==CMD_ADD_BLOCKER)
        {
            if(llListFindList(blockers,[id])==-1)
            {
                blockers+=[id];
                numBlockers++;
            }
        }
        else if(num==CMD_REMSRC)
        {
            integer pos=llListFindList(blockers,[id]);
            if(pos!=-1)
            {
                blockers=llDeleteSubList(blockers,pos,pos);
                numBlockers--;
            }
        }
        else if(num==CMD_REMALLSRC)
        {
            blockers=[];
            numBlockers=0;
        }
    }
    
    listen(integer channel, string name, key id, string message)
    {        
        if (channel == helpchan)
        {
            llListenRemove(saviorListener);
            if (message=="Free")
            {
                safeword(sourceToSafeword);
                llSay(0, relayOwnerName+" has been freed by "+name+"!");
            }
            else if (message=="Punish")
            {
                safewordBlocked = punishBlockTime;
                llOwnerSay("Your safeword is blocked by "+name+" for "+(string)punishBlockTime+" seconds!");
                llSay(0, name+" has punished "+relayOwnerName+" for having the gall to beg for mercy! Safewording is blocked for "+(string)punishBlockTime+" seconds.");
            }
            else if (message=="Ignore")
            {
                llSay(0, name+" has ignored "+relayOwnerName+"'s pleas for help.");
            }
        }
    }
        
    
    timer()
    {
        if(safewordBlocked>0)
        {
            safewordBlocked--;
        }
        else
        {
            llOwnerSay("Safeword no longer blocked");
            llSetTimerEvent(0);
        }
    }
        
    sensor(integer num)
    {
        helpchan=-(integer)(1000000+llFrand(1000000));
        // select a random person from the list of people nearby
        integer saviorNum=randint(num);
        key savior=llDetectedKey(saviorNum);
        string saviorName=llDetectedName(saviorNum);
        llDialog(savior, relayOwnerName+" is trapped and is begging you for assistance.  What would you like to do?\nSelecting \"punish\" will block safewording for "+(string)punishBlockTime+" seconds.", ["Free", "Punish", "Ignore"], helpchan);
        llListenRemove(saviorListener);
        llSay(0, relayOwnerName +" is begging "+saviorName+" for help.");
        saviorListener=llListen(helpchan, "", savior, "");
    }

    no_sensor()
    {
        llOwnerSay("Nobody is around! You are free.");
        safeword(sourceToSafeword);
    }
}