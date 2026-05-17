// Deliberately broken LSL — used to demo error messages from lsl-ide.

integer good_global = 5;
integer key = 10                 // missing semicolon + reserved name as variable
string broken_string = 5;        // type mismatch: integer literal into string
vector v = 5;                    // type mismatch: integer literal into vector
key k = "00000000-0000-0000-0000-000000000000";   // OK: string-to-key
integer x = 1.5;                 // type mismatch: float literal into integer
float y = 3;                     // OK: implicit int-to-float

llHelper()                       // user fn with `ll` prefix; also missing ()
{
    integer a = 1;
    integer b = a > 0 ? 1 : 0;   // ternary
    switch(a);                   // switch
    break;                       // break
}

default
{
    state_entry()
    {
        integer attach = 5;      // reserved event name as local
        list things = [1, 2, 3   // missing close bracket
        llOwnerSay("hi"          // missing ) and ;
    }
}
