# HAOAH Blender Extensions
# yi jian fa bu jiao ben
# yong fa: .\release.ps1 [-Push]

param(
    [switch]$Push
)

$ErrorActionPreference = "Stop"

# ============================ config ============================
$blenderExe = "G:\steam\steamapps\common\Blender\blender.exe"
$addonsSource = "F:\desktop\BaiduSyncdisk\addons"
$repoRoot = "F:\desktop\BaiduSyncdisk\blender-extensions-repo"
$packagesDir = Join-Path $repoRoot "packages"
$tempRoot = "$env:TEMP\blender-ext-release"

# ============================ parse bl_info ============================
function Get-BlInfo($addonDir) {
    $init = Join-Path $addonDir "__init__.py"
    if (-not (Test-Path $init)) { return $null }

    $content = Get-Content $init -Raw -Encoding UTF8

    $blInfoStart = $content.IndexOf('bl_info')
    if ($blInfoStart -lt 0) { return $null }
    
    $braceStart = $content.IndexOf('{', $blInfoStart)
    if ($braceStart -lt 0) { return $null }
    
    $depth = 0
    $endPos = -1
    for ($i = $braceStart; $i -lt $content.Length; $i++) {
        $ch = $content[$i]
        if ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') {
            $depth--
            if ($depth -eq 0) { $endPos = $i; break }
        }
    }
    if ($endPos -lt 0) { return $null }

    $raw = $content.Substring($braceStart + 1, $endPos - $braceStart - 1)
    $info = @{}

    if ($raw -match '"name"\s*:\s*"(.+?)"')           { $info.name = $matches[1] }
    if ($raw -match '"author"\s*:\s*"(.+?)"')         { $info.author = $matches[1] }
    if ($raw -match '"description"\s*:\s*"(.+?)"')     { $info.description = $matches[1] }
    if ($raw -match '"category"\s*:\s*"(.+?)"')       { $info.category = $matches[1] }
    if ($raw -match '"version"\s*:\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)') {
        $info.version = "$($matches[1]).$($matches[2]).$($matches[3])"
    } elseif ($raw -match '"version"\s*:\s*\(\s*(\d+)\s*,\s*(\d+)\s*\)') {
        $info.version = "$($matches[1]).$($matches[2]).0"
    }
    if ($raw -match '"blender"\s*:\s*\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)') {
        $info.blender_min = "$($matches[1]).$($matches[2]).$($matches[3])"
    } elseif ($raw -match '"blender"\s*:\s*\(\s*(\d+)\s*,\s*(\d+)\s*\)') {
        $info.blender_min = "$($matches[1]).$($matches[2]).0"
    }

    return $info
}

# ============================ category -> tags ============================
function Get-Tags($category) {
    switch -Wildcard ($category) {
        "Render*"        { return @("Render") }
        "Animation*"     { return @("Animation") }
        "Compositing*"   { return @("Compositing") }
        "Import-Export*" { return @("Import-Export") }
        "3D View*"       { return @("3D View") }
        "System*"        { return @("Pipeline", "System") }
        "Material*"      { return @("Material") }
        "Rigging*"       { return @("Rigging") }
        default          { return @("Pipeline") }
    }
}

# ============================ generate manifest ============================
function New-Manifest($id, $info) {
    $tags = Get-Tags $info.category
    $tagsStr = ($tags | ForEach-Object { '"' + $_ + '"' }) -join ", "

    $desc = $info.description
    if ($desc.Length -gt 100) {
        $desc = $desc.Substring(0, 97) + "..."
    }

    $lines = @()
    $lines += 'schema_version = "1.0.0"'
    $lines += ''
    $lines += 'id = "' + $id + '"'
    $lines += 'version = "' + $info.version + '"'
    $lines += 'name = "' + $info.name + '"'
    $lines += 'tagline = "' + $desc + '"'
    $lines += 'maintainer = "' + $info.author + '"'
    $lines += ''
    $lines += 'type = "add-on"'
    $lines += ''
    $lines += 'tags = [' + $tagsStr + ']'
    $lines += ''
    $lines += 'blender_version_min = "' + $info.blender_min + '"'
    $lines += ''
    $lines += 'license = ['
    $lines += '  "SPDX:GPL-3.0-or-later",'
    $lines += ']'

    return ($lines -join [Environment]::NewLine)
}

# ============================ clean temp ============================
function Clear-TempPackage($dir) {
    # __pycache__ / .git / .gitignore
    Get-ChildItem $dir -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem $dir -Recurse -File -Filter ".gitignore" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $dir -Recurse -File -Filter "*.zip" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $dir -Recurse -Directory -Filter ".git" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem $dir -Recurse -Directory -Filter ".~stale~*" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    # dev directories ---- do not ship to users
    @("dev_plans", "_plans", "docs", "plans", "notes", ".vscode", ".idea", "__MACOSX") | ForEach-Object {
        Get-ChildItem $dir -Recurse -Directory -Filter $_ -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    # dev plan / temp files ---- do not ship to users
    Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like '*计划*' -or $_.Name -like '*开发*' -or $_.Name -like '*进度*' -or
        $_.Name -like '*plan*' -or $_.Name -like '*TODO*' -or
        $_.Name -like '*CHANGELOG*' -or $_.Name -like '*VERSION*' -or
        $_.Name -like 'plan_*' -or $_.Name -like 'plan-*' -or $_.Name -like '*_plan.*' -or
        $_.Name -like '_temp_*' -or $_.Name -like '*.tmp'
    } | Remove-Item -Force -ErrorAction SilentlyContinue

    # empty / $null files
    Get-ChildItem $dir -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq '$null' -or $_.Name -eq '' } | Remove-Item -Force -ErrorAction SilentlyContinue
}

# ============================ main ============================
Write-Host ""
Write-Host "=== HAOAH Blender Extensions Release ===" -ForegroundColor Cyan
Write-Host ""

$exclude = @(".~stale~*", "qingjian_AEScripts-main")
$addonDirs = Get-ChildItem $addonsSource -Directory | Where-Object {
    $name = $_.Name
    foreach ($pat in $exclude) {
        if ($name -like $pat) { return $false }
    }
    return (Test-Path (Join-Path $_.FullName "__init__.py"))
}

if (-not $addonDirs) {
    Write-Host "ERROR: no addon source directories found." -ForegroundColor Red
    exit 1
}

Write-Host "Found $($addonDirs.Count) addons:" -ForegroundColor Green
$addonDirs | ForEach-Object { Write-Host "  $($_.Name)" }

New-Item -ItemType Directory -Force -Path $packagesDir | Out-Null

Write-Host ""
Write-Host "Cleaning old packages..." -ForegroundColor Yellow
$oldZips = Get-ChildItem $packagesDir -Filter "*.zip" -ErrorAction SilentlyContinue
if ($oldZips) {
    $oldZips | Remove-Item -Force
    Write-Host "  removed $($oldZips.Count) old zip(s)"
}

$processed = 0
foreach ($dir in $addonDirs) {
    $id = $dir.Name -replace '-master$', ''
    $info = Get-BlInfo $dir.FullName

    if (-not $info -or -not $info.ContainsKey('version')) {
        Write-Host "  SKIP $($dir.Name): cannot parse bl_info" -ForegroundColor DarkYellow
        continue
    }

    Write-Host ""
    Write-Host "--- $($dir.Name) -> $id v$($info.version) ---" -ForegroundColor Cyan

    $tmp = Join-Path $tempRoot $id
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    Copy-Item -Recurse -Path $dir.FullName -Destination $tmp

    Clear-TempPackage $tmp

    $manifest = New-Manifest $id $info
    $manifestPath = Join-Path $tmp "blender_manifest.toml"
    [System.IO.File]::WriteAllText($manifestPath, $manifest, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  -> blender_manifest.toml"

    $zipName = "$id-$($info.version).zip"
    $zipPath = Join-Path $packagesDir $zipName

    Push-Location $tmp
    try {
        $items = Get-ChildItem -Path $tmp
        Compress-Archive -Path $items.FullName -DestinationPath $zipPath -Force
        $sizeKB = [math]::Round((Get-Item $zipPath).Length / 1KB, 1)
        Write-Host "  -> $zipName (${sizeKB} KB)" -ForegroundColor Green
        $processed++
    } finally {
        Pop-Location
    }
}

Write-Host ""
Write-Host "Packaged: $processed extension(s)" -ForegroundColor Green

# ============================ generate index ============================
Write-Host ""
Write-Host "Generating index.json..." -ForegroundColor Cyan
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$result = & $blenderExe --command extension server-generate --repo-dir=$packagesDir 2>&1
$ErrorActionPreference = $prevEAP
$foundMatch = $result | Select-String "found (\d+) packages"
if ($foundMatch) {
    $count = $foundMatch.Matches.Groups[1].Value
    Write-Host "  recognized: $count extension(s)" -ForegroundColor Green
} else {
    Write-Host "  WARNING: cannot confirm index generation status" -ForegroundColor Yellow
}

# ============================ git push ============================
if ($Push) {
    Write-Host ""
    Write-Host "Pushing to GitHub..." -ForegroundColor Cyan
    Push-Location $repoRoot
    try {
        git add packages/
        $gitStatus = git status -s
        if ($gitStatus) {
            $date = Get-Date -Format "yyyy-MM-dd HH:mm"
            git commit -m "release: $date - $processed extension(s)"
            git push
            Write-Host "  pushed." -ForegroundColor Green
        } else {
            Write-Host "  no changes, skip." -ForegroundColor DarkYellow
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Host ""
    Write-Host "Skip push (add -Push to auto-push to GitHub)" -ForegroundColor DarkYellow
}

Write-Host ""
Write-Host "=== DONE ===" -ForegroundColor Cyan
Write-Host "local packages: $packagesDir"
if (-not $Push) {
    Write-Host "review OK then: git add packages/; git commit; git push"
}