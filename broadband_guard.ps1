# =====================================================
#  PPPoE-Guardian - 宽带连接守护脚本
#  功能: 检测宽带(PPPoE)掉线后自动重拨(拟人点击"连接"按钮或 rasdial),
#        连续稳定指定时长(默认10分钟)后自动退出
#  用法: 双击 start_guard.bat 运行; 加 -Check 参数仅查看当前状态
# =====================================================
param([switch]$Check)

# ---------------- 配置区(可按需修改) ----------------
$connName        = ""                                  # 拨号连接名称; 留空=自动检测(多个条目时会让你选)
$pingTargets     = @("223.5.5.5", "119.29.29.29")      # 连通性测试目标, 任一通即算在线
$checkInterval   = 10                                  # 在线时检测间隔(秒)
$stableMinutes   = 10                                  # 连续稳定多久后自动退出(分钟)
$maxRetries      = 15                                  # 连续重拨多少次失败后放弃
$dialMethod      = "gui"                               # 拨号方式: "gui"=点击设置页连接按钮(和手动操作一致) / "rasdial"=命令行拨号
$broadbandUser   = ""                                  # 宽带账号(仅 rasdial 方式用到; 如账号带 xxx@xxx 后缀请填全)
$broadbandPass   = ""                                  # 宽带密码(仅 rasdial 方式用到; 留空则尝试用系统记住的凭据拨号)
# -----------------------------------------------------

$logFile = Join-Path $PSScriptRoot "guard.log"

function Write-Log {
    param([string]$Message, [ConsoleColor]$Color = "Gray")
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

# 从系统电话簿(rasphone.pbk)枚举本机所有拨号条目
function Get-DialEntries {
    $pbk = Join-Path $env:APPDATA "Microsoft\Network\Connections\Pbk\rasphone.pbk"
    if (-not (Test-Path $pbk)) { return @() }
    # pbk 可能是无 BOM 的 UTF-8 / 带 BOM 的 UTF-16 / ANSI, 用 StreamReader 自动识别编码
    $sr = New-Object System.IO.StreamReader($pbk, $true)
    try { $lines = $sr.ReadToEnd() -split "`r?`n" } finally { $sr.Close() }
    return @($lines |
        Where-Object { $_ -match '^\[(.+)\]$' } |
        ForEach-Object { $Matches[1] })
}

# RAS 层面是否已连接(名称出现在 rasdial 连接列表里)
function Test-RasConnected {
    $list = (rasdial 2>&1) -join "`n"
    return ($list -match [regex]::Escape($connName))
}

# 网络是否真正连通(ping 任一目标成功)
function Test-NetOnline {
    foreach ($ip in $pingTargets) {
        try {
            $ping = New-Object System.Net.NetworkInformation.Ping
            if ($ping.Send($ip, 2000).Status -eq "Success") { return $true }
        } catch { }
    }
    return $false
}

function Show-Status {
    $ras = if (Test-RasConnected) { "已连接" } else { "未连接" }
    $net = if (Test-NetOnline)    { "通畅" } else { "不通" }
    Write-Host ("当前状态: 拨号[{0}] 网络[{1}]" -f $ras, $net) -ForegroundColor Cyan
}

# 在设置页"拨号"里定位设置窗口(中英文系统各试一次)
function Find-SettingsWindow {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    foreach ($title in @("设置", "Settings")) {
        $cond = New-Object System.Windows.Automation.AndCondition(
            (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, "ApplicationFrameWindow")),
            (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $title))
        )
        $win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
        if ($win) { return $win }
    }
    return $null
}

function Ensure-SettingsWindow {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction SilentlyContinue
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction SilentlyContinue

    $win = Find-SettingsWindow
    if ($win) { return $win }

    Start-Process "ms-settings:network-dialup"
    for ($w = 1; $w -le 6 -and -not $win; $w++) {   # 设置页冷启动可能要好几秒, 最多等 12 秒
        Start-Sleep -Seconds 2
        $win = Find-SettingsWindow
    }
    return $win
}

# 拟人操作: 在设置页找到"$connName"卡片的"连接"按钮并点击(后台触发, 不需要前台)
function Invoke-GuiConnect {
    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction SilentlyContinue
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction SilentlyContinue

        $win = Ensure-SettingsWindow
        if (-not $win) { return $false }

        $itemCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $connName)
        $item = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $itemCond)
        if (-not $item) { return $false }

        # 从连接卡片向上找包含按钮的容器, 精确匹配本卡片的"连接"按钮(中英文)
        $btnTypeCond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
        $node = $item; $btn = $null
        for ($up = 0; $up -lt 10 -and $node; $up++) {
            $btns = $node.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnTypeCond)
            foreach ($b in $btns) {
                if ($b.Current.Name -eq "连接" -or $b.Current.Name -eq "Connect") { $btn = $b; break }
            }
            if ($btn) { break }
            $node = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($node)
        }
        if (-not $btn) { return $false }   # 没找到"连接"按钮(可能已在拨号中或已连接)

        ($btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke()
        return $true
    } catch { return $false }
}

# 按配置的方式发起一次拨号
function Invoke-Dial {
    if ($dialMethod -eq "gui") {
        if (Invoke-GuiConnect) { return "UI点击'连接'按钮" }
        Write-Log "设置页'连接'按钮定位失败, 本次回退 rasdial 拨号" DarkYellow
    }
    if ($broadbandUser) {
        return (rasdial $connName $broadbandUser $broadbandPass 2>&1) -join " "
    }
    return (rasdial $connName 2>&1) -join " "
}

# ---------------- 解析连接名称 ----------------
if (-not $connName) {
    $entries = @(Get-DialEntries)   # 必须强制数组: 单条目时函数返回会被展开成字符串, [0] 会取出首字符
    if ($entries.Count -eq 0) {
        Write-Host "未在本机找到任何拨号条目(rasphone.pbk 为空或不存在)。" -ForegroundColor Red
        Write-Host "请先在 设置 > 网络和 Internet > 拨号 里创建宽带连接, 或在脚本配置区手动填写 `$connName。" -ForegroundColor Yellow
        exit 1
    }
    if ($entries.Count -eq 1) {
        $connName = $entries[0]
        Write-Host "自动检测到拨号连接: $connName" -ForegroundColor Cyan
    }
    elseif ($Check) {
        $connName = $entries[0]
        Write-Host "检测到多个拨号条目, -Check 模式默认使用第一个: $connName" -ForegroundColor DarkYellow
    }
    else {
        Write-Host "检测到多个拨号条目, 请选择要守护的连接:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $entries.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $entries[$i])
        }
        $sel = Read-Host "输入序号(回车默认 1)"
        $idx = 0
        if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $entries.Count) { $idx = [int]$sel - 1 }
        $connName = $entries[$idx]
        Write-Host "已选择: $connName" -ForegroundColor Cyan
    }
}

# 只读检查模式: 不拨号不断网, 仅查看状态
if ($Check) {
    Show-Status
    exit 0
}

# 干净启动: 检查是否已有旧的守护进程, 询问是否关闭后重新启动
$old = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'broadband_guard\.ps1' -and $_.ProcessId -ne $PID })
if ($old.Count -gt 0) {
    Write-Host "检测到 $($old.Count) 个旧的宽带守护进程:" -ForegroundColor Yellow
    $old | ForEach-Object { Write-Host ("  PID {0}  启动于 {1}" -f $_.ProcessId, $_.CreationDate) -ForegroundColor Gray }
    $answer = Read-Host "是否关闭以上进程并干净启动? (Y/N)"
    if ($answer -match '^[Yy]') {
        $old | ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force; Write-Log "已关闭旧守护进程 PID $($_.ProcessId)" Yellow } catch { }
        }
        Write-Host "旧进程已关闭, 继续启动..." -ForegroundColor Green
    } else {
        Write-Host "已取消, 本实例退出(旧守护继续运行)。" -ForegroundColor Yellow
        exit 0
    }
}

# 单实例保护(兜底): 极端情况下避免两个守护同时重拨
$created = $false
$mutex = New-Object System.Threading.Mutex($true, "BroadbandGuardMutex", [ref]$created)
if (-not $created) {
    Write-Host "已有一个宽带守护在运行, 本实例退出。" -ForegroundColor Yellow
    exit 0
}

Write-Log ("=" * 50) DarkCyan
Write-Log "PPPoE-Guardian 启动, 监测连接: $connName" Green
Write-Log "规则: 掉线自动重拨(最多连续 $maxRetries 次), 连续稳定 $stableMinutes 分钟后自动退出" Gray

if ($dialMethod -eq "gui") {
    if (Ensure-SettingsWindow) {
        Write-Log "启动时已确认设置 > 拨号窗口存在" Gray
    } else {
        Write-Log "启动时未能打开设置 > 拨号窗口, GUI 拨号失败时将回退 rasdial" DarkYellow
    }
}

$stableSeconds = 0
$offlineStreak = 0
while ($true) {
    if ((Test-RasConnected) -and (Test-NetOnline)) {
        $offlineStreak = 0
        $stableSeconds += $checkInterval
        $min = [int]($stableSeconds / 60)
        $sec = $stableSeconds % 60
        Write-Host ("在线中, 已稳定 {0}分{1}秒 / {2}分钟" -f $min, $sec, $stableMinutes) -ForegroundColor Green
        if ($stableSeconds -ge ($stableMinutes * 60)) {
            Write-Log "网络已连续稳定 $stableMinutes 分钟, 守护任务完成, 自动退出" Green
            exit 0
        }
        Start-Sleep -Seconds $checkInterval
        continue
    }

    # 连续 2 次检测都失败才判定真掉线, 避免单次 ping 丢包误判而断开好连接
    $offlineStreak++
    if ($offlineStreak -lt 2) {
        Write-Host "检测到一次网络异常, 观察中..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds $checkInterval
        continue
    }

    # 掉线确认: 清零稳定计时, 进入重拨流程
    $offlineStreak = 0
    $stableSeconds = 0
    Write-Log "确认掉线, 开始自动重拨..." Yellow

    $dialed = $false
    for ($i = 1; $i -le $maxRetries; $i++) {
        if (Test-RasConnected) {
            # 已有会话但 ping 不通: 再观察 15 秒, 确认真死才断开, 避免误杀刚拨通的连接
            $alive = $false
            for ($t = 1; $t -le 3; $t++) {
                Start-Sleep -Seconds 5
                if (Test-NetOnline) { $alive = $true; break }
            }
            if ($alive) {
                Write-Log "连接其实已自行恢复, 取消重拨" Green
                $dialed = $true
                break
            }
            rasdial $connName /disconnect 2>&1 | Out-Null
            Start-Sleep -Seconds 2
        }
        $out = Invoke-Dial

        # 拨号后轮询 30 秒确认就绪, IP 没配好前不算失败
        $ok = $false
        for ($try = 1; $try -le 6; $try++) {
            Start-Sleep -Seconds 5
            if ((Test-RasConnected) -and (Test-NetOnline)) { $ok = $true; break }
        }

        if ($ok) {
            Write-Log ("第 {0} 次重拨成功" -f $i) Green
            $dialed = $true
            break
        }
        if ($out -match "628|691") {
            $hint = if ($broadbandUser) { "账号密码已显式传入仍被拒, 可能是网关未释放旧会话或账号在别处在线" } else { "未指定账号密码, 若持续 628/691 请在脚本顶部配置区填入宽带账号密码" }
            Write-Log ("第 {0} 次重拨未成功: {1}  (提示: {2})" -f $i, $out, $hint) Yellow
        } else {
            Write-Log ("第 {0} 次重拨未成功: {1}" -f $i, $out) Yellow
        }
        # 退避等待: 失败越多次等越久(10s -> 最多60s), 给网关释放旧会话的时间
        $backoff = [Math]::Min(10 * $i, 60)
        Write-Host "等待 $backoff 秒后进行下一次重拨..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $backoff
    }

    if (-not $dialed) {
        Write-Log "连续 $maxRetries 次重拨均失败, 守护放弃并退出, 请手动排查(账号是否被挤下线/运营商维护等)" Red
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [System.Windows.Forms.MessageBox]::Show(
                "宽带连续 $maxRetries 次重拨失败, 守护脚本已退出。`n请检查宽带账号状态或稍后手动重试。",
                "宽带重连失败", 0, 48) | Out-Null
        } catch { }
        exit 1
    }

    Write-Log "重连成功, 重新开始 $stableMinutes 分钟稳定性计时" Cyan
}
