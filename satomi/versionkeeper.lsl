// ********************************************************
// IMPORTANT! IMPORTANT! IMPORTANT! IMPORTANT! IMPORTANT!
// SET THE PERMISSIONS ON THIS SCRIPT TO NO TRANSFER
// BEFORE YOU INCLUDE IT IN YOUR PRODUCTS!
// ********************************************************

// FOLLOW THE INSTRUCTIONS BELOW TO EDIT THIS SCRIPT TO
// WORK WITH YOUR PRODUCT

// insert your server name between the quotemarks below
string server = "Relay Updates";

// insert your server's password between the quotemarks below
string password = "thisisnotasecret";

// insert the product name between the quotemarks below
string product = "Satomi's Multi-Relay HUD";

// insert the current version number between the quotemarks below
// don't use numbers like 1.2.4 ... stick to integers (1, 4, 9 etc.) or decimals (1.2, 4.12 etc.)
string version = "1.02";

// insert your avatar key below (use the server's "My Key" command to get it)
string my_key = "abf1cc1a-52ce-4e4f-8a8a-5ab761d45430";
 
// the variable below is the number of seconds that must have elapsed
// since a user last got this update before being given it again.
// It prevents a user getting relentlessly spammed with updates if,
// for example, they rez multiple versions of a product with
// this script in it. The default is a 12 hour gap.

integer elapsed = 43200;





key reqid;




// *************************************************************************************************
// * DON'T CHANGE THINGS BELOW THIS POINT UNLESS YOU KNOW WHAT YOU'RE DOING!
// *************************************************************************************************

string myRPC;
string serverKEY;
string last_url;
integer retries;
string ownerName;

check_for_update()
{
    // calculate hashcode that will let the server identify paired communication events
    
    integer hash = ((integer) llFrand(9999) * llGetUnixTime()) % 65536;
    if (hash < 0) {hash *= -1;}
    
   // perform a database lookup
   
   load_html("http://www.hippo-tech-sl.com/hippoupdate/update-give.php?N=" + llEscapeURL(server) + "&O=" + my_key + "&PS=" + llMD5String(password, 45736) + "&PR=" + llEscapeURL(product) + "&V=" + llEscapeURL(version) + "&TO=" + (string) llGetOwner() + "&TONAME=" + llEscapeURL(ownerName) + "&H=" + (string) hash + "&R=" + myRPC + "&T=" + (string) elapsed);
   
    llSetTimerEvent(60);
}

load_html(string url)
{
    last_url = url;
    reqid = llHTTPRequest(url, [HTTP_METHOD,"GET"], "");
}

process_command(string message)
{
    list data = llParseStringKeepNulls(message, ["^"], []);
    
    // success
    
    if (llList2String(data, 0) == "SUCCESS")
    {
        llMessageLinked(LINK_SET, -2948813, "SUCCESS", "");
        llSetTimerEvent(0);
        return;
    }
    
    // failure
    
    if (llList2String(data, 0) == "FAIL")
    {
        llMessageLinked(LINK_SET, -2948813, llList2String(data, 1), "");
        llSetTimerEvent(0);
        return;
    }
    
    if (llList2String(data, 0) == "DOUPDATE") 
    {
        serverKEY = llList2String(data, 1);
        llEmail(serverKEY + "@lsl.secondlife.com", llMD5String(password, 28172) + "XGIVE", llList2String(data, 2) + "^" + llList2String(data, 3) + "^" + llList2String(data, 4) + "^" + llList2String(data, 5) + "^" + llList2String(data, 6) + "^" + llList2String(data, 7) + "^" + llList2String(data, 8) + "^" + llList2String(data, 9) + "^" + llList2String(data, 10));
    }
}

default
{
   
    on_rez(integer params)
    {
        llResetScript();
    }
    
    state_entry()
    {        
        // save the product owner name for later
        
        ownerName = llKey2Name(llGetOwner());
        
        // check script has correct permissions for the next owner
  // Satomi: well do I really need this? Full perm is fine for this free relay, alone on its update server, isn't it?      
//        if (llGetInventoryPermMask(llGetScriptName(), MASK_NEXT) & PERM_TRANSFER) {llWhisper(0, "Warning! Transfer permissions are set on " + llGetScriptName() + "!");}
//        if (llGetInventoryPermMask(llGetScriptName(), MASK_NEXT) & PERM_MODIFY) {llWhisper(0, "Warning! Modify permissions are set on " + llGetScriptName() + "!");}
        
        // open XML-RPC channel --- when one is assigned, an update is checked for
        llOpenRemoteDataChannel();
        
    }
        
    timer()
    {
        // request for item has timed out, so transmit that error code in case somebody want its
        llSetTimerEvent(0);
        llMessageLinked(LINK_SET, -2948813, "TIMEOUT", ""); return;
        
    }
    
    remote_data(integer type, key channel, key message_id, string sender, integer idata, string sdata)
    { 
        if (type == REMOTE_DATA_CHANNEL)
        {
            // channel created 
            
            myRPC = channel; 
                
            // check for update
                
            check_for_update();
            
            return;
        }
        
        if (type == REMOTE_DATA_REQUEST)
        {
            process_command(sdata);
        }
    }
    
    http_response(key id, integer err, list metadata, string body)
    {        
        if (id != reqid) return;
        if (err == 404 || err == 500)
        {
            retries++;
            if (retries > 4) {retries = 0; last_url = ""; llMessageLinked(LINK_SET, -2948813, " PROBLEM", ""); llSetTimerEvent(0);}
            if (last_url !="") {load_html(last_url);}
        }
        else
        {
            last_url = ""; retries = 0;
            
            // other stuff
            process_command(body);
        }
    }
    
    // if you've read this far, you're clearly bored, so I can recommend
    // "Pooh and the Philosophers" by John Tyerman Williams
}
