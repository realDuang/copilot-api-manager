#Requires -Version 5.1
<#
.SYNOPSIS
    GitHub Copilot API 独立管理工具
.DESCRIPTION
    完全独立运行，可放在任何位置使用
    工作目录为脚本所在目录
    支持服务守护进程，自动检测故障并重启
.NOTES
    Version: 3.0 (with Watchdog)
    Author: Halo
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 配置变量
$script:Port = 4141
$script:WorkDir = $PSScriptRoot  # 使用脚本所在目录
$script:LogFile = Join-Path $script:WorkDir "copilot-api.log"
$script:WatchdogLogFile = Join-Path $script:WorkDir "watchdog.log"
$script:ServiceUrl = "http://localhost:$Port"
$script:HealthCheckInterval = 30  # Health check interval in seconds
$script:MaxRestartAttempts = 5    # Maximum restart attempts within cooldown period
$script:RestartCooldown = 300     # Cooldown period in seconds (5 minutes)

# 模型配置方案
$script:ModelPresets = @{
    "1" = @{
        Name = "gpt-5.1-codex (Sonnet) + gpt-5-mini (Haiku)"
        Sonnet = "gpt-5.1-codex"
        Haiku = "gpt-5-mini"
        Category = "OpenAI GPT-5 系列"
    }
    "2" = @{
        Name = "gpt-5.2 (Sonnet) + gpt-5-mini (Haiku)"
        Sonnet = "gpt-5.2"
        Haiku = "gpt-5-mini"
        Category = "OpenAI GPT-5 系列"
    }
    "3" = @{
        Name = "gpt-5 (Sonnet) + gpt-5-mini (Haiku)"
        Sonnet = "gpt-5"
        Haiku = "gpt-5-mini"
        Category = "OpenAI GPT-5 系列"
    }
    "4" = @{
        Name = "gpt-4.1 (Sonnet) + gpt-4o-mini (Haiku)"
        Sonnet = "gpt-4.1"
        Haiku = "gpt-4o-mini"
        Category = "OpenAI GPT-4 系列"
    }
    "5" = @{
        Name = "gpt-4o (Sonnet) + gpt-4o-mini (Haiku)"
        Sonnet = "gpt-4o"
        Haiku = "gpt-4o-mini"
        Category = "OpenAI GPT-4 系列"
    }
    "6" = @{
        Name = "claude-sonnet-4.5 (Sonnet) + claude-haiku-4.5 (Haiku) [推荐]"
        Sonnet = "claude-sonnet-4.5"
        Haiku = "claude-haiku-4.5"
        Category = "Anthropic Claude 系列"
    }
    "7" = @{
        Name = "claude-opus-4.5 (Sonnet) + claude-haiku-4.5 (Haiku)"
        Sonnet = "claude-opus-4.5"
        Haiku = "claude-haiku-4.5"
        Category = "Anthropic Claude 系列"
    }
    "8" = @{
        Name = "gemini-2.5-pro (Sonnet) + gemini-3-flash-preview (Haiku)"
        Sonnet = "gemini-2.5-pro"
        Haiku = "gemini-3-flash-preview"
        Category = "Google Gemini 系列"
    }
}

# 辅助函数
function Write-Title {
    param([string]$Title)
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host ""
}

function Clear-HostSafe {
    # Only clear host if running in an interactive terminal
    try {
        if ($Host.UI.RawUI.WindowSize.Width -gt 0) {
            Clear-Host
        }
    }
    catch {
        # Not in interactive terminal, skip clear
    }
}

function Write-Success {
    param([string]$Message)
    Write-Host "[✓] $Message" -ForegroundColor Green
}

function Write-Error {
    param([string]$Message)
    Write-Host "[×] $Message" -ForegroundColor Red
}

function Write-Warning {
    param([string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Message)
    Write-Host "[i] $Message" -ForegroundColor Blue
}

function Test-PortInUse {
    param([int]$Port)
    $connections = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    return $null -ne $connections
}

function Write-WatchdogLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $script:WatchdogLogFile -Value $logEntry -ErrorAction SilentlyContinue
}

function Test-ServiceHealth {
    # Check if port is in use
    if (-not (Test-PortInUse -Port $script:Port)) {
        return @{ Healthy = $false; Reason = "Port not listening" }
    }
    
    # Check API responsiveness
    try {
        $response = Invoke-WebRequest -Uri "$script:ServiceUrl/v1/models" -TimeoutSec 10 -ErrorAction Stop
        if ($response.StatusCode -eq 200) {
            return @{ Healthy = $true; Reason = "OK" }
        }
        return @{ Healthy = $false; Reason = "Unexpected status code: $($response.StatusCode)" }
    }
    catch {
        return @{ Healthy = $false; Reason = "API request failed: $($_.Exception.Message)" }
    }
}

function Start-ServiceInternal {
    # Start service without user interaction (for watchdog use)
    try {
        $vbsContent = "Set WshShell = CreateObject(""WScript.Shell"")" + [Environment]::NewLine
        $vbsContent += "WshShell.CurrentDirectory = ""$script:WorkDir""" + [Environment]::NewLine
        $vbsContent += "WshShell.Run ""cmd /c npx -y copilot-api@latest start --port $script:Port >> copilot-api.log 2>&1"", 0, False"
        
        $vbsFile = Join-Path $env:TEMP "start-copilot-api.vbs"
        $vbsContent | Out-File -FilePath $vbsFile -Encoding ASCII
        Start-Process -FilePath "cscript.exe" -ArgumentList "//nologo", "`"$vbsFile`"" -WindowStyle Hidden
        Start-Sleep -Milliseconds 500
        Remove-Item $vbsFile -Force -ErrorAction SilentlyContinue
        
        # Wait for service to start (max 15 seconds)
        $maxAttempts = 15
        $attempt = 0
        while ($attempt -lt $maxAttempts) {
            Start-Sleep -Seconds 1
            if (Test-PortInUse -Port $script:Port) {
                return $true
            }
            $attempt++
        }
        return $false
    }
    catch {
        return $false
    }
}

function Stop-ServiceInternal {
    # Stop service without user interaction (for watchdog use)
    $process = Get-ServiceProcess
    if ($null -ne $process) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            Start-Sleep -Milliseconds 500
            return $true
        }
        catch {
            return $false
        }
    }
    return $true
}

function Start-WatchdogInternal {
    # Stop existing watchdog if any
    Stop-WatchdogInternal
    Start-Sleep -Milliseconds 500
    
    # Create the watchdog script content
    $watchdogScript = @"
# Copilot API Watchdog Script
# Auto-generated - do not modify directly

`$ErrorActionPreference = "Continue"
`$Port = $script:Port
`$WorkDir = "$($script:WorkDir -replace '\\', '\\')"
`$LogFile = "$($script:WatchdogLogFile -replace '\\', '\\')"
`$ServiceUrl = "$script:ServiceUrl"
`$HealthCheckInterval = 10
`$MaxRestartAttempts = $script:MaxRestartAttempts
`$RestartCooldown = $script:RestartCooldown
`$HeartbeatInterval = 30

function Write-Log {
    param([string]`$Message, [string]`$Level = "INFO")
    try {
        `$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path `$LogFile -Value "[`$timestamp] [`$Level] `$Message" -ErrorAction SilentlyContinue
    } catch {}
}

function Test-PortInUse {
    param([int]`$Port)
    try {
        `$connections = Get-NetTCPConnection -LocalPort `$Port -State Listen -ErrorAction SilentlyContinue
        return `$null -ne `$connections
    } catch { return `$false }
}

function Test-ServiceHealth {
    try {
        if (-not (Test-PortInUse -Port `$Port)) {
            return @{ Healthy = `$false; Reason = "Port not listening" }
        }
        `$response = Invoke-WebRequest -Uri "`$ServiceUrl/v1/models" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        if (`$response.StatusCode -eq 200) { return @{ Healthy = `$true; Reason = "OK" } }
        return @{ Healthy = `$false; Reason = "Status: `$(`$response.StatusCode)" }
    }
    catch {
        `$msg = `$_.Exception.Message
        if (`$msg.Length -gt 80) { `$msg = `$msg.Substring(0, 80) }
        return @{ Healthy = `$false; Reason = `$msg }
    }
}

function Start-CopilotService {
    try {
        Write-Log "Starting service..." "INFO"
        `$vbsContent = "Set WshShell = CreateObject(""WScript.Shell"")" + [Environment]::NewLine
        `$vbsContent += "WshShell.CurrentDirectory = ""`$WorkDir""" + [Environment]::NewLine
        `$vbsContent += "WshShell.Run ""cmd /c npx -y copilot-api@latest start --port `$Port >> copilot-api.log 2>&1"", 0, False"
        
        `$vbsFile = Join-Path `$env:TEMP "start-copilot-api.vbs"
        `$vbsContent | Out-File -FilePath `$vbsFile -Encoding ASCII
        Start-Process -FilePath "cscript.exe" -ArgumentList "//nologo", "```"`$vbsFile```"" -WindowStyle Hidden
        Start-Sleep -Milliseconds 500
        Remove-Item `$vbsFile -Force -ErrorAction SilentlyContinue
        
        for (`$i = 0; `$i -lt 30; `$i++) {
            Start-Sleep -Seconds 1
            if (Test-PortInUse -Port `$Port) { return `$true }
        }
        return `$false
    }
    catch {
        Write-Log "Start exception: `$(`$_.Exception.Message)" "ERROR"
        return `$false
    }
}

function Stop-CopilotService {
    try {
        `$connections = Get-NetTCPConnection -LocalPort `$Port -State Listen -ErrorAction SilentlyContinue
        if (`$connections) {
            foreach (`$conn in `$connections) {
                `$proc = Get-Process -Id `$conn.OwningProcess -ErrorAction SilentlyContinue
                if (`$proc) {
                    Get-CimInstance Win32_Process -Filter "ParentProcessId = `$(`$proc.Id)" -ErrorAction SilentlyContinue | 
                        ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }
                    Stop-Process -Id `$proc.Id -Force -ErrorAction SilentlyContinue
                }
            }
            Start-Sleep -Milliseconds 1000
        }
    } catch {
        Write-Log "Stop exception: `$(`$_.Exception.Message)" "ERROR"
    }
}

# Main watchdog loop with exception handling
Write-Log "Watchdog started (PID: `$PID)" "INFO"
`$restartTimes = @()
`$lastHeartbeat = Get-Date

try {
    while (`$true) {
        try {
            Start-Sleep -Seconds `$HealthCheckInterval
            
            if (((Get-Date) - `$lastHeartbeat).TotalSeconds -ge `$HeartbeatInterval) {
                Write-Log "Heartbeat: alive" "DEBUG"
                `$lastHeartbeat = Get-Date
            }
            
            `$health = Test-ServiceHealth
            
            if (-not `$health.Healthy) {
                Write-Log "Health failed: `$(`$health.Reason)" "WARN"
                
                `$now = Get-Date
                `$restartTimes = @(`$restartTimes | Where-Object { (`$now - `$_).TotalSeconds -lt `$RestartCooldown })
                
                if (`$restartTimes.Count -ge `$MaxRestartAttempts) {
                    Write-Log "Rate limit exceeded" "ERROR"
                    continue
                }
                
                Write-Log "Restarting (`$(`$restartTimes.Count + 1)/`$MaxRestartAttempts)..." "WARN"
                Stop-CopilotService
                Start-Sleep -Seconds 2
                
                if (Start-CopilotService) {
                    Write-Log "Restarted OK" "INFO"
                    `$restartTimes += `$now
                } else {
                    Write-Log "Restart failed" "ERROR"
                }
            }
        }
        catch {
            Write-Log "Loop error: `$(`$_.Exception.Message)" "ERROR"
            Start-Sleep -Seconds 5
        }
    }
}
catch {
    Write-Log "Fatal: `$(`$_.Exception.Message)" "FATAL"
}
finally {
    Write-Log "Watchdog stopped" "WARN"
}
"@
    
    # Save watchdog script
    $watchdogScriptPath = Join-Path $script:WorkDir "copilot-watchdog.ps1"
    $watchdogScript | Out-File -FilePath $watchdogScriptPath -Encoding UTF8
    
    # Start watchdog in background
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "powershell.exe"
    $startInfo.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchdogScriptPath`""
    $startInfo.CreateNoWindow = $true
    $startInfo.UseShellExecute = $false
    
    $process = [System.Diagnostics.Process]::Start($startInfo)
    
    if ($process) {
        Write-Success "守护进程已启动 (PID: $($process.Id))"
        return $true
    }
    return $false
}

function Stop-WatchdogInternal {
    $watchdogProcesses = Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | 
        Where-Object { $_.CommandLine -match "copilot-watchdog\.ps1" }
    
    if ($watchdogProcesses) {
        foreach ($proc in $watchdogProcesses) {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-WatchdogRunning {
    $watchdogProcesses = Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | 
        Where-Object { $_.CommandLine -match "copilot-watchdog\.ps1" }
    return $null -ne $watchdogProcesses
}

function Get-ServiceProcess {
    $connections = Get-NetTCPConnection -LocalPort $script:Port -State Listen -ErrorAction SilentlyContinue
    if ($connections) {
        return Get-Process -Id $connections[0].OwningProcess -ErrorAction SilentlyContinue
    }
    return $null
}

function Show-ModelSelectionMenu {
    param([string]$Title = "配置全局环境变量")

    Clear-HostSafe
    Write-Title $Title
    Write-Host "请选择模型配置方案：" -ForegroundColor White
    Write-Host ""

    # 按类别分组显示
    $categories = $script:ModelPresets.Values | Select-Object -ExpandProperty Category -Unique
    foreach ($category in $categories) {
        Write-Host "  === $category ===" -ForegroundColor Yellow
        $script:ModelPresets.GetEnumerator() | Where-Object { $_.Value.Category -eq $category } | ForEach-Object {
            $key = $_.Key
            $name = $_.Value.Name
            if ($name -match "\[推荐\]") {
                Write-Host "  $key. $name" -ForegroundColor Green
            } else {
                Write-Host "  $key. $name"
            }
        }
        Write-Host ""
    }

    Write-Host "  === 其他 ===" -ForegroundColor Yellow
    Write-Host "  9. 自定义模型"
    Write-Host "  0. 返回主菜单"
    Write-Host ""

    $choice = Read-Host "请选择 (0-9)"
    return $choice
}

function Set-EnvironmentVariables {
    param(
        [string]$SonnetModel,
        [string]$HaikuModel
    )

    Write-Host ""
    Write-Host "将设置以下环境变量（用户级）：" -ForegroundColor White
    Write-Host ""
    Write-Host "  ANTHROPIC_BASE_URL = $script:ServiceUrl"
    Write-Host "  ANTHROPIC_AUTH_TOKEN = dummy"
    Write-Host "  ANTHROPIC_MODEL = $SonnetModel"
    Write-Host "  ANTHROPIC_DEFAULT_SONNET_MODEL = $SonnetModel"
    Write-Host "  ANTHROPIC_SMALL_FAST_MODEL = $HaikuModel"
    Write-Host "  ANTHROPIC_DEFAULT_HAIKU_MODEL = $HaikuModel"
    Write-Host "  DISABLE_NON_ESSENTIAL_MODEL_CALLS = 1"
    Write-Host "  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = 1"
    Write-Host ""
    Write-Host "配置后，所有工作目录的 Claude Code 都将使用 Copilot API" -ForegroundColor Yellow
    Write-Host ""

    $confirm = Read-Host "确认设置全局环境变量? (Y/N)"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Warning "操作已取消"
        return $false
    }

    Write-Host ""
    Write-Host "[开始设置环境变量]" -ForegroundColor Cyan

    try {
        [Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", $script:ServiceUrl, "User")
        Write-Success "ANTHROPIC_BASE_URL"

        [Environment]::SetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", "dummy", "User")
        Write-Success "ANTHROPIC_AUTH_TOKEN"

        [Environment]::SetEnvironmentVariable("ANTHROPIC_MODEL", $SonnetModel, "User")
        Write-Success "ANTHROPIC_MODEL"

        [Environment]::SetEnvironmentVariable("ANTHROPIC_DEFAULT_SONNET_MODEL", $SonnetModel, "User")
        Write-Success "ANTHROPIC_DEFAULT_SONNET_MODEL"

        [Environment]::SetEnvironmentVariable("ANTHROPIC_SMALL_FAST_MODEL", $HaikuModel, "User")
        Write-Success "ANTHROPIC_SMALL_FAST_MODEL"

        [Environment]::SetEnvironmentVariable("ANTHROPIC_DEFAULT_HAIKU_MODEL", $HaikuModel, "User")
        Write-Success "ANTHROPIC_DEFAULT_HAIKU_MODEL"

        [Environment]::SetEnvironmentVariable("DISABLE_NON_ESSENTIAL_MODEL_CALLS", "1", "User")
        Write-Success "DISABLE_NON_ESSENTIAL_MODEL_CALLS"

        [Environment]::SetEnvironmentVariable("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1", "User")
        Write-Success "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"

        Write-Host ""
        Write-Title "✓ 环境变量设置完成！"
        Write-Host "重要提示：" -ForegroundColor Yellow
        Write-Host "  1. 需要重启所有已打开的命令行窗口"
        Write-Host "  2. 需要重启 IDE/编辑器（如 VS Code）"
        Write-Host "  3. 重启后，所有工作目录都会使用 Copilot API"
        Write-Host ""

        return $true
    }
    catch {
        Write-Error "设置环境变量失败: $_"
        return $false
    }
}

function Remove-EnvironmentVariables {
    Clear-HostSafe
    Write-Title "清除全局环境变量"

    Write-Host "此操作将删除以下环境变量：" -ForegroundColor White
    Write-Host ""
    Write-Host "  ANTHROPIC_BASE_URL"
    Write-Host "  ANTHROPIC_AUTH_TOKEN"
    Write-Host "  ANTHROPIC_MODEL"
    Write-Host "  ANTHROPIC_DEFAULT_SONNET_MODEL"
    Write-Host "  ANTHROPIC_SMALL_FAST_MODEL"
    Write-Host "  ANTHROPIC_DEFAULT_HAIKU_MODEL"
    Write-Host "  DISABLE_NON_ESSENTIAL_MODEL_CALLS"
    Write-Host "  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
    Write-Host ""
    Write-Host "清除后，Claude Code 将恢复使用 Anthropic 官方 API" -ForegroundColor Yellow
    Write-Host ""

    $confirm = Read-Host "确认清除全局环境变量? (Y/N)"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Warning "操作已取消"
        return
    }

    Write-Host ""
    Write-Host "[开始清除环境变量]" -ForegroundColor Cyan

    $variables = @(
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "DISABLE_NON_ESSENTIAL_MODEL_CALLS",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
    )

    foreach ($var in $variables) {
        try {
            [Environment]::SetEnvironmentVariable($var, $null, "User")
            Write-Success "$var 已删除"
        }
        catch {
            Write-Warning "$var 删除失败或不存在"
        }
    }

    Write-Host ""
    Write-Title "✓ 环境变量清除完成！"
    Write-Host "重要提示：" -ForegroundColor Yellow
    Write-Host "  1. 需要重启所有已打开的命令行窗口"
    Write-Host "  2. 需要重启 IDE/编辑器（如 VS Code）"
    Write-Host "  3. 重启后将使用 Anthropic 官方 API"
    Write-Host ""
}

function Start-CopilotService {
    Clear-HostSafe
    Write-Title "启动 Copilot API 服务"

    # 检查 Node.js
    Write-Info "[1/4] 检查 Node.js..."
    try {
        $nodeVersion = node --version 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Node.js $nodeVersion"
        }
        else {
            throw "Node.js 未找到"
        }
    }
    catch {
        Write-Error "未找到 Node.js，请先安装 Node.js"
        Write-Host ""
        Write-Host "下载地址: https://nodejs.org/" -ForegroundColor Cyan
        return
    }

    # 检查并安装 copilot-api（避免交互式提示）
    Write-Info "[2/4] 检查 copilot-api 包..."
    try {
        # 使用 -y 参数自动确认安装
        $null = cmd /c "npx -y copilot-api@latest --version 2>&1"
        Write-Success "copilot-api 已就绪"
    }
    catch {
        Write-Warning "无法验证 copilot-api 状态，将尝试继续启动"
    }

    # 检查是否已有实例在运行
    Write-Info "[3/4] 检查服务状态..."
    if (Test-PortInUse -Port $script:Port) {
        Write-Warning "端口 $script:Port 已被占用，服务可能已在运行"
        Write-Host ""
        $restart = Read-Host "是否要停止现有服务并重启? (Y/N)"
        if ($restart -eq 'Y' -or $restart -eq 'y') {
            Stop-CopilotService -Silent
            Start-Sleep -Seconds 2
        }
        else {
            Write-Warning "操作已取消"
            return
        }
    }
    Write-Success "端口检查完成"

    # 启动服务（后台运行）
    Write-Info "[4/4] 启动 Copilot API 服务器..."
    Write-Host ""

    try {
        # 使用 VBScript 后台启动服务，使用 -y 避免交互提示
        $vbsScript = @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.CurrentDirectory = "$script:WorkDir"
WshShell.Run "cmd /c npx -y copilot-api@latest start --port $script:Port > copilot-api.log 2>&1", 0, False
"@

        $vbsFile = Join-Path $env:TEMP "start-copilot-api.vbs"
        $vbsScript | Out-File -FilePath $vbsFile -Encoding ASCII

        # 不使用 -Wait，让 VBS 异步执行
        Start-Process -FilePath "cscript.exe" -ArgumentList "//nologo", "`"$vbsFile`"" -WindowStyle Hidden

        # 等待一小段时间让 VBS 启动
        Start-Sleep -Milliseconds 500
        Remove-Item $vbsFile -Force -ErrorAction SilentlyContinue

        Write-Info "等待服务启动..."

        # 多次尝试检测端口（最多 15 秒，首次启动可能需要下载）
        $maxAttempts = 15
        $attempt = 0
        $serviceStarted = $false

        while ($attempt -lt $maxAttempts) {
            Start-Sleep -Seconds 1
            if (Test-PortInUse -Port $script:Port) {
                $serviceStarted = $true
                break
            }
            $attempt++
            if ($attempt % 3 -eq 0) {
                Write-Host "." -NoNewline
            }
        }

        if ($serviceStarted) {
            Write-Host ""
            Write-Host ""
            Write-Success "服务启动成功"
            
            # Auto-start watchdog
            Write-Info "启动守护进程..."
            Start-WatchdogInternal
            
            Write-Host ""
            Write-Title "✓ 启动完成！"
            Write-Host "  服务地址: $script:ServiceUrl" -ForegroundColor Green
            Write-Host "  工作目录: $script:WorkDir" -ForegroundColor Gray
            Write-Host "  日志文件: $script:LogFile" -ForegroundColor Gray
            Write-Host "  监控面板: https://ericc-ch.github.io/copilot-api?endpoint=$script:ServiceUrl/usage" -ForegroundColor Cyan
            Write-Host ""
            Write-Info "提示: 服务和守护进程已在后台运行，可以关闭此窗口"
            Write-Host "  守护进程会在服务异常时自动重启" -ForegroundColor Gray
        }
        else {
            Write-Host ""
            Write-Warning "无法确认服务状态，请查看日志文件或手动检查"
            Write-Host "  日志文件: $script:LogFile" -ForegroundColor Gray
        }
    }
    catch {
        Write-Error "启动服务时出错: $_"
    }

    Write-Host ""
}

function Stop-CopilotService {
    param([switch]$Silent)

    if (-not $Silent) {
        Clear-HostSafe
        Write-Title "停止 Copilot API 服务"
    }

    # Stop watchdog first
    if (Test-WatchdogRunning) {
        Write-Info "停止守护进程..."
        Stop-WatchdogInternal
        Write-Success "守护进程已停止"
    }

    $process = Get-ServiceProcess
    if ($null -ne $process) {
        try {
            Write-Info "找到进程 PID: $($process.Id)"
            # Kill child processes first
            Get-CimInstance Win32_Process -Filter "ParentProcessId = $($process.Id)" -ErrorAction SilentlyContinue | 
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Stop-Process -Id $process.Id -Force
            Write-Success "服务已停止"
        }
        catch {
            Write-Error "停止进程失败: $_"
        }
    }
    else {
        if (-not $Silent) {
            Write-Warning "未找到运行中的服务"
        }
    }

    Start-Sleep -Milliseconds 500

    if (-not (Test-PortInUse -Port $script:Port)) {
        if (-not $Silent) {
            Write-Success "端口 $script:Port 已释放"
        }
    }
    else {
        Write-Warning "端口仍被占用，请手动检查"
    }

    Write-Host ""
}

function Show-ServiceStatus {
    Clear-HostSafe
    Write-Title "Copilot API 服务状态检查"

    # 检查 Node.js
    Write-Host "[检查环境]" -ForegroundColor Cyan
    try {
        $nodeVersion = node --version 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Node.js: " -NoNewline
            Write-Host "[✓] $nodeVersion" -ForegroundColor Green
        }
        else {
            Write-Host "  Node.js: " -NoNewline
            Write-Host "[×] 未安装" -ForegroundColor Red
        }
    }
    catch {
        Write-Host "  Node.js: " -NoNewline
        Write-Host "[×] 未安装" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "[检查服务状态]" -ForegroundColor Cyan

    # 检查端口占用
    if (Test-PortInUse -Port $script:Port) {
        Write-Host "  状态:    " -NoNewline
        Write-Host "[✓] 服务运行中" -ForegroundColor Green
        Write-Host "  端口:    $script:Port (使用中)"

        $process = Get-ServiceProcess
        if ($null -ne $process) {
            Write-Host "  进程ID:  $($process.Id)"
        }

        # 测试 API 连接
        Write-Host ""
        Write-Host "[测试 API 连接]" -ForegroundColor Cyan
        try {
            $response = Invoke-WebRequest -Uri "$script:ServiceUrl/v1/models" -TimeoutSec 5 -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                Write-Host "  连接:    " -NoNewline
                Write-Host "[✓] API 正常响应" -ForegroundColor Green
            }
        }
        catch {
            Write-Host "  连接:    " -NoNewline
            Write-Host "[×] 无法连接到 API" -ForegroundColor Red
        }
    }
    else {
        Write-Host "  状态:    " -NoNewline
        Write-Host "[×] 服务未运行" -ForegroundColor Red
        Write-Host "  端口:    $script:Port (空闲)"
    }

    # 检查环境变量
    Write-Host ""
    Write-Host "[检查全局环境变量]" -ForegroundColor Cyan

    $envVarNames = [Environment]::GetEnvironmentVariables("User").Keys | 
        Where-Object { $_ -match "^ANTHROPIC_" -or $_ -eq "DISABLE_NON_ESSENTIAL_MODEL_CALLS" -or $_ -eq "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" } |
        Sort-Object

    if ($envVarNames.Count -gt 0) {
        foreach ($varName in $envVarNames) {
            $varValue = [Environment]::GetEnvironmentVariable($varName, "User")
            Write-Host "  ${varName}: " -NoNewline
            Write-Host "[✓] $varValue" -ForegroundColor Green
        }
    }
    else {
        Write-Host "  " -NoNewline
        Write-Host "[×] 未配置任何环境变量" -ForegroundColor Red
    }

    # 守护进程状态
    Write-Host ""
    Write-Host "[守护进程状态]" -ForegroundColor Cyan
    if (Test-WatchdogRunning) {
        Write-Host "  状态:    " -NoNewline
        Write-Host "[✓] 守护进程运行中" -ForegroundColor Green
        
        # Show recent watchdog log
        if (Test-Path $script:WatchdogLogFile) {
            $recentLogs = Get-Content $script:WatchdogLogFile -Tail 3 -ErrorAction SilentlyContinue
            if ($recentLogs) {
                Write-Host "  最近日志:" -ForegroundColor Gray
                foreach ($log in $recentLogs) {
                    Write-Host "    $log" -ForegroundColor Gray
                }
            }
        }
    }
    else {
        Write-Host "  状态:    " -NoNewline
        Write-Host "[×] 守护进程未运行" -ForegroundColor Yellow
    }

    # 其他信息
    Write-Host ""
    Write-Host "[其他信息]" -ForegroundColor Cyan
    Write-Host "  工作目录: $script:WorkDir" -ForegroundColor Gray
    if (Test-Path $script:LogFile) {
        Write-Host "  服务日志: " -NoNewline
        Write-Host "[✓] $script:LogFile" -ForegroundColor Green
    }
    else {
        Write-Host "  服务日志: [-] 无日志文件"
    }
    if (Test-Path $script:WatchdogLogFile) {
        Write-Host "  守护日志: " -NoNewline
        Write-Host "[✓] $script:WatchdogLogFile" -ForegroundColor Green
    }
    Write-Host "  监控面板: https://ericc-ch.github.io/copilot-api?endpoint=$script:ServiceUrl/usage" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "======================================" -ForegroundColor Cyan
}

function Invoke-SetupEnv {
    $choice = Show-ModelSelectionMenu -Title "配置全局环境变量"

    if ($choice -eq "0") {
        return
    }

    if ($choice -eq "9") {
        Write-Host ""
        $sonnetModel = Read-Host "请输入 Sonnet 模型名称"
        $haikuModel = Read-Host "请输入 Haiku 模型名称"

        if ([string]::IsNullOrWhiteSpace($sonnetModel) -or [string]::IsNullOrWhiteSpace($haikuModel)) {
            Write-Error "模型名称不能为空"
            Start-Sleep -Seconds 2
            return
        }
    }
    elseif ($script:ModelPresets.ContainsKey($choice)) {
        $preset = $script:ModelPresets[$choice]
        $sonnetModel = $preset.Sonnet
        $haikuModel = $preset.Haiku
    }
    else {
        Write-Error "无效选择"
        Start-Sleep -Seconds 2
        return
    }

    Set-EnvironmentVariables -SonnetModel $sonnetModel -HaikuModel $haikuModel
}

function Invoke-QuickStart {
    $choice = Show-ModelSelectionMenu -Title "一键配置并启动"

    if ($choice -eq "0") {
        return
    }

    if ($choice -eq "9") {
        Write-Host ""
        $sonnetModel = Read-Host "请输入 Sonnet 模型名称"
        $haikuModel = Read-Host "请输入 Haiku 模型名称"

        if ([string]::IsNullOrWhiteSpace($sonnetModel) -or [string]::IsNullOrWhiteSpace($haikuModel)) {
            Write-Error "模型名称不能为空"
            Start-Sleep -Seconds 2
            return
        }
    }
    elseif ($script:ModelPresets.ContainsKey($choice)) {
        $preset = $script:ModelPresets[$choice]
        $sonnetModel = $preset.Sonnet
        $haikuModel = $preset.Haiku
    }
    else {
        Write-Error "无效选择"
        Start-Sleep -Seconds 2
        return
    }

    Clear-HostSafe
    Write-Title "一键配置并启动"

    Write-Host "此操作将：" -ForegroundColor White
    Write-Host "  1. 配置全局环境变量 (Sonnet: $sonnetModel, Haiku: $haikuModel)"
    Write-Host "  2. 启动服务和守护进程"
    Write-Host ""

    $confirm = Read-Host "确认执行? (Y/N)"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Warning "操作已取消"
        return
    }

    # 步骤 1: 配置环境变量
    Write-Host ""
    Write-Info "[步骤 1/2] 配置全局环境变量..."

    try {
        [Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", $script:ServiceUrl, "User")
        [Environment]::SetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", "dummy", "User")
        [Environment]::SetEnvironmentVariable("ANTHROPIC_MODEL", $sonnetModel, "User")
        [Environment]::SetEnvironmentVariable("ANTHROPIC_DEFAULT_SONNET_MODEL", $sonnetModel, "User")
        [Environment]::SetEnvironmentVariable("ANTHROPIC_SMALL_FAST_MODEL", $haikuModel, "User")
        [Environment]::SetEnvironmentVariable("ANTHROPIC_DEFAULT_HAIKU_MODEL", $haikuModel, "User")
        [Environment]::SetEnvironmentVariable("DISABLE_NON_ESSENTIAL_MODEL_CALLS", "1", "User")
        [Environment]::SetEnvironmentVariable("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1", "User")

        Write-Success "环境变量配置完成"
    }
    catch {
        Write-Error "配置环境变量失败: $_"
        return
    }

    # 步骤 2: 启动服务
    Write-Host ""
    Write-Info "[步骤 2/2] 启动服务..."

    # 检查 Node.js
    try {
        $nodeVersion = node --version 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "未找到 Node.js，请先安装 Node.js"
            return
        }
    }
    catch {
        Write-Error "未找到 Node.js，请先安装 Node.js"
        return
    }

    # 检查端口并启动服务
    if (Test-PortInUse -Port $script:Port) {
        Write-Info "服务已在运行"
        # Ensure watchdog is running
        if (-not (Test-WatchdogRunning)) {
            Write-Info "启动守护进程..."
            Start-WatchdogInternal
        }
    }
    else {
        try {
            # 使用 VBScript 后台启动服务
            $vbsScript = @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.CurrentDirectory = "$script:WorkDir"
WshShell.Run "cmd /c npx -y copilot-api@latest start --port $script:Port > copilot-api.log 2>&1", 0, False
"@

            $vbsFile = Join-Path $env:TEMP "start-copilot-api.vbs"
            $vbsScript | Out-File -FilePath $vbsFile -Encoding ASCII
            Start-Process -FilePath "cscript.exe" -ArgumentList "//nologo", "`"$vbsFile`"" -WindowStyle Hidden
            Start-Sleep -Milliseconds 500
            Remove-Item $vbsFile -Force -ErrorAction SilentlyContinue

            # 等待服务启动
            $maxAttempts = 15
            $attempt = 0
            $serviceStarted = $false

            while ($attempt -lt $maxAttempts) {
                Start-Sleep -Seconds 1
                if (Test-PortInUse -Port $script:Port) {
                    $serviceStarted = $true
                    break
                }
                $attempt++
            }

            if ($serviceStarted) {
                Write-Success "服务启动完成"
                # Start watchdog
                Write-Info "启动守护进程..."
                Start-WatchdogInternal
            }
            else {
                Write-Warning "无法确认服务状态，请手动检查"
            }
        }
        catch {
            Write-Error "启动服务失败: $_"
            return
        }
    }

    Write-Host ""
    Write-Title "✓ 配置和启动完成！"
    Write-Host "  服务地址: $script:ServiceUrl" -ForegroundColor Green
    if (Test-WatchdogRunning) {
        Write-Host "  守护进程: 已启动 (自动监控重启)" -ForegroundColor Green
    }
    Write-Host "  工作目录: $script:WorkDir" -ForegroundColor Gray
    Write-Host "  监控面板: https://ericc-ch.github.io/copilot-api?endpoint=$script:ServiceUrl/usage" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "重要提示：" -ForegroundColor Yellow
    Write-Host "  - 需要重启 IDE/编辑器使环境变量生效"
    Write-Host "  - 服务和守护进程在后台运行，关闭此窗口不影响运行"
    Write-Host "  - 守护进程会在服务异常时自动重启服务"
    Write-Host ""
}

# 主菜单
function Show-MainMenu {
    while ($true) {
        Clear-HostSafe
        Write-Title "GitHub Copilot API 管理工具"

        Write-Host "  工作目录: $script:WorkDir" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  [服务管理]" -ForegroundColor Yellow
        Write-Host "  1. 启动服务 (含守护进程)" -ForegroundColor Green
        Write-Host "  2. 停止服务" -ForegroundColor White
        Write-Host "  3. 检查服务状态" -ForegroundColor White
        Write-Host ""
        Write-Host "  [环境配置]" -ForegroundColor Yellow
        Write-Host "  4. 配置全局环境变量" -ForegroundColor White
        Write-Host "  5. 清除全局环境变量" -ForegroundColor White
        Write-Host ""
        Write-Host "  [快捷操作]" -ForegroundColor Yellow
        Write-Host "  6. 一键配置并启动" -ForegroundColor Cyan
        Write-Host "  0. 退出" -ForegroundColor Gray
        Write-Host ""
        Write-Host "======================================" -ForegroundColor Cyan

        $choice = Read-Host "请选择操作 (0-6)"

        switch ($choice) {
            "1" {
                Start-CopilotService
                Read-Host "按 Enter 继续"
            }
            "2" {
                Stop-CopilotService
                Read-Host "按 Enter 继续"
            }
            "3" {
                Show-ServiceStatus
                Read-Host "按 Enter 继续"
            }
            "4" {
                Invoke-SetupEnv
                Read-Host "按 Enter 继续"
            }
            "5" {
                Remove-EnvironmentVariables
                Read-Host "按 Enter 继续"
            }
            "6" {
                Invoke-QuickStart
                Read-Host "按 Enter 继续"
            }
            "0" {
                Write-Host "再见！" -ForegroundColor Cyan
                exit
            }
            default {
                Write-Warning "无效选择，请重新输入"
                Start-Sleep -Seconds 1
            }
        }
    }
}

# Entry point - only show menu if script is run directly (not dot-sourced)
# When dot-sourced, $MyInvocation.InvocationName will be "."
if ($MyInvocation.InvocationName -ne ".") {
    Show-MainMenu
}
