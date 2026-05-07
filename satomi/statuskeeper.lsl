integer CMD_ADD = 1;
integer CMD_REM = 2;
integer CMD_CLR = 3;
integer CMD_RES = 4;
integer CMD_SWD = 5;
integer CMD_SEND = 6;
integer CMD_LISTOBJ = 7;

integer CMD_ADDSRC = 11;
integer CMD_REMSRC = 12;
integer CMD_REMALLSRC = 13;
integer CMD_STATUS = 21;


integer CMD_SOURCES=200000; // message to timer display

integer trans = FALSE;
integer nsources = 0;

float BASE_ALPHA = 0.7;
float LOCKED_ALPHA = 1.0;
float HIGH_ALPHA = 1.0;
float LOW_ALPHA = 0.3;
float OFF_ALPHA = 0.2;
float alpha = BASE_ALPHA;
string text = "";

string btexture="ab75d5ec-c4fa-eaf8-3746-138002ad8125";
integer pendingprim;
integer sourcesprim;

string buttondown="ask";
integer buttonlocked=FALSE;

texture()
{
    float x=-0.25;
    float y;
    if (nsources>0) x=0.25;
    if (buttondown=="auto") y=0.375;
    else if (buttondown=="ask") y=0.125;
    else if (buttondown=="restricted") y=-0.125;
    else if (buttondown=="off") y=-0.375;
    llOffsetTexture(x,y,ALL_SIDES);
    if (buttondown=="off") llSetAlpha(0.6,ALL_SIDES);
    else llSetAlpha(1.0,ALL_SIDES);
}


default
{
    state_entry()
    {
        llSetTexture(btexture,ALL_SIDES);
        texture();
        
        llMessageLinked(LINK_SET,CMD_SOURCES,"0",NULL_KEY);
    }
        
    link_message(integer sender_num, integer num, string str, key id )
    {    
        if (num==CMD_STATUS)
        {   
            if (str!="idle" && str !="pending")
            {
                buttondown=str;
                texture();
            }
            
        }
        else if ((num >= CMD_ADDSRC && num <=CMD_REMALLSRC) || num == CMD_SWD)
        {
            if (num==CMD_ADDSRC)
            {
                nsources++;
            }
            else if (num==CMD_REMSRC)
            {
                nsources--;
            }
            else if (num==CMD_REMALLSRC)
            {
                nsources=0;
            }
            else if (num==CMD_SWD) 
            {
                if (id == NULL_KEY) nsources=0;
            }
            
            texture();
            llMessageLinked(LINK_SET,CMD_SOURCES,(string)nsources,NULL_KEY);
        }
    }
   
    
}