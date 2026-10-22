; Inno Setup script for the Windows installer. Built by scripts\build-windows.ps1, which passes
; the version and the staged files in; do not run it by hand without those defines.
;
;   ISCC /DAppVersion=1.2.3 /DSourceDir=..\dist\ReviewBot-windows /DOutputDir=..\dist ReviewBot.iss
;
; Installs per user, under %LOCALAPPDATA%\Programs\Review Bot, so it needs no administrator
; rights — the same place the app's own data folder and registry entry live.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\dist\ReviewBot-windows"
#endif
#ifndef OutputDir
  #define OutputDir "..\dist"
#endif

[Setup]
AppId={{7D3C1F0E-5A6B-4C4B-9E2A-3B7F5C1D9E21}
AppName=Review Bot
AppVersion={#AppVersion}
AppVerName=Review Bot {#AppVersion}
AppPublisher=Review Bot
AppPublisherURL=https://github.com/melihucar/review-bot
DefaultDirName={localappdata}\Programs\Review Bot
DefaultGroupName=Review Bot
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=ReviewBot-{#AppVersion}-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=Review Bot
; The app holds this mutex while it runs. Setup and the uninstaller ask for it to be closed
; rather than overwriting a running executable.
AppMutex=Local\ReviewBot.SingleInstance
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "autostart"; Description: "Start Review Bot when I sign in"; GroupDescription: "Startup:"
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
; ReviewBot.exe, the Swift runtime DLLs beside it, and version.txt.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\Review Bot"; Filename: "{app}\ReviewBot.exe"; Comment: "Reviews your GitHub pull requests from the notification area"
Name: "{group}\Uninstall Review Bot"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Review Bot"; Filename: "{app}\ReviewBot.exe"; Tasks: desktopicon

[Registry]
; The same value the app's own "Launch at sign-in" toggle writes (name, quoted path), so the
; dashboard shows the installer's choice and can turn it off again.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Review Bot"; ValueData: """{app}\ReviewBot.exe"""; Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{app}\ReviewBot.exe"; Description: "Start Review Bot now"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; A running instance would keep its files locked; AppMutex already asks the user to close it,
; this is the backstop for one that did not respond.
Filename: "{sys}\taskkill.exe"; Parameters: "/IM ReviewBot.exe /F"; Flags: runhidden; RunOnceId: "StopReviewBot"

[UninstallDelete]
; Only what the installer put there. The data folder (%APPDATA%\ReviewBot: config, history,
; logs) is the user's and is left alone.
Type: filesandordirs; Name: "{app}"
