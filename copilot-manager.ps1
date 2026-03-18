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
        # Record log file size before starting, so we only scan new content
        $logFileSize = 0
        if (Test-Path $script:LogFile) {
            $logFileSize = (Get-Item $script:LogFile).Length
        }

        $vbsContent = "Set WshShell = CreateObject(""WScript.Shell"")" + [Environment]::NewLine
        $vbsContent += "WshShell.CurrentDirectory = ""$script:WorkDir""" + [Environment]::NewLine
        $vbsContent += "WshShell.Run ""cmd /c npx -y copilot-api@latest start --port $script:Port >> copilot-api.log 2>&1"", 0, False"
        
        $vbsFile = Join-Path $env:TEMP "start-copilot-api.vbs"
        $vbsContent | Out-File -FilePath $vbsFile -Encoding ASCII
        Start-Process -FilePath "cscript.exe" -ArgumentList "//nologo", "`"$vbsFile`"" -WindowStyle Hidden
        Start-Sleep -Milliseconds 500
        Remove-Item $vbsFile -Force -ErrorAction SilentlyContinue
        
        # Wait for service to start (max 90 seconds, extended for device auth flow)
        $maxAttempts = 90
        $attempt = 0
        $authCodeShown = $false
        while ($attempt -lt $maxAttempts) {
            Start-Sleep -Seconds 1
            if (Test-PortInUse -Port $script:Port) {
                return $true
            }
            # Check log for GitHub device auth code (only show once)
            if (-not $authCodeShown -and (Test-Path $script:LogFile)) {
                try {
                    $stream = [System.IO.FileStream]::new($script:LogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    if ($stream.Length -gt $logFileSize) {
                        $stream.Position = $logFileSize
                        $reader = [System.IO.StreamReader]::new($stream)
                        $newContent = $reader.ReadToEnd()
                        $reader.Close()
                        if ($newContent -match 'enter the code "([^"]+)" in (https://[^\s]+)') {
                            Write-Host ""
                            Write-Host "  ============================================" -ForegroundColor Yellow
                            Write-Host "  GitHub 设备授权码: $($Matches[1])" -ForegroundColor Yellow
                            Write-Host "  请在浏览器中打开: $($Matches[2])" -ForegroundColor Yellow
                            Write-Host "  ============================================" -ForegroundColor Yellow
                            Write-Host ""
                            $authCodeShown = $true
                        }
                    } else {
                        $stream.Close()
                    }
                } catch {}
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

function Get-AutostartVbsPath {
    return Join-Path ([Environment]::GetFolderPath("Startup")) "copilot-autostart.vbs"
}

function Test-AutostartRegistered {
    return Test-Path (Get-AutostartVbsPath)
}

function Register-Autostart {
    $autostartScript = Join-Path $script:WorkDir "copilot-autostart.ps1"
    if (-not (Test-Path $autostartScript)) {
        Write-Error "找不到自启脚本: $autostartScript"
        return $false
    }

    $vbsPath = Get-AutostartVbsPath
    $vbsContent = "Set WshShell = CreateObject(""WScript.Shell"")" + [Environment]::NewLine
    $vbsContent += "WshShell.Run ""powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File """"$autostartScript"""""", 0, False"

    try {
        $vbsContent | Out-File -FilePath $vbsPath -Encoding ASCII -Force
        return $true
    } catch {
        Write-Error "写入 VBS 文件失败: $($_.Exception.Message)"
        return $false
    }
}

function Unregister-Autostart {
    $vbsPath = Get-AutostartVbsPath
    if (Test-Path $vbsPath) {
        try {
            Remove-Item $vbsPath -Force
            return $true
        } catch {
            Write-Error "删除 VBS 文件失败: $($_.Exception.Message)"
            return $false
        }
    }
    return $true
}

function Invoke-ToggleAutostart {
    if (Test-AutostartRegistered) {
        Write-Host ""
        Write-Info "当前状态: 已注册开机自启"
        Write-Host ""
        $confirm = Read-Host "确认取消开机自启? (Y/N)"
        if ($confirm -eq 'Y' -or $confirm -eq 'y') {
            if (Unregister-Autostart) {
                Write-Success "已取消开机自启"
            } else {
                Write-Error "取消开机自启失败"
            }
        } else {
            Write-Info "操作已放弃，开机自启保持启用"
        }
    } else {
        Write-Host ""
        Write-Info "当前状态: 未注册开机自启"
        Write-Host "  注册后，系统启动时将自动启动 Copilot API 服务和守护进程" -ForegroundColor Gray
        Write-Host ""
        $confirm = Read-Host "确认注册开机自启? (Y/N)"
        if ($confirm -eq 'Y' -or $confirm -eq 'y') {
            if (Register-Autostart) {
                Write-Success "已注册开机自启"
                $vbsPath = Get-AutostartVbsPath
                Write-Host "  VBS 文件: $vbsPath" -ForegroundColor Gray
            } else {
                Write-Error "注册开机自启失败"
            }
        } else {
            Write-Info "操作已放弃，开机自启保持关闭"
        }
    }
}

function Get-AvailableModels {
    # Fetch available models from the API
    try {
        $response = Invoke-WebRequest -Uri "$script:ServiceUrl/v1/models" -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        $data = $response.Content | ConvertFrom-Json
        return $data.data
    }
    catch {
        return $null
    }
}

function Get-FilteredModels {
    param([array]$Models)
    
    # Filter criteria
    $skipPatterns = @(
        '^text-embedding',       # embedding models
        '^goldeneye',            # internal models
        '.*-copilot$',           # copilot-specific models
        '^gpt-3\.5',             # outdated models
        '^gpt-4-0',             # old dated gpt-4 variants
        '^gpt-4$',              # base gpt-4
        '^gpt-4-o-preview$',    # old preview alias
        '^gpt-4o$',             # outdated standalone (superseded by gpt-4.1/5)
        '^gpt-4o-mini$',        # outdated standalone (superseded by gpt-4.1-mini/5-mini)
        '^gpt-4\.1$',           # base gpt-4.1 (dated version preferred)
        '^gpt-4\.1-mini$',      # base gpt-4.1-mini (dated version preferred)
        '^gpt-4\.1-nano$',      # base gpt-4.1-nano (dated version preferred)
        '-\d{4}-\d{2}-\d{2}$'  # dated versions like gpt-4o-2024-05-13
    )
    
    $seenIds = @{}
    $filtered = @()
    
    foreach ($m in $Models) {
        $mid = $m.id
        $display = if ($m.display_name) { $m.display_name } else { $mid }
        $owned = if ($m.owned_by) { $m.owned_by } else { "Unknown" }
        
        # Skip duplicates
        if ($seenIds.ContainsKey($mid)) { continue }
        
        # Skip by pattern
        $skip = $false
        foreach ($pat in $skipPatterns) {
            if ($mid -match $pat) {
                $skip = $true
                break
            }
        }
        if ($skip) { continue }
        
        $seenIds[$mid] = $true
        
        # Normalize vendor name
        $vendor = switch -Regex ($owned.ToLower()) {
            'anthropic' { 'Anthropic'; break }
            'openai|azure' { 'OpenAI'; break }
            'google' { 'Google'; break }
            default { '其他' }
        }
        
        $filtered += [PSCustomObject]@{
            Vendor = $vendor
            Id = $mid
            DisplayName = $display
            VendorOrder = switch ($vendor) {
                'Anthropic' { 0 }
                'OpenAI' { 1 }
                'Google' { 2 }
                default { 3 }
            }
        }
    }
    
    # Sort by vendor order, then by id
    return $filtered | Sort-Object VendorOrder, Id
}

function Select-ModelFromList {
    param(
        [string]$Role,
        [array]$Models
    )
    
    Write-Host ""
    Write-Host "请选择 " -NoNewline -ForegroundColor White
    Write-Host "$Role" -NoNewline -ForegroundColor Cyan
    Write-Host " 的模型：" -ForegroundColor White
    Write-Host ""
    
    $currentVendor = ""
    $index = 0
    $modelMap = @{}
    
    foreach ($m in $Models) {
        if ($m.Vendor -ne $currentVendor) {
            if ($currentVendor -ne "") { Write-Host "" }
            Write-Host "  === $($m.Vendor) ===" -ForegroundColor Yellow
            $currentVendor = $m.Vendor
        }
        $index++
        $modelMap[$index] = $m.Id
        Write-Host "  $index. $($m.DisplayName) ($($m.Id))"
    }
    
    Write-Host ""
    Write-Host "  0. 自定义模型"
    Write-Host ""
    
    $choice = Read-Host "请选择 (0-$index)"
    
    if ($choice -eq "0") {
        $custom = Read-Host "请输入模型名称"
        return $custom
    }
    
    $choiceInt = 0
    if ([int]::TryParse($choice, [ref]$choiceInt) -and $choiceInt -ge 1 -and $choiceInt -le $index) {
        return $modelMap[$choiceInt]
    }
    
    return $null
}

function Show-ModelSelectionMenu {
    Write-Host ""
    Write-Info "正在从 API 获取可用模型..."

    $rawModels = Get-AvailableModels
    if ($null -eq $rawModels) {
        Write-Host ""
        Write-Error "无法获取模型列表。服务是否在端口 ${script:Port} 上运行？"
        Write-Info "请先启动服务（主菜单选项 1）"
        Write-Host ""
        return "FETCH_FAILED"
    }

    $models = Get-FilteredModels -Models $rawModels
    if ($models.Count -eq 0) {
        Write-Error "过滤后没有可用模型"
        return "FETCH_FAILED"
    }

    Write-Success "找到 $($models.Count) 个可用模型"

    # Step 1: Select Opus model (powerful model)
    $opusModel = Select-ModelFromList -Role "Opus (强力模型)" -Models $models
    if ([string]::IsNullOrWhiteSpace($opusModel)) {
        Write-Error "无效选择"
        return "INVALID"
    }

    # Step 2: Select Sonnet model (main model)
    $sonnetModel = Select-ModelFromList -Role "Sonnet (主模型)" -Models $models
    if ([string]::IsNullOrWhiteSpace($sonnetModel)) {
        Write-Error "无效选择"
        return "INVALID"
    }

    # Step 3: Select Haiku model (fast model)
    $haikuModel = Select-ModelFromList -Role "Haiku (快速模型)" -Models $models
    if ([string]::IsNullOrWhiteSpace($haikuModel)) {
        Write-Error "无效选择"
        return "INVALID"
    }

    return "$opusModel|$sonnetModel|$haikuModel"
}

function Set-EnvironmentVariables {
    param(
        [string]$OpusModel,
        [string]$SonnetModel,
        [string]$HaikuModel
    )

    Write-Host ""
    Write-Host "将设置以下环境变量（用户级）：" -ForegroundColor White
    Write-Host ""
    Write-Host "  ANTHROPIC_BASE_URL = $script:ServiceUrl"
    Write-Host "  ANTHROPIC_AUTH_TOKEN = dummy"
    Write-Host "  ANTHROPIC_MODEL = $SonnetModel"
    Write-Host "  ANTHROPIC_DEFAULT_OPUS_MODEL = $OpusModel"
    Write-Host "  ANTHROPIC_DEFAULT_SONNET_MODEL = $SonnetModel"
    Write-Host "  ANTHROPIC_DEFAULT_HAIKU_MODEL = $HaikuModel"
    Write-Host "  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = 1"
    Write-Host "  DISABLE_TELEMETRY = 1"
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

        [Environment]::SetEnvironmentVariable("ANTHROPIC_DEFAULT_OPUS_MODEL", $OpusModel, "User")
        Write-Success "ANTHROPIC_DEFAULT_OPUS_MODEL"

        [Environment]::SetEnvironmentVariable("ANTHROPIC_DEFAULT_SONNET_MODEL", $SonnetModel, "User")
        Write-Success "ANTHROPIC_DEFAULT_SONNET_MODEL"

        [Environment]::SetEnvironmentVariable("ANTHROPIC_DEFAULT_HAIKU_MODEL", $HaikuModel, "User")
        Write-Success "ANTHROPIC_DEFAULT_HAIKU_MODEL"

        [Environment]::SetEnvironmentVariable("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1", "User")
        Write-Success "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"

        [Environment]::SetEnvironmentVariable("DISABLE_TELEMETRY", "1", "User")
        Write-Success "DISABLE_TELEMETRY"

        Write-Host ""
        Write-Title "✓ 环境变量设置完成！"
        
        # Auto-restart service if running, so new env vars take effect
        if (Test-PortInUse -Port $script:Port) {
            Write-Host ""
            Write-Info "正在重启服务以应用新配置..."
            Stop-ServiceInternal
            Start-Sleep -Seconds 1
            if (Start-ServiceInternal) {
                Write-Success "服务已使用新配置重启"
                # Restart watchdog too
                if (Test-WatchdogRunning) {
                    Stop-WatchdogInternal
                    Start-WatchdogInternal
                }
            }
            else {
                Write-Error "服务重启失败，请手动重启（选项 1）"
            }
        }
        
        Write-Host ""
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
    Write-Host "  ANTHROPIC_MODEL"
    Write-Host "  ANTHROPIC_DEFAULT_SONNET_MODEL"
    Write-Host "  ANTHROPIC_DEFAULT_OPUS_MODEL"
    Write-Host "  ANTHROPIC_DEFAULT_HAIKU_MODEL"
    Write-Host "  ANTHROPIC_AUTH_TOKEN"
    Write-Host "  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"
    Write-Host "  DISABLE_TELEMETRY"
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
        "ANTHROPIC_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
        "DISABLE_TELEMETRY"
    )

    # Use registry to completely remove environment variables (key + value)
    $regPath = "HKCU:\Environment"

    foreach ($var in $variables) {
        try {
            # Check if variable exists in registry
            $existingValue = Get-ItemProperty -Path $regPath -Name $var -ErrorAction SilentlyContinue
            if ($null -ne $existingValue) {
                # Remove from registry (completely deletes key)
                Remove-ItemProperty -Path $regPath -Name $var -ErrorAction Stop
                # Also clear from .NET cache
                [Environment]::SetEnvironmentVariable($var, $null, "User")
                Write-Success "$var 已删除"
            }
            else {
                Write-Info "$var 不存在，跳过"
            }
        }
        catch {
            Write-Warning "$var 删除失败: $_"
        }
    }

    # Also clean up any deprecated/unknown ANTHROPIC_ variables
    $allUserVars = Get-Item -Path $regPath | Select-Object -ExpandProperty Property
    $deprecatedVars = $allUserVars | Where-Object { $_ -match "^ANTHROPIC_" -and $_ -notin $variables }
    foreach ($var in $deprecatedVars) {
        try {
            Remove-ItemProperty -Path $regPath -Name $var -ErrorAction Stop
            [Environment]::SetEnvironmentVariable($var, $null, "User")
            Write-Warning "$var (已弃用) 已删除"
        }
        catch {}
    }

    # Broadcast environment change to notify other applications
    if (-not ("Win32.NativeMethods" -as [type])) {
        Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @"
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
"@
    }
    $HWND_BROADCAST = [IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x1a
    $result = [UIntPtr]::Zero
    [Win32.NativeMethods]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, "Environment", 2, 5000, [ref]$result) | Out-Null

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
WshShell.Run "cmd /c npx -y copilot-api@latest start --port $script:Port >> copilot-api.log 2>&1", 0, False
"@

        $vbsFile = Join-Path $env:TEMP "start-copilot-api.vbs"
        $vbsScript | Out-File -FilePath $vbsFile -Encoding ASCII

        # 不使用 -Wait，让 VBS 异步执行
        Start-Process -FilePath "cscript.exe" -ArgumentList "//nologo", "`"$vbsFile`"" -WindowStyle Hidden

        # 等待一小段时间让 VBS 启动
        Start-Sleep -Milliseconds 500
        Remove-Item $vbsFile -Force -ErrorAction SilentlyContinue

        # Record log file size before starting, so we only scan new content
        $logFileSize = 0
        if (Test-Path $script:LogFile) {
            $logFileSize = (Get-Item $script:LogFile).Length
        }

        Write-Info "等待服务启动..."

        # 多次尝试检测端口（最多 90 秒，首次启动可能需要下载和设备授权）
        $maxAttempts = 90
        $attempt = 0
        $serviceStarted = $false
        $authCodeShown = $false

        while ($attempt -lt $maxAttempts) {
            Start-Sleep -Seconds 1
            if (Test-PortInUse -Port $script:Port) {
                $serviceStarted = $true
                break
            }
            # Check log for GitHub device auth code (only show once)
            if (-not $authCodeShown -and (Test-Path $script:LogFile)) {
                try {
                    $stream = [System.IO.FileStream]::new($script:LogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    if ($stream.Length -gt $logFileSize) {
                        $stream.Position = $logFileSize
                        $reader = [System.IO.StreamReader]::new($stream)
                        $newContent = $reader.ReadToEnd()
                        $reader.Close()
                        if ($newContent -match 'enter the code "([^"]+)" in (https://[^\s]+)') {
                            Write-Host ""
                            Write-Host "  ============================================" -ForegroundColor Yellow
                            Write-Host "  GitHub 设备授权码: $($Matches[1])" -ForegroundColor Yellow
                            Write-Host "  请在浏览器中打开: $($Matches[2])" -ForegroundColor Yellow
                            Write-Host "  ============================================" -ForegroundColor Yellow
                            Write-Host ""
                            $authCodeShown = $true
                        }
                    } else {
                        $stream.Close()
                    }
                } catch {}
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
        Where-Object { $_ -match "^ANTHROPIC_" -or $_ -eq "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" } |
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
    Clear-HostSafe
    Write-Title "配置全局环境变量"

    $result = Show-ModelSelectionMenu

    if ($result -eq "FETCH_FAILED" -or $result -eq "INVALID" -or $null -eq $result) {
        Start-Sleep -Seconds 2
        return
    }

    $parts = $result -split '\|'
    $opusModel = $parts[0]
    $sonnetModel = $parts[1]
    $haikuModel = $parts[2]

    if ([string]::IsNullOrWhiteSpace($opusModel) -or [string]::IsNullOrWhiteSpace($sonnetModel) -or [string]::IsNullOrWhiteSpace($haikuModel)) {
        Write-Error "无效的模型选择"
        Start-Sleep -Seconds 2
        return
    }

    Set-EnvironmentVariables -OpusModel $opusModel -SonnetModel $sonnetModel -HaikuModel $haikuModel
}

function Invoke-QuickStart {
    Clear-HostSafe
    Write-Title "一键配置并启动"

    # Step 1: Start service if not running
    Write-Info "[步骤 1/3] 检查服务..."

    if (-not (Test-PortInUse -Port $script:Port)) {
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

        Write-Info "启动 Copilot API 服务器..."
        Write-Host ""
        Write-Host "如果出现提示，请在下方完成 GitHub 设备授权：" -ForegroundColor Yellow
        Write-Host ""

        try {
            # Record log file size before starting, so we only scan new content
            $logFileSize = 0
            if (Test-Path $script:LogFile) {
                $logFileSize = (Get-Item $script:LogFile).Length
            }

            $vbsScript = @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.CurrentDirectory = "$script:WorkDir"
WshShell.Run "cmd /c npx -y copilot-api@latest start --port $script:Port >> copilot-api.log 2>&1", 0, False
"@
            $vbsFile = Join-Path $env:TEMP "start-copilot-api.vbs"
            $vbsScript | Out-File -FilePath $vbsFile -Encoding ASCII
            Start-Process -FilePath "cscript.exe" -ArgumentList "//nologo", "`"$vbsFile`"" -WindowStyle Hidden
            Start-Sleep -Milliseconds 500
            Remove-Item $vbsFile -Force -ErrorAction SilentlyContinue

            $maxAttempts = 90
            $attempt = 0
            $serviceStarted = $false
            $authCodeShown = $false

            while ($attempt -lt $maxAttempts) {
                Start-Sleep -Seconds 1
                if (Test-PortInUse -Port $script:Port) {
                    $serviceStarted = $true
                    break
                }
                # Check log for GitHub device auth code (only show once)
                if (-not $authCodeShown -and (Test-Path $script:LogFile)) {
                    try {
                        $stream = [System.IO.FileStream]::new($script:LogFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                        if ($stream.Length -gt $logFileSize) {
                            $stream.Position = $logFileSize
                            $reader = [System.IO.StreamReader]::new($stream)
                            $newContent = $reader.ReadToEnd()
                            $reader.Close()
                            if ($newContent -match 'enter the code "([^"]+)" in (https://[^\s]+)') {
                                Write-Host ""
                                Write-Host "  ============================================" -ForegroundColor Yellow
                                Write-Host "  GitHub 设备授权码: $($Matches[1])" -ForegroundColor Yellow
                                Write-Host "  请在浏览器中打开: $($Matches[2])" -ForegroundColor Yellow
                                Write-Host "  ============================================" -ForegroundColor Yellow
                                Write-Host ""
                                $authCodeShown = $true
                            }
                        } else {
                            $stream.Close()
                        }
                    } catch {}
                }
                $attempt++
            }

            if (-not $serviceStarted) {
                Write-Error "服务启动失败，请检查日志文件: $script:LogFile"
                return
            }
            Write-Success "服务启动完成"
        }
        catch {
            Write-Error "启动服务失败: $_"
            return
        }
    }
    else {
        Write-Success "服务已在运行"
    }

    # Start watchdog
    if (-not (Test-WatchdogRunning)) {
        Write-Info "启动守护进程..."
        Start-WatchdogInternal
    }

    # Step 2: Fetch models and let user select
    Write-Info "[步骤 2/3] 获取可用模型..."

    $result = Show-ModelSelectionMenu

    if ($result -eq "FETCH_FAILED" -or $result -eq "INVALID" -or $null -eq $result) {
        Write-Host ""
        Write-Warning "模型选择已取消。服务仍在运行。"
        return
    }

    $parts = $result -split '\|'
    $opusModel = $parts[0]
    $sonnetModel = $parts[1]
    $haikuModel = $parts[2]

    if ([string]::IsNullOrWhiteSpace($opusModel) -or [string]::IsNullOrWhiteSpace($sonnetModel) -or [string]::IsNullOrWhiteSpace($haikuModel)) {
        Write-Error "无效的模型选择"
        return
    }

    # Step 3: Configure environment variables
    Write-Info "[步骤 3/3] 配置全局环境变量..."

    try {
        [Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", $script:ServiceUrl, "User")
        [Environment]::SetEnvironmentVariable("ANTHROPIC_MODEL", $sonnetModel, "User")
        [Environment]::SetEnvironmentVariable("ANTHROPIC_DEFAULT_OPUS_MODEL", $opusModel, "User")
        [Environment]::SetEnvironmentVariable("ANTHROPIC_DEFAULT_SONNET_MODEL", $sonnetModel, "User")
        [Environment]::SetEnvironmentVariable("ANTHROPIC_DEFAULT_HAIKU_MODEL", $haikuModel, "User")
        [Environment]::SetEnvironmentVariable("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1", "User")
        [Environment]::SetEnvironmentVariable("DISABLE_TELEMETRY", "1", "User")

        # Remove deprecated vars
        [Environment]::SetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", "dummy", "User")
        [Environment]::SetEnvironmentVariable("DISABLE_NON_ESSENTIAL_MODEL_CALLS", $null, "User")

        Write-Success "环境变量配置完成"
    }
    catch {
        Write-Error "配置环境变量失败: $_"
        return
    }

    # Restart service to apply new env vars
    Write-Info "正在重启服务以应用新配置..."
    Stop-ServiceInternal
    Start-Sleep -Seconds 1
    if (Start-ServiceInternal) {
        Write-Success "服务已使用新配置重启"
        # Restart watchdog too
        if (-not (Test-WatchdogRunning)) {
            Start-WatchdogInternal
        }
        else {
            Stop-WatchdogInternal
            Start-WatchdogInternal
        }
    }
    else {
        Write-Error "服务重启失败，请手动重启（选项 1）"
    }

    Write-Host ""
    Write-Title "✓ 配置和启动完成！"
    Write-Host "  服务地址: $script:ServiceUrl" -ForegroundColor Green
    Write-Host "  Opus 模型: $opusModel" -ForegroundColor Green
    Write-Host "  Sonnet 模型: $sonnetModel" -ForegroundColor Green
    Write-Host "  Haiku 模型: $haikuModel" -ForegroundColor Green
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
        $autostartStatus = if (Test-AutostartRegistered) { "已启用" } else { "未启用" }
        Write-Host "  7. 开机自启 ($autostartStatus)" -ForegroundColor White
        Write-Host "  0. 退出" -ForegroundColor Gray
        Write-Host ""
        Write-Host "======================================" -ForegroundColor Cyan

        $choice = Read-Host "请选择操作 (0-7)"

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
            "7" {
                Invoke-ToggleAutostart
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
