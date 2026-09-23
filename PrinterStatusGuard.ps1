# PrinterStatusGuard.ps1 —— 打印机状态守护：路线A 启用端口SNMP + 路线B IPP哨兵常驻
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File PrinterStatusGuard.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File PrinterStatusGuard.ps1 -Guard      # 隐藏到托盘并立即开始哨兵（用于开机自启）
#   powershell -NoProfile -ExecutionPolicy Bypass -File PrinterStatusGuard.ps1 -SelfTest   # 无头逻辑自检
# 注意：本文件必须带 UTF-8 BOM，否则 PowerShell 5.1 会按 ANSI 解码把中文与语法一起搞坏。

param(
    [switch]$Guard,
    [switch]$SelfTest,
    [string]$EnablePort,
    [string]$DisablePort
)

$ErrorActionPreference = 'Continue'
$ScriptVersion = '0.1.0'

# 取脚本目录（exe 形态下 $MyInvocation.MyCommand.Path 是 exe 路径；ps1 形态下是 ps1 路径）
function Get-ScriptDir {
    if ($MyInvocation.MyCommand.Path) { return Split-Path $MyInvocation.MyCommand.Path -Parent }
    if ($PSScriptRoot) { return $PSScriptRoot }
    return (Get-Location).Path
}
$ScriptDir = Get-ScriptDir
$ExeOrScript = if ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $PSCommandPath }
if (-not $ExeOrScript) { $ExeOrScript = Join-Path $ScriptDir 'PrinterStatusGuard.ps1' }

$ConfigDir = Join-Path $env:APPDATA 'PrinterStatusGuard'
$ConfigFile = Join-Path $ConfigDir 'config.json'
$LogDir = Join-Path $ConfigDir 'logs'

# ===================== 纯逻辑：状态原因映射 =====================
# IPP printer-state-reasons 关键词 -> 中文 + 严重度
$ReasonMap = [ordered]@{
    'media-empty'            = @{ Text = '缺纸';                 Sev = 'Critical' }
    'media-low'              = @{ Text = '纸张不足';             Sev = 'Warning'  }
    'media-jam'              = @{ Text = '卡纸';                 Sev = 'Critical' }
    'paper-jam'              = @{ Text = '卡纸';                 Sev = 'Critical' }
    'cover-open'             = @{ Text = '盖板 / 前盖未关';      Sev = 'Warning'  }
    'door-open'              = @{ Text = '门未关';               Sev = 'Warning'  }
    'output-tray-missing'    = @{ Text = '出纸盘缺失';           Sev = 'Warning'  }
    'input-tray-missing'     = @{ Text = '进纸盘缺失';           Sev = 'Warning'  }
    'input-tray-empty'       = @{ Text = '进纸盘为空';           Sev = 'Warning'  }
    'marker-supply-empty'    = @{ Text = '墨 / 碳粉耗尽';        Sev = 'Critical' }
    'marker-supply-low'      = @{ Text = '墨 / 碳粉不足';        Sev = 'Warning'  }
    'toner-empty'            = @{ Text = '碳粉耗尽';             Sev = 'Critical' }
    'toner-low'              = @{ Text = '碳粉不足';             Sev = 'Warning'  }
    'ink-empty'              = @{ Text = '墨水耗尽';             Sev = 'Critical' }
    'ink-low'                = @{ Text = '墨水不足';             Sev = 'Warning'  }
    'paused'                 = @{ Text = '打印机已暂停';         Sev = 'Warning'  }
    'stopped-partly'         = @{ Text = '部分停止';             Sev = 'Warning'  }
    'timed-out'              = @{ Text = '响应超时';             Sev = 'Warning'  }
    'none'                   = @{ Text = '正常';                 Sev = 'OK'       }
}

function ConvertFrom-StateReasons {
    param([string[]]$Reasons)
    $out = @()
    foreach ($r in $Reasons) {
        $key = ($r -split '/')[0].Trim()
        if ($ReasonMap.Contains($key)) { $out += $ReasonMap[$key] }
        else { $out += @{ Text = $r; Sev = 'Warning' } }
    }
    if ($out.Count -eq 0) { $out += $ReasonMap['none'] }
    # -NoEnumerate：单元素数组返回时不会被 PowerShell 拆成标量（否则调用方 $m[0] 取不到）
    Write-Output -NoEnumerate $out
}

function ConvertFrom-PrinterState {
    param([int]$State)
    switch ($State) {
        3 { return @{ Text = '空闲'; Sev = 'OK' } }
        4 { return @{ Text = '打印中'; Sev = 'OK' } }
        5 { return @{ Text = '已停止'; Sev = 'Warning' } }
        default { return @{ Text = "状态$State"; Sev = 'OK' } }
    }
}

# ===================== 纯逻辑：IPP 客户端（复用已验证代码） =====================
function Get-IppOidBytes([string]$oid) {
    $parts = $oid.Split('.') | ForEach-Object { [int]$_ }
    $b = New-Object System.Collections.ArrayList
    [void]$b.Add([byte](40 * $parts[0] + $parts[1]))
    for ($i = 2; $i -lt $parts.Count; $i++) {
        $v = $parts[$i]; $stack = New-Object System.Collections.ArrayList
        [void]$stack.Insert(0, [byte]($v -band 0x7F)); $v = $v -shr 7
        while ($v -gt 0) { [void]$stack.Insert(0, [byte](($v -band 0x7F) -bor 0x80)); $v = $v -shr 7 }
        foreach ($x in $stack) { [void]$b.Add($x) }
    }
    return , $b.ToArray()
}

function Add-IppAttr([System.Collections.ArrayList]$buf, [byte]$tag, [string]$name, [string]$value) {
    $nb = [System.Text.Encoding]::ASCII.GetBytes($name)
    $vb = [System.Text.Encoding]::UTF8.GetBytes($value)
    [void]$buf.Add($tag)
    [void]$buf.Add([byte](($nb.Length -shr 8) -band 0xFF)); [void]$buf.Add([byte]($nb.Length -band 0xFF))
    foreach ($x in $nb) { [void]$buf.Add($x) }
    [void]$buf.Add([byte](($vb.Length -shr 8) -band 0xFF)); [void]$buf.Add([byte]($vb.Length -band 0xFF))
    foreach ($x in $vb) { [void]$buf.Add($x) }
}

function Build-IppGetPrinterAttributes([string]$uri, [string[]]$requested) {
    $buf = New-Object System.Collections.ArrayList
    [void]$buf.Add([byte]0x01); [void]$buf.Add([byte]0x01)          # IPP version 1.1
    [void]$buf.Add([byte]0x00); [void]$buf.Add([byte]0x0B)          # operation Get-Printer-Attributes
    [void]$buf.Add([byte]0x00); [void]$buf.Add([byte]0x00); [void]$buf.Add([byte]0x00); [void]$buf.Add([byte]0x01)
    [void]$buf.Add([byte]0x01)                                       # operation-attributes-tag
    Add-IppAttr $buf 0x47 'attributes-charset' 'utf-8'
    Add-IppAttr $buf 0x48 'attributes-natural-language' 'en-us'
    Add-IppAttr $buf 0x45 'printer-uri' $uri
    foreach ($a in $requested) { Add-IppAttr $buf 0x44 'requested-attributes' $a }
    [void]$buf.Add([byte]0x03)                                       # end-of-attributes-tag
    return $buf.ToArray()
}

function Parse-IppAttributes([byte[]]$rb) {
    $attrs = [ordered]@{}
    if ($rb.Length -lt 8) { return $attrs }
    $i = 8; $curName = ''
    while ($i -lt $rb.Length) {
        $tag = [int]$rb[$i]
        if ($tag -eq 0x03) { break }
        if ($tag -eq 0x01 -or $tag -eq 0x02 -or $tag -eq 0x04) { $i++; continue }
        if ($tag -lt 0x10) { $i++; continue }
        $nl = ([int]$rb[$i + 1] -shl 8) + [int]$rb[$i + 2]
        if ($nl -gt 0) { $name = [System.Text.Encoding]::ASCII.GetString($rb, $i + 3, $nl); $curName = $name }
        else { $name = $curName }
        $p = $i + 3 + $nl
        $vl = ([int]$rb[$p] -shl 8) + [int]$rb[$p + 1]
        if ($tag -eq 0x21 -or $tag -eq 0x22 -or $tag -eq 0x23 -or $tag -eq 0x24) {
            $n = 0; for ($k = 0; $k -lt $vl; $k++) { $n = ($n -shl 8) + [int]$rb[$p + 2 + $k] }
            $val = [string]$n
        }
        else { $val = [System.Text.Encoding]::UTF8.GetString($rb, $p + 2, $vl) }
        if ($attrs.Contains($name)) {
            $ex = $attrs[$name]
            if ($ex -is [System.Collections.ArrayList]) { [void]$ex.Add($val) }
            else { $list = New-Object System.Collections.ArrayList; [void]$list.Add($ex); [void]$list.Add($val); $attrs[$name] = $list }
        }
        else { $attrs[$name] = $val }
        $i = $p + 2 + $vl
    }
    return $attrs
}

function Invoke-IppGetPrinterAttributes {
    param([string]$Ip, [int]$Port = 631, [string]$Path = '/ipp/print', [string[]]$Requested = @())
    $uri = ('ipp://' + $Ip + ':' + $Port + $Path)
    $body = Build-IppGetPrinterAttributes $uri $Requested
    try {
        $req = [System.Net.HttpWebRequest]::Create(('http://' + $Ip + ':' + $Port + $Path))
        $req.Method = 'POST'; $req.ContentType = 'application/ipp'
        $req.ContentLength = $body.Length; $req.Timeout = 5000; $req.ReadWriteTimeout = 5000
        $req.Proxy = $null
        $st = $req.GetRequestStream(); $st.Write($body, 0, $body.Length); $st.Close()
        $resp = $req.GetResponse()
        $ms = New-Object System.IO.MemoryStream
        $resp.GetResponseStream().CopyTo($ms)
        $rb = $ms.ToArray(); $ms.Close(); $resp.Close()
        return Parse-IppAttributes $rb
    }
    catch { return $null }
}

# ===================== 纯逻辑：SNMP 客户端（复用已验证代码） =====================
function Tlv([byte]$tag, [byte[]]$val) {
    $out = New-Object System.Collections.ArrayList
    [void]$out.Add($tag)
    if ($val.Length -lt 0x80) { [void]$out.Add([byte]$val.Length) }
    elseif ($val.Length -le 0xFF) { [void]$out.Add([byte]0x81); [void]$out.Add([byte]$val.Length) }
    else { [void]$out.Add([byte]0x82); [void]$out.Add([byte](($val.Length -shr 8) -band 0xFF)); [void]$out.Add([byte]($val.Length -band 0xFF)) }
    foreach ($x in $val) { [void]$out.Add($x) }
    return , $out.ToArray()
}

function Read-Tlv([byte[]]$b, [int]$pos) {
    $tag = [int]$b[$pos]; $p = $pos + 1; $first = [int]$b[$p]
    if ($first -lt 0x80) { $len = $first; $p += 1 }
    else {
        $n = $first -band 0x7F; $len = 0
        for ($i = 0; $i -lt $n; $i++) { $len = ($len -shl 8) + [int]$b[$p + 1 + $i] }
        $p += 1 + $n
    }
    return @{ Tag = $tag; Len = $len; ValueStart = $p; Next = ($p + $len) }
}

function Get-OidString([byte[]]$b, [int]$off, [int]$len) {
    $sb = New-Object System.Text.StringBuilder
    $first = [int]$b[$off]
    [void]$sb.Append([string][math]::Floor($first / 40) + '.' + [string]($first % 40))
    $v = 0
    for ($i = 1; $i -lt $len; $i++) {
        $x = [int]$b[$off + $i]; $v = ($v -shl 7) + ($x -band 0x7F)
        if (($x -band 0x80) -eq 0) { [void]$sb.Append('.' + [string]$v); $v = 0 }
    }
    return $sb.ToString()
}

function Invoke-SnmpGet {
    param([string]$Target, [string]$Community = 'public', [string]$Oid, [int]$TimeoutMs = 2000)
    $oidTlv = Tlv 0x06 (Get-IppOidBytes $Oid)
    $nullTlv = Tlv 0x05 @()
    $varbind = Tlv 0x30 (@(@($oidTlv) + @($nullTlv)))
    $vbList = Tlv 0x30 $varbind
    $reqId = @([byte]0x02, [byte]0x04, [byte]0x11, [byte]0x22, [byte]0x33, [byte]0x44)
    $errStat = @([byte]0x02, [byte]0x01, [byte]0x00)
    $errIdx = @([byte]0x02, [byte]0x01, [byte]0x00)
    $pdu = Tlv 0xA0 (@(@($reqId) + @($errStat) + @($errIdx) + @($vbList)))
    $ver = @([byte]0x02, [byte]0x01, [byte]0x00)
    $comm = Tlv 0x04 ([System.Text.Encoding]::ASCII.GetBytes($Community))
    $pkt = Tlv 0x30 (@(@($ver) + @($comm) + @($pdu)))
    $u = New-Object System.Net.Sockets.UdpClient
    try {
        $u.Client.ReceiveTimeout = $TimeoutMs; $u.Connect($Target, 161)
        [void]$u.Send($pkt, $pkt.Length)
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        return $u.Receive([ref]$ep)
    }
    catch { return $null }
    finally { $u.Close() }
}

function Decode-Snmp([byte[]]$b) {
    $res = @{ Oid = ''; Type = -1; Text = ''; Raw = $null; ErrStatus = -1; Error = '' }
    try {
        $p = (Read-Tlv $b 0).ValueStart
        $t = Read-Tlv $b $p; $p = $t.Next              # version
        $t = Read-Tlv $b $p; $p = $t.Next              # community
        $tPdu = Read-Tlv $b $p; $p = $tPdu.ValueStart  # PDU (0xA2 = GetResponse)
        $t = Read-Tlv $b $p; $p = $t.Next              # request-id
        $t = Read-Tlv $b $p; $res.ErrStatus = [int]$b[$t.ValueStart]; $p = $t.Next
        if ($res.ErrStatus -ne 0) { $res.Error = 'error-status=' + $res.ErrStatus; return $res }
        $t = Read-Tlv $b $p; $p = $t.Next              # error-index
        $t = Read-Tlv $b $p; $p = $t.ValueStart        # varbind list
        $t = Read-Tlv $b $p; $p = $t.ValueStart        # first varbind
        $tOid = Read-Tlv $b $p; $p = $tOid.Next
        $res.Oid = Get-OidString $b $tOid.ValueStart $tOid.Len
        $tVal = Read-Tlv $b $p; $res.Type = $tVal.Tag
        $raw = New-Object byte[] $tVal.Len
        if ($tVal.Len -gt 0) { [Array]::Copy($b, $tVal.ValueStart, $raw, 0, $tVal.Len) }
        $res.Raw = $raw
        switch ($res.Type) {
            0x02 { $v = 0; foreach ($x in $raw) { $v = ($v -shl 8) + [int]$x }; $res.Text = [string]$v }
            0x04 {
                $s = ''; foreach ($x in $raw) { if ($x -ge 32 -and $x -lt 127) { $s += [char]$x } else { $s += ('\x' + $x.ToString('X2')) } }
                $res.Text = $s
            }
            0x05 { $res.Text = '(NULL)' }
            0x06 { $res.Text = Get-OidString $raw 0 $raw.Length }
            default { $res.Text = (($raw | ForEach-Object { $_.ToString('X2') }) -join ' ') }
        }
    }
    catch { $res.Error = 'decode failed: ' + $_.Exception.Message }
    return $res
}

# hrPrinterDetectedErrorState 位域 -> 中文名（RFC 2790，无卡纸位）
$SnmpErrorBits = [ordered]@{
    '0.0' = '其他'; '0.1' = '未知'; '0.2' = '定影器过热'; '0.3' = '定影器过冷'
    '0.4' = 'OPC 临近寿命'; '0.5' = 'OPC 寿命终'; '0.6' = '定影器临近寿命'; '0.7' = '定影器寿命终'
    '1.0' = '进纸盘缺失'; '1.1' = '出纸盘缺失'; '1.2' = '耗材缺失'; '1.3' = '出纸盘将满'
    '1.4' = '出纸盘已满'; '1.5' = '进纸盘为空(缺纸)'; '1.6' = '维护到期'
}

function Get-SnmpPrinterErrorState {
    param([string]$Ip, [string]$Community = 'public')
    $resp = Invoke-SnmpGet -Target $Ip -Community $Community -Oid '1.3.6.1.2.1.25.3.5.1.2.1' -TimeoutMs 2000
    if ($null -eq $resp) { return $null }
    $d = Decode-Snmp $resp
    if ($d.Type -eq 0x04 -and $null -ne $d.Raw -and $d.Raw.Length -gt 0) {
        $bits = @()
        for ($by = 0; $by -lt $d.Raw.Length; $by++) {
            for ($bit = 0; $bit -lt 8; $bit++) {
                if ((([int]$d.Raw[$by] -shr $bit) -band 1) -eq 1) {
                    $key = "$by.$bit"; $nm = $SnmpErrorBits[$key]
                    if ([string]::IsNullOrEmpty($nm)) { $nm = 'bit ' + $key }
                    $bits += $nm
                }
            }
        }
        return $bits
    }
    return $null
}

# ===================== 纯逻辑：路线A 端口 SNMP 开关 + 路由B 配置 =====================
function Test-Admin {
    try {
        $wp = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        return $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Get-PrinterTcpIpPorts {
    $list = New-Object System.Collections.ArrayList
    try {
        $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\Standard TCP/IP Port\Ports'
        if (-not (Test-Path $base)) { return $list }
        Get-ChildItem $base -ErrorAction Stop | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath
            [void]$list.Add([ordered]@{
                PortName     = $_.PSChildName
                Protocol     = [int]($p.Protocol)
                PortNumber   = [int]($p.PortNumber)
                HostName     = [string]($p.HostName)
                IPAddress    = [string]($p.IPAddress)
                SNMPEnabled  = [int]($p.'SNMP Enabled')
                Community    = [string]($p.'SNMP Community')
            })
        }
    }
    catch { }
    return $list
}

function Set-PortSnmpEnabled {
    param([string]$PortName, [bool]$Enable, [string]$Community = 'public', [int]$Index = 1)
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\Standard TCP/IP Port\Ports'
    # 注意：不能用 Join-Path —— 它会把键名 Standard TCP/IP Port 里的 '/' 当成路径分隔符，改写成 Standard TCP\IP Port。
    # 注册表路径用 '\' 分隔，'/' 是键名的一部分，必须用字符串拼接保留。
    $kp = "$base\$PortName"
    if (-not (Test-Path $kp)) { return @{ Ok = $false; Msg = '端口注册表项不存在：' + $PortName } }
    if ($Enable) {
        New-ItemProperty -Path $kp -Name 'SNMP Enabled' -Value 1 -PropertyType DWORD -Force | Out-Null
        New-ItemProperty -Path $kp -Name 'SNMP Community' -Value $Community -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $kp -Name 'SNMP Index' -Value $Index -PropertyType DWORD -Force | Out-Null
        New-ItemProperty -Path $kp -Name 'PortMonMibPortIndex' -Value $Index -PropertyType DWORD -Force | Out-Null
    }
    else {
        New-ItemProperty -Path $kp -Name 'SNMP Enabled' -Value 0 -PropertyType DWORD -Force | Out-Null
    }
    # 重启 Print Spooler 让设置生效
    try { Restart-Service Spooler -Force -ErrorAction Stop; return @{ Ok = $true; Msg = '已写入注册表并重启 Spooler' } }
    catch { return @{ Ok = $true; Msg = '已写入注册表，但重启 Spooler 失败（请手动重启打印后台处理程序）' } }
}

function Get-AutoStart {
    try {
        $k = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'PrinterStatusGuard' -ErrorAction SilentlyContinue
        return [bool]($k.'PrinterStatusGuard')
    }
    catch { return $false }
}

function Set-AutoStart {
    param([bool]$Enable)
    $rk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if ($Enable) {
        if ($ExeOrScript -match '\.ps1$') {
            $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Guard' -f $ExeOrScript
        }
        else {
            $cmd = '"{0}" -Guard' -f $ExeOrScript
        }
        New-ItemProperty -Path $rk -Name 'PrinterStatusGuard' -Value $cmd -PropertyType String -Force | Out-Null
    }
    else {
        Remove-ItemProperty -Path $rk -Name 'PrinterStatusGuard' -ErrorAction SilentlyContinue
    }
}

# 以管理员身份重新启动本程序，并带上 -EnablePort/-DisablePort 一次性完成操作
function Start-ElevatedPortAction {
    param([string]$PortName, [bool]$Enable)
    $arg = if ($Enable) { '-EnablePort' } else { '-DisablePort' }
    if ($ExeOrScript -match '\.ps1$') {
        $psi = 'powershell.exe'
        $args = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1} "{2}"' -f $ExeOrScript, $arg, $PortName
    }
    else {
        $psi = $ExeOrScript
        $args = '{0} "{1}"' -f $arg, $PortName
    }
    try {
        Start-Process -Verb RunAs -FilePath $psi -ArgumentList $args | Out-Null
        return $true
    }
    catch { return $false }
}

# ===================== 纯逻辑：配置读写 =====================
function Read-Config {
    if (Test-Path $ConfigFile) {
        try { return (Get-Content $ConfigFile -Encoding UTF8 | ConvertFrom-Json) } catch { }
    }
    return [pscustomobject]@{
        IntervalSec = 30
        Targets     = @()
    }
}

function Write-Config($Cfg) {
    if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $Cfg | ConvertTo-Json -Depth 6 | Out-File $ConfigFile -Encoding UTF8
}

function Save-Log {
    param([string]$Msg)
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        $f = Join-Path $LogDir ('guard-' + (Get-Date -Format 'yyyy-MM-dd') + '.log')
        ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Msg) | Out-File $f -Encoding UTF8 -Append
    }
    catch { }
}

# ===================== 纯逻辑：通知（Toast 优先，失败回退气泡） =====================
# 返回 $true 表示 Toast 成功；返回 $false 表示回退到气泡（或两者都不可用）
$Global:NotifyIcon = $null

function Ensure-ToastAppId {
    # 让 Toast 能正常弹出，需要一个在「开始」菜单里、且 System.AppUserModel.ID 匹配的快捷方式
    try {
        $startDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
        if (-not (Test-Path $startDir)) { return }
        $lnk = Join-Path $startDir 'PrinterStatusGuard.lnk'
        $ws = New-Object -ComObject WScript.Shell
        $s = $ws.CreateShortcut($lnk)
        $s.TargetPath = $ExeOrScript
        $s.Arguments = '-Guard'
        $s.Description = 'PrinterStatusGuard 打印机状态守护'
        $s.Save()
        # 设置 AUMID（System.AppUserModel.ID），COM 方式
        $shield = $s.GetType().InvokeMember('IShellLinkDataList', [System.Reflection.BindingFlags]::GetProperty, $null, $s, $null)
        if ($shield) {
            $prop = $shield.GetType().InvokeMember('GetFlags', [System.Reflection.BindingFlags]::InvokeMethod, $null, $shield, $null)
        }
    }
    catch { }
}

function Send-Toast {
    param([string]$Title, [string]$Message, [string]$Icon = 'Info')
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
        Ensure-ToastAppId
        $appId = 'PrinterStatusGuard'
        $tt = [Windows.UI.Notifications.ToastTemplateType]::ToastText02
        $tpl = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent($tt)
        $txt = $tpl.GetElementsByTagName('text')
        $txt.Item(0).AppendChild($tpl.CreateTextNode($Title)) | Out-Null
        $txt.Item(1).AppendChild($tpl.CreateTextNode($Message)) | Out-Null
        $toast = [Windows.UI.Notifications.ToastNotification]::new($tpl)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
        return $true
    }
    catch { return $false }
}

function Send-Notification {
    param([string]$Title, [string]$Message, [string]$Icon = 'Warning')
    $toastOk = Send-Toast -Title $Title -Message $Message -Icon $Icon
    if ($toastOk) { return 'Toast' }
    # 回退：系统托盘气泡（需要 NotifyIcon）
    if ($Global:NotifyIcon) {
        $bi = [System.Windows.Forms.ToolTipIcon]::Warning
        if ($Icon -eq 'Info') { $bi = [System.Windows.Forms.ToolTipIcon]::Info }
        if ($Icon -eq 'Error') { $bi = [System.Windows.Forms.ToolTipIcon]::Error }
        $Global:NotifyIcon.ShowBalloonTip(6000, $Title, $Message, $bi)
        return 'Balloon'
    }
    # 都没有就写日志
    Save-Log ('NOTIFY(' + $Icon + '): ' + $Title + ' - ' + $Message)
    return 'LogOnly'
}

# ===================== 纯逻辑：哨兵一轮巡检 =====================
function Invoke-SentinelPoll($Cfg) {
    $events = New-Object System.Collections.ArrayList
    foreach ($t in $Cfg.Targets) {
        if (-not $t.Enabled) { continue }
        $attrs = Invoke-IppGetPrinterAttributes -Ip $t.Ip -Port $t.Port -Path $t.Path -Requested @('printer-state', 'printer-state-reasons', 'printer-is-accepting-jobs', 'marker-levels', 'printer-make-and-model')
        if ($null -eq $attrs) {
            # 重试一次（某些机型只认第一条 requested-attributes）
            $attrs = Invoke-IppGetPrinterAttributes -Ip $t.Ip -Port $t.Port -Path $t.Path -Requested @('printer-state-reasons')
        }
        if ($null -eq $attrs) {
            $now = '离线/无响应'
            if ($t.LastState -ne $now) {
                $t.LastState = $now; $t.LastReasons = ''
                [void]$events.Add(@{ Target = $t; Title = ('【' + $t.Name + '】无响应'); Message = 'IPP 端口无响应，可能已关机或网络不通'; Icon = 'Error' })
            }
            continue
        }
        $state = 0
        if ($attrs.Contains('printer-state')) { [int]::TryParse([string]$attrs['printer-state'], [ref]$state) | Out-Null }
        $reasonsRaw = ''
        if ($attrs.Contains('printer-state-reasons')) {
            $rv = $attrs['printer-state-reasons']
            if ($rv -is [System.Collections.ArrayList]) { $reasonsRaw = ($rv | ForEach-Object { $_ }) -join ' ' } else { $reasonsRaw = [string]$rv }
        }
        # 规范化：IPP 用空格分隔多个原因
        $reasons = ($reasonsRaw -split '\s+' | Where-Object { $_ -ne '' })
        $friendly = ConvertFrom-StateReasons -Reasons $reasons
        $stateInfo = ConvertFrom-PrinterState -State $state
        # 组合当前状态签名：状态 + 原因集合
        $sig = ($stateInfo.Text + '|' + (($reasons | Sort-Object) -join ','))
        $prevSig = ($t.LastState + '|' + ($t.LastReasons))
        if ($sig -ne $prevSig) {
            # 只在出现非「正常/空闲」的异常时弹通知；恢复正常也提示一次
            $crit = $friendly | Where-Object { $_.Sev -ne 'OK' }
            if ($crit.Count -gt 0) {
                $msgs = ($friendly | Where-Object { $_.Sev -ne 'OK' } | ForEach-Object { $_.Text }) -join '、'
                [void]$events.Add(@{ Target = $t; Title = ('【' + $t.Name + '】' + $stateInfo.Text); Message = $msgs; Icon = 'Warning' })
            }
            elseif ($prevSig -ne '') {
                [void]$events.Add(@{ Target = $t; Title = ('【' + $t.Name + '】已恢复'); Message = '状态恢复正常'; Icon = 'Info' })
            }
            $t.LastState = $stateInfo.Text; $t.LastReasons = (($reasons | Sort-Object) -join ',')
        }
    }
    return $events
}

# ===================== 无头自检 =====================
if ($SelfTest) {
    $ok = $true
    $r = New-Object System.Text.StringBuilder
    function ST([string]$name, [bool]$pass, [string]$extra = '') {
        $script:ok = ($script:ok -and $pass)
        [void]$r.AppendLine(('[{0}] {1} {2}' -f $(if ($pass) { 'OK  ' } else { 'FAIL' }), $name, $extra))
    }
    # 1) 状态原因映射
    $m = ConvertFrom-StateReasons -Reasons @('media-jam', 'toner-low')
    ST '状态原因映射 media-jam/toner-low' ($m.Count -eq 2 -and $m[0].Text -eq '卡纸' -and $m[1].Text -eq '碳粉不足')
    $m2 = ConvertFrom-StateReasons -Reasons @('none')
    ST '状态原因映射 none -> 正常' (($m2.Count -eq 1) -and ($m2[0].Text -eq '正常') -and ($m2[0].Sev -eq 'OK')) ('m2.Count=' + $m2.Count + ' Text=' + $m2[0].Text + ' Sev=' + $m2[0].Sev)
    # 2) 打印机状态映射
    ST '打印机状态 3->空闲' ((ConvertFrom-PrinterState -State 3).Text -eq '空闲')
    ST '打印机状态 5->已停止' ((ConvertFrom-PrinterState -State 5).Text -eq '已停止')
    # 3) IPP 解析（合成一个最小响应：version+op+id，再塞一个 printer-state=3 和一个 printer-state-reasons=none）
    # 构造：头部 8 字节 + printer-attributes-tag(0x04) + 一个枚举属性
    $sample = New-Object System.Collections.ArrayList
    # header
    [void]$sample.Add([byte]0x01); [void]$sample.Add([byte]0x01)
    [void]$sample.Add([byte]0x00); [void]$sample.Add([byte]0x0B)
    [void]$sample.Add([byte]0x00); [void]$sample.Add([byte]0x00); [void]$sample.Add([byte]0x00); [void]$sample.Add([byte]0x01)
    # printer-attributes-tag
    [void]$sample.Add([byte]0x04)
    # printer-state : tag 0x21 (enum), name='printer-state', value=3 (1 byte)
    $nb = [System.Text.Encoding]::ASCII.GetBytes('printer-state')
    [void]$sample.Add([byte]0x21)
    [void]$sample.Add([byte]0x00); [void]$sample.Add([byte]$nb.Length)
    foreach ($x in $nb) { [void]$sample.Add($x) }
    [void]$sample.Add([byte]0x00); [void]$sample.Add([byte]0x01); [void]$sample.Add([byte]0x03)
    # printer-state-reasons : tag 0x44 (keyword), name='printer-state-reasons', value='none'
    $nb2 = [System.Text.Encoding]::ASCII.GetBytes('printer-state-reasons')
    $vb2 = [System.Text.Encoding]::UTF8.GetBytes('none')
    [void]$sample.Add([byte]0x44)
    [void]$sample.Add([byte]0x00); [void]$sample.Add([byte]$nb2.Length)
    foreach ($x in $nb2) { [void]$sample.Add($x) }
    [void]$sample.Add([byte]0x00); [void]$sample.Add([byte]$vb2.Length)
    foreach ($x in $vb2) { [void]$sample.Add($x) }
    # end-of-attributes
    [void]$sample.Add([byte]0x03)
    $parsed = Parse-IppAttributes $sample.ToArray()
    ST 'IPP 解析 printer-state=3' ($parsed.Contains('printer-state') -and [string]$parsed['printer-state'] -eq '3')
    ST 'IPP 解析 printer-state-reasons=none' ($parsed.Contains('printer-state-reasons') -and [string]$parsed['printer-state-reasons'] -eq 'none')
    # 4) SNMP 解码（用 Tlv 助手构造一个合法 GetResponse）
    $ver = Tlv 0x02 @([byte]0x00)
    $comm = Tlv 0x04 ([System.Text.Encoding]::ASCII.GetBytes('public'))
    $reqId = Tlv 0x02 @([byte]0x11, [byte]0x22, [byte]0x33, [byte]0x44)
    $errStat = Tlv 0x02 @([byte]0x00)
    $errIdx = Tlv 0x02 @([byte]0x00)
    $oidTlv = Tlv 0x06 (Get-IppOidBytes '1.3.6.1.2.1.25.3.5.1.1.1')
    $valTlv = Tlv 0x02 @([byte]0x05)
    $vb = Tlv 0x30 (@(@($oidTlv) + @($valTlv)))
    $vbl = Tlv 0x30 $vb
    $pdu = Tlv 0xA2 (@(@($reqId) + @($errStat) + @($errIdx) + @($vbl)))
    $outer = Tlv 0x30 (@(@($ver) + @($comm) + @($pdu)))
    $d = Decode-Snmp $outer
    ST 'SNMP 解码 ErrStatus=0' ($d.ErrStatus -eq 0)
    ST 'SNMP 解码 value=5 (int)' ($d.Type -eq 0x02 -and $d.Text -eq '5')
    # 5) 端口注册表路径构造（不实际写）—— 用字符串拼接，不能用 Join-Path（会把 '/' 当成分隔符）
    $kp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\Standard TCP/IP Port\Ports' + '\' + 'IP_192.168.1.100'
    ST '端口SNMP注册表路径构造' ($kp -match 'Standard TCP/IP Port\\Ports\\IP_192.168.1.100')
    # 6) 通知函数存在
    ST 'Send-Notification 函数存在' (Get-Command Send-Notification -ErrorAction SilentlyContinue)
    ST 'Send-Toast 函数存在' (Get-Command Send-Toast -ErrorAction SilentlyContinue)
    # 7) 配置读写
    ST 'Read-Config 返回对象' ($null -ne (Read-Config))

    [void]$r.AppendLine('')
    [void]$r.AppendLine(('失败用例数: ' + $(if ($script:ok) { 0 } else { 1 })))
    $txt = $r.ToString()
    Write-Output $txt
    $outPath = Join-Path $ScriptDir 'PrinterStatusGuard_selftest.txt'
    try { [System.IO.File]::WriteAllText($outPath, $txt, (New-Object System.Text.UTF8Encoding($true))) } catch { }
    if (-not $script:ok) { exit 1 } else { exit 0 }
}

# ===================== 提权子进程：直接执行端口 SNMP 开关并退出 =====================
# 非管理员在主界面点「启用/关闭 SNMP」时，会用 RunAs 重新以管理员启动本程序并带上 -EnablePort/-DisablePort，
# 这里作为一次性子进程完成注册表写入后弹结果并退出（不加载主窗体）。
if ($EnablePort -or $DisablePort) {
    $pn = if ($EnablePort) { $EnablePort } else { $DisablePort }
    $en = [bool]$EnablePort
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
    if (-not (Test-Admin)) {
        [System.Windows.Forms.MessageBox]::Show('本操作需要管理员权限，但提权后仍未获得管理员身份。请手动右键「以管理员身份运行」后再试。', 'PrinterStatusGuard') | Out-Null
        exit 1
    }
    $r = Set-PortSnmpEnabled -PortName $pn -Enable $en
    [System.Windows.Forms.MessageBox]::Show($r.Msg, 'PrinterStatusGuard') | Out-Null
    exit 0
}

# ===================== 以下为 GUI / 托盘 / 哨兵（仅非自检时运行） =====================
[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
[void][System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')

$Cfg = Read-Config

# 托盘图标（用运行时生成的小位图，避免外部资源）
function New-TrayIcon {
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(0, 120, 215))
    $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $fnt = New-Object System.Drawing.Font('Arial', 10, [System.Drawing.FontStyle]::Bold)
    $g.DrawString('P', $fnt, $br, 1, 0)
    $g.Dispose()
    $ico = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    return $ico
}

$Global:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$Global:NotifyIcon.Icon = New-TrayIcon
$Global:NotifyIcon.Text = 'PrinterStatusGuard 打印机状态守护'
$Global:NotifyIcon.Visible = $true

# 托盘菜单
$cm = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = $cm.Items.Add('显示主窗口')
$miGuard = $cm.Items.Add('开始哨兵')
$miAuto = $cm.Items.Add('开机自启')
$miExit = $cm.Items.Add('退出')
$miAuto.Checked = (Get-AutoStart)
$Global:NotifyIcon.ContextMenuStrip = $cm

$SentinelTimer = $null
$GuardRunning = $false

function Start-Sentinel {
    param([bool]$FromUi = $true)
    if ($GuardRunning) { return }
    $GuardRunning = $true
    $miGuard.Text = '停止哨兵'
    $Global:NotifyIcon.Text = 'PrinterStatusGuard — 哨兵运行中'
    $script:SnmpFailedNotified = @{}
    $script:SnmpLastCheck = @{}
    $SentinelTimer = New-Object System.Windows.Forms.Timer
    $SentinelTimer.Interval = [math]::Max(10, $Cfg.IntervalSec) * 1000
    $SentinelTimer.Add_Tick({
        try {
            $evs = Invoke-SentinelPoll $script:Cfg
            foreach ($e in $evs) {
                $how = Send-Notification -Title $e.Title -Message $e.Message -Icon $e.Icon
                Save-Log ($e.Title + ' | ' + $e.Message + ' [' + $how + ']')
            }
            # 同时用 SNMP 补一路（若端口已开启 SNMP），把缺纸/缺墨也反映到 Windows 原生状态
            foreach ($t in $script:Cfg.Targets) {
                if (-not $t.Enabled) { continue }
                $now = Get-Date
                if ($script:SnmpLastCheck.Contains($t.Ip) -and (($now - $script:SnmpLastCheck[$t.Ip]).TotalSeconds -lt $script:Cfg.IntervalSec)) { continue }
                $script:SnmpLastCheck[$t.Ip] = $now
                $bits = Get-SnmpPrinterErrorState -Ip $t.Ip -Community $t.Community
                if ($null -ne $bits -and $bits.Count -gt 0) {
                    $key = ($bits -join ',')
                    if (-not $script:SnmpFailedNotified.Contains($t.Ip) -or $script:SnmpFailedNotified[$t.Ip] -ne $key) {
                        $script:SnmpFailedNotified[$t.Ip] = $key
                        $how = Send-Notification -Title ('【' + $t.Name + '】SNMP') -Message ('打印机状态: ' + ($bits -join '、')) -Icon 'Warning'
                        Save-Log ('SNMP ' + $t.Ip + ': ' + ($bits -join '、') + ' [' + $how + ']')
                    }
                }
            }
        }
        catch { Save-Log ('SENTINEL ERROR: ' + $_.Exception.Message) }
    })
    $SentinelTimer.Start()
    if ($FromUi) { Save-Log '哨兵已启动' }
}

function Stop-Sentinel {
    if (-not $GuardRunning) { return }
    $GuardRunning = $false
    $miGuard.Text = '开始哨兵'
    $Global:NotifyIcon.Text = 'PrinterStatusGuard 打印机状态守护'
    if ($SentinelTimer) { $SentinelTimer.Stop(); $SentinelTimer.Dispose(); $SentinelTimer = $null }
    Save-Log '哨兵已停止'
}

$miShow.Add_Click({ Show-MainForm })
$miGuard.Add_Click({ if ($GuardRunning) { Stop-Sentinel } else { Start-Sentinel -FromUi $true } })
$miAuto.Add_Click({
    $new = -not (Get-AutoStart); Set-AutoStart -Enable $new; $miAuto.Checked = $new
    Save-Log ('开机自启 ' + $(if ($new) { '已开启' } else { '已关闭' }))
})
$miExit.Add_Click({ Stop-Sentinel; $Global:NotifyIcon.Visible = $false; [System.Windows.Forms.Application]::Exit(); $Global:ExitFlag = $true })
$Global:NotifyIcon.Add_DoubleClick({ Show-MainForm })

# ===================== 主窗口 =====================
$MainForm = New-Object System.Windows.Forms.Form
$MainForm.Text = 'PrinterStatusGuard v' + $ScriptVersion + ' — 打印机状态守护'
$MainForm.Size = New-Object System.Drawing.Size(820, 560)
$MainForm.StartPosition = 'CenterScreen'
$MainForm.Icon = $Global:NotifyIcon.Icon

$tab = New-Object System.Windows.Forms.TabControl
$tab.Dock = 'Fill'
$MainForm.Controls.Add($tab)

# --- Tab A: 启用端口 SNMP ---
$tabA = New-Object System.Windows.Forms.TabPage; $tabA.Text = '路线A：启用端口 SNMP'
$tab.Controls.Add($tabA)

$lblA = New-Object System.Windows.Forms.Label
$lblA.Text = '开启后，Windows 原生即可显示缺纸/缺墨（SNMP）。需要管理员权限，本工具会尝试重启打印后台处理程序。'
$lblA.Location = New-Object System.Drawing.Point(12, 12); $lblA.Size = New-Object System.Drawing.Size(780, 30); $lblA.AutoSize = $false
$tabA.Controls.Add($lblA)

$dgvA = New-Object System.Windows.Forms.DataGridView
$dgvA.Location = New-Object System.Drawing.Point(12, 48); $dgvA.Size = New-Object System.Drawing.Size(780, 360)
$dgvA.AllowUserToAddRows = $false; $dgvA.ReadOnly = $true; $dgvA.AutoSizeColumnsMode = 'AllCells'
$dgvA.Columns.Add('Name', '端口名') | Out-Null
$dgvA.Columns.Add('Host', '主机/地址') | Out-Null
$dgvA.Columns.Add('Proto', '协议') | Out-Null
$dgvA.Columns.Add('SNMP', 'SNMP已启用') | Out-Null
$dgvA.Columns.Add('Comm', '团体名') | Out-Null
$tabA.Controls.Add($dgvA)

$btnRefreshA = New-Object System.Windows.Forms.Button
$btnRefreshA.Text = '刷新端口列表'; $btnRefreshA.Location = New-Object System.Drawing.Point(12, 416); $btnRefreshA.Size = New-Object System.Drawing.Size(120, 28)
$tabA.Controls.Add($btnRefreshA)

$btnEnableA = New-Object System.Windows.Forms.Button
$btnEnableA.Text = '启用选中端口 SNMP'; $btnEnableA.Location = New-Object System.Drawing.Point(150, 416); $btnEnableA.Size = New-Object System.Drawing.Size(170, 28)
$tabA.Controls.Add($btnEnableA)

$btnDisableA = New-Object System.Windows.Forms.Button
$btnDisableA.Text = '关闭选中端口 SNMP'; $btnDisableA.Location = New-Object System.Drawing.Point(332, 416); $btnDisableA.Size = New-Object System.Drawing.Size(170, 28)
$tabA.Controls.Add($btnDisableA)

$lblAdminA = New-Object System.Windows.Forms.Label
$lblAdminA.Location = New-Object System.Drawing.Point(520, 420); $lblAdminA.Size = New-Object System.Drawing.Size(270, 24)
$tabA.Controls.Add($lblAdminA)

$txtLogA = New-Object System.Windows.Forms.TextBox
$txtLogA.Multiline = $true; $txtLogA.ScrollBars = 'Vertical'; $txtLogA.ReadOnly = $true
$txtLogA.Location = New-Object System.Drawing.Point(12, 452); $txtLogA.Size = New-Object System.Drawing.Size(780, 60)
$tabA.Controls.Add($txtLogA)

function Refresh-PortsGrid {
    $dgvA.Rows.Clear()
    $ports = Get-PrinterTcpIpPorts
    foreach ($p in $ports) {
        $proto = if ($p.Protocol -eq 1) { 'RAW(9100)' } elseif ($p.Protocol -eq 2) { 'LPR' } else { [string]$p.Protocol }
        $dgvA.Rows.Add($p.PortName, ($p.HostName + ' / ' + $p.IPAddress), $proto, $(if ($p.SNMPEnabled -eq 1) { '是' } else { '否' }), $p.Community) | Out-Null
    }
    $lblAdminA.Text = if (Test-Admin) { '当前：管理员 ✔' } else { '当前：非管理员（操作会请求提权）' }
}

$btnRefreshA.Add_Click({ Refresh-PortsGrid })
$btnEnableA.Add_Click({
    if ($dgvA.SelectedRows.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('请先在表格里选中一个端口'); return }
    $pn = $dgvA.SelectedRows[0].Cells[0].Value
    if (-not (Test-Admin)) {
        if (Start-ElevatedPortAction -PortName $pn -Enable $true) {
            [System.Windows.Forms.MessageBox]::Show('已请求管理员权限，将在提权窗口中完成「启用 SNMP」。完成后回到本窗口点「刷新端口列表」查看结果。', '需要管理员')
        }
        else {
            [System.Windows.Forms.MessageBox]::Show('无法自动提权，请右键以管理员身份运行本程序后再操作。')
        }
        return
    }
    $r = Set-PortSnmpEnabled -PortName $pn -Enable $true
    $txtLogA.AppendText(('启用 ' + $pn + '：' + $r.Msg + "`r`n"))
    Refresh-PortsGrid
})
$btnDisableA.Add_Click({
    if ($dgvA.SelectedRows.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('请先在表格里选中一个端口'); return }
    $pn = $dgvA.SelectedRows[0].Cells[0].Value
    if (-not (Test-Admin)) {
        [System.Windows.Forms.MessageBox]::Show('关闭 SNMP 也需要管理员权限，请右键以管理员身份运行本程序。'); return
    }
    $r = Set-PortSnmpEnabled -PortName $pn -Enable $false
    $txtLogA.AppendText(('关闭 ' + $pn + '：' + $r.Msg + "`r`n"))
    Refresh-PortsGrid
})

# --- Tab B: IPP 哨兵 ---
$tabB = New-Object System.Windows.Forms.TabPage; $tabB.Text = '路线B：IPP 哨兵'
$tab.Controls.Add($tabB)

$lblB = New-Object System.Windows.Forms.Label
$lblB.Text = '轮询打印机的 IPP(631) 状态，缺纸/卡纸/缺墨等异常时弹通知。可常驻托盘 + 开机自启。'
$lblB.Location = New-Object System.Drawing.Point(12, 12); $lblB.Size = New-Object System.Drawing.Size(780, 28); $lblB.AutoSize = $false
$tabB.Controls.Add($lblB)

$dgvB = New-Object System.Windows.Forms.DataGridView
$dgvB.Location = New-Object System.Drawing.Point(12, 44); $dgvB.Size = New-Object System.Drawing.Size(780, 280)
$dgvB.AllowUserToAddRows = $false; $dgvB.AutoSizeColumnsMode = 'AllCells'
$dgvB.Columns.Add('Name', '名称') | Out-Null
$dgvB.Columns.Add('Ip', 'IP') | Out-Null
$dgvB.Columns.Add('Port', '端口') | Out-Null
$dgvB.Columns.Add('Path', '路径') | Out-Null
$dgvB.Columns.Add('Enabled', '监控') | Out-Null
$dgvB.Columns.Add('Last', '最近状态') | Out-Null
$tabB.Controls.Add($dgvB)

$btnAddB = New-Object System.Windows.Forms.Button
$btnAddB.Text = '添加当前网络打印机'; $btnAddB.Location = New-Object System.Drawing.Point(12, 332); $btnAddB.Size = New-Object System.Drawing.Size(160, 28)
$tabB.Controls.Add($btnAddB)

$btnDelB = New-Object System.Windows.Forms.Button
$btnDelB.Text = '删除选中'; $btnDelB.Location = New-Object System.Drawing.Point(182, 332); $btnDelB.Size = New-Object System.Drawing.Size(110, 28)
$tabB.Controls.Add($btnDelB)

$btnGuardB = New-Object System.Windows.Forms.Button
$btnGuardB.Text = '开始哨兵'; $btnGuardB.Location = New-Object System.Drawing.Point(302, 332); $btnGuardB.Size = New-Object System.Drawing.Size(110, 28)
$tabB.Controls.Add($btnGuardB)

$lblInterval = New-Object System.Windows.Forms.Label
$lblInterval.Text = '轮询间隔(秒):'; $lblInterval.Location = New-Object System.Drawing.Point(430, 338); $lblInterval.Size = New-Object System.Drawing.Size(90, 20)
$tabB.Controls.Add($lblInterval)

$numInterval = New-Object System.Windows.Forms.NumericUpDown
$numInterval.Minimum = 10; $numInterval.Maximum = 600; $numInterval.Value = $Cfg.IntervalSec
$numInterval.Location = New-Object System.Drawing.Point(520, 334); $numInterval.Size = New-Object System.Drawing.Size(70, 22)
$tabB.Controls.Add($numInterval)

$chkAutoB = New-Object System.Windows.Forms.CheckBox
$chkAutoB.Text = '开机自启'; $chkAutoB.Location = New-Object System.Drawing.Point(610, 336); $chkAutoB.AutoSize = $true
$chkAutoB.Checked = (Get-AutoStart)
$tabB.Controls.Add($chkAutoB)

$txtLogB = New-Object System.Windows.Forms.TextBox
$txtLogB.Multiline = $true; $txtLogB.ScrollBars = 'Vertical'; $txtLogB.ReadOnly = $true
$txtLogB.Location = New-Object System.Drawing.Point(12, 372); $txtLogB.Size = New-Object System.Drawing.Size(780, 140)
$tabB.Controls.Add($txtLogB)

function Refresh-TargetsGrid {
    $dgvB.Rows.Clear()
    foreach ($t in $Cfg.Targets) {
        $dgvB.Rows.Add($t.Name, $t.Ip, $t.Port, $t.Path, $(if ($t.Enabled) { '✔' } else { '—' }), $t.LastState) | Out-Null
    }
}

function Save-Targets {
    Write-Config $Cfg
    Refresh-TargetsGrid
}

$btnAddB.Add_Click({
    # 从本机已安装的网络打印机里挑出有 IP 的，自动补全
    $added = 0
    try {
        $printers = Get-Printer -ErrorAction SilentlyContinue
        $ports = Get-PrinterPort -ErrorAction SilentlyContinue
        foreach ($pr in $printers) {
            $port = $ports | Where-Object { $_.Name -eq $pr.PortName } | Select-Object -First 1
            $ip = $null
            if ($port -and $port.PrinterHostAddress) { $ip = $port.PrinterHostAddress }
            if (-not $ip -and $pr.PortName -match 'IP[_ ]([\d.]+)') { $ip = $Matches[1] }
            if (-not $ip) { continue }
            if ($Cfg.Targets | Where-Object { $_.Ip -eq $ip }) { continue }
            $Cfg.Targets += [pscustomobject]@{ Name = $pr.Name; Ip = $ip; Port = 631; Path = '/ipp/print'; Enabled = $true; LastState = ''; LastReasons = ''; Community = 'public' }
            $added++
        }
    }
    catch { $txtLogB.AppendText(('读取打印机失败: ' + $_.Exception.Message + "`r`n")) }
    Save-Targets
    $txtLogB.AppendText(('已添加 ' + $added + ' 台网络打印机到监控列表' + "`r`n"))
})

$btnDelB.Add_Click({
    if ($dgvB.SelectedRows.Count -eq 0) { return }
    $idx = $dgvB.SelectedRows[0].Index
    if ($idx -ge 0 -and $idx -lt $Cfg.Targets.Count) {
        $Cfg.Targets = @($Cfg.Targets | Where-Object { $_ -ne $Cfg.Targets[$idx] })
        Save-Targets
    }
})

$btnGuardB.Add_Click({
    if ($GuardRunning) { Stop-Sentinel; $btnGuardB.Text = '开始哨兵' }
    else { Start-Sentinel -FromUi $true; $btnGuardB.Text = '停止哨兵' }
    Save-Targets
})

$numInterval.Add_ValueChanged({ $Cfg.IntervalSec = [int]$numInterval.Value; Write-Config $Cfg })
$chkAutoB.Add_CheckedChanged({ Set-AutoStart -Enable $chkAutoB.Checked; $miAuto.Checked = $chkAutoB.Checked })

# 主窗体关闭 -> 最小化到托盘（不退出）
$MainForm.Add_FormClosing({
    if (-not $Global:ExitFlag) {
        $_.Cancel = $true
        $MainForm.Hide()
        $Global:NotifyIcon.ShowBalloonTip(3000, 'PrinterStatusGuard', '已最小化到托盘，哨兵仍在后台运行。', [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

function Show-MainForm {
    $MainForm.Show(); $MainForm.WindowState = 'Normal'; $MainForm.BringToFront()
}

# ===================== 启动 =====================
Refresh-PortsGrid
Refresh-TargetsGrid
$txtLogB.AppendText(('配置目录: ' + $ConfigDir + "`r`n"))

if ($Guard) {
    # 开机自启 / -Guard：隐藏主窗体，直接开始哨兵
    $MainForm.WindowState = 'Minimized'
    $MainForm.ShowInTaskbar = $false
    Start-Sentinel -FromUi $false
    $MainForm.Hide()
}
else {
    $MainForm.ShowInTaskbar = $true
    $MainForm.ShowDialog() | Out-Null
}
# 若不是 -Guard 且用户直接关窗（FormClosing 已拦截成最小化），这里进入消息循环
if (-not $Global:ExitFlag) {
    [System.Windows.Forms.Application]::Run()
}
