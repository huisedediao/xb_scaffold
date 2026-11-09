; XbUme Windows 安装器（Inno Setup 6）
;
; 由 build.ps1 调用：
;   ISCC.exe /DVersion=1.0.0 /DSourceDir=...\app /DOutDir=...\dist installer.iss
;
; 安装后的目录结构与免安装目录完全一致，程序只靠「同目录存在兄弟可执行
; 文件」判定自己是分发版，因此安装位置不影响功能。

#ifndef Version
  #define Version "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "app"
#endif
#ifndef OutDir
  #define OutDir "dist"
#endif

[Setup]
AppId={{9F2B7C41-6A8E-4D3B-9C05-1E7A5B2D8F30}
AppName=XbUme
AppVerName=XbUme {#Version}
AppVersion={#Version}
AppPublisher=XbUme
DefaultDirName={autopf}\XbUme
DefaultGroupName=XbUme
DisableProgramGroupPage=yes
OutputDir={#OutDir}
OutputBaseFilename=XbUme-{#Version}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; 装到当前用户目录，不需要管理员权限（测试人员常见场景是没有管理员账号）。
PrivilegesRequired=lowest
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
UninstallDisplayIcon={app}\xbume-ide.exe
UninstallDisplayName=XbUme {#Version}
VersionInfoVersion={#Version}

[Languages]
Name: "zhcn"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加快捷方式:"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\XbUme"; Filename: "{app}\xbume-ide.exe"; WorkingDir: "{app}"
Name: "{group}\使用说明"; Filename: "{app}\使用说明.txt"
Name: "{autodesktop}\XbUme"; Filename: "{app}\xbume-ide.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
; 装完直接拉起（xbume-ide 负责起后台服务 + 打开浏览器，自己很快退出）。
Filename: "{app}\xbume-ide.exe"; Description: "立即启动 XbUme"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; 只按可执行文件名收掉本程序自己的进程，卸载才会删得干净。
Filename: "{sys}\taskkill.exe"; Parameters: "/IM xbume-gui.exe /F"; Flags: runhidden; RunOnceId: "KillGui"
Filename: "{sys}\taskkill.exe"; Parameters: "/IM xbume-ide.exe /F"; Flags: runhidden; RunOnceId: "KillIde"
Filename: "{sys}\taskkill.exe"; Parameters: "/IM xbume-mcp.exe /F"; Flags: runhidden; RunOnceId: "KillMcp"
Filename: "{sys}\taskkill.exe"; Parameters: "/IM xbume-hotkey.exe /F"; Flags: runhidden; RunOnceId: "KillHotkey"
