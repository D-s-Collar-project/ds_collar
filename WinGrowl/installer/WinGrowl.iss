; Inno Setup script for WinGrowl.
;
; Build prerequisites:
;   1. dotnet publish via tools\publish.ps1 (outputs to ..\publish\win-x64\)
;   2. Inno Setup 6+ installed (https://jrsoftware.org/isdl.php)
;
; Build the installer:
;   tools\build-installer.ps1
;   ...or manually:
;   "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\WinGrowl.iss
;
; Output: installer\Output\WinGrowl-Setup.exe

#define AppName    "WinGrowl"
#define AppVersion "1.0.0"
#define AppPublisher "WinGrowl"
#define AppExeName "WinGrowl.exe"
#define AppId      "{{A1B2C3D4-5E6F-4A7B-8C9D-0E1F2A3B4C5D}}"
; AUMID — the AppUserModelID that ties the Start Menu shortcut to
; Windows toast notifications. Must match what ToastNotificationManagerCompat
; expects; same string used throughout the app lifetime.
#define AppAUMID   "WinGrowl.App"
#define PublishDir "..\publish\win-x64"

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL=https://github.com/anne-skydancer/WinGrowl
AppSupportURL=https://github.com/anne-skydancer/WinGrowl/issues
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputBaseFilename={#AppName}-{#AppVersion}-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

; x64 build — disallow installing the 64-bit publish on 32-bit Windows.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; Default to per-machine (all users) install — most installations of
; a notification daemon serve all sign-ins on the box. User can drop
; down to per-user via the UAC choice dialog
; (PrivilegesRequiredOverridesAllowed=dialog), which then writes to
; %LOCALAPPDATA%\Programs and skips elevation.
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
; Autostart writes to HKCU intentionally even on per-machine installs
; — each user toggles independently for their own sign-in, and the
; tray's "Start with Windows" menu owns runtime changes. Silence
; Inno's "per-user areas used with admin install" advisory; the
; per-user scope is the desired behavior.
UsedUserAreasWarning=no

; Wear the same icon as the app for the installer .exe itself.
; UninstallDisplayIcon points at the published .exe — its
; <ApplicationIcon> Win32 resource carries the same icon, and
; shipping no loose .ico keeps the install surface to a single file.
; Conditional: Inno tolerates missing SetupIconFile via #ifexist.
#if FileExists("..\src\WinGrowl.App\Assets\wingrowl.ico")
SetupIconFile=..\src\WinGrowl.App\Assets\wingrowl.ico
UninstallDisplayIcon={app}\{#AppExeName}
#endif

; GPL-3.0. Shown as a wizard page during install.
LicenseFile=..\LICENSE

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "autostart"; Description: "Start {#AppName} automatically when I sign in"; GroupDescription: "Additional options:"; Flags: unchecked

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; Start Menu shortcut. AppUserModelID is what lets Windows recognize
; this app as the source of toast notifications even though it's not
; an MSIX-packaged app — the toast notifier reads AUMID from the
; shortcut that launched the process.
;
; IconFilename pins the shortcut icon explicitly. Without it, Windows
; picks an icon from the exe at first paint and caches it per install
; scope; a stale cache from an earlier install can leave per-machine
; and per-user shortcuts displaying different icons. Pointing at the
; exe directly (no IconIndex, defaults to index 0 = the Win32 icon
; <ApplicationIcon> embedded) is the canonical fix.
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"; IconFilename: "{app}\{#AppExeName}"; AppUserModelID: "{#AppAUMID}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"

[Registry]
; Auto-start on sign-in if the user ticked the optional task. Per-user
; Run key so it doesn't require admin and tracks the install scope.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#AppName}"; ValueData: """{app}\{#AppExeName}"""; Tasks: autostart; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch {#AppName} now"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Stop any running instance before removing files. taskkill returns
; non-zero if nothing matches; runhidden avoids the console window
; flash. RunOnceId guarantees the kill fires exactly once even if
; the uninstaller is invoked through a path that re-evaluates this
; section (e.g. modify/repair).
Filename: "{cmd}"; Parameters: "/C taskkill /F /IM {#AppExeName} /T"; Flags: runhidden; RunOnceId: "KillWinGrowl"
