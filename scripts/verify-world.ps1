# End-to-end in-world verification & A/B regression runner.
# Launches an isolated copy of the title with full world telemetry + frame capture,
# waits until real 3D world rendering (`>= 500 draws/frame`) is sampled, and runs
# `scripts/analyze-world-run.py` against hard visual/VRAM/FPS/stall gates.
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Game,
    [string]$GoldenDataDir,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [ValidateSet('series-s', 'series-x')][string]$Console = 'series-s',
    [ValidateSet('off', 'dlaa', 'quality', 'balanced', 'performance')][string]$DlssMode = 'quality',
    [switch]$LevelsOnDemand,
    [switch]$GpuDetile,
    [switch]$RayTracing,
    [int]$WorldSeconds = 45,
    [int]$MaxBootSeconds = 180,
    [string]$BaselineJson,
    [switch]$AutoNudgeMenu,
    [hashtable]$ExtraEnv = @{}
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Exe)) {
    Write-Host "FAIL: missing victory executable: $Exe"
    exit 1
}
$Exe = (Resolve-Path $Exe).Path

if (-not $Game -and $env:VICTORY_GAME_DIR) {
    $candidate = Get-ChildItem -Path $env:VICTORY_GAME_DIR -Filter '*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($candidate) { $Game = $candidate.FullName }
}
if (-not $Game -or -not (Test-Path $Game)) {
    Write-Host "FAIL: pass -Game <path\to\title.exe> or set `$env:VICTORY_GAME_DIR."
    exit 1
}
$Game = (Resolve-Path $Game).Path

$existing = Get-Process victory, victory_sm -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "FAIL: victory/victory_sm is already running ($($existing.Id -join ', ')). Close it before verifying."
    exit 1
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

$framesDir = Join-Path $OutDir 'frames'
$sandboxData = Join-Path $OutDir 'sandbox-data'
$stdoutLog = Join-Path $OutDir 'stdout.log'
$stderrLog = Join-Path $OutDir 'stderr.log'
$summaryJson = Join-Path $OutDir 'summary.json'
$reportMd = Join-Path $OutDir 'report.md'

Remove-Item $framesDir, $sandboxData -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $stdoutLog, $stderrLog, $summaryJson, $reportMd -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $framesDir | Out-Null

if ($GoldenDataDir -and (Test-Path $GoldenDataDir)) {
    Copy-Item -Path $GoldenDataDir -Destination $sandboxData -Recurse -Force
} else {
    New-Item -ItemType Directory -Force $sandboxData | Out-Null
}

# Exact baseline matching apps/victory/src/play.rs SETTINGS plus deterministic diagnostics/capture.
$envVars = @{
    VICTORY_THIN                    = '1'
    VICTORY_JOIN_PARTS              = '8'
    VICTORY_RELAY                   = '2'
    VICTORY_RELAY_COPY              = '1'
    VICTORY_WIDE_BACK               = '1'
    VICTORY_CARD_REHASH_RUNS        = '1'
    VICTORY_JOIN_COPIES             = '1'
    VICTORY_CARD_STEPS              = '2'
    VICTORY_CARD_AWAKE              = '1'
    VICTORY_CARD_BUFFERS_MIN_KB     = '64'
    VICTORY_INDIRECT_WINDOW         = '1'
    VICTORY_INDIRECT_BATCH          = '2'
    VICTORY_UPLOAD_AHEAD            = '1'
    VICTORY_SHOW_AFTER              = '1'
    VICTORY_MAP_THREADS             = '1'
    VICTORY_TEXSPK_PASS_MS          = '8'
    VICTORY_PASSES_HOT              = '1'
    VICTORY_HELPER_PRIORITY         = '1'
    VICTORY_WC_NO_BACK              = '1'
    VICTORY_WC_NO_BACK_MIN_KB       = '1024'
    VICTORY_SOFT_VIEWS              = 'copies'
    VICTORY_TEXTURE_POOL            = '1'
    VICTORY_RIPE_BLOCKS             = '0'
    VICTORY_TEXTURE_NO_WAIT         = '1'
    VICTORY_TEXTURE_CATCHUP         = '0'
    VICTORY_TEXTURE_STAGE_MS        = '16'
    VICTORY_LEVELS_ON_DEMAND        = '0'
    VICTORY_PRELUDE_UPLOADS         = '1'
    VICTORY_SHOW_NEW_LATER          = '1'
    VICTORY_POOL_SMALL              = '0'
    VICTORY_TABLED_REREAD           = '1'
    VICTORY_QUEUE_HOST_TEXTURES     = '0'
    VICTORY_HEAP_SYNC_FIRST         = '1'
    VICTORY_SYNC_IN_PLACE           = '1'
    VICTORY_SPANS_QUICK             = '1'
    VICTORY_SYNC_FINE               = '1'
    VICTORY_HEAP_SYNC_AT_SUBMIT     = '1'
    VICTORY_AMBIENT                 = '0.8'
    VICTORY_AMBIENT_AIR             = '1.5'
    VICTORY_AMBIENT_SPECULAR        = '1'
    VICTORY_EARLY_DEPTH             = '1'
    VICTORY_LEAVE_OUT               = '02384a60fda6f2d0,731a39171b568298'
    VICTORY_PIPELINE_BOOK           = '1'
    VICTORY_FRAME_INTERVAL_US       = '1000'
    VICTORY_NO_WATCHDOG             = '1'
    VICTORY_SKIP_BINK               = '1'
    VICTORY_CARD_ACCOUNTING         = '1'
    VICTORY_D3D12_DRED              = 'light'
    VICTORY_DATA_DIR                = $sandboxData
    VICTORY_CAPTURE                 = $framesDir
    VICTORY_CAPTURE_WORLD           = '1'
    VICTORY_CAPTURE_WORLD_ALSO      = '30,60,120'
}

$slDir = Join-Path $repoRoot 'nvidia-sdk\Streamline\bin\x64'
if ($DlssMode -ne 'off' -and (Test-Path $slDir)) {
    $envVars.VICTORY_DLSS = '1'
    $envVars.VICTORY_DLSS_MODE = $DlssMode
    $envVars.VICTORY_STREAMLINE_DIR = $slDir
}

if ($LevelsOnDemand) {
    $envVars.VICTORY_LEVELS_ON_DEMAND = '1'
    $envVars.VICTORY_LEVELS_ALL = '1'
    $envVars.VICTORY_LEVELS_MAX_DIM = '2048'
    $envVars.VICTORY_LEVELS_RECLAIM = '1'
}
if ($GpuDetile) {
    $envVars.VICTORY_GPU_DETILE = '1'
    $envVars.VICTORY_GPU_DETILE_TRIM = '1'
}
if ($RayTracing) {
    $envVars.VICTORY_BVH_BUILDER = '1'
    $envVars.VICTORY_RAYS = '1'
}
foreach ($k in $ExtraEnv.Keys) {
    $envVars[$k] = $ExtraEnv[$k]
}

if ($AutoNudgeMenu) {
    Add-Type -Namespace VictoryVerify -Name NativeWin -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
'@ -ErrorAction SilentlyContinue | Out-Null
    $wshell = New-Object -ComObject WScript.Shell
}

$keep = @('VICTORY_CONFIG', 'VICTORY_GAME_DIR', 'VICTORY_CACHE_DIR')
$saved = @{}
foreach ($item in Get-ChildItem Env:VICTORY_* -ErrorAction SilentlyContinue) {
    if ($item.Name -notin $keep) {
        $saved[$item.Name] = $item.Value
        Remove-Item "Env:$($item.Name)"
    }
}
foreach ($k in $envVars.Keys) {
    Set-Item "Env:$k" $envVars[$k]
}

Write-Host "=== In-World Verifier ==="
Write-Host "Exe: $Exe | Console: $Console | DLSS: $DlssMode | LevelsOnDemand: $([bool]$LevelsOnDemand) | GpuDetile: $([bool]$GpuDetile) | RT: $([bool]$RayTracing)"
Write-Host "Output: $OutDir"

$proc = Start-Process -FilePath $Exe -ArgumentList @('run', '--execute', '--console', $Console, $Game) `
    -WorkingDirectory $repoRoot -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog -PassThru

$worldStartedAt = $null
$nudges = 0
$lastNudge = [DateTime]::MinValue
try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if ($proc.HasExited) {
            Write-Host "Process exited with code $($proc.ExitCode) after $([int]$sw.Elapsed.TotalSeconds)s"
            break
        }
        if ($null -eq $worldStartedAt -and $sw.Elapsed.TotalSeconds -ge $MaxBootSeconds) {
            Write-Host "Timed out after ${MaxBootSeconds}s waiting for 3D world (>= 500 draws/frame)"
            break
        }
        if ($null -ne $worldStartedAt -and $worldStartedAt.Elapsed.TotalSeconds -ge $WorldSeconds) {
            Write-Host "Captured ${WorldSeconds}s of 3D world execution; stopping child process"
            break
        }
        Start-Sleep -Seconds 2
        if (Test-Path $stderrLog) {
            $lines = Get-Content $stderrLog -ErrorAction SilentlyContinue
            if ($null -eq $worldStartedAt) {
                $hit = $lines | Select-String '(\d+)\s+draws/frame' | Where-Object {
                    ($_ -replace '\x1b\[[0-9;]*m', '') -match '(\d+)\s+draws/frame' -and [int]$Matches[1] -ge 500
                } | Select-Object -First 1
                if ($hit) {
                    $worldStartedAt = [Diagnostics.Stopwatch]::StartNew()
                    Write-Host "Reached 3D world (>= 500 draws/frame) at $([int]$sw.Elapsed.TotalSeconds)s; sampling ${WorldSeconds}s..."
                } elseif ($AutoNudgeMenu -and $sw.Elapsed.TotalSeconds -ge 30 -and $nudges -lt 5 -and ([DateTime]::UtcNow - $lastNudge).TotalSeconds -ge 10) {
                    $proc.Refresh()
                    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
                        [VictoryVerify.NativeWin]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
                        Start-Sleep -Milliseconds 150
                        $wshell.SendKeys('{ENTER}')
                        $nudges++
                        $lastNudge = [DateTime]::UtcNow
                        Write-Host "Sent menu nudge #$nudges"
                    }
                }
            }
        }
    }
} finally {
    if (-not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        $proc.WaitForExit(10000) | Out-Null
    }
    foreach ($k in $envVars.Keys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
    foreach ($k in $saved.Keys) { Set-Item "Env:$k" $saved[$k] }
}

$analyzer = Join-Path $PSScriptRoot 'analyze-world-run.py'
$pyArgs = @(
    $analyzer,
    '--log', $stderrLog,
    '--stdout', $stdoutLog,
    '--frames-dir', $framesDir,
    '--out-json', $summaryJson,
    '--out-md', $reportMd
)
if ($LevelsOnDemand) {
    $pyArgs += '--expect-levels-on-demand'
}
if ($BaselineJson) {
    $pyArgs += @('--baseline', $BaselineJson)
}

& python -B @pyArgs
exit $LASTEXITCODE
