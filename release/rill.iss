; Inno Setup script for the Windows x64 installer.
;
;   iscc /DAppVersion=0.1.412 /O"build\installer" release\rill.iss
;
; SourceDir is the staged Release folder (`flutter build windows --release` plus
; the sidecar copied into sidecar\dist, which rill.ps1 and the release workflow
; both do). Design notes live in docs/architecture.md, "Release pipeline".

#ifndef AppVersion
  #error AppVersion must be passed on the command line, e.g. /DAppVersion=0.1.412
#endif
#ifndef SourceDir
  #define SourceDir "..\app\build\windows\x64\runner\Release"
#endif

[Setup]
; Never change this: it is how a newer installer recognises an older install as
; the same app, which is what makes an update an upgrade rather than a second copy.
AppId={{A447ABAE-6731-4A19-895B-87460613E7C8}
AppName=Rill
AppVersion={#AppVersion}
AppVerName=Rill {#AppVersion}
AppPublisher=LordLux
AppPublisherURL=https://github.com/LordLux/rill
AppSupportURL=https://github.com/LordLux/rill/issues
VersionInfoVersion={#AppVersion}.0

; Per-user install: no admin rights, so an update never raises a UAC prompt.
; With PrivilegesRequired=lowest, {autopf} resolves to %LOCALAPPDATA%\Programs.
PrivilegesRequired=lowest
DefaultDirName={autopf}\Rill
DisableProgramGroupPage=yes
DisableDirPage=auto

; x64 build only. On Windows-on-ARM this still installs and runs under emulation.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

OutputBaseFilename=Rill-Setup-x64
SetupIconFile=..\app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\rill.exe
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern

; Restart Manager closes a running Rill (and the sidecar it spawned) so its
; files can be replaced. The in-app updater quits first, so this is a backstop.
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; Flags: unchecked

[InstallDelete]
; The app owns these directories outright — user data lives under %LOCALAPPDATA%\rill
; and the credential store, never in {app}. Clearing them stops a file dropped
; from one build (a plugin DLL, an asset) lingering in every install after it.
Type: filesandordirs; Name: "{app}\data"
Type: filesandordirs; Name: "{app}\sidecar"
Type: files; Name: "{app}\*.dll"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.lib,*.exp,*.pdb"
Source: "..\THIRD_PARTY_LICENSES"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Rill"; Filename: "{app}\rill.exe"
Name: "{autodesktop}\Rill"; Filename: "{app}\rill.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\rill.exe"; Description: "Launch Rill"; Flags: nowait postinstall skipifsilent
