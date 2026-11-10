#define MyAppName "Circle"
#ifndef AppVersion
  #define AppVersion "0.4.1"
#endif
#ifndef BuildRoot
  #define BuildRoot "..\build\windows\x64\runner\Release"
#endif
[Setup]
AppId={{B24D8C66-97D5-4816-B133-055260C22622}
AppName={#MyAppName}
AppVersion={#AppVersion}
AppVerName=Circle {#AppVersion}
AppPublisher=Circle
DefaultDirName={localappdata}\Programs\Circle
DefaultGroupName=Circle
OutputDir=..\dist
OutputBaseFilename=Circle_Windows_{#AppVersion}_Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\branding\circle.ico
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\circle_windows.exe
CloseApplications=yes
RestartApplications=no
DisableProgramGroupPage=yes
[Files]
Source: "{#BuildRoot}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
[Icons]
Name: "{autoprograms}\Circle"; Filename: "{app}\circle_windows.exe"
Name: "{autodesktop}\Circle"; Filename: "{app}\circle_windows.exe"; Tasks: desktopicon
[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; GroupDescription: "Дополнительные задачи:"
[Run]
Filename: "{app}\circle_windows.exe"; Description: "Запустить Circle"; Flags: nowait postinstall skipifsilent
