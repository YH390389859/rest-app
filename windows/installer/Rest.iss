; Rest for Windows —— Inno Setup 安装器
;
; 生成方式（一般通过 build.ps1 -Installer 调用，不用手敲）：
;   iscc /DAppVersion=1.1.0 installer\Rest.iss
;
; 几个刻意的选择：
;   * PrivilegesRequired=lowest：装到 %LOCALAPPDATA%\Programs\Rest，不需要管理员、不弹 UAC。
;     休息提醒这种常驻托盘的个人工具没必要进 Program Files，也不需要给所有用户装。
;   * 目录固定 + AppId 固定：升级时原地覆盖，卸载项只有一条，不会像便携版那样每换一个
;     解压目录就多出一堆互不相认的副本。
;   * 装完不强制开机自启：那件事交给应用自己的设置项，安装器不替用户做决定。

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#define AppName "Rest"
#define AppPublisher "yanghui"
#define AppExeName "Rest.exe"
#define AppUrl "https://github.com/YH390389859/rest-app"

[Setup]
AppId={{8F3C2A71-5B4D-4E9A-9C1F-2D6E7A0B4C58}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases
VersionInfoVersion={#AppVersion}
VersionInfoDescription={#AppName} 休息提醒 安装程序
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=Rest-{#AppVersion}-win-x64-setup
SetupIconFile=..\src\Resources\Rest.ico
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
MinVersion=10.0.19041

[Languages]
; Inno Setup 官方安装包里没带简体中文（Languages 目录只有 29 种语言），
; 这里把官方 issrc 仓库的 ChineseSimplified.isl 放进仓库，避免构建时联网拉翻译。
Name: "chinesesimplified"; MessagesFile: "languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务:"; Flags: unchecked

[Files]
; 整个 self-contained 发布目录（约 70 MB，含 .NET 运行时，装完不需要再装 .NET）
Source: "..\dist\win-x64\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\卸载 {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "立即启动 {#AppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; 只删安装目录里生成的东西；用户设置在 %LOCALAPPDATA%\Rest 下，卸载时保留
Type: filesandordirs; Name: "{app}"
