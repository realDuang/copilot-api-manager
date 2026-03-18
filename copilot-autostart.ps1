$ErrorActionPreference = "Continue"
$managerDir = $PSScriptRoot
# Use a unique variable name to avoid collision with $script:LogFile from copilot-manager.ps1
# (PowerShell variables are case-insensitive, so $logFile and $LogFile conflict)
$autostartLog = Join-Path $managerDir "autostart.log"

function Log { param([string]$Msg)
    Add-Content -Path $script:autostartLog -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Msg" -ErrorAction SilentlyContinue
}

Log "Autostart triggered"

# Load all functions from the manager script
try {
    . "$managerDir\copilot-manager.ps1"
    Log "Manager script loaded successfully"
} catch {
    Log "ERROR: Failed to load manager script: $($_.Exception.Message)"
    Log "Autostart aborted"
    exit 1
}

# Wait for network and system to settle after boot
Start-Sleep -Seconds 15

# Start service with retry
$maxRetries = 3
$retryDelay = 10
$serviceStarted = $false

if (-not (Test-PortInUse -Port $script:Port)) {
    for ($i = 1; $i -le $maxRetries; $i++) {
        Log "Starting service (attempt $i/$maxRetries)..."
        try {
            if (Start-ServiceInternal) {
                Log "Service started successfully"
                $serviceStarted = $true
                break
            } else {
                Log "Service start returned false (attempt $i/$maxRetries)"
            }
        } catch {
            Log "ERROR: Service start exception (attempt $i/$maxRetries): $($_.Exception.Message)"
        }
        if ($i -lt $maxRetries) {
            Log "Waiting ${retryDelay}s before retry..."
            Start-Sleep -Seconds $retryDelay
        }
    }
    if (-not $serviceStarted) {
        Log "WARNING: Service failed to start after $maxRetries attempts"
    }
} else {
    Log "Service already running on port $($script:Port)"
    $serviceStarted = $true
}

# Start watchdog (regardless of service state - watchdog will handle restarts)
try {
    if (-not (Test-WatchdogRunning)) {
        Log "Starting watchdog..."
        if (Start-WatchdogInternal) {
            Log "Watchdog started successfully"
        } else {
            Log "WARNING: Watchdog start returned false"
        }
    } else {
        Log "Watchdog already running"
    }
} catch {
    Log "ERROR: Watchdog start exception: $($_.Exception.Message)"
}

Log "Autostart completed"
