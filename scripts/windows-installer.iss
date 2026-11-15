#ifndef BundleDir
  #error Please define BundleDir
#endif
#ifndef ReleaseDir
  #error Please define ReleaseDir
#endif
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{9164475C-8354-4875-A1F3-6CBCBE2BC32C}
AppName=随行定位
AppVersion={#AppVersion}
AppPublisher=随行定位项目
DefaultDirName={localappdata}\Programs\SuixingLoc
DefaultGroupName=随行定位
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
OutputDir={#ReleaseDir}
OutputBaseFilename=随行定位-安装
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\FlutterApp\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\随行定位.exe
LicenseFile=..\LICENSE
InfoAfterFile=..\README-桌面版.md
CloseApplications=yes
RestartApplications=no
SetupMutex=SuixingLoc.Setup
AppMutex=Local\SuixingLoc.Flutter
UninstallDisplayName=随行定位

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式："

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\随行定位"; Filename: "{app}\随行定位.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\随行定位"; Filename: "{app}\随行定位.exe"; WorkingDir: "{app}"; Tasks: desktopicon

; No [Run] entry: the user decides when to start and validate the application.
; User settings under %LOCALAPPDATA%\SuixingLoc are retained on uninstall.
