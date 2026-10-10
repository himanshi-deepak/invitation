# Downloads every remote asset referenced by the mirrored Framer page and
# rewrites all references to local relative paths so the page works offline.

[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot,
    [string]$Page = 'demo3artfulinvites.framer.website\index.html'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$HostsToMirror = @('framerusercontent.com', 'fonts.gstatic.com')
$TextExtensions = @('.mjs', '.js', '.json', '.css', '.map')
$UrlPattern = 'https://(?:framerusercontent\.com|fonts\.gstatic\.com)/[^"''`\s,\)\\<>]+'

$pagePath = Join-Path $Root $Page
if (-not (Test-Path $pagePath)) { throw "Page not found: $pagePath" }

# Windows PowerShell defaults to ANSI for BOM-less files, which corrupts UTF-8 content.
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Read-Text { param([string]$Path) [IO.File]::ReadAllText($Path, $Utf8NoBom) }
function Write-Text { param([string]$Path, [string]$Content) [IO.File]::WriteAllText($Path, $Content, $Utf8NoBom) }

function Get-AssetKey {
    param([string]$Url)
    $u = [uri]$Url
    # Query strings (Framer image resizing) are dropped: the bare URL returns the original asset.
    "$($u.Host)$($u.AbsolutePath)"
}

function Get-LocalPath {
    param([string]$Url)
    $u = [uri]$Url
    $relative = $u.AbsolutePath.TrimStart('/') -replace '/', '\'
    Join-Path $Root (Join-Path $u.Host $relative)
}

function Save-Asset {
    param([string]$Url)

    $target = Get-LocalPath $Url
    if (Test-Path $target) { return $target }

    $dir = Split-Path $target -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $clean = ([uri]$Url).GetLeftPart([System.UriPartial]::Path)
    Invoke-WebRequest -Uri $clean -OutFile $target -UseBasicParsing -Headers @{
        'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36'
    }
    $target
}

# ---------------------------------------------------------------- discovery --

$seen = @{}
$queue = [System.Collections.Generic.Queue[string]]::new()

function Add-Url {
    param([string]$Url)
    $u = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u)) { return }
    if ($HostsToMirror -notcontains $u.Host) { return }
    $key = Get-AssetKey $Url
    if ($seen.ContainsKey($key)) { return }
    $seen[$key] = $true
    $queue.Enqueue($u.GetLeftPart([System.UriPartial]::Path))
}

function Add-UrlsFromText {
    param([string]$Text, [string]$BaseUrl)

    # Absolute URLs (HTML entities decoded first so &amp; does not break parsing).
    foreach ($m in [regex]::Matches(($Text -replace '&amp;', '&'), $UrlPattern)) { Add-Url $m.Value }

    if ($BaseUrl) {
        # Relative / root-relative ES module specifiers inside downloaded bundles
        # (rolldown emits dynamic imports inside template literals, hence the backtick).
        $pattern = '["''`](\.{1,2}/[^"''`\s]+?\.(?:mjs|js|json|css)|/[^"''`\s]+?\.(?:mjs|js|json|css|woff2))["''`]'
        foreach ($m in [regex]::Matches($Text, $pattern)) {
            Add-Url ([uri]::new([uri]$BaseUrl, $m.Groups[1].Value)).AbsoluteUri
        }
    }
}

$html = Read-Text $pagePath
Add-UrlsFromText -Text $html -BaseUrl $null

# Re-seed from already-mirrored bundles so chunks discovered on a later run are fetched too.
foreach ($mirrorHost in $HostsToMirror) {
    $dir = Join-Path $Root $mirrorHost
    if (-not (Test-Path $dir)) { continue }
    $base = (Resolve-Path $dir).ProviderPath.TrimEnd('\')
    Get-ChildItem $dir -Recurse -File |
        Where-Object { $TextExtensions -contains $_.Extension.ToLower() } |
        ForEach-Object {
            $rel = $_.FullName.Substring($base.Length).TrimStart('\') -replace '\\', '/'
            Add-UrlsFromText -Text (Read-Text $_.FullName) -BaseUrl "https://$mirrorHost/$rel"
        }
}

$downloaded = [System.Collections.Generic.List[string]]::new()
$failed = [System.Collections.Generic.List[string]]::new()

while ($queue.Count -gt 0) {
    $url = $queue.Dequeue()
    try {
        $file = Save-Asset $url
        $downloaded.Add($url)
        Write-Host "  ok  $url"
        if ($TextExtensions -contains [IO.Path]::GetExtension($file).ToLower()) {
            Add-UrlsFromText -Text (Read-Text $file) -BaseUrl $url
        }
    }
    catch {
        $failed.Add("$url  ->  $($_.Exception.Message)")
        Write-Warning "fail $url : $($_.Exception.Message)"
    }
}

Write-Host "`nDownloaded $($downloaded.Count) assets, $($failed.Count) failures." -ForegroundColor Cyan
$failed | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }

# ------------------------------------------------------------------ rewrite --

function Get-RelativePrefix {
    param([string]$FilePath)
    $dir = (Resolve-Path (Split-Path $FilePath -Parent)).ProviderPath.TrimEnd('\')
    $base = (Resolve-Path $Root).ProviderPath.TrimEnd('\')
    if ($dir -eq $base) { return '' }
    $depth = ($dir.Substring($base.Length).Trim('\') -split '\\').Count
    ('../' * $depth)
}

function Convert-References {
    param([string]$FilePath)

    $content = Read-Text $FilePath
    $prefix = Get-RelativePrefix $FilePath

    $rewritten = [regex]::Replace($content, $UrlPattern, {
            param($m)
            $u = [uri]($m.Value -replace '&amp;', '&')
            if (-not (Test-Path (Get-LocalPath $u.AbsoluteUri))) { return $m.Value }
            "$prefix$($u.Host)$($u.AbsolutePath)"
        })

    if ($rewritten -ne $content) {
        Write-Text -Path $FilePath -Content $rewritten
        return $true
    }
    $false
}

$textFiles = @($pagePath)
foreach ($h in $HostsToMirror) {
    $dir = Join-Path $Root $h
    if (Test-Path $dir) {
        $textFiles += (Get-ChildItem $dir -Recurse -File |
            Where-Object { $TextExtensions -contains $_.Extension.ToLower() } |
            ForEach-Object { $_.FullName })
    }
}

$changed = 0
foreach ($f in $textFiles) { if (Convert-References $f) { $changed++ } }
Write-Host "Rewrote references in $changed file(s)." -ForegroundColor Cyan
