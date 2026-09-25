# build-exe.ps1 —— 把 PrinterStatusGuard.ps1 编译成免安装的单文件 exe（GUI / 无控制台）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File build-exe.ps1
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$src  = Join-Path $ScriptDir 'PrinterStatusGuard.ps1'
$exe  = Join-Path $ScriptDir 'PrinterStatusGuard.exe'
$cmd  = Join-Path $ScriptDir 'PrinterStatusGuard.cmd'
$ico  = Join-Path $ScriptDir 'app.ico'
$ver  = '1.1.3'

if (-not (Test-Path $src)) { throw "找不到源文件: $src" }

# 若目标 exe 被占用（程序正在运行），改写到 _new 后缀，避免编译失败
function Test-FileLocked([string]$p) {
    if (-not (Test-Path $p)) { return $false }
    try { $fs = [System.IO.File]::Open($p, 'Open', 'ReadWrite', 'None'); $fs.Close(); return $false }
    catch { return $true }
}
if (Test-FileLocked $exe) {
    $newExe = Join-Path $ScriptDir 'PrinterStatusGuard_new.exe'
    Write-Host ("目标被占用（程序运行中），改写到: " + $newExe)
    Write-Host "请退出正在运行的 PrinterStatusGuard 后，用新文件覆盖旧文件再启动。"
    $exe = $newExe
}

Import-Module ps2exe -ErrorAction Stop

Write-Host ("编译中 -> " + $exe)
$params = @{
    inputFile   = $src
    outputFile  = $exe
    noConsole   = $true
    x64         = $true
    title       = 'PrinterStatusGuard 打印机状态守护'
    description = '打印机状态守护（SNMP+IPP 双通道）+ 打印子系统深度体检，免安装单文件工具'
    company     = 'DC1024'
    product     = 'PrinterStatusGuard'
    copyright   = '(c) DC1024'
    version     = $ver
    noOutput    = $true
}
if (Test-Path $ico) { $params.iconFile = $ico; Write-Host ("使用图标: " + $ico) }
Invoke-ps2exe @params

if (-not (Test-Path $exe)) { throw "编译失败：未生成 $exe" }
$sizeKB = [math]::Round((Get-Item $exe).Length / 1KB, 1)
Write-Host ("已生成 exe: " + $exe + " (" + $sizeKB + " KB)")

# ===================== 生成 .cmd 启动器（GBK 编码，exe -> ps1 回退） =====================
# 纯 ASCII 内容，避免中文在默认控制台（CP936）下因编码错位而乱码；按 GBK 落盘。
$cmdContent = @'
@echo off
set "DIR=%~dp0"
if exist "%DIR%PrinterStatusGuard.exe" (
    "%DIR%PrinterStatusGuard.exe" %*
    exit /b %errorlevel%
)
if exist "%DIR%PrinterStatusGuard.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%DIR%PrinterStatusGuard.ps1" %*
    exit /b %errorlevel%
)
echo PrinterStatusGuard.exe and PrinterStatusGuard.ps1 not found in same folder.
pause
exit /b 1
'@
[System.IO.File]::WriteAllText($cmd, $cmdContent, [System.Text.Encoding]::GetEncoding('GB2312'))
Write-Host ("已生成启动器: " + $cmd + " (GBK)")
Write-Host "完成。"
