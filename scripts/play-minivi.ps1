# Portable MiniVI launcher for 8 GB VRAM / 16-32 GB RAM systems (Series S / X profile),
# rebased onto VIctory-NVIDIA (foxhound + DLSS/FG + F1 menu + F3 overlay).
# Supply -Exe or set $env:VICTORY_GAME_DIR before launching.
param(
    [string]$Exe,
    [ValidateSet('perf-540p', 'balanced-720p', 'quality-720p', 'native-1080p')][string]$Preset = 'balanced-720p',
    [ValidateSet('diag', 'release')][string]$Build = 'diag',
    [ValidateSet('series-s', 'series-x')][string]$Console = 'series-s',
    [ValidateSet('off', 'dlaa', 'quality', 'balanced', 'performance', 'ultraperformance')][string]$Dlss = 'quality',
    [ValidateSet('off', 'auto', '2x', '3x', '4x', '5x', '6x')][string]$FrameGen = 'off',
    [ValidateSet('auto', 'dlss', 'fsr3')][string]$FrameGenType = 'auto',
    [switch]$NoSmoothMotion,
    [switch]$RayTracing,
    [switch]$Amd,
    [switch]$SkipBink,
    [string]$Adapter,
    [hashtable]$More = @{}
)

if (-not $Exe -and $env:VICTORY_GAME_DIR) {
    $candidate = Join-Path $env:VICTORY_GAME_DIR 'game_scarlett_master.exe'
    if (Test-Path $candidate) { $Exe = $candidate }
}
if (-not $Exe -or -not (Test-Path $Exe)) {
    Write-Host "Pass -Exe <path\to\game_scarlett_master.exe> or set `$env:VICTORY_GAME_DIR."
    exit 1
}

$scale = switch ($Preset) {
    'perf-540p'     { '0.5' }
    'balanced-720p' { '0.6666667' }
    'quality-720p'  { '0.6666667' }
    'native-1080p'  { '1.0' }
}
$maxDim = switch ($Preset) {
    'perf-540p'     { '1024' }
    'balanced-720p' { '1024' }
    'quality-720p'  { '2048' }
    'native-1080p'  { '2048' }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$settings = @{
    # VIctory-NVIDIA / foxhound core switches
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
    VICTORY_WC_NO_BACK              = '1'
    VICTORY_WC_NO_BACK_MIN_KB       = '1024'
    VICTORY_SOFT_VIEWS              = 'copies'
    VICTORY_TEXTURE_POOL            = '1'
    VICTORY_RIPE_BLOCKS             = '0'
    VICTORY_TEXTURE_NO_WAIT         = '1'
    VICTORY_TEXTURE_CATCHUP         = '0'
    VICTORY_TEXTURE_STAGE_MS        = '16'
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

    # MiniVI 8 GB VRAM / 16-32 GB RAM guards + watchdog/scrubbing
    VICTORY_NO_WATCHDOG             = '1'
    VICTORY_LEVELS_ON_DEMAND        = '1'
    VICTORY_LEVELS_ALL              = '1'
    VICTORY_LEVELS_MAX_DIM          = $maxDim
    VICTORY_LEVELS_RECLAIM          = '1'
    VICTORY_CARD_BUFFERS_MB         = '1024'
    VICTORY_CARD_WINDOWS_MB         = '256'
    VICTORY_CARD_ROOM_FOR_TARGETS_MB = '512'
    VICTORY_DSTORAGE_STAGING_MB     = '64'
    VICTORY_READBACK_POOL           = '1'
    VICTORY_READBACK_POOL_MB        = '64'
    VICTORY_NAN_SCRUB               = '1'
    VICTORY_D3D12_DRED              = 'light'
}

if (-not $Amd -and $Dlss -ne 'off') {
    $slDir = if ($env:VICTORY_STREAMLINE_DIR) {
        $env:VICTORY_STREAMLINE_DIR
    } else {
        $bundled = Join-Path $repoRoot 'nvidia-sdk\Streamline\bin\x64'
        if (Test-Path $bundled) { $bundled } else { Join-Path $repoRoot 'nvidia-sdk' }
    }
    if (Test-Path $slDir) {
        $settings.VICTORY_STREAMLINE_DIR = $slDir
    }
    $settings.VICTORY_DLSS = '1'
    $settings.VICTORY_DLSS_MODE = $Dlss
    $settings.VICTORY_MENU_DLSS = $Dlss
} else {
    $settings.VICTORY_UPSCALER = '6'
    $settings.VICTORY_RENDER_SCALE = $scale
    $settings.VICTORY_MENU_DLSS = 'off'
}

$fgTimes = switch ($FrameGen) {
    'off'  { 0 }
    'auto' { 2 }
    default { [int]($FrameGen -replace 'x$', '') }
}
if ($fgTimes -ge 2) {
    if ($FrameGenType -eq 'fsr3' -or $Amd) {
        $settings.VICTORY_FSR_FRAMEGEN = '1'
    } else {
        $settings.VICTORY_FRAMEGEN = '1'
        $settings.VICTORY_TEXTURE_ROOM_PERCENT = '80'
    }
    $settings.VICTORY_FRAMEGEN_X = [string]$fgTimes
    $settings.VICTORY_MENU_FRAMEGEN = [string]$fgTimes
} else {
    $settings.VICTORY_MENU_FRAMEGEN = '0'
}

if ($RayTracing) {
    $settings.VICTORY_BVH_BUILDER = '1'
    $settings.VICTORY_RAYS = '1'
    $settings.VICTORY_FIRSTLANE_OWN = '1'
    $settings.VICTORY_RT_MEMORY_MB = '1024'
    $settings.VICTORY_BVH_FAULTS_ALL = '8192'
    $settings.VICTORY_AMBIENT_RT = '0.5,2.0,0.8'
    $settings.VICTORY_CARD_BUFFERS_MB = '512'
    foreach ($off in 'VICTORY_AMBIENT', 'VICTORY_AMBIENT_AIR', 'VICTORY_AMBIENT_SPECULAR') {
        $settings.Remove($off)
    }
}

if ($Amd) {
    foreach ($off in 'VICTORY_RELAY', 'VICTORY_RELAY_COPY', 'VICTORY_DLSS', 'VICTORY_DLSS_MODE', 'VICTORY_FRAMEGEN') {
        $settings.Remove($off)
    }
}

if ($SkipBink) { $settings.VICTORY_SKIP_BINK = '1' }
if ($Adapter) { $settings.VICTORY_ADAPTER = $Adapter }
foreach ($k in $More.Keys) { $settings[$k] = $More[$k] }

$targetRoot = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $repoRoot 'target' }
$victory = Join-Path $targetRoot "$Build\victory.exe"
if (-not (Test-Path $victory)) {
    Write-Host "Missing $victory. Build first with: cargo build --locked --profile $Build -p victory"
    exit 1
}

if (-not $NoSmoothMotion -and $fgTimes -eq 0) {
    $sm = Join-Path (Split-Path $victory) 'victory_sm.exe'
    if (-not (Test-Path $sm) -or (Get-Item $sm).LastWriteTime -lt (Get-Item $victory).LastWriteTime) {
        Copy-Item $victory $sm -Force
    }
    $victory = $sm
}

$keep = 'VICTORY_CONFIG', 'VICTORY_GAME_DIR', 'VICTORY_CACHE_DIR', 'VICTORY_DATA_DIR', 'VICTORY_STREAMLINE_DIR', 'VICTORY_FIDELITYFX_DIR'
Get-ChildItem Env:VICTORY_* | Where-Object { $_.Name -notin $keep } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
foreach ($k in $settings.Keys) { Set-Item "Env:$k" $settings[$k] }

$Exe = (Resolve-Path $Exe).Path
Write-Host "MiniVI ($Preset, $Console, DLSS=$Dlss, FG=$FrameGen, max mip ${maxDim}px)"
Push-Location $repoRoot
try { & $victory run $Exe --execute --console $Console } finally { Pop-Location }
