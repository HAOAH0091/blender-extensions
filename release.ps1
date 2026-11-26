# HAOAH Blender Extensions
# yi jian fa bu jiao ben
# yong fa: .\release.ps1
# 用 -NoPause 可禁止内部所有 "Press Enter" 暂停(供 bat 包装脚本调用, 由 bat 统一 pause)

param(
    [switch]$NoPause,
    [string]$Repackage = ""
)

# 统一暂停出口：NoPause 时跳过内部暂停(bat 会兜底 pause)
function Wait-Close {
    if (-not $NoPause) {
        Write-Host ""
        Read-Host "Press Enter to close" | Out-Null
    }
}

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
# Resolve paths from the script location so the entry keeps working after a machine move.
# The add-on source and the Blender executable can be overridden for non-default layouts.
$repoRoot = $PSScriptRoot
$addonsSource = Join-Path (Split-Path -Parent $repoRoot) "addons"
if ($env:BLENDER_EXT_ADDONS_SOURCE) { $addonsSource = $env:BLENDER_EXT_ADDONS_SOURCE }
$blenderExe = "C:\Program Files (x86)\Steam\steamapps\common\Blender\blender.exe"
if ($env:BLENDER_EXT_BLENDER_EXE) { $blenderExe = $env:BLENDER_EXT_BLENDER_EXE }
$packagesDir = Join-Path $repoRoot "packages"
$tempRoot = "$env:TEMP\blender-ext-release"

# GitHub rejects any single file above 100 MB, so keep a hard stop well below it.
# The environment override exists for tests and for non-GitHub mirrors.
$maxZipMB = 95
if ($env:BLENDER_EXT_MAX_ZIP_MB) { $maxZipMB = [double]$env:BLENDER_EXT_MAX_ZIP_MB }
$maxStagedMB = $maxZipMB * 1.6

# Add-ons to rebuild even though the index already lists the same version.
$repackageIds = @{}
foreach ($rawId in ($Repackage -split ',')) {
    $rid = $rawId.Trim()
    if ($rid) { $repackageIds[$rid] = $true }
}

# Development material that is never part of a release package.
$devDirs = @("_dev", ".dev", "_dev_tools", ".docs", "compify-guide")

# ============================ preflight ============================
$repoFull = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd('\')
$gitRoot = & git -C $repoRoot rev-parse --show-toplevel 2>$null
$gitExit = $LASTEXITCODE
$gitRoot = @($gitRoot)[0]
if ($gitExit -ne 0 -or -not $gitRoot) {
    Write-Host "ERROR: not a Git repository: $repoRoot" -ForegroundColor Red
    Write-Host "Keep release.bat and release.ps1 at the repository root." -ForegroundColor Yellow
    Wait-Close
    exit 1
}
$gitFull = [System.IO.Path]::GetFullPath($gitRoot.Trim()).TrimEnd('\')
if (-not [string]::Equals($repoFull, $gitFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "ERROR: release scripts must sit at the Git repository root." -ForegroundColor Red
    Write-Host "  script dir: $repoFull" -ForegroundColor Yellow
    Write-Host "  git root:   $gitFull" -ForegroundColor Yellow
    Wait-Close
    exit 1
}
if (-not (Test-Path -LiteralPath $addonsSource -PathType Container)) {
    Write-Host "ERROR: add-on source directory not found: $addonsSource" -ForegroundColor Red
    Write-Host "Set BLENDER_EXT_ADDONS_SOURCE or place the addons folder next to the repository." -ForegroundColor Yellow
    Wait-Close
    exit 1
}
if (-not (Test-Path -LiteralPath $blenderExe -PathType Leaf)) {
    Write-Host "ERROR: Blender not found at: $blenderExe" -ForegroundColor Red
    Write-Host "Set BLENDER_EXT_BLENDER_EXE to the installed blender.exe." -ForegroundColor Yellow
    Wait-Close
    exit 1
}

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

    $descText = Safe-Substring $info.description 100
    # Blender rejects a tagline that ends with punctuation, and truncation appends "...".
    $descText = $descText -replace '[\p{P}\s]+$', ''
    $desc = ConvertTo-TomlString $descText

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
    $devDirPatterns = @("dev_plans", "_plans", "docs", "plans", "notes", ".vscode", ".idea", "__MACOSX") + $devDirs
    $devDirPatterns | ForEach-Object {
        Get-ChildItem $dir -Recurse -Directory -Filter $_ -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    # VCS metadata belongs to the repository, not to the add-on.
    Get-ChildItem $dir -Recurse -File -Filter ".gitattributes" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    # empty / $null files
    Get-ChildItem $dir -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq '$null' -or $_.Name -eq '' } | Remove-Item -Force -ErrorAction SilentlyContinue

    # prune directories left empty after cleaning (removed dev folders, untracked trees)
    for ($pass = 0; $pass -lt 6; $pass++) {
        $empties = @(Get-ChildItem $dir -Recurse -Directory -ErrorAction SilentlyContinue |
            Where-Object { -not (Get-ChildItem $_.FullName -Force -ErrorAction SilentlyContinue) })
        if ($empties.Count -eq 0) { break }
        $empties | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
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
    Wait-Close
    exit 1
}

Write-Host "Found $($addonDirs.Count) addons:" -ForegroundColor Green
$addonDirs | ForEach-Object { Write-Host "  $($_.Name)" }

if ($repackageIds.Count -gt 0) {
    $knownIds = @($addonDirs | ForEach-Object { $_.Name -replace '-master$', '' })
    foreach ($rid in @($repackageIds.Keys)) {
        if ($knownIds -notcontains $rid) {
            Write-Host "ERROR: -Repackage '$rid' is not an add-on source directory. Known ids: $($knownIds -join ', ')" -ForegroundColor Red
            Wait-Close
            exit 1
        }
    }
}

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
$packagedInfo = @{}
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
    $forceRebuild = $repackageIds.ContainsKey($id)
    if ($oldVer -and $oldVer -eq $info.version -and -not $forceRebuild) {
        Write-Host "  SKIP $($dir.Name): v$($info.version) unchanged" -ForegroundColor DarkGray
        $skipped += $id
        continue
    }

    # remove old zips for this addon (exact prefix match: id- followed by digit)
    Get-ChildItem $packagesDir -Filter "$id-[0-9]*.zip" -ErrorAction SilentlyContinue | Remove-Item -Force

    Write-Host ""
    if ($oldVer -and $forceRebuild -and $oldVer -eq $info.version) {
        Write-Host "--- $($dir.Name): v$($info.version) (forced rebuild) ---" -ForegroundColor Cyan
    } elseif ($oldVer) {
        Write-Host "--- $($dir.Name): v$oldVer -> v$($info.version) ---" -ForegroundColor Cyan
    } else {
        Write-Host "--- $($dir.Name): NEW v$($info.version) ---" -ForegroundColor Cyan
    }

    $tmp = Join-Path $tempRoot $id
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    Copy-Item -Recurse -Path $dir.FullName -Destination $tmp

    # Release artifacts come from committed sources: never ship local scratch files.
    if (Test-Path (Join-Path $dir.FullName ".git")) {
        $untracked = @(& git -C $dir.FullName ls-files --others --exclude-standard 2>$null)
        if ($LASTEXITCODE -eq 0 -and $untracked.Count -gt 0) {
            foreach ($rel in $untracked) {
                $target = Join-Path $tmp $rel
                if (Test-Path -LiteralPath $target) {
                    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            Write-Host "  removed $($untracked.Count) untracked file(s) from package" -ForegroundColor DarkGray
        }
    }

    Clear-TempPackage $tmp

    $stagedMB = [math]::Round((Get-ChildItem $tmp -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB, 2)
    if ($stagedMB -gt $maxStagedMB) {
        Write-Host "ERROR: $($dir.Name) stages $stagedMB MB, which cannot fit in a $maxZipMB MB package." -ForegroundColor Red
        Write-Host "  Add the development material to the exclusion list; nothing was committed." -ForegroundColor Yellow
        Wait-Close
        exit 1
    }

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

        $zipMB = (Get-Item $zipPath).Length / 1MB
        if ($zipMB -gt $maxZipMB) {
            Write-Host "ERROR: $zipName is $([math]::Round($zipMB, 1)) MB, above the $maxZipMB MB limit." -ForegroundColor Red
            Write-Host "  Exclude development material or split the package; nothing was committed." -ForegroundColor Yellow
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            Wait-Close
            exit 1
        }

        # Self-check: no development directory may survive into the archive.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $zipEntries = @($zip.Entries)
            $leaked = @($zipEntries | Where-Object {
                $parts = $_.FullName -split '[\\/]'
                $parts.Count -gt 1 -and ($devDirs -contains $parts[0])
            })
            $unpackedMB = [math]::Round((($zipEntries | Measure-Object Length -Sum).Sum) / 1MB, 2)
        } finally {
            $zip.Dispose()
        }
        if ($leaked.Count -gt 0) {
            Write-Host "ERROR: $zipName still contains development files: $($leaked[0].FullName)" -ForegroundColor Red
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            Wait-Close
            exit 1
        }
        Write-Host "    $($zipEntries.Count) entries, $unpackedMB MB unpacked" -ForegroundColor DarkGray

        $packaged += $id
        $packagedInfo[$id] = $info.version
    } finally {
        Pop-Location
    }
}

Write-Host ""
$pCount = $packaged.Count
$sCount = $skipped.Count
Write-Host "Packaged: $pCount | Skipped (unchanged): $sCount" -ForegroundColor Green

# ============================ clean stale zips (keep newest per addon) ============================
# 无论是否重新打包，都清理每个插件目录下"非最新版本"的旧 zip，
# 避免旧版残留导致 server-generate 索引进重复条目。
Write-Host ""
Write-Host "Cleaning stale zips..." -ForegroundColor Cyan
$zipFiles = Get-ChildItem $packagesDir -Filter "*.zip" -ErrorAction SilentlyContinue
$removed = 0
# 按 id 前缀分组（格式 id-X.Y.Z.zip）。id 为最后一个 '-' 前的部分。
$byId = @{}
foreach ($z in $zipFiles) {
    if ($null -eq $z) { continue }
    $base = $z.BaseName   # e.g. psd_layer_importer_plus-3.4.0
    if ($null -eq $base) { continue }
    $lastDash = $base.LastIndexOf('-')
    if ($lastDash -lt 0) { continue }
    $id = $base.Substring(0, $lastDash)
    $ver = $base.Substring($lastDash + 1)
    $entry = [PSCustomObject]@{ File = $z; Ver = $ver }
    if ($byId.ContainsKey($id)) {
        $byId[$id] = @($byId[$id]) + $entry
    } else {
        $byId[$id] = @($entry)
    }
}
foreach ($id in $byId.Keys) {
    $group = $byId[$id] | Sort-Object { [version]$_.Ver } -Descending
    for ($i = 1; $i -lt $group.Count; $i++) {
        Remove-Item $group[$i].File.FullName -Force -ErrorAction SilentlyContinue
        Write-Host "  removed stale: $($group[$i].File.Name)" -ForegroundColor DarkYellow
        $removed++
    }
}
$keptCount = (Get-ChildItem $packagesDir -Filter "*.zip").Count
Write-Host "  removed $removed stale zip(s), now $keptCount newest zip(s)." -ForegroundColor Green

# ============================ generate index ============================
Write-Host ""
Write-Host "Generating index.json..." -ForegroundColor Cyan

$prevErrorAction = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$result = & $blenderExe --command extension server-generate --repo-dir=$packagesDir 2>&1
$blenderExit = $LASTEXITCODE
$ErrorActionPreference = $prevErrorAction
if ($blenderExit -ne 0) {
    Write-Host "ERROR: Blender server-generate failed (exit code $blenderExit)." -ForegroundColor Red
    $result | Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    Write-Host "Nothing was committed or pushed." -ForegroundColor Yellow
    Wait-Close
    exit 1
}
$foundMatch = $result | Select-String "found (\d+) packages"
if ($foundMatch) {
    $count = $foundMatch.Matches.Groups[1].Value
    Write-Host "  recognized: $count extension(s)" -ForegroundColor Green
} else {
    Write-Host "  WARNING: cannot confirm index generation status" -ForegroundColor Yellow
}

if (-not (Test-Path $indexPath)) {
    Write-Host "ERROR: index.json was not generated. Check Blender output above." -ForegroundColor Red
    Wait-Close
    exit 1
}

if ($packaged.Count -gt 0) {
    try {
        $newIndex = Get-Content $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Host "ERROR: index.json is not valid JSON: $($_.Exception.Message)" -ForegroundColor Red
        Wait-Close
        exit 1
    }
    $indexById = @{}
    foreach ($entry in $newIndex.data) { $indexById[$entry.id] = $entry }
    foreach ($id in $packaged) {
        $expectedVer = $packagedInfo[$id]
        $entry = $indexById[$id]
        if (-not $entry) {
            Write-Host "ERROR: package '$id' is missing from index.json." -ForegroundColor Red
            Wait-Close
            exit 1
        }
        if ($entry.version -ne $expectedVer) {
            Write-Host "ERROR: index.json has $id v$($entry.version), expected v$expectedVer." -ForegroundColor Red
            Wait-Close
            exit 1
        }
        $zipPath = Join-Path $packagesDir "$id-$expectedVer.zip"
        $actualHash = "sha256:" + (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLower()
        if ($entry.archive_hash -ne $actualHash) {
            Write-Host "ERROR: index.json hash for $id does not match $zipPath." -ForegroundColor Red
            Wait-Close
            exit 1
        }
    }
    Write-Host "  index verified for $($packaged.Count) package(s)." -ForegroundColor Green
}

# ============================ git push ============================
Write-Host ""
Write-Host "Pushing to GitHub..." -ForegroundColor Cyan
Push-Location $repoRoot
$failure = $null
try {
    & git add packages/
    if ($LASTEXITCODE -ne 0) { throw "git add failed." }

    & git diff --cached --quiet
    $hasStaged = ($LASTEXITCODE -ne 0)

    if ($hasStaged) {
        $gName = git config --local user.name
        $gEmail = git config --local user.email
        if (-not $gName -or -not $gEmail) {
            throw "git identity not configured. Run: git config --local user.name / user.email"
        }

        $date = Get-Date -Format "yyyy-MM-dd HH:mm"
        $commitMsg = "release: $date - $($packaged -join ', ')"
        & git commit -m $commitMsg
        if ($LASTEXITCODE -ne 0) { throw "git commit failed (identity or other issue); nothing was pushed." }
        Write-Host "  commit created: $(& git rev-parse --short HEAD)" -ForegroundColor Green
    } else {
        Write-Host "  no file changes." -ForegroundColor DarkYellow
    }

    $ahead = [int](& git rev-list --count origin/main..HEAD)
    if ($LASTEXITCODE -ne 0) { throw "cannot compare with origin/main - is the remote configured?" }

    if ($ahead -eq 0) {
        Write-Host "  already up to date, nothing to push." -ForegroundColor DarkYellow
    } else {
        Write-Host "  $ahead commit(s) to push..." -ForegroundColor Cyan
        & git push
        if ($LASTEXITCODE -ne 0) {
            throw "git push failed. The local commit is kept; fix the cause and rerun this script to push it."
        }
        $aheadAfter = [int](& git rev-list --count origin/main..HEAD)
        if ($LASTEXITCODE -ne 0 -or $aheadAfter -ne 0) {
            throw "push claimed success but origin/main is still behind HEAD."
        }
        Write-Host "  pushed." -ForegroundColor Green
    }

    Write-Host "  local $(& git rev-parse --short HEAD) | remote $(& git rev-parse --short origin/main)" -ForegroundColor Green
} catch {
    $failure = $_.Exception.Message
} finally {
    Pop-Location
}

if ($failure) {
    Write-Host "ERROR: $failure" -ForegroundColor Red
    Wait-Close
    exit 1
}

Write-Host ""
Write-Host "=== DONE ===" -ForegroundColor Cyan

Wait-Close
