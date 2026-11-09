# XbUme Windows 分发包构建（AOT 编译 + Inno Setup 安装器）。
#
# 用法（在仓库任意位置执行）：
#   powershell -ExecutionPolicy Bypass -File tool\package\windows\build.ps1
#   powershell ... build.ps1 -Version 1.0.0 -OutDir D:\dist -NoInstaller
#
# 产物：
#   build\package\windows\app\                 可直接运行的目录（免安装）
#   dist\XbUme-<version>-setup.exe             Inno Setup 安装包（有 ISCC 时）
#
# 目录结构（安装后的程序目录）：
#   xbume-ide.exe / xbume-gui.exe / xbume-mcp.exe / xbume-hotkey.exe
#   tools\adb.exe / hdc.exe / idevice_id.exe / iproxy.exe （及所需 dll）
#   version.txt / 使用说明.txt
#
# 说明：
#   - 四个入口分别 AOT 编译，目标机不需要装 Dart / Flutter；
#   - 运行期靠「同目录存在兄弟可执行文件」判定为分发版
#     （见 bin/src/control/svc_control.dart 的 isBundledBuild）；
#   - tools 目录被 preferredBinDirs 放在 PATH 之前，测试人员不用自己装
#     platform-tools / DevEco；
#   - 没有 Inno Setup 时只产出免安装目录，把它打成 zip 发给测试人员也能用。

param(
  [string]$Version = "",
  [string]$OutDir = "",
  [string]$ToolDir = "",
  [switch]$NoInstaller
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = (Resolve-Path (Join-Path $Here '..\..\..')).Path
$Build = Join-Path $Root 'build\package\windows'
$App = Join-Path $Build 'app'
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $Root 'dist' }

function Step($n, $msg) { Write-Host ""; Write-Host "[$n] $msg" -ForegroundColor Cyan }

function Find-Dart {
  $c = Get-Command dart -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  throw 'PATH 里找不到 dart（Flutter SDK 的 bin 目录）'
}

# ---------------------------------------------------------------------------
# 读版本号
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Version)) {
  $line = Select-String -Path (Join-Path $Root 'pubspec.yaml') -Pattern '^version:\s*(\S+)' |
    Select-Object -First 1
  if ($line) { $Version = $line.Matches[0].Groups[1].Value }
}
if ([string]::IsNullOrWhiteSpace($Version)) { throw '读不到 pubspec.yaml 的 version' }
Write-Host "版本: $Version"

$Dart = Find-Dart

# ---------------------------------------------------------------------------
# 1. AOT 编译四个入口
# ---------------------------------------------------------------------------
Step '1/5' 'AOT 编译（dart compile exe）'
if (Test-Path $App) { Remove-Item $App -Recurse -Force }
New-Item -ItemType Directory -Path $App -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $App 'tools') -Force | Out-Null

$targets = @(
  @{ Src = 'bin\ide.dart';                            Out = 'xbume-ide.exe' },
  @{ Src = 'bin\ide_gui.dart';                        Out = 'xbume-gui.exe' },
  @{ Src = 'bin\mcp.dart';                            Out = 'xbume-mcp.exe' },
  @{ Src = 'bin\src\hotkeys\hotkey_listener.dart';    Out = 'xbume-hotkey.exe' }
)
Push-Location $Root
try {
  foreach ($t in $targets) {
    & $Dart compile exe $t.Src -o (Join-Path $App $t.Out)
    if ($LASTEXITCODE -ne 0) { throw "编译失败: $($t.Src)" }
  }
} finally { Pop-Location }

# ---------------------------------------------------------------------------
# 2. 版本与说明
# ---------------------------------------------------------------------------
Step '2/5' '版本与说明'
Set-Content -Path (Join-Path $App 'version.txt') -Value $Version -Encoding ASCII -NoNewline
$readme = Join-Path $Here '使用说明.txt'
if (Test-Path $readme) { Copy-Item $readme (Join-Path $App '使用说明.txt') -Force }

# ---------------------------------------------------------------------------
# 3. 内嵌转发工具（adb / hdc / idevice_id / iproxy）
# ---------------------------------------------------------------------------
Step '3/5' '内嵌转发工具'
$tools = @('adb.exe', 'hdc.exe', 'idevice_id.exe', 'iproxy.exe')
foreach ($name in $tools) {
  $src = $null
  if (-not [string]::IsNullOrWhiteSpace($ToolDir)) {
    $p = Join-Path $ToolDir $name
    if (Test-Path $p) { $src = $p }
  }
  if (-not $src) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { $src = $c.Source }
  }
  if (-not $src) {
    $cands = @(
      (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\' + $name),
      (Join-Path $env:USERPROFILE 'AppData\Local\Android\Sdk\platform-tools\' + $name),
      'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\' + $name,
      'C:\Windows\System32\' + $name
    )
    foreach ($p in $cands) { if (Test-Path $p) { $src = $p; break } }
  }
  if ($src) {
    Copy-Item $src (Join-Path $App "tools\$name") -Force
    Write-Host "  - $name <- $src"
  } else {
    Write-Host "  - $name: 未找到，跳过（测试机需自行安装）" -ForegroundColor Yellow
  }
  # libimobiledevice 的附属 dll / usbmuxd 组件：有就一起带上。
}
$extraDlls = @('libimobiledevice-1.0.dll', 'libusbmuxd-2.0.dll',
  'libplist-2.0.dll', 'libimobiledevice-glue-1.0.dll', 'libcrypto-3-x64.dll',
  'libssl-3-x64.dll', 'usbmuxd.dll', 'libusb-1.0.dll')
foreach ($dll in $extraDlls) {
  foreach ($dir in @($ToolDir, (Join-Path $env:ProgramFiles 'XbUme\tools'))) {
    if ([string]::IsNullOrWhiteSpace($dir)) { continue }
    $p = Join-Path $dir $dll
    if (Test-Path $p) { Copy-Item $p (Join-Path $App "tools\$dll") -Force; break }
  }
}

# ---------------------------------------------------------------------------
# 4. 组装完成
# ---------------------------------------------------------------------------
Step '4/5' '免安装目录'
Write-Host "  $App"
Get-ChildItem $App | Select-Object Name, Length | Format-Table -AutoSize | Out-String | Write-Host

# ---------------------------------------------------------------------------
# 5. Inno Setup 安装包
# ---------------------------------------------------------------------------
Step '5/5' '生成安装包'
if ($NoInstaller) {
  Write-Host '  已跳过（-NoInstaller）'
} else {
  $isccCands = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 5\ISCC.exe')
  ) | Where-Object { $_ -and (Test-Path $_) }
  $iscc = $isccCands | Select-Object -First 1
  if (-not $iscc) {
    Write-Host '  未找到 ISCC.exe（Inno Setup 6）。' -ForegroundColor Yellow
    Write-Host '  安装 Inno Setup 后重跑，或把 build\package\windows\app 打成 zip 分发。'
  } else {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    & $iscc "/DVersion=$Version" "/DSourceDir=$App" "/DOutDir=$OutDir" (Join-Path $Here 'installer.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Inno Setup 编译失败' }
    Write-Host "  $OutDir\XbUme-$Version-setup.exe"
  }
}

Write-Host ''
Write-Host '注意：被测 app 必须以 --dart-define=XBUME_AGENT=1 构建，否则'
Write-Host '      直连（不依赖 VM）通道不会开启，本工具看不到任何会话。'
