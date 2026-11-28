# Portable MiniVI launcher for Windows (Series S / X profile),
# rebased onto VIctory-NVIDIA (foxhound + DLSS/FG + F1 menu + F3 overlay).
# Supply -Exe, set $env:VICTORY_GAME_DIR, or configure game_dir in victory.toml.
param(
    [string]$Exe,
    [ValidateSet('perf-540p', 'balanced-720p', 'quality-720p', 'native-1080p')][string]$Preset = 'balanced-720p',
    [ValidateSet('diag', 'release')][string]$Build = 'release',
    [ValidateSet('series-s', 'series-x')][string]$Console = 'series-s',
    [ValidateSet('off', 'dlaa', 'quality', 'balanced', 'performance', 'ultraperformance')][string]$Dlss = 'quality',
    [ValidateSet('off', 'auto', '2x', '3x', '4x', '5x', '6x')][string]$FrameGen = 'off',
    [ValidateSet('auto', 'dlss', 'fsr3')][string]$FrameGenType = 'auto',
    [switch]$FrameGenReady,
    [switch]$NoFrameGenReady,
    [ValidateRange(1, 1000)][int]$Fps = 1000,
    [switch]$LowVram,
    [switch]$HighVram,
    [switch]$LazyCompare,
    [switch]$WindowGrow,
    [switch]$Preload,
    [switch]$NoSmoothMotion,
    [switch]$RayTracing,
    [switch]$Amd,
    [switch]$SkipBink,
    [string]$Adapter,
    [hashtable]$More = @{}
)

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if (-not $Exe -and $env:VICTORY_GAME_DIR) {
    $candidate = Join-Path $env:VICTORY_GAME_DIR 'game_scarlett_master.exe'
    if (Test-Path $candidate) { $Exe = $candidate }
}
if (-not $Exe) {
    $tomlPath = Join-Path $repoRoot 'victory.toml'
    if (Test-Path $tomlPath) {
        foreach ($line in Get-Content -LiteralPath $tomlPath) {
            if ($line -match "^\s*game_dir\s*=\s*['""]([^'""]+)['""]") {
                $candidate = Join-Path $Matches[1] 'game_scarlett_master.exe'
                if (Test-Path $candidate) { $Exe = $candidate; break }
            }
        }
    }
}
if (-not $Exe -or -not (Test-Path $Exe)) {
    Write-Host "Pass -Exe <path\to\game_scarlett_master.exe>, set `$env:VICTORY_GAME_DIR, or set game_dir in victory.toml."
    exit 1
}

# Read F1 menu overrides if present and respect VICTORY_PRELOAD=1 restarts.
$preloadRequested = $Preload -or ($env:VICTORY_PRELOAD -eq '1')
$menuFile = Join-Path $repoRoot 'victory-settings.txt'
$menu = [ordered]@{}
if (Test-Path -LiteralPath $menuFile) {
    foreach ($line in Get-Content -LiteralPath $menuFile) {
        if ($line -match '^\s*(VICTORY_[A-Z0-9_]+)\s*=(.*)$') { $menu[$Matches[1]] = $Matches[2].Trim() }
    }
}
$fpsWanted = $Fps
if ($menu.Contains('VICTORY_MENU_CONSOLE') -and $menu['VICTORY_MENU_CONSOLE'] -in 'series-s', 'series-x') {
    $Console = $menu['VICTORY_MENU_CONSOLE']
}
if ($menu['VICTORY_MENU_DLSS'] -in 'off', 'dlaa', 'quality', 'balanced', 'performance', 'ultraperformance') {
    $Dlss = $menu['VICTORY_MENU_DLSS']
}
if ($menu.Contains('VICTORY_MENU_FRAMEGEN')) {
    $mv = $menu['VICTORY_MENU_FRAMEGEN']
    if ($mv -eq '0') { $FrameGen = 'off' }
    elseif ($mv -eq '1') { $FrameGen = '2x' }
    elseif ($mv -match '^[2-6]$') { $FrameGen = "${mv}x" }
}
if ($menu['VICTORY_MENU_FG_TYPE'] -in 'auto', 'dlss', 'fsr') {
    $FrameGenType = if ($menu['VICTORY_MENU_FG_TYPE'] -eq 'fsr') { 'fsr3' } else { $menu['VICTORY_MENU_FG_TYPE'] }
}
if ($menu['VICTORY_MENU_FPS'] -match '^\d+$' -and [int]$menu['VICTORY_MENU_FPS'] -ge 1 -and [int]$menu['VICTORY_MENU_FPS'] -le 1000) {
    $fpsWanted = [int]$menu['VICTORY_MENU_FPS']
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

# Detect GPU name and dedicated VRAM (MiB) to auto-select low-VRAM vs >9 GiB profile.
$gpuName = ''
$vramMiB = 0
if (-not $Amd -and (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
    try {
        $smiOut = (& nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
        if ($smiOut -and ($smiOut -match '^(.*?),\s*(\d+)\s*$')) {
            $gpuName = $Matches[1].Trim()
            $vramMiB = [int]$Matches[2]
        }
    } catch {}
}
if ($vramMiB -le 0) {
    try {
        $pattern = if ($Amd) { 'AMD|Radeon' } else { 'NVIDIA|AMD|Radeon|Intel' }
        $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $pattern -and $_.AdapterRAM -gt 0 } |
            Sort-Object AdapterRAM -Descending
        $pick = $gpus | Select-Object -First 1
        if ($pick) {
            if (-not $gpuName) { $gpuName = $pick.Name }
            $vramMiB = [int][Math]::Round($pick.AdapterRAM / 1MB)
        }
    } catch {}
}

$isLowVram = if ($LowVram) {
    $true
} elseif ($HighVram) {
    $false
} elseif ($vramMiB -gt 0) {
    $vramMiB -le 9728
} else {
    $true
}

$settings = @{
    # VIctory-NVIDIA / foxhound core switches
    VICTORY_THIN                = '1'
    VICTORY_JOIN_PARTS          = '8'
    VICTORY_RELAY               = '2'
    VICTORY_RELAY_COPY          = '1'
    VICTORY_WIDE_BACK           = '1'
    VICTORY_CARD_REHASH_RUNS    = '1'
    VICTORY_JOIN_COPIES         = '1'
    VICTORY_CARD_STEPS          = '2'
    VICTORY_CARD_AWAKE          = '0'
    VICTORY_CARD_BUFFERS_MIN_KB = '64'
    VICTORY_INDIRECT_WINDOW     = '1'
    VICTORY_INDIRECT_BATCH      = '2'
    VICTORY_UPLOAD_AHEAD        = '1'
    VICTORY_SHOW_AFTER          = '1'
    VICTORY_MAP_THREADS         = '1'
    VICTORY_WC_NO_BACK          = '1'
    VICTORY_WC_NO_BACK_MIN_KB   = '1024'
    VICTORY_SOFT_VIEWS          = 'copies'
    VICTORY_TEXTURE_POOL        = '1'
    VICTORY_RIPE_BLOCKS         = '0'
    VICTORY_TEXTURE_NO_WAIT     = '1'
    VICTORY_PRELUDE_UPLOADS     = '1'
    VICTORY_SHOW_NEW_LATER      = '1'
    VICTORY_POOL_SMALL          = '0'
    VICTORY_TABLED_REREAD       = '1'
    VICTORY_QUEUE_HOST_TEXTURES = '0'
    VICTORY_HEAP_SYNC_FIRST     = '1'
    VICTORY_SYNC_IN_PLACE       = '1'
    VICTORY_SPANS_QUICK         = '1'
    VICTORY_SYNC_FINE           = '1'
    VICTORY_HEAP_SYNC_AT_SUBMIT = '1'
    VICTORY_AMBIENT             = '0.8'
    VICTORY_AMBIENT_AIR         = '1.5'
    VICTORY_AMBIENT_SPECULAR    = '1'
    VICTORY_EARLY_DEPTH         = '1'
    VICTORY_LEAVE_OUT           = '731a39171b568298'
    VICTORY_PIPELINE_BOOK       = '1'

    # Watchdog & NaN scrubbing
    VICTORY_NO_WATCHDOG         = '1'
    VICTORY_NAN_SCRUB           = '1'
}

if ($Build -eq 'diag') {
    $settings.VICTORY_D3D12_DRED = 'light'
}

if ($isLowVram) {
    # 8 GB VRAM / tight-budget guards
    $settings.VICTORY_LEVELS_ON_DEMAND         = '1'
    $settings.VICTORY_LEVELS_ALL               = '1'
    $settings.VICTORY_LEVELS_MAX_DIM           = $maxDim
    $settings.VICTORY_LEVELS_RECLAIM           = '1'
    $settings.VICTORY_TEXTURE_CATCHUP          = '0'
    $settings.VICTORY_TEXTURE_STAGE_MS         = '16'
    $settings.VICTORY_CARD_BUFFERS_MB          = '1024'
    $settings.VICTORY_CARD_WINDOWS_MB          = '256'
    $settings.VICTORY_CARD_ROOM_FOR_TARGETS_MB = '512'
    $settings.VICTORY_DSTORAGE_STAGING_MB      = '64'
    $settings.VICTORY_READBACK_POOL            = '1'
    $settings.VICTORY_READBACK_POOL_MB         = '64'
} else {
    # >9 GiB VRAM profile: full mip chains, catch-up enabled, and VRAM-scaled budgets
    $settings.VICTORY_LEVELS_ON_DEMAND         = '0'
    $settings.VICTORY_TEXTURE_CATCHUP          = '1'
    $settings.VICTORY_TEXTURE_STAGE_MS         = '24'
    $settings.VICTORY_DSTORAGE_STAGING_MB      = '128'
    $settings.VICTORY_READBACK_POOL            = '1'
    $settings.VICTORY_READBACK_POOL_MB         = '256'
}

# CPU-scaled worker thread pools and placed-order scheduling
$cpus = [Environment]::ProcessorCount
if ($env:MINIVI_NO_TUNE -ne '1') {
    $settings.VICTORY_PLACED_ORDER    = '1'
    $settings.VICTORY_TEXSPK_PASS_MS  = '8'
    $settings.VICTORY_PASSES_HOT      = '1'
    $settings.VICTORY_HELPER_PRIORITY = '1'
    if ($cpus -ge 24) {
        $settings.VICTORY_THIN_THREADS  = '12'
        $settings.VICTORY_UNDER_THREADS = '8'
        $settings.VICTORY_LAND_THREADS  = '8'
    } elseif ($cpus -ge 16) {
        $settings.VICTORY_THIN_THREADS  = '12'
        $settings.VICTORY_UNDER_THREADS = '8'
        $settings.VICTORY_LAND_THREADS  = '6'
    } elseif ($cpus -ge 8) {
        $settings.VICTORY_THIN_THREADS  = '8'
        $settings.VICTORY_UNDER_THREADS = '6'
        $settings.VICTORY_LAND_THREADS  = '4'
    }
}

if ($fpsWanted -gt 0) {
    $settings.VICTORY_FRAME_INTERVAL_US = [string][int][Math]::Round(1000000 / $fpsWanted)
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
    'auto' { if (-not $Amd -and $gpuName -match 'RTX\s*50\d\d') { 4 } else { 2 } }
    default { [int]($FrameGen -replace 'x$', '') }
}
if ($fgTimes -ge 2) {
    if ($FrameGenType -eq 'fsr3' -or $Amd) {
        $settings.VICTORY_FSR_FRAMEGEN = '1'
    } else {
        $settings.VICTORY_FRAMEGEN = '1'
        $settings.VICTORY_TEXTURE_ROOM_PERCENT = if ($fgTimes -gt 2) { '74' } else { '80' }
    }
    $settings.VICTORY_FRAMEGEN_X = [string]$fgTimes
    $settings.VICTORY_MENU_FRAMEGEN = [string]$fgTimes
} else {
    if ($FrameGenReady -and -not $NoFrameGenReady -and -not $Amd -and $Dlss -ne 'off' -and $settings.VICTORY_STREAMLINE_DIR -and (Test-Path (Join-Path $settings.VICTORY_STREAMLINE_DIR 'sl.interposer.dll'))) {
        # Keep Streamline frame generation ready (off) only when asked with -FrameGenReady.
        $settings.VICTORY_FRAMEGEN = '1'
        $settings.VICTORY_FRAMEGEN_X = '0'
        $settings.VICTORY_TEXTURE_ROOM_PERCENT = '86'
    }
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
if ($LazyCompare) {
    $settings.VICTORY_LAZY_COMPARE_MB = '64'
    $settings.VICTORY_LAZY_NARROW     = '1'
}
if ($WindowGrow) { $settings.VICTORY_WINDOW_GROW = '1' }
if ($Adapter) { $settings.VICTORY_ADAPTER = $Adapter }

# Apply any custom F1 menu switches saved in victory-settings.txt.
foreach ($k in $menu.Keys) {
    if ($k -like 'VICTORY_MENU_*') { continue }
    if ($menu[$k]) { $settings[$k] = $menu[$k] } else { $settings.Remove($k) }
}
foreach ($k in $More.Keys) { $settings[$k] = $More[$k] }

# F1 menu metadata so "Save and restart" / "Preload shaders" work cleanly.
$Exe = (Resolve-Path $Exe).Path
$menuFgType = if ($FrameGenType -eq 'fsr3') { 'fsr' } else { $FrameGenType }
$settings.VICTORY_MENU_CONSOLE = $Console
$settings.VICTORY_MENU_RES = if ($Console -eq 'series-s') { '1080to1440' } else { '1440' }
$settings.VICTORY_MENU_FG_TYPE = $menuFgType
$settings.VICTORY_MENU_FPS = [string]$fpsWanted
$settings.VICTORY_MENU_FILE = $menuFile
$settings.VICTORY_MENU_PLAY = $MyInvocation.MyCommand.Path
$settings.VICTORY_MENU_EXE = $Exe
$settings.VICTORY_MENU_CWD = $PWD.ProviderPath
$settings.VICTORY_MENU_ARGS = "-Exe `$env:VICTORY_MENU_EXE -Preset $Preset -Build $Build$(if ($FrameGenReady -and -not $NoFrameGenReady) { ' -FrameGenReady' })"

$targetRoot = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $repoRoot 'target' }
$victory = Join-Path $targetRoot "$Build\victory.exe"
if (-not (Test-Path $victory)) {
    $buildCmd = if ($Build -eq 'diag') {
        "cargo build --locked --profile diag --features diagnostics -p victory"
    } else {
        "cargo build --locked --release -p victory"
    }
    Write-Host "Missing $victory. Build first with: $buildCmd"
    exit 1
}

if (-not $NoSmoothMotion -and $fgTimes -eq 0) {
    $sm = Join-Path (Split-Path $victory) 'victory_sm.exe'
    if (-not (Test-Path $sm) -or (Get-Item $sm).LastWriteTime -lt (Get-Item $victory).LastWriteTime) {
        Copy-Item $victory $sm -Force
    }
    $victory = $sm
}

$keep = 'VICTORY_HOME', 'VICTORY_ADAPTER', 'VICTORY_CONFIG', 'VICTORY_GAME_DIR', 'VICTORY_CACHE_DIR', 'VICTORY_DATA_DIR', 'VICTORY_STREAMLINE_DIR', 'VICTORY_FIDELITYFX_DIR'
Get-ChildItem Env:VICTORY_* | Where-Object { $_.Name -notin $keep } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
foreach ($k in $settings.Keys) { Set-Item "Env:$k" $settings[$k] }

$vramLabel = if ($isLowVram) { "low-VRAM (<=9 GiB, max mip ${maxDim}px)" } else { "high-VRAM (>9 GiB, full mips)" }
$fgLabel = if ($fgTimes -ge 2) { "${fgTimes}x" } else { 'off' }
Write-Host "MiniVI ($Preset, $Build, $Console, DLSS=$Dlss, FG=$fgLabel, $vramLabel, ${cpus} CPUs)"

Push-Location $repoRoot
try {
    if ($preloadRequested) {
        Write-Host 'Preloading shaders and recorded pipelines before launch ...'
        & $victory preload ([IO.Path]::GetDirectoryName($Exe))
    }
    & $victory run $Exe --execute --console $Console
} finally {
    Pop-Location
}
