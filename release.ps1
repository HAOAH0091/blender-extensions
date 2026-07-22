# HAOAH Blender Extensions
# yi jian fa bu jiao ben
# yong fa: .\release.ps1

# Any unexpected error should terminate immediately.
$ErrorActionPreference = "Stop"

# ============================ helpers ============================

function ConvertTo-TomlString($s) {
    # Escape special characters in TOML basic strings: backslash and double-quote.
    if (-not $s) { return "" }
    return $s.Replace('\', '\\').Replace('"', '\"')
}

function Safe-Substring($s, $maxLen) {
    # Truncate by character count, avoiding surrogate-pair split.
    if ($s.Length -le $maxLen) { return $s }
    $result = ""
    $i = 0
    $count = 0
    while ($i -lt $s.Length -and $count -lt $maxLen) {
        if ([char]::IsHighSurrogate($s[$i]) -and ($i + 1) -lt $s.Length -and [char]::IsLowSurrogate($s[$i + 1])) {
            $result += $s.Substring($i, 2)
            $i += 2
        } else {
            $result += $s[$i]
            $i++
        }
        $count++
    }
    return $result + "..."
}

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
    } else {
        $info.blender_min = "4.2.0"  # default: oldest Blender that supports extensions
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

    $desc = ConvertTo-TomlString (Safe-Substring $info.description 100)

    $lines = @()
    $lines += 'schema_version = "1.0.0"'
    $lines += ''
    $lines += 'id = "' + (ConvertTo-TomlString $id) + '"'
    $lines += 'version = "' + (ConvertTo-TomlString $info.version) + '"'
    $lines += 'name = "' + (ConvertTo-TomlString $info.name) + '"'
    $lines += 'tagline = "' + $desc + '"'
    $lines += 'maintainer = "' + (ConvertTo-TomlString $info.author) + '"'
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
    # __pycache__ / .git / .gitignore / .~stale~
    Get-ChildItem $dir -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem $dir -Recurse -File -Filter ".gitignore" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $dir -Recurse -File -Filter "*.zip" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $dir -Recurse -Directory -Filter ".git" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem $dir -Recurse -Directory -Filter ".~stale~*" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    # dev directories ---- do not ship to users
    @("dev_plans", "_plans", "docs", "plans", "notes", ".vscode", ".idea", "__MACOSX") | ForEach-Object {
        Get-ChildItem $dir -Recurse -Directory -Filter $_ -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

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

# ---- read existing index to detect version changes ----
$indexPath = Join-Path $packagesDir "index.json"
$oldVersions = @{}
if (Test-Path $indexPath) {
    try {
        $oldIndex = Get-Content $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $oldIndex.data | ForEach-Object { $oldVersions[$_.id] = $_.version }
        Write-Host "Existing index: $($oldVersions.Count) extension(s)"
    } catch {
        Write-Host "WARNING: cannot parse existing index, will package all" -ForegroundColor DarkYellow
    }
}

# ---- packaging: skip unchanged ----
$packaged = @()
$skipped = @()
foreach ($dir in $addonDirs) {
    $id = $dir.Name -replace '-master$', ''
    $info = Get-BlInfo $dir.FullName

    if (-not $info -or -not $info.ContainsKey('version')) {
        Write-Host "  SKIP $($dir.Name): cannot parse bl_info" -ForegroundColor DarkYellow
        continue
    }

    # check if version changed
    $oldVer = $oldVersions[$id]
    if ($oldVer -and $oldVer -eq $info.version) {
        Write-Host "  SKIP $($dir.Name): v$($info.version) unchanged" -ForegroundColor DarkGray
        $skipped += $id
        continue
    }

    # remove old zips for this addon (exact prefix match: id- followed by digit)
    Get-ChildItem $packagesDir -Filter "$id-[0-9]*.zip" -ErrorAction SilentlyContinue | Remove-Item -Force

    Write-Host ""
    if ($oldVer) {
        Write-Host "--- $($dir.Name): v$oldVer -> v$($info.version) ---" -ForegroundColor Cyan
    } else {
        Write-Host "--- $($dir.Name): NEW v$($info.version) ---" -ForegroundColor Cyan
    }

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
        if (-not $items) {
            Write-Host "  WARNING: nothing to package (empty addon directory?)" -ForegroundColor Yellow
            continue
        }
        Compress-Archive -Path $items.FullName -DestinationPath $zipPath -Force
        $sizeKB = [math]::Round((Get-Item $zipPath).Length / 1KB, 1)
        Write-Host "  -> $zipName (${sizeKB} KB)" -ForegroundColor Green
        $packaged += $id
    } finally {
        Pop-Location
    }
}

Write-Host ""
$pCount = $packaged.Count
$sCount = $skipped.Count
Write-Host "Packaged: $pCount | Skipped (unchanged): $sCount" -ForegroundColor Green

# ============================ generate index ============================
Write-Host ""
Write-Host "Generating index.json..." -ForegroundColor Cyan

if (-not (Test-Path $blenderExe)) {
    Write-Host "ERROR: Blender not found at: $blenderExe" -ForegroundColor Red
    Write-Host "Update `$blenderExe in release.ps1 if Blender was moved."
    exit 1
}

$prevErrorAction = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$result = & $blenderExe --command extension server-generate --repo-dir=$packagesDir 2>&1
$ErrorActionPreference = $prevErrorAction
$foundMatch = $result | Select-String "found (\d+) packages"
if ($foundMatch) {
    $count = $foundMatch.Matches.Groups[1].Value
    Write-Host "  recognized: $count extension(s)" -ForegroundColor Green
} else {
    Write-Host "  WARNING: cannot confirm index generation status" -ForegroundColor Yellow
}

if (-not (Test-Path $indexPath)) {
    Write-Host "ERROR: index.json was not generated. Check Blender output above." -ForegroundColor Red
    exit 1
}

# ============================ git push ============================
Write-Host ""
Write-Host "Pushing to GitHub..." -ForegroundColor Cyan
Push-Location $repoRoot
try {
    git add packages/
    $gitStatus = git status -s
    if (-not $gitStatus) {
        Write-Host "  no changes, skip." -ForegroundColor DarkYellow
        Pop-Location
        Write-Host ""
        Write-Host "=== DONE ===" -ForegroundColor Cyan
        exit 0
    }

    $date = Get-Date -Format "yyyy-MM-dd HH:mm"
    $commitMsg = "release: $date - $($packaged -join ', ')"
    git commit -m $commitMsg

    try {
        git push
        Write-Host "  pushed." -ForegroundColor Green
    } catch {
        Write-Host "ERROR: git push failed. Rolling back commit..." -ForegroundColor Red
        git reset --soft HEAD~1
        Write-Host "  commit rolled back. Fix the issue and try again."
        exit 1
    }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "=== DONE ===" -ForegroundColor Cyan