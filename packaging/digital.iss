; Inno Setup script for Digital.
;
; Produces a Windows .exe installer that wraps the jpackage
; `--type app-image` output at <repo>/target/dist/Digital/.
; The app-image (bundled JRE + Digital.exe launcher + lib/) is
; produced by packaging/package.sh; this script only packages it.
;
; Beyond the standard install/uninstall behaviour, the uninstall
; step cleans up the user configuration directory that Digital
; creates at %APPDATA%\Digital at runtime and the leftover registry
; subtree written by the pre-Prefs java.util.prefs era, so that
; uninstalling returns the system to a pristine state.
;
; Usage:
;   iscc //DMyAppVersion=1.0.0 //Qp packaging/digital.iss
;
; `//D` (double slash) is required under MSYS/Git Bash so that
; the leading slash is not mangled to a Windows path.

#ifndef MyAppName
  #define MyAppName "Digital"
#endif

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

#ifndef MyAppPublisher
  #define MyAppPublisher "neemann"
#endif

#define MyAppExeName "Digital.exe"

[Setup]
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
OutputBaseFilename=Digital-{#MyAppVersion}
; The .iss lives in packaging/, the app-image lives in
; <repo>/target/dist/Digital/, and we want the final .exe to land
; next to jpackage's output under <repo>/target/dist/.
OutputDir=..\target\dist
Compression=lzma2
SolidCompression=yes
; x64compatible covers both AMD64 (native) and ARM64 (via x64 emulation).
; Inno Setup's "x64" would block installation on ARM64 Windows.
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
PrivilegesRequired=admin
DisableProgramGroupPage=yes
DisableDirPage=no
; Lets the MSI-era "Control Panel" uninstaller entry look clean.
VersionInfoVersion={#MyAppVersion}
VersionInfoProductVersion={#MyAppVersion}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Recursively copy the whole jpackage app-image (Digital.exe,
; runtime/, lib/, Digital.jar) into {app}.
Source: "..\target\dist\Digital\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[Code]
// Runs after Inno has removed {app}/Program Files\Digital. Deletes
// the per-user runtime configuration that Digital writes to
// %APPDATA%\Digital (Prefs.java storage) and wipes the legacy
// registry subtree left behind by the old java.util.prefs usage.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    // New file-based preference store used since the Prefs refactor.
    DelTree(ExpandConstant('{userappdata}\Digital'), True, True, True);
    // Legacy registry residue from the pre-Prefs era, in case an
    // earlier Digital install wrote to it. Harmless if it's absent.
    RegDeleteKeyIncludingSubkeys(HKCU, 'Software\JavaSoft\Prefs\dig');
  end;
end;