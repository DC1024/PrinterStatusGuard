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
    [string]$DisablePort,
    [switch]$EnableAutoStart,
    [switch]$DisableAutoStart
)

$ErrorActionPreference = 'Continue'
$ScriptVersion = '1.1.2'

# 取脚本目录（exe 形态下 ps2exe 不设置 $MyInvocation.MyCommand.Path，须从进程主模块取，否则会错用 CWD 导致自启注册指向错误路径）
function Get-ScriptDir {
    try {
        $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exePath -and ([IO.Path]::GetFileName($exePath) -like 'PrinterStatusGuard*') -and (Test-Path $exePath)) {
            return Split-Path $exePath -Parent
        }
    } catch { }
    if ($MyInvocation.MyCommand.Path) { return Split-Path $MyInvocation.MyCommand.Path -Parent }
    if ($PSScriptRoot) { return $PSScriptRoot }
    return (Get-Location).Path
}
$ScriptDir = Get-ScriptDir
# $ExeOrScript 用于开机自启/提权子进程指向自身：exe 形态必须取进程主模块（ps2exe 不设置 MyCommand.Path），
# 否则会错误回退到 ps1 路径，导致自启条目指向 powershell+ps1 而不是 exe（旧版自启失效的根因之一）。
$ExeOrScript = $null
try {
    $mmPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($mmPath -and ($mmPath -match '\.exe$') -and ([IO.Path]::GetFileName($mmPath) -like 'PrinterStatusGuard*') -and (Test-Path $mmPath)) {
        $ExeOrScript = $mmPath
    }
} catch { }
if (-not $ExeOrScript) { if ($MyInvocation.MyCommand.Path) { $ExeOrScript = $MyInvocation.MyCommand.Path } else { $ExeOrScript = $PSCommandPath } }
if (-not $ExeOrScript) { $ExeOrScript = Join-Path $ScriptDir 'PrinterStatusGuard.ps1' }

$ConfigDir = Join-Path $env:APPDATA 'PrinterStatusGuard'
$ConfigFile = Join-Path $ConfigDir 'config.json'
$LogDir = Join-Path $ConfigDir 'logs'

# ===================== 日志基础设施 =====================
# 内存环形缓冲 + 文件落盘；GUI「日志」页实时渲染（仅 UI 线程访问控件）。
# 日志用于让用户看到「软件与打印机之间真实交互了什么」——尤其是排查「卡纸没提示、只提示过热」这类问题。
$Global:LogEntries = New-Object System.Collections.ArrayList
$Global:LogMax = 3000
$Global:LogGrid = $null          # 由 GUI 在创建日志页时赋值
$Global:LogFilter = '全部'

function Write-Log {
    param([string]$Level = 'Info', [string]$Source = 'APP', [string]$Message)
    if ([string]::IsNullOrWhiteSpace($Level)) { $Level = 'Info' }
    if ([string]::IsNullOrWhiteSpace($Source)) { $Source = 'APP' }
    $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $entry = [ordered]@{ Time = $time; Level = $Level; Source = $Source; Message = $Message }
    try {
        [void]$Global:LogEntries.Add($entry)
        while ($Global:LogEntries.Count -gt $Global:LogMax) { $Global:LogEntries.RemoveAt(0) }
    } catch { }
    # 文件落盘（每天一个文件，UTF-8 无 BOM 追加）
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        $f = Join-Path $LogDir ('app-' + (Get-Date -Format 'yyyy-MM-dd') + '.log')
        $line = ('[{0}] [{1}] [{2}] {3}' -f $time, $Level.ToUpper(), $Source, $Message)
        [System.IO.File]::AppendAllText($f, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    # GUI 实时渲染（日志页已创建且控件未销毁时）
    try {
        if ($null -ne $Global:LogGrid -and $Global:LogGrid.IsDisposed -eq $false) {
            if ($Global:LogFilter -eq '全部' -or $Global:LogFilter -eq $Level) {
                $ri = $Global:LogGrid.Rows.Add($time, $Level, $Source, $Message)
                if ($Level -eq 'Error') { $Global:LogGrid.Rows[$ri].DefaultCellStyle.BackColor = [System.Drawing.Color]::MistyRose }
                elseif ($Level -eq 'Warning') { $Global:LogGrid.Rows[$ri].DefaultCellStyle.BackColor = [System.Drawing.Color]::LightYellow }
                # 防止长时间后台运行时网格行数无限增长
                if ($Global:LogGrid.Rows.Count -gt $Global:LogMax) { $Global:LogGrid.Rows.RemoveAt(0) }
            }
        }
    } catch { }
}

function Apply-LogFilter {
    if ($null -eq $Global:LogGrid) { return }
    try {
        $Global:LogGrid.Rows.Clear()
        foreach ($e in $Global:LogEntries) {
            if ($Global:LogFilter -eq '全部' -or $Global:LogFilter -eq $e.Level) {
                $ri = $Global:LogGrid.Rows.Add($e.Time, $e.Level, $e.Source, $e.Message)
                if ($e.Level -eq 'Error') { $Global:LogGrid.Rows[$ri].DefaultCellStyle.BackColor = [System.Drawing.Color]::MistyRose }
                elseif ($e.Level -eq 'Warning') { $Global:LogGrid.Rows[$ri].DefaultCellStyle.BackColor = [System.Drawing.Color]::LightYellow }
            }
        }
    } catch { }
}

function Clear-Log {
    try { $Global:LogEntries.Clear() } catch { }
    try { if ($null -ne $Global:LogGrid) { $Global:LogGrid.Rows.Clear() } } catch { }
    Write-Log -Level 'Info' -Source 'APP' -Message '日志已清空'
}

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

# IPP 友好原因 + SNMP 位域 -> 统一的问题清单与严重度。
# 关键点：卡纸在 RFC 2790 里没有专门位，通常落在 IPP printer-state-reasons(media-jam/paper-jam)，
# 或落在厂商自定义 SNMP 位（显示为 'bit X.Y'）。把两路合并，任何一路有异常都不再漏报。
function Merge-PrinterStatus {
    param([hashtable]$StateInfo, [array]$FriendlyReasons, [array]$SnmpBits)
    $issues = New-Object System.Collections.ArrayList
    $critCount = 0
    if ($FriendlyReasons) {
        foreach ($fr in $FriendlyReasons) {
            if ($fr.Sev -ne 'OK') {
                [void]$issues.Add($fr.Text)
                if ($fr.Sev -eq 'Critical') { $critCount++ }
            }
        }
    }
    if ($SnmpBits) {
        foreach ($b in $SnmpBits) {
            [void]$issues.Add($b)
            # 卡纸/缺纸/碳粉/墨水等关键语义位按 Critical 提升级别（含厂商自定义位）
            if ($b -match '卡纸|缺纸|碳粉|墨水|墨') { $critCount++ }
        }
    }
    $sev = 'OK'
    if ($issues.Count -gt 0) { $sev = if ($critCount -gt 0) { 'Critical' } else { 'Warning' } }
    return @{ Issues = $issues; Sev = $sev; Text = (($issues | Sort-Object) -join '、') }
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

# 把 hrPrinterDetectedErrorState 的 OCTET STRING 原始字节解码成人类可读位名。
# RFC 2790 没有卡纸位，厂商自定义位会显示为 'bit X.Y'（日志里能看到原始字节，便于后续映射）。
# 注意：单元素 byte[] 传给 [byte[]] 参数会被 PowerShell 拆成标量，必须先归一化为数组（否则单 bit 解码会失败）。
function ConvertFrom-SnmpErrorState($Raw) {
    $bits = New-Object System.Collections.ArrayList
    if ($null -eq $Raw) { return $bits }
    if ($Raw -isnot [System.Array]) { $Raw = @($Raw) }
    if ($Raw.Length -eq 0) { return $bits }
    for ($by = 0; $by -lt $Raw.Length; $by++) {
        for ($bit = 0; $bit -lt 8; $bit++) {
            if ((([int]$Raw[$by] -shr $bit) -band 1) -eq 1) {
                $key = "$by.$bit"; $nm = $SnmpErrorBits[$key]
                if ([string]::IsNullOrEmpty($nm)) { $nm = 'bit ' + $key }
                [void]$bits.Add($nm)
            }
        }
    }
    # 用 ,$bits 防止单元素数组在返回时被 PowerShell 拆成标量字符串（否则 $x[0] 会变成第一个字符）
    return , $bits
}

function Get-SnmpPrinterErrorState {
    param([string]$Ip, [string]$Community = 'public')
    $resp = Invoke-SnmpGet -Target $Ip -Community $Community -Oid '1.3.6.1.2.1.25.3.5.1.2.1' -TimeoutMs 2000
    if ($null -eq $resp) { return $null }
    $d = Decode-Snmp $resp
    if ($d.Type -eq 0x04 -and $null -ne $d.Raw -and $d.Raw.Length -gt 0) {
        return ConvertFrom-SnmpErrorState $d.Raw
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
    # 计划任务（v1.1.1 起的正牌方案）或旧版 HKCU Run 条目任一存在即视为已开启
    try {
        if (Get-ScheduledTask -TaskName 'PrinterStatusGuard' -ErrorAction SilentlyContinue) { return $true }
    } catch { }
    try {
        $k = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'PrinterStatusGuard' -ErrorAction SilentlyContinue
        if ($k -and $k.'PrinterStatusGuard') { return $true }
    } catch { }
    return $false
}

function Set-AutoStart {
    # 开机自启用「计划任务 + 最高权限 + 登录触发」实现：需要管理员（创建时 UAC 一次），
    # 之后每次登录静默自启、托盘常驻，不再依赖 HKCU Run（部分环境会被启动项禁用，且无法提权）。
    param([bool]$Enable)
    $rk = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $tn = 'PrinterStatusGuard'
    if ($Enable) {
        if (-not (Test-Admin)) {
            return @{ Ok = $false; Msg = '注册开机自启需要管理员权限（创建最高权限计划任务）。请允许 UAC 提权后重试。' }
        }
        $exe = $ExeOrScript
        try {
            if ($exe -match '\.ps1$') {
                $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Guard' -f $exe)
            }
            else {
                $action = New-ScheduledTaskAction -Execute $exe -Argument '-Guard'
            }
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
            Register-ScheduledTask -TaskName $tn -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force -ErrorAction Stop | Out-Null
        }
        catch {
            return @{ Ok = $false; Msg = ('创建开机自启计划任务失败: ' + $_.Exception.Message) }
        }
        # 清理旧版 Run 键，避免双重启动
        Remove-ItemProperty -Path $rk -Name $tn -ErrorAction SilentlyContinue
        return @{ Ok = $true; Msg = '开机自启已开启（计划任务，最高权限；下次登录自动在托盘运行哨兵）。' }
    }
    else {
        try { Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        Remove-ItemProperty -Path $rk -Name $tn -ErrorAction SilentlyContinue
        return @{ Ok = $true; Msg = '开机自启已关闭。' }
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
        IntervalSec     = 30
        Targets         = @()
        AutoUpdateCheck = $true
    }
}

function Write-Config($Cfg) {
    if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $Cfg | ConvertTo-Json -Depth 6 | Out-File $ConfigFile -Encoding UTF8
}

function Save-Log {
    param([string]$Msg)
    Write-Log -Level 'Info' -Source 'APP' -Message $Msg
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
# 通知防抖（迟滞）：异常立即上报（用户希望看到）；但「离线」与「已恢复」必须连续 3 次轮询稳定才上报，
# 避免打印机 IPP/SNMP 抖动（瞬时超时、单轮毛刺）造成「恢复」通知刷屏。
$script:PollState = $null

function Update-PollState($t, [string]$Category, $events, $stateInfo = $null, $merged = $null) {
    if (-not $script:PollState) { $script:PollState = @{} }
    $ps = $script:PollState[$t.Ip]
    if ($null -eq $ps) { $ps = @{ ReportedState = $null; RawCategory = ''; StableCount = 0 }; $script:PollState[$t.Ip] = $ps }
    if ($ps.RawCategory -eq $Category) { $ps.StableCount++ } else { $ps.RawCategory = $Category; $ps.StableCount = 1 }
    switch ($Category) {
        'offline' {
            # 连续 3 次无响应才报离线：扫描/打印时打印机常短暂不响应 IPP，属正常，不能当故障报警
            if ($ps.StableCount -ge 3 -and $ps.ReportedState -ne 'offline') {
                [void]$events.Add(@{ Target = $t; Title = ('【' + $t.Name + '】无响应'); Message = 'IPP 端口无响应，可能已关机或网络不通'; Icon = 'Error' })
                $ps.ReportedState = 'offline'
                Write-Log -Level 'Error' -Source 'ALERT' -Message ('[' + $t.Name + '] 离线/无响应（连续3次确认）')
            }
        }
        'anomaly' {
            # 异常立即上报（用户希望第一时间看到卡纸/过热等），但同一异常不重复刷屏（去重）
            if ($ps.ReportedState -ne 'anomaly') {
                $icon = if ($merged.Sev -eq 'Critical') { 'Error' } else { 'Warning' }
                [void]$events.Add(@{ Target = $t; Title = ('【' + $t.Name + '】' + $stateInfo.Text); Message = $merged.Text; Icon = $icon })
                $ps.ReportedState = 'anomaly'
                Write-Log -Level $icon -Source 'ALERT' -Message ('[' + $t.Name + '] ' + $stateInfo.Text + ' -> ' + $merged.Text)
            }
        }
        'ok' {
            # 仅当之前确实报过异常/离线，且连续 3 次稳定正常，才报「已恢复」（扫描结束后的短暂回 idle 不再刷屏）
            if ($ps.StableCount -ge 3 -and $ps.ReportedState -ne 'ok' -and $ps.ReportedState -ne $null) {
                [void]$events.Add(@{ Target = $t; Title = ('【' + $t.Name + '】已恢复'); Message = '状态恢复正常'; Icon = 'Info' })
                $ps.ReportedState = 'ok'
                Write-Log -Level 'Info' -Source 'ALERT' -Message ('[' + $t.Name + '] 状态恢复正常（连续3次确认）')
            }
        }
    }
}

function Invoke-SentinelPoll($Cfg) {
    $events = New-Object System.Collections.ArrayList
    if (-not $script:PollState) { $script:PollState = @{} }
    foreach ($t in $Cfg.Targets) {
        if (-not $t.Enabled) { continue }
        # ---- IPP 巡检 ----
        $attrs = Invoke-IppGetPrinterAttributes -Ip $t.Ip -Port $t.Port -Path $t.Path -Requested @('printer-state', 'printer-state-reasons', 'printer-is-accepting-jobs', 'marker-levels', 'printer-make-and-model')
        if ($null -eq $attrs) {
            # 重试一次（某些机型只认第一条 requested-attributes）
            $attrs = Invoke-IppGetPrinterAttributes -Ip $t.Ip -Port $t.Port -Path $t.Path -Requested @('printer-state-reasons')
        }
        if ($null -eq $attrs) {
            Write-Log -Level 'Error' -Source 'POLL' -Message ('IPP 无响应: ' + $t.Ip + ' (' + $t.Name + ')')
            $t.LastState = '离线/无响应'; $t.LastReasons = ''
            Update-PollState $t 'offline' $events
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

        # ---- SNMP 巡检（交叉确认，补 IPP 缺失的厂商位，如卡纸） ----
        $snmpBits = $null
        try {
            $snmpBits = Get-SnmpPrinterErrorState -Ip $t.Ip -Community $t.Community
        }
        catch { Write-Log -Level 'Warning' -Source 'POLL' -Message ('SNMP 查询异常 ' + $t.Ip + ': ' + $_.Exception.Message) }
        # 记录原始数据，便于排查「卡纸没提示、只提示过热」这类问题：用户可在「日志」页看到打印机到底发了什么
        Write-Log -Level 'Info' -Source 'POLL' -Message ('IPP 原始原因 [' + $t.Ip + ']: ' + $(if ($reasonsRaw) { $reasonsRaw } else { '(空/无)' }))
        Write-Log -Level 'Info' -Source 'POLL' -Message ('SNMP 位域 [' + $t.Ip + ']: ' + $(if ($snmpBits -and $snmpBits.Count -gt 0) { ($snmpBits -join ',') } else { '(无/未启用 SNMP)' }))

        # ---- 合并两路，判定类别 ----
        $merged = Merge-PrinterStatus -StateInfo $stateInfo -FriendlyReasons $friendly -SnmpBits $snmpBits
        $t.LastState = if ($merged.Issues.Count -gt 0) { $merged.Text } else { $stateInfo.Text }
        $t.LastReasons = (($reasons | Sort-Object) -join ',')
        $category = if ($merged.Sev -eq 'OK') { 'ok' } else { 'anomaly' }
        Update-PollState $t $category $events $stateInfo $merged
    }
    return $events
}

# ===================== 深度体检核心（原独立工具 WinPrintDiag 已并入） =====================
# 逻辑源自 https://github.com/DC1024/winprintdiag （v1.0），作为「深度体检」页签的后端。
# 只读扫描打印服务/崩溃历史/组件签名/打印机-驱动配对/队列/审计日志；-Repair / -ClearQueue 需管理员。
function Invoke-PrintSubsystemCheckup {
    param(
        [switch]$Repair,
        [switch]$ClearQueue,
        [string]$OutDir = ''
    )
$ToolVersion = '1.1 (merged)'
$StartTime = Get-Date

$Report = New-Object System.Collections.ArrayList
$Flags  = New-Object System.Collections.ArrayList

function Add-Line {
    param([AllowEmptyString()][string]$Text)
    [void]$Report.Add($Text)
}

function Add-Blank {
    [void]$Report.Add('')
}

function Add-Flag {
    param([string]$Level, [string]$Text)
    $tag = $Level
    switch ($Level) {
        'CRITICAL' { $tag = '严重' }
        'WARN' { $tag = '警告' }
        'INFO' { $tag = '提示' }
    }
    [void]$Flags.Add(('[' + $tag + '] ' + $Text))
}

function Get-DispWidth {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if (($code -ge 0x1100 -and $code -le 0x115F) -or
            ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE30 -and $code -le 0xFE6F) -or
            ($code -ge 0xFF00 -and $code -le 0xFF60) -or
            ($code -ge 0xFFE0 -and $code -le 0xFFE6)) { $w = $w + 2 }
        else { $w = $w + 1 }
    }
    return $w
}

function Pad-R {
    param([AllowEmptyString()][string]$Text, [int]$Width)
    $w = Get-DispWidth -Text $Text
    if ($w -ge $Width) { return $Text }
    return ($Text + (' ' * ($Width - $w)))
}

function Get-SigText {
    param([AllowEmptyString()][string]$Text)
    switch ($Text) {
        'Valid' { return '有效' }
        'NotSigned' { return '未签名' }
        'HashMismatch' { return '哈希不匹配' }
        'NotTrusted' { return '不受信任' }
        'UnknownError' { return '未知错误' }
        'NotSupportedFileFormat' { return '格式不支持' }
        'Incompatible' { return '不兼容' }
        'MISSING' { return '文件缺失' }
        'UNKNOWN' { return '无法判定' }
    }
    if ([string]::IsNullOrEmpty($Text)) { return '（空）' }
    return $Text
}

function Get-SvcText {
    param([AllowEmptyString()][string]$Text)
    switch ($Text) {
        'Running' { return '运行中' }
        'Stopped' { return '已停止' }
        'StartPending' { return '正在启动' }
        'StopPending' { return '正在停止' }
        'Paused' { return '已暂停' }
        'Automatic' { return '自动' }
        'Manual' { return '手动' }
        'Disabled' { return '已禁用' }
        'AutomaticDelayedStart' { return '自动（延迟启动）' }
    }
    return $Text
}

function Get-DateText {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd') }
    $s = [string]$Value
    if ($s -match '^\d{8}$') { return ($s.Substring(0, 4) + '-' + $s.Substring(4, 2) + '-' + $s.Substring(6, 2)) }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse($s, [ref]$dt)) { return $dt.ToString('yyyy-MM-dd') }
    return $s
}

function Get-ConnKind {
    param([AllowEmptyString()][string]$Port)
    if ([string]::IsNullOrEmpty($Port)) { return '未知' }
    if ($Port -match '^USB\d+$') { return 'USB 直连' }
    if ($Port -match '^WSD') { return '网络 WSD' }
    if ($Port -match '^IPP') { return '网络 IPP' }
    if ($Port -match '^IP_|^IP-') { return '网络 IP' }
    if ($Port -match '^TCP') { return '网络 TCP' }
    if ($Port -match '^PORTPROMPT|^\\\\|pipe|\.pdf$|^FILE:|^SHRFAX|^nul|virtual|pdf') { return '虚拟/本地' }
    return '其他'
}

# 从「打印机名 + 端口名」提取设备标识词，用来判断两条记录是不是同一台物理打印机。
# 只保留「长度 >= 5 且同时含字母和数字」的词：这类词通常是机型或主机名后缀（如 13cedd / m6200nw），
# 而 pdf / series / 0001 这种通用词或纯数字会被排除，避免把不同机型误判成同一台。
function Get-PrinterTokens {
    param([AllowEmptyString()][string]$Name, [AllowEmptyString()][string]$Port)
    $raw = ($Name + ' ' + $Port).ToLower()
    $parts = [regex]::Split($raw, '[^a-z0-9]+')
    $res = New-Object System.Collections.ArrayList
    foreach ($t in $parts) {
        if ($t.Length -lt 5) { continue }
        if ($t -notmatch '[a-z]') { continue }
        if ($t -notmatch '[0-9]') { continue }
        if (-not $res.Contains($t)) { [void]$res.Add($t) }
    }
    return $res
}

# 从打印操作日志（Microsoft-Windows-PrintService/Operational，事件 307 = 文档打印成功）
# 采集「哪个打印机条目真的被用过」。事件字段是固定位置的结构化数据：
#   Param5 = 打印机名，Param6 = 端口名 —— 不要去解析本地化的 Message 文案，那个随系统语言变。
# 返回 @{ Total=..; Matched=..; Error=$bool; Disabled=$bool; ByPort=@{}; ByName=@{} }
function Get-PrinterUsage {
    param([int]$MaxEvents = 500, [string[]]$KnownPorts = @(), [string[]]$KnownNames = @())
    $byPort = @{}
    $byName = @{}
    $stats = [ordered]@{
        Total    = 0
        Matched  = 0
        Error    = $false
        Disabled = $false
        ByPort   = $byPort
        ByName   = $byName
    }

    try {
        $lg = Get-WinEvent -ListLog 'Microsoft-Windows-PrintService/Operational' -ErrorAction Stop
        if (-not $lg.IsEnabled) {
            $stats.Disabled = $true
            return $stats
        }
    }
    catch {
        $stats.Error = $true
        return $stats
    }

    $events = @()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-PrintService/Operational'; Id = 307 } -MaxEvents $MaxEvents -ErrorAction Stop)
    }
    catch {
        # 日志开着但一条记录都没有时，Get-WinEvent 会抛 NoMatchingEventsFound，这不是错误
        if ([string]$_.FullyQualifiedErrorId -match 'NoMatchingEventsFound') { return $stats }
        $stats.Error = $true
        return $stats
    }

    $portKeys = @()
    foreach ($k in $KnownPorts) { $portKeys += ([string]$k).ToLower() }
    $nameKeys = @()
    foreach ($k in $KnownNames) { $nameKeys += ([string]$k).ToLower() }

    foreach ($e in $events) {
        $prn = ''
        $port = ''
        try {
            $x = [xml]$e.ToXml()
            $node = $x.SelectSingleNode("//*[local-name()='DocumentPrinted']")
            if ($null -eq $node) { continue }
            $n5 = $node.SelectSingleNode("*[local-name()='Param5']")
            $n6 = $node.SelectSingleNode("*[local-name()='Param6']")
            if ($null -ne $n5) { $prn = [string]$n5.InnerText }
            if ($null -ne $n6) { $port = [string]$n6.InnerText }
        }
        catch {
            continue
        }
        if ([string]::IsNullOrEmpty($port) -and [string]::IsNullOrEmpty($prn)) { continue }
        $stats.Total = $stats.Total + 1
        $t = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
        if ($portKeys -contains $port.ToLower()) { $stats.Matched = $stats.Matched + 1 }

        # 注意：值里不能用键名 Count —— Hashtable/OrderedDictionary 自带 Count 属性会覆盖它
        $pk = $port.ToLower()
        if (-not [string]::IsNullOrEmpty($pk)) {
            if ($byPort.ContainsKey($pk)) {
                $byPort[$pk].Times = $byPort[$pk].Times + 1
                if ($t -gt $byPort[$pk].Last) { $byPort[$pk].Last = $t }
            }
            else {
                $byPort[$pk] = [ordered]@{ Times = 1; Last = $t; Name = $prn }
            }
        }
        $nk = $prn.ToLower()
        if (-not [string]::IsNullOrEmpty($nk)) {
            if ($byName.ContainsKey($nk)) {
                $byName[$nk].Times = $byName[$nk].Times + 1
                if ($t -gt $byName[$nk].Last) { $byName[$nk].Last = $t }
            }
            else {
                $byName[$nk] = [ordered]@{ Times = 1; Last = $t; Port = $port }
            }
        }
    }
    return $stats
}

# 查某个打印机条目有没有使用记录：先按端口匹配（打印机被改名也不影响），匹配不到再退回按名字匹配
function Get-UsageOf {
    param($Usage, [AllowEmptyString()][string]$Name, [AllowEmptyString()][string]$Port)
    $none = [ordered]@{ Times = 0; Last = '' }
    if ($null -eq $Usage) { return $none }
    if (-not [string]::IsNullOrEmpty($Port)) {
        $k = $Port.ToLower()
        if ($Usage.ByPort.ContainsKey($k)) { return $Usage.ByPort[$k] }
    }
    if (-not [string]::IsNullOrEmpty($Name)) {
        $k2 = $Name.ToLower()
        if ($Usage.ByName.ContainsKey($k2)) { return $Usage.ByName[$k2] }
    }
    return $none
}

function Get-UsageText {
    param($U)
    if ($null -eq $U) { return '无使用记录' }
    if ($U.Times -le 0) { return '无使用记录' }
    return ('最近 ' + [string]$U.Last + '，共 ' + $U.Times + ' 次')
}

# 在两条重复条目里选一条建议保留。
# 判据优先级：① 只有一条有成功打印记录 -> 留它；② 两条都有 -> 留最近用过的那条（同时提示需人工确认）；
#             ③ 两条都没记录 -> 退化为按驱动判断，留装了厂商驱动的那条（通用 IPP 类驱动功能会缺）。
# 返回 @{ Keep='A'|'B'|''; KeepName; DropName; Reason; BothUsed }
function Get-DupVerdict {
    param(
        [AllowEmptyString()][string]$NameA = '',
        [int]$UseA = 0,
        [AllowEmptyString()][string]$LastA = '',
        [bool]$IppA = $false,
        [AllowEmptyString()][string]$NameB = '',
        [int]$UseB = 0,
        [AllowEmptyString()][string]$LastB = '',
        [bool]$IppB = $false
    )
    $keep = ''
    $reason = ''
    $both = $false

    if ($UseA -gt 0 -and $UseB -eq 0) {
        $keep = 'A'
        $reason = '有成功打印记录，而另一条从未被使用过'
    }
    elseif ($UseB -gt 0 -and $UseA -eq 0) {
        $keep = 'B'
        $reason = '有成功打印记录，而另一条从未被使用过'
    }
    elseif ($UseA -gt 0 -and $UseB -gt 0) {
        $both = $true
        if ($LastA -gt $LastB) { $keep = 'A' } else { $keep = 'B' }
        $reason = '两条都在用，只能按“最近用过”排序'
    }
    elseif ($IppA -ne $IppB) {
        if (-not $IppA) { $keep = 'A' } else { $keep = 'B' }
        $reason = '两条都没有打印记录，改按驱动判断：保留装了厂商驱动的条目'
    }
    else {
        $keep = ''
        $reason = '两条都没有打印记录、驱动类型也相同，无法判断该留哪条'
    }

    $keepName = ''
    $dropName = ''
    if ($keep -eq 'A') { $keepName = $NameA; $dropName = $NameB }
    if ($keep -eq 'B') { $keepName = $NameB; $dropName = $NameA }

    return [ordered]@{
        Keep     = $keep
        KeepName = $keepName
        DropName = $dropName
        Reason   = $reason
        BothUsed = $both
    }
}

# 把「该保留哪条」的使用证据与建议拼成多行文本。每行自带 7 个空格缩进，
# 追加到告警文字后面时，正好与 [标签] 之后的正文左对齐。
function Get-DupAdvice {
    param($A, $B, $Usage)
    $ind = '       '
    $ua = Get-UsageOf -Usage $Usage -Name ([string]$A.Name) -Port ([string]$A.Port)
    $ub = Get-UsageOf -Usage $Usage -Name ([string]$B.Name) -Port ([string]$B.Port)
    $lines = New-Object System.Collections.ArrayList

    if ($null -ne $Usage -and $Usage.Error) {
        [void]$lines.Add($ind + '使用记录: 打印操作日志不可读，无法据此判断该保留哪条')
        [void]$lines.Add($ind + '建议: 优先保留装了厂商驱动的那条（通用 IPP 类驱动功能会缺失）')
        return ("`n" + ($lines -join "`n"))
    }
    if ($null -ne $Usage -and $Usage.Disabled) {
        [void]$lines.Add($ind + '使用记录: 打印操作日志未启用，无法判断哪条在用')
        [void]$lines.Add($ind + '建议: 先开启打印操作日志（本工具加 -Repair 可开），用一段时间后再回来判断')
        return ("`n" + ($lines -join "`n"))
    }

    $w = 30
    foreach ($n in @([string]$A.Name, [string]$B.Name)) {
        $nw = Get-DispWidth -Text $n
        if ($nw -gt $w) { $w = $nw }
    }
    if ($w -gt 36) { $w = 36 }

    [void]$lines.Add($ind + '使用记录（打印操作日志事件 307）:')
    [void]$lines.Add($ind + '  ' + (Pad-R (Get-Trunc -Text ([string]$A.Name) -Width $w) $w) + ' ' + (Get-UsageText -U $ua))
    [void]$lines.Add($ind + '  ' + (Pad-R (Get-Trunc -Text ([string]$B.Name) -Width $w) $w) + ' ' + (Get-UsageText -U $ub))
    if ($null -ne $Usage -and $Usage.Total -le 0) {
        [void]$lines.Add($ind + '  （日志里没有任何历史打印记录）')
    }

    $v = Get-DupVerdict -NameA ([string]$A.Name) -UseA ([int]$ua.Times) -LastA ([string]$ua.Last) -IppA ([bool]$A.IsIpp) -NameB ([string]$B.Name) -UseB ([int]$ub.Times) -LastB ([string]$ub.Last) -IppB ([bool]$B.IsIpp)

    if ($v.Keep -eq '') {
        [void]$lines.Add($ind + '建议: ' + $v.Reason)
    }
    else {
        [void]$lines.Add($ind + '建议保留: 「' + $v.KeepName + '」')
        [void]$lines.Add($ind + '建议删除: 「' + $v.DropName + '」')
        [void]$lines.Add($ind + '依据: ' + $v.Reason)
        if ($v.BothUsed) {
            [void]$lines.Add($ind + '注意: 两条都有打印记录，删除前请确认另一条确实不再需要')
        }
        [void]$lines.Add($ind + '操作: 设置 → 蓝牙和其他设备 → 打印机和扫描仪 → 选中「' + $v.DropName + '」→ 删除设备')
    }
    return ("`n" + ($lines -join "`n"))
}

function Get-Trunc {
    param([AllowEmptyString()][string]$Text, [int]$Width)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Width -le 1) { return '' }
    if ((Get-DispWidth -Text $Text) -le $Width) { return $Text }
    $sb = New-Object System.Text.StringBuilder
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $cw = Get-DispWidth -Text ([string]$ch)
        if (($w + $cw) -gt ($Width - 1)) { break }
        [void]$sb.Append($ch)
        $w = $w + $cw
    }
    return ($sb.ToString() + '~')
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-UniStrings {
    param([string]$Path, [int]$MinLen = 3, [int]$MaxItems = 12)
    $res = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path)) { return $res }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $run = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt ($bytes.Length - 1)) {
        $lo = [int]$bytes[$i]
        $hi = [int]$bytes[$i + 1]
        if ($hi -eq 0 -and $lo -ge 32 -and $lo -lt 127) {
            [void]$run.Append([char]$lo)
        }
        else {
            if ($run.Length -ge $MinLen) {
                [void]$res.Add($run.ToString())
                if ($res.Count -ge $MaxItems) { break }
            }
            [void]$run.Clear()
        }
        $i = $i + 2
    }
    return $res
}

function Get-PrintBinaryRow {
    param([string]$Path)
    $row = [ordered]@{
        Name    = ''
        Size    = 0
        Version = ''
        MTime   = ''
        Sig     = 'MISSING'
        Note    = ''
    }
    $row.Name = Split-Path -Path $Path -Leaf
    if (-not (Test-Path -LiteralPath $Path)) { return $row }
    $fi = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $fi) { return $row }
    $row.Size = $fi.Length
    $row.Version = $fi.VersionInfo.ProductVersion
    $row.MTime = $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
    try {
        $sig = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
        $row.Sig = [string]$sig.Status
    }
    catch {
        $row.Sig = 'UNKNOWN'
    }
    return $row
}
$IsAdmin = Test-IsAdmin

$modeText = '仅诊断（只读）'
if ($Repair) { $modeText = '诊断 + 修复' }
Add-Line ('WinPrintDiag ' + $ToolVersion + '  生成时间 ' + $StartTime.ToString('yyyy-MM-dd HH:mm:ss'))
$adminText = '否'
if ($IsAdmin) { $adminText = '是' }
Add-Line ('管理员权限 : ' + $adminText)
Add-Line ('运行模式   : ' + $modeText)
Add-Blank

# ---------- 1. environment ----------
Add-Line '===== [1] 环境 ====='
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($os) {
    Add-Line ('操作系统   : ' + $os.Caption)
    Add-Line ('内部版本   : ' + $os.BuildNumber + ' / ' + $os.Version)
}
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
if ($cv) {
    Add-Line ('功能版本   : ' + $cv.DisplayVersion + '  UBR: ' + $cv.UBR)
    if ($cv.InstallDate) {
        $ins = [datetime]'1970-01-01'
        Add-Line ('系统安装日 : ' + $ins.AddSeconds($cv.InstallDate).ToLocalTime().ToString('yyyy-MM-dd'))
    }
}
Add-Line ('PowerShell : ' + $PSVersionTable.PSVersion.ToString())
Add-Line ('当前用户   : ' + [Security.Principal.WindowsIdentity]::GetCurrent().Name)
Add-Blank

# ---------- 2. print spooler service ----------
Add-Line '===== [2] 打印服务状态 ====='
$svc = Get-Service Spooler -ErrorAction SilentlyContinue
if ($svc) {
    Add-Line ('服务状态   : ' + (Get-SvcText -Text ([string]$svc.Status)) + '     启动类型: ' + (Get-SvcText -Text ([string]$svc.StartType)))
}
else {
    Add-Line '服务状态   : 未找到该服务'
    Add-Flag 'CRITICAL' '未找到 Print Spooler 服务（系统打印子系统可能已损坏）'
}
$procList = @(Get-Process spoolsv -ErrorAction SilentlyContinue)
if ($procList.Count -eq 0) {
    Add-Line '进程状态   : 未运行'
}
else {
    Add-Line ('进程状态   : 运行中，实例数 ' + $procList.Count)
    $procStartTime = $null
    try {
        $procStartTime = $procList[0].StartTime
    }
    catch {
        $procStartTime = $null
    }
    if ($null -ne $procStartTime) {
        $uptimeSec = [int]((Get-Date) - $procStartTime).TotalSeconds
        Add-Line ('启动时间   : ' + $procStartTime.ToString('yyyy-MM-dd HH:mm:ss') + '  (已运行 ' + $uptimeSec + ' 秒)')
        if ($uptimeSec -lt 300) {
            Add-Flag 'WARN' ('spoolsv 仅运行 ' + $uptimeSec + ' 秒，疑似刚重启或处于崩溃循环')
        }
    }
    else {
        Add-Line '启动时间   : （受保护进程，改查事件日志）'
        $lastStartTime = $null
        try {
            $stateEv = @(Get-WinEvent -FilterHashtable @{LogName = 'System'; Id = 7036; StartTime = (Get-Date).AddDays(-2)} -ErrorAction SilentlyContinue |
                Where-Object { $_.Message -match 'Print Spooler|Spooler' })
            if ($stateEv.Count -gt 0) {
                $lastStartTime = ($stateEv | Sort-Object TimeCreated | Select-Object -Last 1).TimeCreated
            }
        }
        catch {
            $lastStartTime = $null
        }
        if ($null -ne $lastStartTime) {
            $uptimeSec2 = [int]((Get-Date) - $lastStartTime).TotalSeconds
            Add-Line ('最近状态   : ' + $lastStartTime.ToString('yyyy-MM-dd HH:mm:ss') + '  (约已运行 ' + $uptimeSec2 + ' 秒)')
            if ($uptimeSec2 -lt 300) {
                Add-Flag 'WARN' ('spoolsv 仅运行约 ' + $uptimeSec2 + ' 秒，疑似刚重启或处于崩溃循环')
            }
        }
        else {
            Add-Line '最近状态   : 不可用（本机不记录服务启停事件）'
            Add-Line '            崩溃循环判定改由“近期崩溃次数”承担'
        }
    }
}
Add-Blank

# ---------- 3. crash history ----------
Add-Line '===== [3] 崩溃历史 ====='
$crashEvents = $null
try {
    $crashEvents = @(Get-WinEvent -FilterHashtable @{LogName = 'Application'; Id = 1000} -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'spoolsv' })
}
catch {
    $crashEvents = @()
}
Add-Line ('spoolsv 崩溃事件（应用程序日志 1000）: ' + $crashEvents.Count)
if ($crashEvents.Count -gt 0) {
    $sorted = $crashEvents | Sort-Object TimeCreated
    Add-Line ('最早       : ' + $sorted[0].TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))
    Add-Line ('最近       : ' + $sorted[$sorted.Count - 1].TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))
    Add-Line '-- 按日统计（最近 14 天）--'
    $grouped = $crashEvents | ForEach-Object { $_.TimeCreated.ToString('yyyy-MM-dd') } | Group-Object | Sort-Object Name -Descending | Select-Object -First 14
    foreach ($g in $grouped) { Add-Line ('  ' + $g.Name + '  x' + $g.Count) }
    Add-Line '-- 出错模块统计 --'
    $mods = @{}
    foreach ($e in $crashEvents) {
        $match = [regex]::Match($e.Message, '(?m)^出错模块名称[:：]\s*([^,，]+)')
        if ($match.Success) {
            $mod = $match.Groups[1].Value.Trim()
            if ($mods.ContainsKey($mod)) { $mods[$mod] = $mods[$mod] + 1 }
            else { $mods[$mod] = 1 }
        }
    }
    foreach ($k in $mods.Keys) { Add-Line ('  ' + $k + '  x' + $mods[$k]) }
    $recentCut = (Get-Date).AddMinutes(-30)
    $recent = @($crashEvents | Where-Object { $_.TimeCreated -gt $recentCut })
    Add-Line ('近 30 分钟崩溃次数: ' + $recent.Count)
    if ($recent.Count -ge 3) { Add-Flag 'CRITICAL' '近 30 分钟内崩溃 3 次以上，处于崩溃循环' }
}
Add-Blank

# ---------- 4. service control manager events ----------
Add-Line '===== [4] 服务控制管理器事件 ====='
try {
    $scm = @(Get-WinEvent -FilterHashtable @{LogName = 'System'; ProviderName = 'Service Control Manager'} -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'Spooler' -and ($_.Id -eq 7031 -or $_.Id -eq 7034) })
}
catch {
    $scm = @()
}
Add-Line ('Spooler 服务异常终止事件（7031/7034）: ' + $scm.Count)
if ($scm.Count -gt 0) {
    $scmSorted = $scm | Sort-Object TimeCreated
    Add-Line ('最早       : ' + $scmSorted[0].TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))
    Add-Line ('最近       : ' + $scmSorted[$scmSorted.Count - 1].TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))
}
Add-Line '-- 日志可视窗口（决定证据能回溯多远）--'
foreach ($lg in @('Application', 'System')) {
    try {
        $info = Get-WinEvent -ListLog $lg -ErrorAction Stop
        $old = Get-WinEvent -LogName $lg -MaxEvents 1 -Oldest -ErrorAction SilentlyContinue
        $lgName = '应用程序'
        if ($lg -eq 'System') { $lgName = '系统' }
        Add-Line ('  ' + $lgName + ': 最早=' + $old.TimeCreated.ToString('yyyy-MM-dd') + '  容量=' + [int]($info.FileSize / 1MB) + 'MB/' + [int]($info.MaximumSizeInBytes / 1MB) + 'MB')
    }
    catch {
        Add-Line ('  ' + $lg + ': 不可用')
    }
}
Add-Blank

# ---------- 5. print stack file integrity ----------
Add-Line '===== [5] 打印组件文件完好性 ====='
$coreFiles = @(
    'C:\Windows\System32\spoolsv.exe',
    'C:\Windows\System32\usbmon.dll',
    'C:\Windows\System32\localspl.dll',
    'C:\Windows\System32\win32spl.dll',
    'C:\Windows\System32\winspool.drv',
    'C:\Windows\System32\spoolss.dll',
    'C:\Windows\System32\tcpmon.dll',
    'C:\Windows\System32\spool\prtprocs\x64\winprint.dll'
)
Add-Line ((Pad-R '文件' 18) + (Pad-R '大小' 10) + (Pad-R '版本' 19) + (Pad-R '修改时间' 18) + '签名')
$suspectFiles = New-Object System.Collections.ArrayList
foreach ($f in $coreFiles) {
    $row = Get-PrintBinaryRow -Path $f
    Add-Line ((Pad-R ([string]$row.Name) 18) + (Pad-R ([string]$row.Size) 10) + (Pad-R ([string]$row.Version) 19) + (Pad-R ([string]$row.MTime) 18) + (Get-SigText -Text ([string]$row.Sig)))
    if ($row.Sig -ne 'Valid') {
        [void]$suspectFiles.Add($f)
        Add-Flag 'CRITICAL' ('系统打印组件签名异常: ' + $row.Name + ' -> ' + $row.Sig)
    }
}
Add-Blank

Add-Line '-- 组件存储里的 spoolsv.exe 候选 --'
$sxscandidates = @()
try {
    $sxscandidates = @(Get-ChildItem 'C:\Windows\WinSxS' -Directory -Filter '*printing-spooler-core*' -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'spoolsv.exe') })
}
catch {
    $sxscandidates = @()
}
$targetSpool = 'C:\Windows\System32\spoolsv.exe'
$suspectSpoolsv = (Test-Path -LiteralPath $targetSpool) -and ((Get-AuthenticodeSignature -FilePath $targetSpool -ErrorAction SilentlyContinue).Status -ne 'Valid')
if ($suspectSpoolsv) {
    foreach ($d in $sxscandidates) {
        $sf = Join-Path $d.FullName 'spoolsv.exe'
        $fi = Get-Item -LiteralPath $sf -ErrorAction SilentlyContinue
        $sig = Get-AuthenticodeSignature -FilePath $sf -ErrorAction SilentlyContinue
        Add-Line ('  ' + $d.Name)
        Add-Line ('      体积=' + $fi.Length + '  版本=' + $fi.VersionInfo.ProductVersion + '  签名=' + (Get-SigText -Text ([string]$sig.Status)))
    }
    $cur = Get-Item -LiteralPath $targetSpool -ErrorAction SilentlyContinue
    Add-Line ('  当前磁盘文件: 体积=' + $cur.Length + '  版本=' + $cur.VersionInfo.ProductVersion + '  修改时间=' + $cur.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
    Add-Flag 'CRITICAL' 'System32\spoolsv.exe 与组件存储不一致（可能被第三方替换）'
}
else {
    Add-Line '  （spoolsv.exe 签名有效，无需比对）'
}
Add-Blank

# ---------- 6. printers and ports (registry, works while spooler is down) ----------
Add-Line '===== [6] 打印机 / 端口 / 驱动配对 ====='
$printerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers'
$printers = @()
try {
    $printers = @(Get-ChildItem $printerKey -ErrorAction Stop)
}
catch {
    Add-Line '无法读取打印机注册表项'
}
if ($printers.Count -eq 0) {
    Add-Line '未配置任何打印机'
}
else {
    $prnList = New-Object System.Collections.ArrayList
    foreach ($p in $printers) {
        $port = [string]$p.GetValue('Port')
        $drv = [string]$p.GetValue('Printer Driver')
        $o = [ordered]@{
            Name  = [string]$p.PSChildName
            Port  = $port
            Drv   = $drv
            Conn  = (Get-ConnKind -Port $port)
            Tok   = @(Get-PrinterTokens -Name ([string]$p.PSChildName) -Port $port)
            IsIpp = ($drv -match 'IPP Class Driver|Mopria')
        }
        [void]$prnList.Add($o)
    }

    Add-Line ((Pad-R '打印机' 40) + (Pad-R '端口' 28) + ' ' + (Pad-R '连接方式' 12) + '驱动')
    foreach ($o in $prnList) {
        Add-Line ((Pad-R (Get-Trunc -Text $o.Name -Width 40) 40) + (Pad-R (Get-Trunc -Text $o.Port -Width 28) 28) + ' ' + (Pad-R ([string]$o.Conn) 12) + ([string]$o.Drv))
    }

    # -- 同一台物理打印机是否被注册成了多个条目 --
    $dupPairs = New-Object System.Collections.ArrayList
    $dupNames = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $prnList.Count; $i++) {
        for ($j = $i + 1; $j -lt $prnList.Count; $j++) {
            $a = $prnList[$i]
            $b = $prnList[$j]
            $shared = @($a.Tok | Where-Object { $b.Tok -contains $_ })
            if ($shared.Count -eq 0) { continue }
            [void]$dupPairs.Add([ordered]@{ A = $a; B = $b; Shared = $shared })
            if (-not $dupNames.Contains([string]$a.Name)) { [void]$dupNames.Add([string]$a.Name) }
            if (-not $dupNames.Contains([string]$b.Name)) { [void]$dupNames.Add([string]$b.Name) }
        }
    }

    # 只有确实存在重复条目时才去读打印操作日志（没有重复就不花这个时间）
    $usage = $null
    if ($dupPairs.Count -gt 0) {
        $kPorts = @()
        $kNames = @()
        foreach ($o in $prnList) {
            $kPorts += [string]$o.Port
            $kNames += [string]$o.Name
        }
        $usage = Get-PrinterUsage -MaxEvents 500 -KnownPorts $kPorts -KnownNames $kNames
    }

    foreach ($pair in $dupPairs) {
        $a = $pair.A
        $b = $pair.B
        $shared = $pair.Shared
        $usbCombo = (($a.Conn -match '^USB') -xor ($b.Conn -match '^USB'))
        $msg = '同一台打印机注册了多个条目: ' + $a.Name + ' [' + $a.Conn + '] 与 ' + $b.Name + ' [' + $b.Conn + ']  (共有标识: ' + ($shared -join '/') + ')'
        if ($usbCombo) {
            $msg = $msg + ' —— 同一台机器同时保留 USB 直连与网络两条通道，是最容易触发 spoolsv 崩溃的组合'
        }
        $msg = $msg + (Get-DupAdvice -A $a -B $b -Usage $usage)
        if ($usbCombo) {
            Add-Flag 'CRITICAL' $msg
        }
        else {
            Add-Flag 'WARN' $msg
        }
    }

    # -- USB 端口却挂在 IPP/Mopria 类驱动上 --
    foreach ($o in $prnList) {
        if (($o.Port -match '^USB\d+$') -and ($o.Drv -match 'IPP|Mopria|Class Driver')) {
            Add-Flag 'CRITICAL' ('端口/驱动错配: ' + $o.Name + '  (' + $o.Port + ' + ' + $o.Drv + ')')
        }
    }

    # -- 单独使用通用 IPP 类驱动（无厂商适配）；已被"重复条目"覆盖的不再重复报 --
    foreach ($o in $prnList) {
        if (-not $o.IsIpp) { continue }
        if ($dupNames.Contains([string]$o.Name)) { continue }
        Add-Flag 'INFO' ('使用通用 IPP 类驱动（无厂商适配）: ' + $o.Name + '  (' + $o.Drv + '，' + $o.Conn + ')')
    }
}
Add-Line '-- USB 监视器端口 --'
try {
    $usbPorts = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\USB Monitor\Ports' -ErrorAction Stop)
    if ($usbPorts.Count -eq 0) { Add-Line '  （无）' }
    foreach ($u in $usbPorts) {
        $pn = [string]$u.PSChildName
        $owner = ''
        if ($null -ne $prnList) {
            foreach ($o in $prnList) {
                if ([string]$o.Port -eq $pn) { $owner = [string]$o.Name; break }
            }
        }
        if ([string]::IsNullOrEmpty($owner)) {
            # 这类“孤儿端口”本身无害：端口定义还留在注册表里，但没有任何打印机指向它。
            # 用户看到 USB001 很容易误以为 USB 通道仍在工作（甚至去拔线缆），所以这里必须写明。
            Add-Line ('  ' + $pn + '  （无打印机使用；只是残留的端口定义，拔插线缆不会改变它，也不影响打印）')
        }
        else {
            Add-Line ('  ' + $pn + '  <- 正在被「' + $owner + '」使用')
        }
    }
}
catch {
    Add-Line '  （无法读取）'
}
Add-Blank

# ---------- 7. print queue ----------
Add-Line '===== [7] 打印队列 ====='
$queueDir = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'
$qFiles = @()
try {
    $qFiles = @(Get-ChildItem -LiteralPath $queueDir -File -ErrorAction Stop)
}
catch {
    $qFiles = @()
}
Add-Line ('队列文件数 : ' + $qFiles.Count)
if ($qFiles.Count -gt 0) {
    $total = ($qFiles | Measure-Object Length -Sum).Sum
    Add-Line ('合计体积   : ' + [int]($total / 1MB) + ' MB')
    $newest = $qFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $oldest = $qFiles | Sort-Object LastWriteTime | Select-Object -First 1
    Add-Line ('最新任务   : ' + $newest.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
    Add-Line ('最早任务   : ' + $oldest.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
    Add-Flag 'WARN' ('打印队列里有 ' + $qFiles.Count + ' 个未完成任务')
    Add-Line '-- 解码队列任务描述（前 6 个）--'
    $shdFiles = @($qFiles | Where-Object { $_.Extension -eq '.SHD' } | Sort-Object Name | Select-Object -First 6)
    foreach ($s in $shdFiles) {
        $strings = Get-UniStrings -Path $s.FullName
        Add-Line ('  ' + $s.Name + ' : ' + (($strings | Select-Object -First 8) -join ' ~ '))
    }
}
else {
    Add-Line '队列为空（没有打印任务时即为正常）'
}
Add-Blank

# ---------- 8. change correlation ----------
Add-Line '===== [8] 变更相关性 ====='
Add-Line '-- 近期安装的补丁（45 天内）--'
try {
    $hot = @(Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 10)
    foreach ($h in $hot) {
        Add-Line ('  ' + (Get-DateText -Value $h.InstalledOn) + '  ' + $h.HotFixID)
    }
}
catch {
    Add-Line '  （无法读取更新历史）'
}
Add-Line '-- 近期安装的软件（45 天内）--'
$thr = (Get-Date).AddDays(-45).ToString('yyyyMMdd')
$uninPaths = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
$apps = @()
foreach ($up in $uninPaths) {
    $apps += @(Get-ItemProperty $up -ErrorAction SilentlyContinue | Where-Object { $_.InstallDate -and ($_.InstallDate -ge $thr) -and $_.DisplayName })
}
foreach ($a in ($apps | Sort-Object InstallDate -Descending | Select-Object -First 10)) {
    Add-Line ('  ' + (Get-DateText -Value $a.InstallDate) + '  ' + $a.DisplayName)
}
if ($apps.Count -eq 0) { Add-Line '  （无）' }
Add-Line '-- 意外关机 / 重启（30 天内）--'
try {
    $bad = @(Get-WinEvent -FilterHashtable @{LogName = 'System'; Id = 6008; StartTime = (Get-Date).AddDays(-30)} -ErrorAction SilentlyContinue)
    Add-Line ('  事件 6008 意外关机次数: ' + $bad.Count)
    foreach ($b in ($bad | Select-Object -First 5)) { Add-Line ('    ' + $b.TimeCreated.ToString('yyyy-MM-dd HH:mm')) }
    $boot = @(Get-WinEvent -FilterHashtable @{LogName = 'System'; Id = 6005; StartTime = (Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue)
    Add-Line ('  近 7 天开机次数: ' + $boot.Count)
    if ($boot.Count -ge 15) { Add-Flag 'WARN' '近 7 天开机次数过多，系统可能反复重启' }
}
catch {
    Add-Line '  （无法读取）'
}
$mdCount = 0
if (Test-Path 'C:\Windows\Minidump') {
    $mdCount = @(Get-ChildItem 'C:\Windows\Minidump' -File -ErrorAction SilentlyContinue).Count
}
Add-Line ('  蓝屏转储文件: ' + $mdCount)
Add-Blank

# ---------- 9. audit log status ----------
Add-Line '===== [9] 打印审计日志 ====='
try {
    $opLog = Get-WinEvent -ListLog 'Microsoft-Windows-PrintService/Operational' -ErrorAction Stop
    $opText = '否'
    if ($opLog.IsEnabled) { $opText = '是' }
    Add-Line ('打印操作日志（PrintService/Operational）已启用: ' + $opText)
    if (-not $opLog.IsEnabled) {
        Add-Flag 'INFO' '打印操作日志未开启，发生问题时无法回溯“谁在何时打印了什么”'
    }
}
catch {
    Add-Line '无法查询打印操作日志状态'
}
Add-Blank

# ---------- 10. verdict ----------
Add-Line '===== [10] 结论与建议 ====='
if ($Flags.Count -eq 0) {
    Add-Line '未发现明显异常。'
}
else {
    Add-Line '发现以下问题:'
    foreach ($f in $Flags) { Add-Line ('  ' + $f) }
}
Add-Blank
Add-Line '建议动作:'
Add-Line '  1. 若存在“端口/驱动错配”，删除该打印机并改用官方驱动重建（不要让它落在 IPP 类驱动上）'
Add-Line '  2. 若存在“同一台打印机注册了多个条目”，打开 设置 → 蓝牙和其他设备 → 打印机和扫描仪，'
Add-Line '     把多余的那条删掉，同一台机器只留一条通道（USB 直连 或 网络，二选一）'
Add-Line '     具体该保留、该删除哪一条，见上方该条告警里的“建议保留 / 建议删除”'
Add-Line '     注意: 这些条目是系统里的登记项，不是线缆状态。拔掉 USB 线缆不会让告警消失，'
Add-Line '           必须到上面那个设置页面把多余条目删掉；若两条都是网络通道，则与 USB 完全无关'
Add-Line '  3. 若存在“组件签名异常”，以管理员身份加 -Repair 运行本工具，会从组件存储还原并隔离外来文件'
Add-Line '  4. 若队列堆积，加 -ClearQueue 运行（会先备份到带时间戳的目录，不做删除）'
Add-Line '  5. 开启打印操作日志以便日后审计'
Add-Blank

# ---------- 11. repair (admin + explicit switch) ----------
if ($Repair -or $ClearQueue) {
    Add-Line '===== [11] 修复动作 ====='
    if (-not $IsAdmin) {
        Add-Line '已跳过：需要以管理员身份运行才会执行修复。'
    }
    else {
        if ($ClearQueue -and $qFiles.Count -gt 0) {
            $bkRoot = Join-Path (Split-Path -Parent $queueDir) ('PRINTERS_backup_' + (Get-Date).ToString('yyyyMMdd_HHmmss'))
            New-Item -ItemType Directory -Path $bkRoot -Force | Out-Null
            $moved = 0
            foreach ($qf in $qFiles) {
                try {
                    Move-Item -LiteralPath $qf.FullName -Destination $bkRoot -Force -ErrorAction Stop
                    $moved = $moved + 1
                }
                catch {
                    Add-Line ('  移动失败: ' + $qf.Name)
                }
            }
            Add-Line ('  队列文件已备份到: ' + $moved + ' -> ' + $bkRoot)
        }

        if ($Repair) {
            try {
                $lgBefore = Get-WinEvent -ListLog 'Microsoft-Windows-PrintService/Operational' -ErrorAction Stop
                if (-not $lgBefore.IsEnabled) {
                    & wevtutil sl 'Microsoft-Windows-PrintService/Operational' /e:true 2>&1 | Out-Null
                    Add-Line '  打印操作日志已开启'
                }
            }
            catch {
                Add-Line '  开启打印操作日志失败'
            }

            foreach ($sf in $suspectFiles) {
                $leaf = Split-Path -Path $sf -Leaf
                Add-Line ('  正在从组件存储还原: ' + $leaf)
                $candidates = @(Get-ChildItem 'C:\Windows\WinSxS' -Directory -ErrorAction SilentlyContinue |
                    Where-Object { (Test-Path (Join-Path $_.FullName $leaf)) -and ($_.Name -match 'printing') })
                if ($candidates.Count -eq 0) {
                    Add-Line '    组件存储中未找到可用源文件，已跳过'
                    continue
                }
                $src = Join-Path ($candidates | Sort-Object Name | Select-Object -Last 1).FullName $leaf
                & net stop spooler 2>&1 | Out-Null
                Start-Sleep -Seconds 3
                & takeown /F $sf /A 2>&1 | Out-Null
                & icacls $sf /grant 'Administrators:F' /C 2>&1 | Out-Null
                $qDir = Join-Path $OutDir ('quarantine_' + (Get-Date).ToString('yyyyMMdd_HHmmss'))
                New-Item -ItemType Directory -Path $qDir -Force | Out-Null
                $aside = Join-Path $qDir ($leaf + '.foreign')
                $ok = $false
                try {
                    Move-Item -LiteralPath $sf -Destination $aside -Force -ErrorAction Stop
                    $ok = $true
                }
                catch {
                    Add-Line ('    移动失败: ' + $_.Exception.Message)
                }
                if ($ok) {
                    Copy-Item -LiteralPath $src -Destination $sf -Force -ErrorAction SilentlyContinue
                    $s2 = Get-AuthenticodeSignature -FilePath $sf -ErrorAction SilentlyContinue
                    Add-Line ('    已还原，当前签名: ' + (Get-SigText -Text ([string]$s2.Status)))
                    Add-Line ('    原文件已保留在: ' + $aside)
                }
                & net start spooler 2>&1 | Out-Null
                Start-Sleep -Seconds 4
                $after = Get-Service Spooler -ErrorAction SilentlyContinue
                Add-Line ('    服务状态: ' + (Get-SvcText -Text ([string]$after.Status)))
            }
        }
    }
    Add-Blank
}

    # ---------- 写报告并返回（原版直接落盘，这里返回给 GUI 使用） ----------
    if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = (Join-Path $LogDir 'checkup') }
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $stamp = $StartTime.ToString('yyyyMMdd_HHmmss')
    $reportPath = Join-Path $OutDir ('PrinterCheckup_' + $stamp + '.txt')
    [System.IO.File]::WriteAllLines($reportPath, $Report, (New-Object System.Text.UTF8Encoding($true)))
    return [pscustomobject]@{
        ReportPath = $reportPath
        ReportText = (($Report -join "`r`n") + "`r`n")
        FlagCount  = $Flags.Count
        Flags      = @($Flags)
    }
}

# ===================== 检查更新（GitHub Releases API） =====================
function Get-LatestRelease {
    # 查询最新 Release；普通用户权限即可，无需提权。纯 .NET HttpWebRequest，无外部依赖。
    try {
        $req = [System.Net.HttpWebRequest]::Create('https://api.github.com/repos/DC1024/PrinterStatusGuard/releases/latest')
        $req.UserAgent = 'PrinterStatusGuard'
        $req.Timeout = 8000
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $json = $sr.ReadToEnd() | ConvertFrom-Json
        $sr.Close(); $resp.Close()
        $exeAsset = $json.assets | Where-Object { $_.name -eq 'PrinterStatusGuard.exe' } | Select-Object -First 1
        return @{ Ok = $true; Tag = [string]$json.tag_name; Url = [string]$json.html_url; Dl = $(if ($exeAsset) { [string]$exeAsset.browser_download_url } else { [string]$json.html_url }) }
    }
    catch { return @{ Ok = $false; Msg = $_.Exception.Message } }
}

function Test-NewerVersion {
    # 语义化比较：tag 形如 v1.2.3 / 当前 $ScriptVersion 形如 1.2.3
    param([string]$Tag, [string]$Current)
    try {
        $a = (($Tag -replace '^v', '') -split '\.') | ForEach-Object { [int]$_ }
        $b = ($Current -split '\.') | ForEach-Object { [int]$_ }
        for ($i = 0; $i -lt [Math]::Max($a.Count, $b.Count); $i++) {
            $x = if ($i -lt $a.Count) { $a[$i] } else { 0 }
            $y = if ($i -lt $b.Count) { $b[$i] } else { 0 }
            if ($x -gt $y) { return $true }
            if ($x -lt $y) { return $false }
        }
        return $false
    }
    catch { return $false }
}

function Invoke-UpdateCheck {
    # $Silent=$true 用于启动后的静默巡检：失败不弹窗，只在发现新版本时弹托盘气泡。
    param([bool]$Silent = $false)
    $r = Get-LatestRelease
    if (-not $r.Ok) {
        Write-Log -Level 'Warning' -Source 'UPDATE' -Message ('检查更新失败: ' + $r.Msg)
        if (-not $Silent) { [System.Windows.Forms.MessageBox]::Show('检查更新失败：' + $r.Msg, 'PrinterStatusGuard', 'OK', 'Warning') | Out-Null }
        return
    }
    Write-Log -Level 'Info' -Source 'UPDATE' -Message ('当前 v' + $ScriptVersion + '，最新 ' + $r.Tag)
    if (Test-NewerVersion -Tag $r.Tag -Current $ScriptVersion) {
        if ($Silent) {
            if ($Global:NotifyIcon) {
                $Global:NotifyIcon.ShowBalloonTip(5000, 'PrinterStatusGuard', ('发现新版本 ' + $r.Tag + '（当前 v' + $ScriptVersion + '）。右键托盘 →「检查更新」可打开下载页。'), [System.Windows.Forms.ToolTipIcon]::Info)
            }
            return
        }
        $msg = '发现新版本 {0}（当前 v{1}）。{2}是否打开下载页面？' -f $r.Tag, $ScriptVersion, [Environment]::NewLine
        if ([System.Windows.Forms.MessageBox]::Show($msg, 'PrinterStatusGuard 更新', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information) -eq [System.Windows.Forms.DialogResult]::Yes) {
            try { Start-Process $r.Url } catch { }
        }
    }
    else {
        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show('已是最新版本（v' + $ScriptVersion + '）。', 'PrinterStatusGuard', 'OK', 'Information') | Out-Null
        }
    }
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
    # 4b) SNMP hrPrinterDetectedErrorState(OCTET STRING) 解码 + 位域映射
    $oidH = Tlv 0x06 (Get-IppOidBytes '1.3.6.1.2.1.25.3.5.1.2.1')
    $valH = Tlv 0x04 @([byte]0x04)          # OCTET STRING，内容 0x04 -> bit 0.2 = 定影器过热
    $vbH = Tlv 0x30 (@(@($oidH) + @($valH)))
    $vblH = Tlv 0x30 $vbH
    $pduH = Tlv 0xA2 (@(@($reqId) + @($errStat) + @($errIdx) + @($vblH)))
    $outerH = Tlv 0x30 (@(@($ver) + @($comm) + @($pduH)))
    $dH = Decode-Snmp $outerH
    ST 'SNMP 解码 hrPrinterDetectedErrorState(OCTET STRING)' ($dH.Type -eq 0x04 -and $dH.Raw.Length -eq 1 -and $dH.Raw[0] -eq 0x04)
    $hbits = ConvertFrom-SnmpErrorState $dH.Raw
    ST 'SNMP 位域 0x04 -> 定影器过热' ($hbits.Count -eq 1 -and $hbits[0] -eq '定影器过热')
    $hbits2 = ConvertFrom-SnmpErrorState @([byte]0x04, [byte]0x02)
    ST 'SNMP 位域 多bit 解码' ($hbits2.Count -eq 2 -and $hbits2[0] -eq '定影器过热' -and $hbits2[1] -eq '出纸盘缺失')
    # 4c) 状态合并（IPP 原因 + SNMP 位域）
    $m1 = Merge-PrinterStatus -StateInfo @{ Text = '空闲'; Sev = 'OK' } -FriendlyReasons @(@{ Text = '正常'; Sev = 'OK' }) -SnmpBits @('定影器过热')
    ST '合并 正常+过热 -> Warning' ($m1.Sev -eq 'Warning' -and $m1.Text -eq '定影器过热')
    $m2 = Merge-PrinterStatus -StateInfo @{ Text = '已停止'; Sev = 'Warning' } -FriendlyReasons @(@{ Text = '卡纸'; Sev = 'Critical' }) -SnmpBits $null
    ST '合并 卡纸 -> Critical' ($m2.Sev -eq 'Critical' -and $m2.Text -eq '卡纸')
    $m3 = Merge-PrinterStatus -StateInfo @{ Text = '空闲'; Sev = 'OK' } -FriendlyReasons @(@{ Text = '正常'; Sev = 'OK' }) -SnmpBits $null
    ST '合并 全正常 -> OK' ($m3.Sev -eq 'OK' -and $m3.Issues.Count -eq 0)
    $m4 = Merge-PrinterStatus -StateInfo @{ Text = '空闲'; Sev = 'OK' } -FriendlyReasons @(@{ Text = '正常'; Sev = 'OK' }) -SnmpBits @('bit 2.3')
    ST '合并 厂商自定义位 -> Warning(不漏报)' ($m4.Sev -eq 'Warning' -and $m4.Text -eq 'bit 2.3')
    # 4d) 通知防抖（迟滞）逻辑：异常去重、恢复需连续3次、抖动不刷屏
    $script:PollState = @{}
    $ft = [pscustomobject]@{ Ip = '10.0.0.1'; Name = '测试机' }
    $ev = New-Object System.Collections.ArrayList
    Update-PollState $ft 'anomaly' $ev @{ Text = '空闲'; Sev = 'Warning' } @{ Sev = 'Warning'; Text = '定影器过冷'; Issues = @('定影器过冷') }
    Update-PollState $ft 'anomaly' $ev @{ Text = '空闲'; Sev = 'Warning' } @{ Sev = 'Warning'; Text = '定影器过冷'; Issues = @('定影器过冷') }
    ST '防抖 异常只报一次(去重)' ($ev.Count -eq 1)
    $ev2 = New-Object System.Collections.ArrayList
    Update-PollState $ft 'ok' $ev2
    Update-PollState $ft 'ok' $ev2
    Update-PollState $ft 'ok' $ev2
    ST '防抖 恢复需连续3次才报' ($ev2.Count -eq 1)
    # 离线需连续3次；2次（扫描时短暂不响应 IPP）不算故障
    $script:PollState = @{}
    $ft3 = [pscustomobject]@{ Ip = '10.0.0.3'; Name = '离线机' }
    $ev4 = New-Object System.Collections.ArrayList
    Update-PollState $ft3 'offline' $ev4
    Update-PollState $ft3 'offline' $ev4
    ST '防抖 离线需连续3次(2次不算)' ($ev4.Count -eq 0)
    $script:PollState = @{}
    $ft2 = [pscustomobject]@{ Ip = '10.0.0.2'; Name = '抖动机' }
    $ev3 = New-Object System.Collections.ArrayList
    Update-PollState $ft2 'offline' $ev3
    Update-PollState $ft2 'ok' $ev3
    Update-PollState $ft2 'offline' $ev3
    Update-PollState $ft2 'ok' $ev3
    ST '防抖 抖动(离线/在线交替)不刷屏' ($ev3.Count -eq 0)
    # 5) 端口注册表路径构造（不实际写）—— 用字符串拼接，不能用 Join-Path（会把 '/' 当成分隔符）
    $kp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Monitors\Standard TCP/IP Port\Ports' + '\' + 'IP_192.168.1.100'
    ST '端口SNMP注册表路径构造' ($kp -match 'Standard TCP/IP Port\\Ports\\IP_192.168.1.100')
    # 6) 通知函数存在（注意：Get-Command 返回 FunctionInfo，须转 bool，否则 ST 的 [bool]$pass 绑定会抛错）
    ST 'Send-Notification 函数存在' ($null -ne (Get-Command Send-Notification -ErrorAction SilentlyContinue))
    ST 'Send-Toast 函数存在' ($null -ne (Get-Command Send-Toast -ErrorAction SilentlyContinue))
    # 7) 配置读写
    ST 'Read-Config 返回对象' ($null -ne (Read-Config))
    # 8) 深度体检（合并自 WinPrintDiag 的完整扫描）
    ST 'Invoke-PrintSubsystemCheckup 函数存在' ($null -ne (Get-Command Invoke-PrintSubsystemCheckup -ErrorAction SilentlyContinue))
    $ckDir = Join-Path $env:TEMP ('PSG_checkup_' + (Get-Date).ToString('yyyyMMddHHmmss'))
    $ck = Invoke-PrintSubsystemCheckup -OutDir $ckDir
    ST '深度体检 产出报告且含结论段' (($null -ne $ck) -and ($ck.ReportText.Length -gt 500) -and ($ck.ReportText -match '\[10\] 结论与建议')) ('Flags=' + $ck.FlagCount)
    ST '深度体检 报告文件已落盘' (Test-Path -LiteralPath $ck.ReportPath)
    # 9) 开机自启（计划任务方案）
    ST 'Get-AutoStart / Set-AutoStart 函数存在' (($null -ne (Get-Command Get-AutoStart -ErrorAction SilentlyContinue)) -and ($null -ne (Get-Command Set-AutoStart -ErrorAction SilentlyContinue)))
    ST 'Get-AutoStart 返回布尔' ((Get-AutoStart) -is [bool])
    ST 'ExeOrScript 指向存在文件' ((Test-Path $ExeOrScript) -and ($ExeOrScript -match 'PrinterStatusGuard'))
    # 10) 检查更新（版本号语义比较，不发网络请求）
    ST 'Test-NewerVersion 1.2.0 > 1.1.1' (Test-NewerVersion -Tag 'v1.2.0' -Current '1.1.1')
    ST 'Test-NewerVersion 1.1.1 = 1.1.1' (-not (Test-NewerVersion -Tag 'v1.1.1' -Current '1.1.1'))
    ST 'Test-NewerVersion 1.1.0 < 1.1.1' (-not (Test-NewerVersion -Tag 'v1.1.0' -Current '1.1.1'))
    ST 'Test-NewerVersion 1.10.0 > 1.9.9' (Test-NewerVersion -Tag 'v1.10.0' -Current '1.9.9')

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

# ===================== 提权子进程：注册/取消开机自启计划任务并退出 =====================
# 非管理员点「开机自启」时，用 RunAs 以管理员重启本程序并带上 -EnableAutoStart/-DisableAutoStart，
# 这里一次性创建/删除计划任务（最高权限）后弹结果并退出（不加载主窗体）。
if ($EnableAutoStart -or $DisableAutoStart) {
    $en = [bool]$EnableAutoStart
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
    if (-not (Test-Admin)) {
        [System.Windows.Forms.MessageBox]::Show('本操作需要管理员权限，但提权后仍未获得管理员身份。请手动右键「以管理员身份运行」后再试。', 'PrinterStatusGuard') | Out-Null
        exit 1
    }
    $r = Set-AutoStart -Enable $en
    [System.Windows.Forms.MessageBox]::Show($r.Msg, 'PrinterStatusGuard') | Out-Null
    if ($r.Ok) { exit 0 } else { exit 1 }
}

# ===================== 以下为 GUI / 托盘 / 哨兵（仅非自检时运行） =====================
[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
[void][System.Reflection.Assembly]::LoadWithPartialName('System.Drawing')

$Cfg = Read-Config
# 旧版配置文件没有 AutoUpdateCheck 字段时补默认值（true），并回写一次
if ($null -eq $Cfg.AutoUpdateCheck) {
    $Cfg | Add-Member -NotePropertyName AutoUpdateCheck -NotePropertyValue $true
    Write-Config $Cfg
}

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
$miUpdate = $cm.Items.Add('检查更新')
$miUpdAuto = $cm.Items.Add('自动检查更新')
$miExit = $cm.Items.Add('退出')
$miAuto.Checked = (Get-AutoStart)
$miUpdAuto.Checked = [bool]$Cfg.AutoUpdateCheck
$Global:NotifyIcon.ContextMenuStrip = $cm

$SentinelTimer = $null
$GuardRunning = $false

function Start-Sentinel {
    param([bool]$FromUi = $true)
    if ($GuardRunning) { return }
    $GuardRunning = $true
    $miGuard.Text = '停止哨兵'
    $Global:NotifyIcon.Text = 'PrinterStatusGuard — 哨兵运行中'
    $SentinelTimer = New-Object System.Windows.Forms.Timer
    $SentinelTimer.Interval = [math]::Max(10, $Cfg.IntervalSec) * 1000
    $SentinelTimer.Add_Tick({
        try {
            $evs = Invoke-SentinelPoll $script:Cfg
            foreach ($e in $evs) {
                $how = Send-Notification -Title $e.Title -Message $e.Message -Icon $e.Icon
                Save-Log ($e.Title + ' | ' + $e.Message + ' [' + $how + ']')
            }
        }
        catch { Write-Log -Level 'Error' -Source 'SENTINEL' -Message ('巡检异常: ' + $_.Exception.Message) }
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

# --- 开机自启（计划任务，最高权限）：UI 统一入口 ---
$Global:AutoBusy = $false

function Set-AutoStartUi([bool]$Val) {
    # 程序内同步两处 UI 状态；$AutoBusy 防止 CheckedChanged 级联再次触发真实开关
    $Global:AutoBusy = $true
    $chkAutoB.Checked = $Val
    $miAuto.Checked = $Val
    $Global:AutoBusy = $false
}

function Start-ElevatedAutoStart {
    param([bool]$Enable)
    $arg = if ($Enable) { '-EnableAutoStart' } else { '-DisableAutoStart' }
    if ($ExeOrScript -match '\.ps1$') {
        $psi = 'powershell.exe'
        $a = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $ExeOrScript, $arg
    }
    else {
        $psi = $ExeOrScript
        $a = $arg
    }
    try { Start-Process -Verb RunAs -FilePath $psi -ArgumentList $a | Out-Null; return $true }
    catch { return $false }
}

function Invoke-AutoStartToggle {
    param([bool]$Enable)
    if (Test-Admin) {
        $r = Set-AutoStart -Enable $Enable
    }
    else {
        if (Start-ElevatedAutoStart -Enable $Enable) {
            # UAC 已弹出，子进程创建/删除计划任务后自行弹结果；这里轮询等待状态落定
            $deadline = (Get-Date).AddSeconds(12)
            while ((Get-Date) -lt $deadline) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 400
                if ((Get-AutoStart) -eq $Enable) { break }
            }
            $r = @{ Ok = $true; Msg = '已在管理员子进程中处理开机自启。' }
        }
        else {
            $r = @{ Ok = $false; Msg = '已取消：未授予管理员权限，开机自启未更改。' }
        }
    }
    Set-AutoStartUi (Get-AutoStart)
    if ($Global:NotifyIcon) {
        $Global:NotifyIcon.ShowBalloonTip(4000, 'PrinterStatusGuard', $r.Msg, [System.Windows.Forms.ToolTipIcon]::Info)
    }
    Write-Log -Level $(if ($r.Ok) { 'Info' } else { 'Warning' }) -Source 'APP' -Message ('开机自启: ' + $r.Msg)
    Save-Log ('开机自启: ' + $r.Msg)
}

$miAuto.Add_Click({ Invoke-AutoStartToggle -Enable (-not (Get-AutoStart)) })
$miUpdate.Add_Click({ Invoke-UpdateCheck })
$miUpdAuto.Add_Click({
    $Cfg.AutoUpdateCheck = -not [bool]$Cfg.AutoUpdateCheck
    $miUpdAuto.Checked = [bool]$Cfg.AutoUpdateCheck
    Write-Config $Cfg
    $tip = $(if ($Cfg.AutoUpdateCheck) { '已开启自动检查更新（每次启动后静默检查，发现新版本才提示）。' } else { '已关闭自动检查更新；可随时通过「检查更新」手动检查。' })
    $Global:NotifyIcon.ShowBalloonTip(3000, 'PrinterStatusGuard', $tip, [System.Windows.Forms.ToolTipIcon]::Info)
    Write-Log -Level 'Info' -Source 'UPDATE' -Message $tip
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
$chkAutoB.Add_CheckedChanged({ if ($Global:AutoBusy) { return }; Invoke-AutoStartToggle -Enable $chkAutoB.Checked })

# --- Tab C: 日志（诊断） ---
$tabC = New-Object System.Windows.Forms.TabPage; $tabC.Text = '日志（诊断）'
$tab.Controls.Add($tabC)

$lblC = New-Object System.Windows.Forms.Label
$lblC.Text = '记录软件与打印机交互的原始消息（IPP 原始原因 / SNMP 位域 / 通知）。可用等级筛选定位「卡纸没提示」等问题。'
$lblC.Location = New-Object System.Drawing.Point(12, 12); $lblC.Size = New-Object System.Drawing.Size(780, 28); $lblC.AutoSize = $false
$tabC.Controls.Add($lblC)

$dgvC = New-Object System.Windows.Forms.DataGridView
$dgvC.Location = New-Object System.Drawing.Point(12, 44); $dgvC.Size = New-Object System.Drawing.Size(780, 380)
$dgvC.AllowUserToAddRows = $false; $dgvC.ReadOnly = $true; $dgvC.AutoSizeColumnsMode = 'AllCells'
$dgvC.Columns.Add('Time', '时间') | Out-Null
$dgvC.Columns.Add('Level', '等级') | Out-Null
$dgvC.Columns.Add('Source', '来源') | Out-Null
$dgvC.Columns.Add('Message', '消息') | Out-Null
$tabC.Controls.Add($dgvC)
$Global:LogGrid = $dgvC

$cboFilter = New-Object System.Windows.Forms.ComboBox
$cboFilter.Location = New-Object System.Drawing.Point(12, 432); $cboFilter.Size = New-Object System.Drawing.Size(120, 22)
$cboFilter.DropDownStyle = 'DropDownList'
$cboFilter.Items.Add('全部') | Out-Null
$cboFilter.Items.Add('Info') | Out-Null
$cboFilter.Items.Add('Warning') | Out-Null
$cboFilter.Items.Add('Error') | Out-Null
$cboFilter.SelectedIndex = 0
$tabC.Controls.Add($cboFilter)

$btnClearLog = New-Object System.Windows.Forms.Button
$btnClearLog.Text = '清空日志'; $btnClearLog.Location = New-Object System.Drawing.Point(150, 430); $btnClearLog.Size = New-Object System.Drawing.Size(100, 26)
$tabC.Controls.Add($btnClearLog)

$btnOpenLogDir = New-Object System.Windows.Forms.Button
$btnOpenLogDir.Text = '打开日志文件夹'; $btnOpenLogDir.Location = New-Object System.Drawing.Point(262, 430); $btnOpenLogDir.Size = New-Object System.Drawing.Size(130, 26)
$tabC.Controls.Add($btnOpenLogDir)

$lblFilterNote = New-Object System.Windows.Forms.Label
$lblFilterNote.Text = '等级筛选:'; $lblFilterNote.Location = New-Object System.Drawing.Point(400, 436); $lblFilterNote.Size = New-Object System.Drawing.Size(70, 20)
$tabC.Controls.Add($lblFilterNote)

$cboFilter.Add_SelectedIndexChanged({
    $Global:LogFilter = $cboFilter.SelectedItem.ToString()
    Apply-LogFilter
})
$btnClearLog.Add_Click({ Clear-Log })
$btnOpenLogDir.Add_Click({
    try { if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }; Start-Process 'explorer.exe' $LogDir } catch { }
})


# --- Tab D: 深度体检（原独立工具 WinPrintDiag 已并入） ---
$tabD = New-Object System.Windows.Forms.TabPage; $tabD.Text = '深度体检'
$tab.Controls.Add($tabD)

$lblD = New-Object System.Windows.Forms.Label
$lblD.Text = '打印子系统一键体检：打印服务 / 崩溃历史 / 组件签名 / 打印机-驱动配对 / 队列 / 审计日志。只读扫描，约 5 秒。'
$lblD.Location = New-Object System.Drawing.Point(12, 12); $lblD.Size = New-Object System.Drawing.Size(780, 28); $lblD.AutoSize = $false
$tabD.Controls.Add($lblD)

$btnDiagScan = New-Object System.Windows.Forms.Button
$btnDiagScan.Text = '开始体检'; $btnDiagScan.Location = New-Object System.Drawing.Point(12, 44); $btnDiagScan.Size = New-Object System.Drawing.Size(110, 28)
$tabD.Controls.Add($btnDiagScan)

$btnDiagRepair = New-Object System.Windows.Forms.Button
$btnDiagRepair.Text = '修复组件（管理员）'; $btnDiagRepair.Location = New-Object System.Drawing.Point(132, 44); $btnDiagRepair.Size = New-Object System.Drawing.Size(140, 28)
$tabD.Controls.Add($btnDiagRepair)

$btnDiagClearQ = New-Object System.Windows.Forms.Button
$btnDiagClearQ.Text = '清理打印队列（管理员）'; $btnDiagClearQ.Location = New-Object System.Drawing.Point(282, 44); $btnDiagClearQ.Size = New-Object System.Drawing.Size(160, 28)
$tabD.Controls.Add($btnDiagClearQ)

$btnDiagOpen = New-Object System.Windows.Forms.Button
$btnDiagOpen.Text = '打开报告目录'; $btnDiagOpen.Location = New-Object System.Drawing.Point(452, 44); $btnDiagOpen.Size = New-Object System.Drawing.Size(120, 28)
$tabD.Controls.Add($btnDiagOpen)

$btnDiagSave = New-Object System.Windows.Forms.Button
$btnDiagSave.Text = '另存报告'; $btnDiagSave.Location = New-Object System.Drawing.Point(582, 44); $btnDiagSave.Size = New-Object System.Drawing.Size(100, 28)
$tabD.Controls.Add($btnDiagSave)

$lblDiagSummary = New-Object System.Windows.Forms.Label
$lblDiagSummary.Text = '点击「开始体检」执行一次只读诊断。'
$lblDiagSummary.Location = New-Object System.Drawing.Point(12, 80); $lblDiagSummary.Size = New-Object System.Drawing.Size(780, 20); $lblDiagSummary.AutoSize = $false
$tabD.Controls.Add($lblDiagSummary)

# 报告窗格需要「等宽 + 自带中文字形」的字体（报告表格按半角/全角对齐）。
# SimSun/NSimSun 在 GDI+ 里以本地化名（宋体/新宋体）出现，故按名探测而非枚举字体族。
$diagFontName = ''
foreach ($cand in @(
    @{ Want = 'NSimSun'; Names = @('NSimSun', '新宋体') },
    @{ Want = 'SimSun'; Names = @('SimSun', '宋体') },
    @{ Want = 'Consolas'; Names = @('Consolas') },
    @{ Want = 'Microsoft YaHei UI'; Names = @('Microsoft YaHei UI', '微软雅黑 UI') }
)) {
    try {
        $probeF = New-Object System.Drawing.Font($cand.Want, 9)
        if ($cand.Names -contains $probeF.Name) { $diagFontName = $probeF.Name; $probeF.Dispose(); break }
        $probeF.Dispose()
    } catch { }
}
if ([string]::IsNullOrWhiteSpace($diagFontName)) { $diagFontName = 'Microsoft Sans Serif' }

$txtDiagReport = New-Object System.Windows.Forms.TextBox
$txtDiagReport.Multiline = $true; $txtDiagReport.ReadOnly = $true
$txtDiagReport.ScrollBars = 'Both'; $txtDiagReport.WordWrap = $false
$txtDiagReport.Location = New-Object System.Drawing.Point(12, 106); $txtDiagReport.Size = New-Object System.Drawing.Size(780, 352)
$txtDiagReport.Font = New-Object System.Drawing.Font($diagFontName, 9)
$txtDiagReport.Text = '尚无报告。点击「开始体检」开始。'
$tabD.Controls.Add($txtDiagReport)

$Global:CheckupBusy = $false
$Global:LastCheckupReport = $null

function Set-DiagBusy([bool]$Busy) {
    $btnDiagScan.Enabled = -not $Busy
    $btnDiagRepair.Enabled = -not $Busy
    $btnDiagClearQ.Enabled = -not $Busy
    $btnDiagSave.Enabled = -not $Busy
}

function Invoke-CheckupUi {
    param([switch]$Repair, [switch]$ClearQueue)
    if ($Global:CheckupBusy) { return }
    if ($Repair -or $ClearQueue) {
        if (-not (Test-Admin)) {
            [System.Windows.Forms.MessageBox]::Show('该操作需要管理员权限。' + [Environment]::NewLine + '请右键以管理员身份重新运行本程序后再试。', 'PrinterStatusGuard', 'OK', 'Warning') | Out-Null
            return
        }
        if ($Repair) { $lblDiagSummary.Text = '正在修复（从组件存储还原被替换文件，旧文件先隔离备份）…' }
        else { $lblDiagSummary.Text = '正在清理打印队列（先备份，不删除）…' }
    }
    else { $lblDiagSummary.Text = '正在体检（约 5-10 秒）…' }
    $lblDiagSummary.ForeColor = [System.Drawing.Color]::FromArgb(180, 110, 20)
    $txtDiagReport.Text = '正在执行深度体检，请稍候…'
    $Global:CheckupBusy = $true; Set-DiagBusy $true
    $MainForm.Cursor = 'WaitCursor'
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $dir = Join-Path $ConfigDir 'checkup'
        $ckArgs = @{ OutDir = $dir }
        if ($Repair) { $ckArgs.Repair = $true }
        if ($ClearQueue) { $ckArgs.ClearQueue = $true }
        $res = Invoke-PrintSubsystemCheckup @ckArgs
        $Global:LastCheckupReport = $res.ReportPath
        $txtDiagReport.Text = $res.ReportText
        $txtDiagReport.SelectionStart = 0; $txtDiagReport.ScrollToCaret()
        if ($res.FlagCount -eq 0) {
            $lblDiagSummary.Text = '体检完成：未发现明显异常。'
            $lblDiagSummary.ForeColor = [System.Drawing.Color]::FromArgb(30, 130, 70)
        }
        else {
            $nc = @($res.Flags | Where-Object { $_ -match '\[严重\]' }).Count
            $nw = @($res.Flags | Where-Object { $_ -match '\[警告\]' }).Count
            $ni = @($res.Flags | Where-Object { $_ -match '\[提示\]' }).Count
            $lblDiagSummary.Text = ('体检完成：发现 {0} 项（严重 {1} / 警告 {2} / 提示 {3}），详见下方报告。' -f $res.FlagCount, $nc, $nw, $ni)
            $lblDiagSummary.ForeColor = [System.Drawing.Color]::FromArgb(180, 40, 40)
        }
        Write-Log -Level 'Info' -Source 'CHECKUP' -Message ('深度体检完成，发现 {0} 项，报告 {1}' -f $res.FlagCount, $res.ReportPath)
    }
    catch {
        $txtDiagReport.Text = '体检失败：' + $_.Exception.Message
        $lblDiagSummary.Text = '体检失败'; $lblDiagSummary.ForeColor = [System.Drawing.Color]::FromArgb(180, 40, 40)
        Write-Log -Level 'Error' -Source 'CHECKUP' -Message ('深度体检失败: ' + $_.Exception.Message)
    }
    $MainForm.Cursor = 'Default'
    $Global:CheckupBusy = $false
    Set-DiagBusy $false
}

$btnDiagScan.Add_Click({ Invoke-CheckupUi })
$btnDiagRepair.Add_Click({ Invoke-CheckupUi -Repair })
$btnDiagClearQ.Add_Click({ Invoke-CheckupUi -ClearQueue })

$btnDiagOpen.Add_Click({
    $dir = Join-Path $ConfigDir 'checkup'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Start-Process 'explorer.exe' $dir
})

$btnDiagSave.Add_Click({
    if ([string]::IsNullOrWhiteSpace($Global:LastCheckupReport)) {
        [System.Windows.Forms.MessageBox]::Show('请先执行一次体检。', 'PrinterStatusGuard', 'OK', 'Information') | Out-Null
        return
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = '文本报告|*.txt|所有文件|*.*'
    $dlg.FileName = (Split-Path $Global:LastCheckupReport -Leaf)
    if ($dlg.ShowDialog() -eq 'OK') {
        Copy-Item -LiteralPath $Global:LastCheckupReport -Destination $dlg.FileName -Force
        $lblDiagSummary.Text = ('报告已另存到 ' + $dlg.FileName)
    }
})

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
# 旧版开机自启迁移：v1.1.0 及以前把自启写在 HKCU Run 且 exe 形态下误指向 ps1，静默失效。
# 升级后首次运行：清掉旧 Run 条目；已具管理员身份则直接重建为计划任务，否则提示重新勾选。
try {
    $oldRun = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'PrinterStatusGuard' -ErrorAction SilentlyContinue
    if ($oldRun -and $oldRun.'PrinterStatusGuard') {
        Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'PrinterStatusGuard' -ErrorAction SilentlyContinue
        if (Test-Admin) {
            $mig = Set-AutoStart -Enable $true
            Write-Log -Level 'Info' -Source 'APP' -Message ('开机自启迁移为计划任务: ' + $mig.Msg)
        }
        else {
            Write-Log -Level 'Warning' -Source 'APP' -Message '检测到旧版开机自启条目已清理；请重新勾选「开机自启」并允许管理员权限（改为最高权限计划任务方案）。'
        }
    }
} catch { }

Write-Log -Level 'Info' -Source 'APP' -Message ('PrinterStatusGuard 启动 v' + $ScriptVersion + '；配置目录 ' + $ConfigDir)

# 启动 15 秒后静默检查一次更新（可由托盘「自动检查更新」关闭；仅在发现新版本时弹托盘气泡，失败不打扰）
if ($Cfg.AutoUpdateCheck) {
    $updTimer = New-Object System.Windows.Forms.Timer
    $updTimer.Interval = 15000
    $updTimer.Add_Tick({ $updTimer.Stop(); Invoke-UpdateCheck -Silent $true })
    $updTimer.Start()
}
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
