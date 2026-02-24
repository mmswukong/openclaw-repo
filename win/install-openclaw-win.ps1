<#
.SYNOPSIS
    OpenClaw Windows 一键安装脚本
    基于 sam_manual/win_manual.md 编写

.DESCRIPTION
    自动检测环境、安装 Node.js（可选）、安装 OpenClaw CLI 并运行引导向导。

.PARAMETER SkipOnboard
    仅安装 CLI，不运行引导向导

.PARAMETER UsePnpm
    使用 pnpm 安装（默认使用 npm）

.PARAMETER InstallNode
    如果 Node.js 不满足要求，自动通过 winget 安装

.PARAMETER Channel
    安装渠道: stable(默认) / beta / dev

.PARAMETER Verbose
    打印更详细的日志到终端

.EXAMPLE
    .\install-openclaw-win.ps1
    .\install-openclaw-win.ps1 -SkipOnboard
    .\install-openclaw-win.ps1 -InstallNode -Channel beta
    .\install-openclaw-win.ps1 -UsePnpm -Verbose
#>

[CmdletBinding()]
param(
    [switch]$SkipOnboard,
    [switch]$UsePnpm,
    [switch]$InstallNode,
    [ValidateSet("stable", "beta", "dev")]
    [string]$Channel = "stable",
    [switch]$ShowHelp
)

# ─────────────────────────────────────────────
# 严格模式
# ─────────────────────────────────────────────
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ─────────────────────────────────────────────
# 全局变量
# ─────────────────────────────────────────────
$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$script:Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$script:LogFile = Join-Path $script:ScriptDir "openclaw-install-$($script:Timestamp).log"
$script:RequiredNodeMajor = 22
$script:InstallSuccess = $false
$script:StepsCompleted = 0
$script:StepsTotal = 0
$script:NpmPrefixOverride = $null
$script:SafeNpmPrefix = "C:\npm-global"

# ─────────────────────────────────────────────
# 日志函数
# ─────────────────────────────────────────────
function Write-Log {
    param([string]$Message)
    Add-Content -Path $script:LogFile -Value $Message -ErrorAction SilentlyContinue
}

function Write-LogInfo {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Log "[$ts] [INFO]  $Message"
    Write-Host "  i  " -ForegroundColor Blue -NoNewline
    Write-Host $Message
}

function Write-LogSuccess {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Log "[$ts] [OK]    $Message"
    Write-Host "  +  " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-LogWarn {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Log "[$ts] [WARN]  $Message"
    Write-Host "  !  " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Write-LogError {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Log "[$ts] [ERROR] $Message"
    Write-Host "  X  " -ForegroundColor Red -NoNewline
    Write-Host $Message
}

function Write-LogStep {
    param([string]$Message)
    $script:StepsCompleted++
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Log "[$ts] [STEP $($script:StepsCompleted)/$($script:StepsTotal)] $Message"
    Write-Host ""
    Write-Host "[$($script:StepsCompleted)/$($script:StepsTotal)] " -ForegroundColor Cyan -NoNewline
    Write-Host $Message -ForegroundColor White
}

function Write-LogDebug {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Log "[$ts] [DEBUG] $Message"
    if ($VerbosePreference -eq "Continue") {
        Write-Host "  -> " -ForegroundColor Cyan -NoNewline
        Write-Host $Message -ForegroundColor Gray
    }
}

# ─────────────────────────────────────────────
# 运行外部命令并捕获输出
# ─────────────────────────────────────────────
function Invoke-CommandLogged {
    param(
        [string]$Description,
        [string]$Command,
        [string[]]$Arguments
    )
    Write-LogDebug "执行命令: $Command $($Arguments -join ' ')"
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    try {
        $output = & $Command @Arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }
    }
    catch {
        $output = $_.Exception.Message
        $exitCode = 1
    }

    if ($output) {
        Write-Log "[$ts] [CMD]   [$Description] 输出:"
        Write-Log $output.Trim()
    }
    if ($exitCode -ne 0) {
        Write-Log "[$ts] [CMD]   [$Description] 退出码: $exitCode"
    }
    if ($VerbosePreference -eq "Continue" -and $output) {
        $output.Trim().Split("`n") | ForEach-Object {
            Write-Host "     $_" -ForegroundColor Gray
        }
    }

    return @{ Output = $output; ExitCode = $exitCode }
}

function Invoke-WithProgress {
    param(
        [string]$Description,
        [scriptblock]$ScriptBlock
    )
    Write-Host "  ...  " -ForegroundColor Cyan -NoNewline
    Write-Host "$Description" -NoNewline

    $job = Start-Job -ScriptBlock $ScriptBlock
    $spinner = @('|', '/', '-', '\')
    $i = 0
    $startTime = Get-Date

    while ($job.State -eq "Running") {
        $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
        $ch = $spinner[$i % 4]
        Write-Host "`r  $ch  $Description ($($elapsed)s)   " -NoNewline -ForegroundColor Cyan
        Start-Sleep -Milliseconds 200
        $i++
    }

    $result = Receive-Job -Job $job
    $jobState = $job.State
    Remove-Job -Job $job -Force

    Write-Host "`r                                                                    `r" -NoNewline

    return $result
}

# ─────────────────────────────────────────────
# 帮助信息
# ─────────────────────────────────────────────
function Show-Help {
    Write-Host ""
    Write-Host "+==================================================+" -ForegroundColor Cyan
    Write-Host "|      OpenClaw Windows 一键安装脚本                |" -ForegroundColor Cyan
    Write-Host "+==================================================+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "用法:"
    Write-Host "  .\install-openclaw-win.ps1 [选项]"
    Write-Host ""
    Write-Host "选项:"
    Write-Host "  -SkipOnboard     仅安装 CLI，不运行引导向导"
    Write-Host "  -UsePnpm         使用 pnpm 安装（默认使用 npm）"
    Write-Host "  -InstallNode     如果 Node.js 不满足要求，自动通过 winget 安装"
    Write-Host "  -Channel <ch>    安装渠道: stable(默认) / beta / dev"
    Write-Host "  -Verbose         打印详细日志到终端"
    Write-Host "  -ShowHelp        显示此帮助信息"
    Write-Host ""
    Write-Host "示例:"
    Write-Host "  # 默认安装（npm + 引导向导）" -ForegroundColor Gray
    Write-Host "  .\install-openclaw-win.ps1"
    Write-Host ""
    Write-Host "  # 使用 pnpm 安装，跳过引导" -ForegroundColor Gray
    Write-Host "  .\install-openclaw-win.ps1 -UsePnpm -SkipOnboard"
    Write-Host ""
    Write-Host "  # 自动安装 Node.js" -ForegroundColor Gray
    Write-Host "  .\install-openclaw-win.ps1 -InstallNode"
    Write-Host ""
    Write-Host "日志:"
    Write-Host "  安装日志自动保存到脚本同目录下，文件名格式:"
    Write-Host "  openclaw-install-<YYYYMMDD_HHMMSS>.log"
    Write-Host ""
    exit 0
}

# ─────────────────────────────────────────────
# 系统信息收集
# ─────────────────────────────────────────────
function Save-SystemInfo {
    Write-Log "==================================================="
    Write-Log "  OpenClaw Windows 安装日志"
    Write-Log "  开始时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')"
    Write-Log "==================================================="
    Write-Log ""
    Write-Log "[系统信息]"
    Write-Log "  主机名:      $env:COMPUTERNAME"
    Write-Log "  用户:        $env:USERNAME"
    Write-Log "  Windows版本: $([System.Environment]::OSVersion.VersionString)"
    Write-Log "  架构:        $env:PROCESSOR_ARCHITECTURE"
    Write-Log "  PowerShell:  $($PSVersionTable.PSVersion)"

    try {
        $disk = Get-PSDrive -Name C -ErrorAction SilentlyContinue
        if ($disk) {
            $freeGB = [math]::Round($disk.Free / 1GB, 1)
            Write-Log "  C盘可用:     ${freeGB} GB"
        }
    } catch {}

    try {
        $mem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($mem) {
            $totalGB = [math]::Round($mem.TotalVisibleMemorySize / 1MB, 1)
            Write-Log "  内存:        ${totalGB} GB"
        }
    } catch {}

    Write-Log ""
    Write-Log "[安装选项]"
    Write-Log "  包管理器:    $(if ($UsePnpm) { 'pnpm' } else { 'npm' })"
    Write-Log "  安装渠道:    $Channel"
    Write-Log "  跳过引导:    $SkipOnboard"
    Write-Log "  自动安装Node: $InstallNode"
    Write-Log ""

    Write-Log "[已安装工具]"
    foreach ($tool in @("node", "npm", "pnpm", "git", "winget", "choco")) {
        $cmd = Get-Command $tool -ErrorAction SilentlyContinue
        if ($cmd) {
            try {
                $ver = & $tool --version 2>$null | Select-Object -First 1
                Write-Log "  ${tool}: $ver"
            } catch {
                Write-Log "  ${tool}: 已安装"
            }
        } else {
            Write-Log "  ${tool}: 未安装"
        }
    }
    Write-Log ""

    Write-Log "[PATH 环境变量]"
    $env:PATH -split ";" | ForEach-Object { Write-Log "  $_" }
    Write-Log ""
}

# ─────────────────────────────────────────────
# 环境检测
# ─────────────────────────────────────────────

function Test-Windows {
    Write-LogStep "检测操作系统"

    if ($env:OS -ne "Windows_NT") {
        Write-LogError "此脚本仅支持 Windows"
        throw "不支持的操作系统"
    }

    $osVer = [System.Environment]::OSVersion.Version
    $verStr = "$($osVer.Major).$($osVer.Minor).$($osVer.Build)"
    Write-LogSuccess "Windows $verStr ($env:PROCESSOR_ARCHITECTURE)"
    Write-LogDebug "完整版本: $([System.Environment]::OSVersion.VersionString)"

    if ($osVer.Build -lt 18362) {
        Write-LogWarn "Windows 版本较低 (Build $($osVer.Build))，建议升级到 Windows 10 1903+ 或 Windows 11"
    }
}

function Test-NodeJs {
    Write-LogStep "检测 Node.js (要求 >=$script:RequiredNodeMajor)"

    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCmd) {
        $nodeVer = & node --version 2>$null
        Write-LogDebug "Node.js 版本: $nodeVer"
        Write-LogDebug "Node.js 路径: $($nodeCmd.Source)"

        $majorStr = $nodeVer -replace '^v', '' -replace '\..*', ''
        $major = [int]$majorStr

        if ($major -ge $script:RequiredNodeMajor) {
            Write-LogSuccess "Node.js $nodeVer"
            return $true
        } else {
            Write-LogError "Node.js 版本过低: $nodeVer (需要 >=$script:RequiredNodeMajor)"
            if ($InstallNode) {
                return Install-NodeJs
            } else {
                Write-LogError "请升级 Node.js 到 v$script:RequiredNodeMajor 或更高版本"
                Show-NodeInstallHelp
                return $false
            }
        }
    } else {
        Write-LogError "Node.js 未安装"
        if ($InstallNode) {
            return Install-NodeJs
        } else {
            Write-LogError "OpenClaw 需要 Node.js >=$script:RequiredNodeMajor"
            Show-NodeInstallHelp
            return $false
        }
    }
}

function Show-NodeInstallHelp {
    Write-LogInfo "方法1: 使用 -InstallNode 选项自动安装"
    Write-LogInfo "方法2: winget install OpenJS.NodeJS.LTS"
    Write-LogInfo "方法3: 访问 https://nodejs.org 下载安装程序"
    Write-LogInfo "方法4: 使用 nvm-windows - nvm install $script:RequiredNodeMajor"
}

function Install-NodeJs {
    Write-LogInfo "正在安装 Node.js $script:RequiredNodeMajor..."
    Write-Log "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INSTALL] 开始安装 Node.js"

    $wingetCmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($wingetCmd) {
        Write-LogInfo "使用 winget 安装 Node.js LTS..."
        try {
            $result = Invoke-CommandLogged -Description "winget install Node.js" -Command "winget" -Arguments @("install", "OpenJS.NodeJS.LTS", "--accept-source-agreements", "--accept-package-agreements")
            if ($result.ExitCode -ne 0 -and $result.ExitCode -ne $null) {
                Write-LogWarn "winget 安装返回非零退出码: $($result.ExitCode)"
            }
        } catch {
            Write-LogError "winget 安装失败: $_"
        }
    } else {
        $chocoCmd = Get-Command choco -ErrorAction SilentlyContinue
        if ($chocoCmd) {
            Write-LogInfo "使用 Chocolatey 安装 Node.js LTS..."
            try {
                $result = Invoke-CommandLogged -Description "choco install nodejs-lts" -Command "choco" -Arguments @("install", "nodejs-lts", "-y")
            } catch {
                Write-LogError "Chocolatey 安装失败: $_"
            }
        } else {
            Write-LogError "未找到 winget 或 Chocolatey，无法自动安装 Node.js"
            Write-LogInfo "请访问 https://nodejs.org 手动下载安装"
            return $false
        }
    }

    # 刷新 PATH
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")

    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCmd) {
        $nodeVer = & node --version 2>$null
        $majorStr = $nodeVer -replace '^v', '' -replace '\..*', ''
        $major = [int]$majorStr
        if ($major -ge $script:RequiredNodeMajor) {
            Write-LogSuccess "Node.js 安装完成: $nodeVer"
            Write-LogWarn "请重新打开终端以确保 PATH 生效"
            return $true
        }
    }

    Write-LogError "Node.js 安装后验证失败"
    Write-LogInfo "请关闭并重新打开 PowerShell 终端后重试"
    return $false
}

function Test-NpmOrPnpm {
    Write-LogStep "检测包管理器"

    if ($UsePnpm) {
        $pnpmCmd = Get-Command pnpm -ErrorAction SilentlyContinue
        if ($pnpmCmd) {
            $pnpmVer = & pnpm --version 2>$null
            Write-LogSuccess "pnpm $pnpmVer"
            Write-LogDebug "pnpm 路径: $($pnpmCmd.Source)"
        } else {
            Write-LogWarn "pnpm 未安装，正在安装..."
            try {
                & npm install -g pnpm 2>$null | Out-Null
                $pnpmVer = & pnpm --version 2>$null
                Write-LogSuccess "pnpm 安装完成: $pnpmVer"
            } catch {
                Write-LogError "pnpm 安装失败，回退到 npm"
                $script:UsePnpmFallback = $true
            }
        }
    }

    $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
    if ($npmCmd) {
        $npmVer = & npm --version 2>$null
        Write-LogSuccess "npm $npmVer"
        Write-LogDebug "npm 路径: $($npmCmd.Source)"
        try {
            $npmPrefix = & npm prefix -g 2>$null
            Write-LogDebug "npm 全局前缀: $npmPrefix"
        } catch {}
    } else {
        Write-LogError "npm 未找到"
        if (-not $UsePnpm) {
            return $false
        }
    }
    return $true
}

function Test-NonAsciiPath {
    Write-LogStep "检测用户名路径兼容性"

    $userProfile = $env:USERPROFILE
    $hasNonAscii = $userProfile -match '[^\x00-\x7F]'

    if ($hasNonAscii) {
        Write-LogWarn "检测到用户目录包含非 ASCII 字符（如中文）: $userProfile"
        Write-LogWarn "这会导致 npm 全局安装失败，将自动切换全局目录"

        $safePath = $script:SafeNpmPrefix
        if (-not (Test-Path $safePath)) {
            try {
                New-Item -Path $safePath -ItemType Directory -Force | Out-Null
                Write-LogDebug "已创建安全目录: $safePath"
            } catch {
                Write-LogError "无法创建目录 ${safePath}: $_"
                Write-LogInfo "请以管理员身份运行，或手动创建此目录后重试"
                return $false
            }
        }

        Write-LogInfo "设置 npm 全局前缀: $safePath"
        & npm config set prefix $safePath 2>$null
        $script:NpmPrefixOverride = $safePath

        $env:PATH = "$safePath;$env:PATH"
        Write-LogDebug "已将 $safePath 加入当前会话 PATH"

        $userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
        if ($userPath -notlike "*$safePath*") {
            try {
                [System.Environment]::SetEnvironmentVariable("PATH", "$safePath;$userPath", "User")
                Write-LogSuccess "已将 $safePath 永久加入用户 PATH"
            } catch {
                Write-LogWarn "无法自动添加 PATH，请手动将 $safePath 加入系统环境变量 PATH"
            }
        }

        Write-LogSuccess "npm 全局目录已切换到: $safePath"
    } else {
        Write-LogSuccess "用户路径兼容（纯 ASCII）"
    }
    return $true
}

function Test-DefenderImpact {
    Write-LogStep "检测 Windows Defender 状态"

    try {
        $defenderStatus = Get-MpPreference -ErrorAction SilentlyContinue
        if ($defenderStatus -and $defenderStatus.DisableRealtimeMonitoring -eq $false) {
            Write-LogWarn "Windows Defender 实时保护已开启"
            Write-LogInfo "npm 全局安装涉及大量小文件写入，Defender 实时扫描可能显著拖慢安装速度"
            Write-LogInfo "如果安装过程很慢（超过 5 分钟），可临时关闭实时保护："
            Write-LogInfo "  Windows 安全中心 -> 病毒和威胁防护 -> 管理设置 -> 关闭实时保护"
            Write-LogInfo "  （安装完成后请重新开启）"

            $npmGlobalDir = $script:NpmPrefixOverride
            if (-not $npmGlobalDir) {
                try { $npmGlobalDir = & npm prefix -g 2>$null } catch {}
            }
            if ($npmGlobalDir) {
                $exclusions = $defenderStatus.ExclusionPath
                if ($exclusions -and ($exclusions -contains $npmGlobalDir)) {
                    Write-LogDebug "npm 全局目录已在 Defender 排除列表中"
                } else {
                    Write-LogInfo "或者将 npm 目录加入排除项: $npmGlobalDir"
                }
            }
        } else {
            Write-LogSuccess "Windows Defender 实时保护未开启或已排除"
        }
    } catch {
        Write-LogDebug "无法检测 Windows Defender 状态（可能权限不足），跳过"
    }
}

function Test-NpmRegistry {
    Write-LogStep "检测 npm 仓库源"

    try {
        $currentRegistry = & npm config get registry 2>$null
        if ($currentRegistry) {
            $currentRegistry = $currentRegistry.Trim()
            Write-LogDebug "当前 npm 仓库源: $currentRegistry"
        }
    } catch {
        $currentRegistry = ""
    }

    if ($currentRegistry -match "registry\.npmmirror\.com|registry\.npm\.taobao\.org") {
        Write-LogSuccess "已使用国内镜像源: $currentRegistry"
        return
    }

    Write-LogDebug "测试 npm 官方仓库下载速度..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-WebRequest -Uri "https://registry.npmjs.org/openclaw" -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop | Out-Null
        $sw.Stop()
        $elapsed = $sw.ElapsedMilliseconds

        if ($elapsed -gt 3000) {
            Write-LogWarn "npm 官方仓库响应较慢 ($($elapsed)ms)"
            Write-LogInfo "建议切换到淘宝镜像加速安装:"
            Write-LogInfo "  npm config set registry https://registry.npmmirror.com"
        } else {
            Write-LogSuccess "npm 仓库连接正常 ($($elapsed)ms)"
        }
    } catch {
        Write-LogWarn "无法连接 npm 官方仓库，建议使用淘宝镜像:"
        Write-LogInfo "  npm config set registry https://registry.npmmirror.com"

        if ($env:HTTP_PROXY) { Write-LogDebug "HTTP_PROXY: $env:HTTP_PROXY" }
        if ($env:HTTPS_PROXY) { Write-LogDebug "HTTPS_PROXY: $env:HTTPS_PROXY" }
    }
}

function Test-Network {
    Write-LogStep "检测网络连接"

    Write-LogDebug "测试 openclaw.ai 连通性..."
    try {
        Invoke-WebRequest -Uri "https://openclaw.ai" -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop | Out-Null
        Write-LogSuccess "openclaw.ai 连接正常"
    } catch {
        Write-LogWarn "无法连接到 openclaw.ai（不影响 npm 安装）"
    }
}

function Test-DiskSpace {
    Write-LogStep "检测磁盘空间"

    try {
        $drive = Get-PSDrive -Name C -ErrorAction Stop
        $freeMB = [math]::Round($drive.Free / 1MB)
        $freeGB = [math]::Round($drive.Free / 1GB, 1)
        Write-LogDebug "可用空间: $freeMB MB ($freeGB GB)"

        if ($freeMB -lt 500) {
            Write-LogError "磁盘空间不足: 仅剩 $freeMB MB（建议至少 500 MB）"
            return $false
        } elseif ($freeMB -lt 1024) {
            Write-LogWarn "磁盘空间较低: $freeMB MB（建议至少 1 GB）"
        } else {
            Write-LogSuccess "可用空间: $freeGB GB"
        }
    } catch {
        Write-LogWarn "无法检测磁盘空间"
    }
    return $true
}

function Test-ExistingInstall {
    Write-LogStep "检测已有安装"

    $openclawCmd = Get-Command openclaw -ErrorAction SilentlyContinue
    if ($openclawCmd) {
        try {
            $currentVer = & openclaw --version 2>$null
        } catch {
            $currentVer = "未知"
        }
        Write-LogWarn "检测到已安装的 OpenClaw: $currentVer"
        Write-LogDebug "安装路径: $($openclawCmd.Source)"
        Write-Log "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INFO]  已有安装: version=$currentVer path=$($openclawCmd.Source)"

        Write-Host ""
        Write-Host "  检测到已安装的 OpenClaw ($currentVer)" -ForegroundColor Yellow
        Write-Host "  继续安装将升级到最新版本。"
        Write-Host ""
        $confirm = Read-Host "  是否继续？(Y/n)"
        if ($confirm -eq "n" -or $confirm -eq "N") {
            Write-LogInfo "用户取消安装"
            exit 0
        }
        Write-LogInfo "用户确认继续安装（升级）"
    } else {
        Write-LogSuccess "未检测到已有安装，将进行全新安装"
    }
}

# ─────────────────────────────────────────────
# 清理上次失败的安装残留
# ─────────────────────────────────────────────
function Remove-StaleInstall {
    $npmGlobalDir = $script:NpmPrefixOverride
    if (-not $npmGlobalDir) {
        try { $npmGlobalDir = & npm prefix -g 2>$null } catch { return }
    }
    $staleDir = Join-Path $npmGlobalDir "node_modules\openclaw"
    if (Test-Path $staleDir) {
        Write-LogInfo "清理上次安装残留: $staleDir"
        try {
            & taskkill /F /IM node.exe 2>$null | Out-Null
        } catch {}
        Start-Sleep -Milliseconds 500
        try {
            Remove-Item -Recurse -Force $staleDir -ErrorAction Stop
            Write-LogSuccess "残留目录已清理"
        } catch {
            Write-LogWarn "残留目录清理失败: $_"
            Write-LogInfo "请手动删除后重试: Remove-Item -Recurse -Force '$staleDir'"
        }
    }
}

# ─────────────────────────────────────────────
# 安装 OpenClaw
# ─────────────────────────────────────────────
function Install-OpenClaw {
    Write-LogStep "安装 OpenClaw CLI"

    Remove-StaleInstall

    $pkg = switch ($Channel) {
        "stable" { "openclaw@latest" }
        "beta"   { "openclaw@beta" }
        "dev"    { "openclaw@latest" }
    }

    Write-LogInfo "安装包: $pkg"
    $usePnpmActual = $UsePnpm -and (-not $script:UsePnpmFallback)
    Write-Log "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INSTALL] 安装 $pkg (管理器: $(if ($usePnpmActual) { 'pnpm' } else { 'npm' }))"

    $env:SHARP_IGNORE_GLOBAL_LIBVIPS = "1"
    Write-LogDebug "已设置 SHARP_IGNORE_GLOBAL_LIBVIPS=1"

    $installExit = 0

    if ($usePnpmActual) {
        Write-LogInfo "使用 pnpm 安装..."

        Write-LogDebug "第一次安装..."
        $r = Invoke-CommandLogged -Description "pnpm add -g $pkg (首次)" -Command "pnpm" -Arguments @("add", "-g", $pkg)
        $installExit = $r.ExitCode

        Write-LogDebug "运行 pnpm approve-builds..."
        try { & pnpm approve-builds -g 2>$null | Out-Null } catch {}

        Write-LogDebug "第二次安装..."
        $r = Invoke-CommandLogged -Description "pnpm add -g $pkg (二次)" -Command "pnpm" -Arguments @("add", "-g", $pkg)
        $installExit = $r.ExitCode
        $installOutput = $r.Output
    } else {
        Write-LogInfo "使用 npm 安装（--ignore-scripts 模式，跳过原生模块编译）..."
        Write-LogInfo "首次安装通常需要 2~5 分钟，请耐心等待..."

        $r = Invoke-CommandLogged -Description "npm install -g $pkg --ignore-scripts" -Command "npm" -Arguments @("install", "-g", $pkg, "--ignore-scripts")
        $installExit = $r.ExitCode
        $installOutput = $r.Output
    }

    if ($installExit -ne 0) {
        Write-LogError "OpenClaw 安装失败（退出码: $installExit）"
        Write-Log "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INSTALL] 失败详情: exit=$installExit"

        if ($installOutput -match "(?i)EACCES|EPERM|permission denied|operation not permitted") {
            Write-LogError "权限不足。请尝试以管理员身份运行 PowerShell"
        }
        if ($installOutput -match "(?i)sharp") {
            Write-LogError "sharp 模块安装失败"
        }
        if ($installOutput -match "(?i)node-gyp|gyp ERR") {
            Write-LogError "node-gyp 编译失败。请安装 Visual Studio Build Tools:"
            Write-LogError "  npm install -g windows-build-tools"
        }
        if ($installOutput -match "(?i)node-llama-cpp|3221225477") {
            Write-LogWarn "node-llama-cpp 原生模块编译崩溃（已自动跳过，不影响核心功能）"
        }

        Write-LogError "详细信息请查看日志: $script:LogFile"
        return $false
    }

    Write-LogSuccess "OpenClaw CLI 安装完成"
    return $true
}

# ─────────────────────────────────────────────
# 验证安装
# ─────────────────────────────────────────────
function Test-Installation {
    Write-LogStep "验证安装"

    # 刷新 PATH
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")

    $openclawCmd = Get-Command openclaw -ErrorAction SilentlyContinue
    if ($openclawCmd) {
        try {
            $ver = & openclaw --version 2>$null
        } catch {
            $ver = "版本获取失败"
        }
        Write-LogSuccess "openclaw 命令可用: $ver"
        Write-LogDebug "安装路径: $($openclawCmd.Source)"
        Write-Log "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [VERIFY] openclaw version=$ver path=$($openclawCmd.Source)"
    } else {
        Write-LogError "openclaw 命令不在 PATH 中"
        try {
            $npmPrefix = & npm prefix -g 2>$null
            Write-LogError "请检查 PATH 是否包含: $npmPrefix"
            Write-LogError "通常为: $env:APPDATA\npm"
        } catch {}
        Write-Log "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [VERIFY] FAILED - openclaw 不在 PATH 中"
        return $false
    }

    Write-LogInfo "跳过 openclaw doctor（安装后可随时手动运行: openclaw doctor）"
    $script:InstallSuccess = $true
    return $true
}

# ─────────────────────────────────────────────
# 运行引导向导
# ─────────────────────────────────────────────
function Start-Onboard {
    Write-LogStep "运行引导向导"

    if ($SkipOnboard) {
        Write-LogInfo "已跳过引导向导（-SkipOnboard）"
        Write-LogInfo "稍后可手动运行: openclaw onboard --install-daemon"
        return
    }

    Write-LogInfo "启动引导向导..."
    Write-LogInfo "引导向导将帮助你配置 AI 提供商、消息渠道和后台服务"
    Write-LogInfo "（按照终端提示操作即可）"
    Write-Host ""

    Write-Log "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [ONBOARD] 启动引导向导"

    try {
        & openclaw onboard --install-daemon 2>&1 | Tee-Object -Append -FilePath $script:LogFile
        Write-LogSuccess "引导向导完成"
    } catch {
        Write-LogWarn "引导向导退出"
        Write-LogInfo "你可以稍后重新运行: openclaw onboard --install-daemon"
        Write-Log "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [ONBOARD] 异常: $_"
    }
}

# ─────────────────────────────────────────────
# 最终报告
# ─────────────────────────────────────────────
function Show-Summary {
    Write-Host ""
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss K"
    Write-Log ""
    Write-Log "==================================================="
    Write-Log "  安装结束: $ts"
    Write-Log "  结果: $(if ($script:InstallSuccess) { '成功' } else { '失败' })"
    Write-Log "==================================================="

    if ($script:InstallSuccess) {
        Write-Host ""
        Write-Host "+==================================================+" -ForegroundColor Green
        Write-Host "|        + OpenClaw 安装成功！                      |" -ForegroundColor Green
        Write-Host "+==================================================+" -ForegroundColor Green
        Write-Host ""

        Write-Host "快速开始:" -ForegroundColor White
        Write-Host ""
        Write-Host "  # 检查状态" -ForegroundColor Cyan
        Write-Host "  openclaw status"
        Write-Host ""
        Write-Host "  # 启动 Gateway（前台）" -ForegroundColor Cyan
        Write-Host "  openclaw gateway --port 18789 --verbose"
        Write-Host ""
        Write-Host "  # 与助手对话" -ForegroundColor Cyan
        Write-Host '  openclaw agent --message "你好" --thinking high'
        Write-Host ""
        Write-Host "  # 打开 Dashboard" -ForegroundColor Cyan
        Write-Host '  Start-Process "http://127.0.0.1:18789/"'
        Write-Host ""
        Write-Host "  # 运行诊断" -ForegroundColor Cyan
        Write-Host "  openclaw doctor"
        Write-Host ""

        if ($SkipOnboard) {
            Write-Host "提示: 你跳过了引导向导，请运行以下命令完成配置:" -ForegroundColor Yellow
            Write-Host "  openclaw onboard --install-daemon"
            Write-Host ""
        }
    } else {
        Write-Host ""
        Write-Host "+==================================================+" -ForegroundColor Red
        Write-Host "|        X OpenClaw 安装未完成                      |" -ForegroundColor Red
        Write-Host "+==================================================+" -ForegroundColor Red
        Write-Host ""

        Write-Host "排查建议:" -ForegroundColor White
        Write-Host ""
        Write-Host "  1. 查看详细日志:"
        Write-Host "     $script:LogFile" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  2. 检查系统要求:"
        Write-Host "     - Node.js >=22: node --version"
        Write-Host ""
        Write-Host "  3. 手动安装尝试:"
        Write-Host "     npm install -g openclaw@latest --ignore-scripts"
        Write-Host ""
        Write-Host "  4. 中文用户名导致安装失败？" -ForegroundColor Yellow
        Write-Host "     mkdir C:\npm-global"
        Write-Host '     npm config set prefix "C:\npm-global"'
        Write-Host "     npm install -g openclaw@latest --ignore-scripts"
        Write-Host ""
        Write-Host "  5. 下载太慢？使用淘宝镜像:"
        Write-Host "     npm config set registry https://registry.npmmirror.com"
        Write-Host ""
        Write-Host "  6. 获取帮助:"
        Write-Host "     - 文档: https://docs.openclaw.ai"
        Write-Host "     - GitHub: https://github.com/openclaw/openclaw"
        Write-Host "     - Discord: https://discord.gg/clawd"
        Write-Host ""
    }

    Write-Host "安装日志: " -NoNewline -ForegroundColor White
    Write-Host $script:LogFile -ForegroundColor Cyan
    Write-Host ""
}

# ─────────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────────
function Main {
    if ($ShowHelp) { Show-Help }

    # 初始化日志
    New-Item -Path $script:LogFile -ItemType File -Force | Out-Null
    Save-SystemInfo

    Write-Host ""
    Write-Host "+==================================================+" -ForegroundColor Cyan
    Write-Host "|        OpenClaw Windows 安装程序                  |" -ForegroundColor Cyan
    Write-Host "|        https://openclaw.ai                       |" -ForegroundColor Cyan
    Write-Host "+==================================================+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  日志文件: " -NoNewline
    Write-Host $script:LogFile -ForegroundColor Cyan
    Write-Host ""

    # 计算步骤数: OS + Node + npm + 路径检测 + npm源 + Defender + 网络 + 磁盘 + 已有安装 + 安装 + 验证 [+ 引导]
    $script:StepsTotal = 12
    if (-not $SkipOnboard) { $script:StepsTotal = 13 }

    # 环境检测
    Test-Windows

    if (-not (Test-NodeJs)) {
        Show-Summary
        exit 1
    }

    if (-not (Test-NpmOrPnpm)) {
        Show-Summary
        exit 1
    }

    if (-not (Test-NonAsciiPath)) {
        Show-Summary
        exit 1
    }

    Test-NpmRegistry
    Test-DefenderImpact
    Test-Network

    if (-not (Test-DiskSpace)) {
        Show-Summary
        exit 1
    }

    Test-ExistingInstall

    # 安装阶段
    if (-not (Install-OpenClaw)) {
        Show-Summary
        exit 1
    }

    if (-not (Test-Installation)) {
        Show-Summary
        exit 1
    }

    # 引导向导
    if (-not $SkipOnboard) {
        Start-Onboard
    }

    # 最终报告
    Show-Summary
}

# 执行
try {
    Main
} catch {
    Write-Log "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [FATAL] 脚本异常: $_"
    Write-Host ""
    Write-Host "  X  安装过程中发生错误: $_" -ForegroundColor Red
    Write-Host "  X  请查看日志: $script:LogFile" -ForegroundColor Red
    exit 1
}
