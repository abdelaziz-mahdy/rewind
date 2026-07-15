; Inno Setup script for the Rewind Windows installer.
; Built in CI by: ISCC.exe tools\windows_installer.iss  (see release.yml).
;
; Packages the release build at build\windows\x64\runner\Release into a
; standard installer that drops Rewind into Program Files with Start-menu +
; optional desktop shortcuts. Version can be overridden at build time:
;   ISCC.exe /DAppVersion=0.2.0 tools\windows_installer.iss
;
; NOTE: the Windows capture backend is not implemented yet (the C shim runs
; in stub mode on Windows) — this ships the functional app minus real
; capture. See ROADMAP.md.

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

#define AppName "Rewind"
#define AppExe "rewind.exe"
#define SrcDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{7B0B5C0D-BEEF-4A11-AA51-C0DE00000001}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Rewind
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir={#SourcePath}\..\dist
OutputBaseFilename=Rewind-windows-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SrcDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
