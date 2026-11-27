# Portable MiniVI launcher for 8 GB VRAM / 16-32 GB RAM systems (Series S / X profile).
# Supply -Exe or set $env:VICTORY_GAME_DIR before launching.
param(
    [string]$Exe,
    [ValidateSet('perf-540p', 'balanced-720p', 'quality-720p', 'native-1080p')][string]$Preset = 'balanced-720p',
    [ValidateSet('diag', 'release')][string]$Build = 'diag',
    [ValidateSet('series-s', 'series-x')][string]$Console = 'series-s',
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

$settings = @{
    VICTORY_TEXTURE_NO_WAIT   = '1'
    VICTORY_RELAY             = '2'
    VICTORY_CARD_STEPS        = '2'
    VICTORY_WIDE_BACK         = '1'
    VICTORY_CARD_REHASH_RUNS  = '1'
    VICTORY_JOIN_COPIES       = '1'
    VICTORY_INDIRECT_WINDOW   = '1'
    VICTORY_RELAY_COPY        = '1'
    VICTORY_INDIRECT_BATCH    = '2'
    VICTORY_MAP_THREADS       = '1'
    VICTORY_TITLE_PRIORITIES  = '0'
    VICTORY_CARD_AWAKE        = '1'
    VICTORY_SHOW_AFTER        = '1'
    VICTORY_THIN              = '0'
    VICTORY_JOIN_PARTS        = '0'
    VICTORY_UPLOAD_AHEAD      = '1'
    VICTORY_AMBIENT           = '1.4'
    VICTORY_AMBIENT_AIR       = '1.5'
    VICTORY_AMBIENT_MOST      = '2'
    VICTORY_AMBIENT_SETTLE    = '250,3'
    VICTORY_NAN_SCRUB         = '1'
    VICTORY_RENDER_SCALE      = $scale
    VICTORY_UPSCALER          = '6'
    VICTORY_BVH_MISS          = '1'
    VICTORY_DYNAMIC_SLOTS     = '524288'
    VICTORY_CARD_BUFFERS_MIN_KB = '64'
    VICTORY_CARD_BUFFERS_MB   = '1024'
    VICTORY_CARD_WINDOWS_MB   = '256'
    VICTORY_CARD_ROOM_FOR_TARGETS_MB = '1024'
    VICTORY_TEXTURE_ROOM_PERCENT = '92'
    VICTORY_DSTORAGE_STAGING_MB = '64'
    VICTORY_EARLY_TEXTURES_MS = '35'
    VICTORY_BAKE_TEXTURES_MS  = '1500'
    VICTORY_LEVELS_ON_DEMAND  = '1'
    VICTORY_LEVELS_ALL        = '1'
    VICTORY_LEVELS_MAX_DIM    = $maxDim
    VICTORY_LEVELS_RECLAIM    = '1'
    VICTORY_READBACK_POOL     = '1'
    VICTORY_READBACK_POOL_MB  = '64'
    VICTORY_PORT_GUARD        = '1'
    VICTORY_PORT_JOURNAL      = '1'
    VICTORY_PORT_CONSTANTS    = '1'
    VICTORY_PORT_CBV          = '0'
    VICTORY_RT_NO_ARENAS      = '1'
    VICTORY_LIBRARY_STORE_LATER = '1'
    VICTORY_PIPELINE_WAIT_MS  = '150'
    VICTORY_PIPELINE_WORKERS  = '6'
    VICTORY_PIPELINE_LOWEST   = '1'
    VICTORY_D3D12_DRED        = 'light'
}

if ($Preset -eq 'quality-720p' -or $Preset -eq 'native-1080p') {
    $settings.VICTORY_AMBIENT_SHADE = '1.2,0.85'
}

if ($RayTracing) {
    $settings.VICTORY_BVH_BUILDER = '1'
    $settings.VICTORY_FIRSTLANE_OWN = '1'
    $settings.VICTORY_RT_MEMORY_MB = '1024'
    $settings.VICTORY_BVH_FAULTS_ALL = '8192'
    $settings.VICTORY_AMBIENT_RT = '0.5,2.0,0.8'
    $settings.VICTORY_CARD_BUFFERS_MB = '512'
    foreach ($off in 'VICTORY_BVH_MISS', 'VICTORY_RT_NO_ARENAS', 'VICTORY_AMBIENT', 'VICTORY_AMBIENT_AIR', 'VICTORY_AMBIENT_MOST', 'VICTORY_AMBIENT_SHADE', 'VICTORY_TEXTURE_MIP_DROP') {
        $settings.Remove($off)
    }
}
if ($Amd) {
    foreach ($off in 'VICTORY_RELAY', 'VICTORY_RELAY_COPY') {
        $settings.Remove($off)
    }
    $settings.VICTORY_THIN = '1'
    $settings.VICTORY_JOIN_PARTS = '8'
    $settings.VICTORY_PORT_CONSTANTS = '1'
    $settings.VICTORY_PORT_CBV = '1'
}
if ($SkipBink) { $settings.VICTORY_SKIP_BINK = '1' }
if ($Adapter) { $settings.VICTORY_ADAPTER = $Adapter }
foreach ($k in $More.Keys) { $settings[$k] = $More[$k] }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$targetRoot = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $repoRoot 'target' }
$victory = Join-Path $targetRoot "$Build\victory.exe"
if (-not (Test-Path $victory)) {
    Write-Host "Missing $victory. Build first with: cargo build --locked --profile $Build -p victory"
    exit 1
}

if (-not $NoSmoothMotion) {
    $sm = Join-Path (Split-Path $victory) 'victory_sm.exe'
    if (-not (Test-Path $sm) -or (Get-Item $sm).LastWriteTime -lt (Get-Item $victory).LastWriteTime) {
        Copy-Item $victory $sm -Force
    }
    $victory = $sm
}

$keep = 'VICTORY_CONFIG', 'VICTORY_GAME_DIR', 'VICTORY_CACHE_DIR', 'VICTORY_DATA_DIR'
Get-ChildItem Env:VICTORY_* | Where-Object { $_.Name -notin $keep } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
foreach ($k in $settings.Keys) { Set-Item "Env:$k" $settings[$k] }

$Exe = (Resolve-Path $Exe).Path
Write-Host "MiniVI ($Preset, $Console, max mip ${maxDim}px, render scale $scale)"
Push-Location $repoRoot
try { & $victory run $Exe --execute --console $Console } finally { Pop-Location }
