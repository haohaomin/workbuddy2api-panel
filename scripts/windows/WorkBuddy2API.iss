; Inno Setup template for the Windows portable server build.
; The installer stores the executable under LocalAppData and never removes
; config.json, auths/ or data/ during uninstall.
#ifndef AppVersion
#define AppVersion "0.0.0"
#endif
#ifndef InputDir
#define InputDir "."
#endif
#ifndef OutputDir
#define OutputDir "."
#endif
#ifndef OutputName
#define OutputName "WorkBuddy2API-Setup-windows"
#endif

[Setup]
AppId={{C3F1F26F-6D8E-4A86-9E6B-3D4A5D10F0C7}
AppName=WorkBuddy2API Panel++
AppVersion={#AppVersion}
AppPublisher=haohaomin
AppPublisherURL=https://github.com/haohaomin/workbuddy2api-panel
AppSupportURL=https://github.com/haohaomin/workbuddy2api-panel/issues
DefaultDirName={localappdata}\WorkBuddy2API
DefaultGroupName=WorkBuddy2API Panel++
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=WorkBuddy2API Panel++
Uninstallable=yes

[Files]
Source: "{#InputDir}\wb2api.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#InputDir}\config.example.json"; DestDir: "{app}"; Flags: ignoreversion onlyifdoesntexist
Source: "{#InputDir}\README.md"; DestDir: "{app}"; Flags: ignoreversion

[Dirs]
Name: "{localappdata}\WorkBuddy2API\auths"
Name: "{localappdata}\WorkBuddy2API\data"

[Icons]
Name: "{autoprograms}\WorkBuddy2API Panel++"; Filename: "{app}\wb2api.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\WorkBuddy2API Panel++"; Filename: "{app}\wb2api.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加快捷方式："

[Run]
Filename: "{app}\wb2api.exe"; WorkingDir: "{app}"; Description: "启动 WorkBuddy2API Panel++"; Flags: nowait postinstall skipifsilent
