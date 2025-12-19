
# Kusanagi Night Ops: URL Scrapper

# -----------------------------------------------------------
# TLS Handling (ignore certificate errors for HTML fetch)
# -----------------------------------------------------------
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
# Force modern TLS versions (1.1, 1.2; 1.3 if available on the box)
[System.Net.ServicePointManager]::SecurityProtocol = `
    [System.Net.SecurityProtocolType]::Tls12 -bor `
    [System.Net.SecurityProtocolType]::Tls11 -bor `
    [System.Net.SecurityProtocolType]::Tls


# -----------------------------------------------------------
# CONSTANTS & PATHS
# -----------------------------------------------------------
$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir  = Split-Path -Parent $ScriptPath

$KnoStateDir = Join-Path $ScriptDir ".kno-url"
if (-not (Test-Path $KnoStateDir)) {
    New-Item -ItemType Directory -Path $KnoStateDir | Out-Null
}

$PlaywrightPreFlag     = Join-Path $KnoStateDir "playwright_preexisting.flag"
$PlaywrightMissingFlag = Join-Path $KnoStateDir "playwright_missing_at_start.flag"
$HistoryMarkerFile     = Join-Path $KnoStateDir "history.marker"

# PowerShell history file
$PSHistFile = Join-Path $env:APPDATA "Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"

# -----------------------------------------------------------
# TRACK INITIAL STATE (FIRST RUN MARKERS)
# -----------------------------------------------------------

function Test-PlaywrightInstalled {
    # Playwright global tool is installed as ~/.dotnet/tools/playwright.ps1
    $playwrightTool = Join-Path $env:USERPROFILE ".dotnet\tools\playwright.ps1"
    return (Test-Path $playwrightTool)
}

function Test-PlaywrightBrowsersInstalled {
    # Browsers installed under: %LOCALAPPDATA%\ms-playwright
    $bundleDir = Join-Path $env:LOCALAPPDATA "ms-playwright"
    if (-not (Test-Path $bundleDir)) { return $false }

    # At least one installed browser must exist
    $sub = Get-ChildItem -Path $bundleDir -Directory -ErrorAction SilentlyContinue
    return ($sub.Count -gt 0)
}

function Ensure-PlaywrightMarkers {
    # Lazily create Playwright marker flags the first time a valid -n is used.
    if (-not (Test-Path $PlaywrightPreFlag) -and -not (Test-Path $PlaywrightMissingFlag)) {
        if (Test-PlaywrightInstalled) {
            New-Item -ItemType File -Path $PlaywrightPreFlag | Out-Null
        } else {
            New-Item -ItemType File -Path $PlaywrightMissingFlag | Out-Null
        }
    }
}

# Record PowerShell history line count at start of session
if (-not (Test-Path $HistoryMarkerFile)) {
    if (Test-Path $PSHistFile) {
        $lineCount = (Get-Content $PSHistFile | Measure-Object -Line).Lines
        Set-Content -Path $HistoryMarkerFile -Value $lineCount
    } else {
        Set-Content -Path $HistoryMarkerFile -Value 0
    }
}

# -----------------------------------------------------------
# URL EXTENSION CATEGORIES
# -----------------------------------------------------------

$MediaExt  = @('.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp', '.ico', '.mp4', '.mov', '.wav')
$ScriptExt = @('.js', '.mjs')
$DocExt    = @('.json', '.xml', '.yml', '.yaml', '.pdf', '.txt', '.csv', '.doc', '.docx')
$HtmlExt   = @('.html', '.htm')
$FrameworkScriptSuffixes = @('.bundle.js', '.chunk.js')
$FontExt   = @('.woff', '.woff2', '.ttf', '.otf')

$CategoryFlagsHtml = @{
    'SCRIPTS'            = '-s'
    'MEDIA'              = '-md'
    'API / ENDPOINTS'    = '-a'
    'DOCUMENTS / CONFIG' = '-d'
    'HTML / FRAMEWORK'   = '-ht'
    'OTHER'              = '-O'
}

$FlagToCategoryHtml = @{}
foreach ($k in $CategoryFlagsHtml.Keys) {
    $FlagToCategoryHtml[$CategoryFlagsHtml[$k]] = $k
}

$NetworkTypeFlags = @{
    'Fetch/XHR' = '-fx'
    'Doc'       = '-d'
    'CSS'       = '-css'
    'JS'        = '-js'
    'Font'      = '-f'
    'Img'       = '-img'
    'Media'     = '-md'
    'Manifest'  = '-mf'
    'Socket'    = '-s'
    'Wasm'      = '-wasm'
    'Other'     = '-O'
}

$FlagToNetType = @{}
foreach ($k in $NetworkTypeFlags.Keys) {
    $FlagToNetType[$NetworkTypeFlags[$k]] = $k
}

$HtmlFlagSet   = $FlagToCategoryHtml.Keys + @('-o', '--no-media')
$NetFlagSet    = $FlagToNetType.Keys + @('-o', '-t', '--live')
$GlobalFlagSet = @('-n', '-sd', '--night-ops', '-h', '--help', '-u', '--search', '--full')

$AllFlags = $HtmlFlagSet + $NetFlagSet + $GlobalFlagSet

# -----------------------------------------------------------
# HELP MENU
# -----------------------------------------------------------

function Show-Help {
@"
Kusanagi Night Ops: URL Scrapper (PowerShell Edition)
====================================================

INTERACTIVE USAGE:
    powershell -File .\kno-url.ps1
    Main URL: <url> [flags]

------------------------------------------------------------
HTML MODE (default)
------------------------------------------------------------

Examples:
    Main URL: https://example.com
    Main URL: cnn.com -o results.txt
    Main URL: cnn.com -s -md
    Main URL: -u 10.8.1.4:80/video -s -md

Flags:
    -s       SCRIPTS
    -md      MEDIA
    -a       API / ENDPOINTS
    -d       DOCUMENTS / CONFIG
    -ht      HTML / FRAMEWORK
    -O       OTHER
    -o FILE  Write results to file
    --no-media   Invert selections (exclude categories)
    --search X   Only include URLs containing substring X
                 Multiple terms: --search mp4,cdn,api
    --full        Dump full raw HTML (like curl)

If no categories given → all categories included by default.
(--no-media flips category flags to exclusions)

------------------------------------------------------------
NETWORK MODE  (-n)
------------------------------------------------------------

WARNING:
    Network mode uses real browser automation (Playwright).
    It is NOT stealthy. Use only in controlled environments.

BEFORE USING:
    dotnet tool install --global Microsoft.Playwright.CLI
    playwright install

This version checks:
    ✔ dotnet availability
    ✔ Playwright CLI installed
    ✔ Browser bundles installed
    ✔ GUI available

If ANY requirement is missing → network mode aborts cleanly
and shows instructions.

User must explicitly confirm:
    "WARNING: Network mode may be noisy ... Proceed? [y/N]"

Network Mode Flags:
    -t <duration>   NOT IMPLEMENTED IN POWERSHELL VERSION
    --live          NOT IMPLEMENTED IN POWERSHELL VERSION
        (Use Python version for real capture)

This PowerShell version provides:
    ✔ Full gating
    ✔ Full warnings
    ✔ Full environment detection
    ✘ NO actual network capture (use Python instead)

------------------------------------------------------------
SELF-DESTRUCT  (--night-ops)
------------------------------------------------------------

1) Standalone:
    Main URL: --night-ops
    → Confirms
    → Deletes:
        - This script
        - .kno-url markers
        - Files beginning with kno-url*
        - __pycache__ (if any)
        - Playwright installation ONLY IF it did NOT exist
          before KNO first launched
        - PSReadLine entries added after KNO launch
    → Exits immediately

2) Scheduled:
    Main URL: <url> [flags] --night-ops -sd <duration>
       Ex: 1h15m30s, 90s, "1h 15m 30s"
    → Runs HTML mode
    → Sleeps for duration
    → Self-destruct with NO confirmation
    → Exits

NOTE:
    -sd only allowed when combined with --night-ops.
    --night-ops cannot be combined with other flags unless -sd is present.

------------------------------------------------------------
MISC:
    -h, --help   Show this help menu
"@ | Write-Host
}

# -----------------------------------------------------------
# URL NORMALIZATION
# -----------------------------------------------------------

function Normalize-UrlCandidate {
    param([string]$Raw)
    $raw = ($Raw | ForEach-Object { $_.Trim() })
    if (-not $raw) { return $raw }

    if ($raw.StartsWith('http://') -or $raw.StartsWith('https://')) {
        return $raw
    }
    if ($raw.StartsWith('www.')) {
        return "https://$raw"
    }

    if ($raw.Contains('.') -or $raw.Contains(':')) {
        return "https://$raw"
    }
    return $raw
}

# -----------------------------------------------------------
# INPUT PARSING
# -----------------------------------------------------------

function Parse-MainInput {
    param([string]$Line)

    $tokens = $Line.Trim().Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
    if (-not $tokens -or $tokens.Count -eq 0) {
        return [pscustomobject]@{ Url = $null; Args = @() }
    }

    if ($tokens.Count -eq 1 -and ($tokens[0] -eq '-h' -or $tokens[0] -eq '--help')) {
        return [pscustomobject]@{ Url = 'HELP'; Args = @() }
    }

    # Explicit URL mode
    if ($tokens[0] -eq '-u' -and $tokens.Count -ge 2) {
        $url = Normalize-UrlCandidate $tokens[1]
        return [pscustomobject]@{
            Url  = $url
            Args = $tokens[2..($tokens.Count-1)]
        }
    }

    # First non-flag token is URL
    if (-not $tokens[0].StartsWith('-')) {
        $url = Normalize-UrlCandidate $tokens[0]
        return [pscustomobject]@{
            Url  = $url
            Args = $tokens[1..($tokens.Count-1)]
        }
    }

    # Search for URL anywhere
    for ($i=0; $i -lt $tokens.Count; $i++) {
        $tok = $tokens[$i]
        if ($tok.StartsWith('http://') -or $tok.StartsWith('https://') -or $tok.StartsWith('www.')) {
            $url = Normalize-UrlCandidate $tok
            $prefix = if ($i -gt 0) { $tokens[0..($i-1)] } else { @() }
            $suffix = if ($i -lt ($tokens.Count-1)) { $tokens[($i+1)..($tokens.Count-1)] } else { @() }
            return [pscustomobject]@{
                Url  = $url
                Args = $prefix + $suffix
            }
        }
    }

    # No URL
    return [pscustomobject]@{ Url = $null; Args = $tokens }
}

# -----------------------------------------------------------
# HTML FETCHING
# -----------------------------------------------------------

function Fetch-Html {
    param([string]$Url)

    # First attempt: Invoke-WebRequest (.NET HTTP stack)
    try {
        $headers = @{ "User-Agent" = "KNO-URL/PowerShell" }
        $resp = Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -TimeoutSec 20
        return $resp.Content
    } catch {
        Write-Host "[-] Invoke-WebRequest failed for $($Url): $($_.Exception.Message)"
    }

    # Second attempt: curl.exe (libcurl, often supports newer ciphers)
    try {
        Write-Host "[*] Falling back to curl.exe for $Url ..."
        $curlArgs = @(
            "-L",              # follow redirects
            "-k",              # ignore cert errors (matches our CERT ignore behavior)
            "-m", "20",        # timeout 20s
            "-A", "KNO-URL/PowerShell",
            "$Url"
        )

        $output = & curl.exe @curlArgs 2>$null
        if ($LASTEXITCODE -eq 0 -and $output) {
            return ($output -join "`n")
        } else {
            Write-Host "[-] curl.exe failed or returned no content for $($Url)."
            return $null
        }
    } catch {
        Write-Host "[-] curl.exe error for $($Url): $($_.Exception.Message)"
        return $null
    }
}


# -----------------------------------------------------------
# SEARCH FILTER
# -----------------------------------------------------------

function Test-MatchesSearch {
    param(
        [string]$Url,
        [string[]]$SearchTerms
    )

    if (-not $SearchTerms -or $SearchTerms.Count -eq 0) {
        return $true
    }

    $lower = $Url.ToLower()
    foreach ($s in $SearchTerms) {
        if ($lower.Contains($s)) { return $true }
    }
    return $false
}
# -----------------------------------------------------------
# EXTRACT URLS FROM HTML
# -----------------------------------------------------------

function Extract-UrlsFromHtml {
    param(
        [string]$Html,
        [string]$BaseUrl
    )

    $urls = New-Object System.Collections.Generic.HashSet[string]

    # 1. http/https URLs
    [regex]::Matches($Html, '(?<!blob:)https?://[^\s''"<>]+') | ForEach-Object {
        [void]$urls.Add($_.Value)
    }

    # 2. blob: URLs
    [regex]::Matches($Html, 'blob:[^\s''"<>]+') | ForEach-Object {
        [void]$urls.Add($_.Value)
    }

    # 3. scheme-relative URLs: //domain/path
    [regex]::Matches($Html, '(?<!:)//[^\s''"<>]+') | ForEach-Object {
        $m = $_.Value
        try {
            $base = [System.Uri]::new($BaseUrl)
            $fixed = "$($base.Scheme):$m"
            [void]$urls.Add($fixed)
        } catch { }
    }

    # 4. anchors: href="#fragment"
    [regex]::Matches($Html, 'href=["''](#.+?)["'']') | ForEach-Object {
        $frag = $_.Groups[1].Value
        try {
            $base = [System.Uri]::new($BaseUrl)
            $joined = [System.Uri]::new($base, $frag)
            [void]$urls.Add($joined.AbsoluteUri)
        } catch {}
    }

    return $urls
}

# -----------------------------------------------------------
# CATEGORIZE URL (HTML MODE)
# -----------------------------------------------------------

function Categorize-UrlHtml {
    param([string]$Url)

    try {
        $uri = [System.Uri]::new($Url)
    } catch {
        return 'OTHER'
    }

    $path = $uri.AbsolutePath
    if (-not $path) { $path = '' }
    $lower = $path.ToLower()
    $ext = [System.IO.Path]::GetExtension($lower)

    # Framework script
    foreach ($sfx in $FrameworkScriptSuffixes) {
        if ($lower.EndsWith($sfx)) { return 'HTML / FRAMEWORK' }
    }

    if ($ScriptExt -contains $ext) { return 'SCRIPTS' }
    if ($MediaExt  -contains $ext) { return 'MEDIA' }
    if ($DocExt    -contains $ext) { return 'DOCUMENTS / CONFIG' }
    if ($HtmlExt   -contains $ext) { return 'HTML / FRAMEWORK' }

    # API-like patterns
    $hp = ($uri.Host + $lower).ToLower()
    if ($lower -like '*/api/*' -or $hp -like '*graphql*') { return 'API / ENDPOINTS' }
    if (-not $ext -and $uri.Query) { return 'API / ENDPOINTS' }

    return 'OTHER'
}

# -----------------------------------------------------------
# HTML CATEGORY FILTERING
# -----------------------------------------------------------

function Filter-CategoriesHtml {
    param([string[]]$Args)

    $include = New-Object System.Collections.Generic.HashSet[string]
    $exclude = New-Object System.Collections.Generic.HashSet[string]
    $outputFile = $null
    $noMediaMode = $false

    $i = 0
    while ($i -lt $Args.Count) {
        $arg = $Args[$i]

        if ($arg -eq '-o' -and $i -lt ($Args.Count-1)) {
            $outputFile = $Args[$i+1]
            $i += 2
            continue
        }

        if ($arg -eq '--no-media') {
            $noMediaMode = $true
            $i++
            continue
        }

        if ($FlagToCategoryHtml.ContainsKey($arg)) {
            [void]$include.Add($FlagToCategoryHtml[$arg])
            $i++
            continue
        }

        $i++
    }

        if ($noMediaMode) {
        # In "no-media" mode: whatever the user *included* becomes an exclusion set,
        # and we clear include so we don't double-filter.
        foreach ($c in $include) {
            [void]$exclude.Add($c)
        }
        $include = $null
    }
    elseif ($include.Count -eq 0) {
        # No categories selected at all → treat as "include everything".
        $include = $null
    }

    return [pscustomobject]@{
        IncludeCategories = $include
        ExcludeCategories = $exclude
        OutputFile        = $outputFile
        NoMediaMode       = $noMediaMode
    }
}


# -----------------------------------------------------------
# PRINT SORTED RESULTS
# -----------------------------------------------------------

function Print-HtmlResults {
    param(
        [hashtable]$Grouped,
        [string]$OutputFile,
        [bool]$BlobPresent
    )

    $order = @(
        'SCRIPTS',
        'MEDIA',
        'API / ENDPOINTS',
        'DOCUMENTS / CONFIG',
        'HTML / FRAMEWORK',
        'OTHER'
    )

    $outList = New-Object System.Collections.Generic.List[string]

    foreach ($cat in $order) {
        if (-not $Grouped.ContainsKey($cat)) { continue }
        $urls = $Grouped[$cat]
        if (-not $urls -or $urls.Count -eq 0) { continue }

        $withExt = @()
        $noExt   = @()

        foreach ($u in $urls) {
            try {
                $uri = [System.Uri]::new($u)
                $ext = [System.IO.Path]::GetExtension($uri.AbsolutePath.ToLower())
            } catch { $ext = '' }

            if ($ext) {
                $withExt += [pscustomobject]@{ Ext = $ext; Url = $u }
            } else {
                $noExt += $u
            }
        }

        $sortedExt = $withExt | Sort-Object Ext, Url
        $sortedNo  = $noExt   | Sort-Object

        $outList.Add($cat)
        foreach ($itm in $sortedExt) { $outList.Add($itm.Url) }
        foreach ($itm in $sortedNo)  { $outList.Add($itm) }
        $outList.Add("")
    }

    $final = ($outList -join "`n").Trim()
    if ($final) { Write-Host $final }
    else { Write-Host "[*] No URLs matched the filter criteria." }

    if ($OutputFile) {
        try {
            $final | Out-File -FilePath $OutputFile -Encoding UTF8
            Write-Host "[*] Results written to $OutputFile"
        } catch {
            Write-Host "[-] Error writing to $($OutputFile): $($_.Exception.Message)"
        }
    }

    if ($BlobPresent) {
        Write-Host ""
        Write-Host "[!] Detected blob: URLs."
        Write-Host "    Consider using Python version's network mode to see beyond blob: URLs."
    }
}

# -----------------------------------------------------------
# PLAYWRIGHT ENVIRONMENT DETECTION
# -----------------------------------------------------------

function Check-DotnetAvailable {
    try {
        $v = & dotnet --version 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Check-PlaywrightCliInstalled {
    $p = Join-Path $env:USERPROFILE ".dotnet\tools\playwright.ps1"
    return (Test-Path $p)
}

function Check-PlaywrightBrowsersInstalled {
    $dir = Join-Path $env:LOCALAPPDATA "ms-playwright"
    if (-not (Test-Path $dir)) { return $false }
    $subs = Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue
    return ($subs.Count -gt 0)
}

function Check-WindowsGuiAvailable {
    # Detect if GUI components exist (not Windows Server Core)
    $testPaths = @(
        "C:\Windows\System32\user32.dll",
        "C:\Windows\System32\win32kfull.sys"
    )
    foreach ($p in $testPaths) {
        if (-not (Test-Path $p)) { return $false }
    }
    return $true
}
# -----------------------------------------------------------
# NETWORK MODE — GATED (NO PLAYWRIGHT EXECUTION)
# -----------------------------------------------------------

function Run-NetworkMode {
    param(
        [string]$Url,
        [string[]]$Args
    )

    Write-Host ""
    Write-Host "[*] Preparing network mode for $Url"

    # --- RED TEAM WARNING ---
    Write-Host ""
    Write-Host "WARNING: Network mode may be noisy in a Red Team operation."
    Write-Host "Would you like to proceed? [y/N]"
    $confirm = Read-Host
    if ($confirm.ToLower() -notin @('y','yes')) {
        Write-Host "[-] Network mode aborted by user."
        return
    }

    # --------------------------
    # ENVIRONMENT REQUIREMENTS
    # --------------------------
    $dotnetOk = Check-DotnetAvailable
    if (-not $dotnetOk) {
        Write-Host "[-] dotnet is not installed."
        Write-Host "    Install .NET SDK to enable network mode:"
        Write-Host "        https://dotnet.microsoft.com/en-us/download/dotnet"
        return
    }

    $pwCli = Check-PlaywrightCliInstalled
    if (-not $pwCli) {
        Write-Host "[-] Playwright CLI not installed."
        Write-Host "    Install with:"
        Write-Host "        dotnet tool install --global Microsoft.Playwright.CLI"
        return
    }

    $pwBrowsers = Check-PlaywrightBrowsersInstalled
    if (-not $pwBrowsers) {
        Write-Host "[-] No Playwright browser bundle installed."
        Write-Host "    Install with:"
        Write-Host "        playwright install"
        return
    }

    $guiOk = Check-WindowsGuiAvailable
    if (-not $guiOk) {
        Write-Host "[-] GUI components not detected. Network mode requires a GUI."
        return
    }

    # --------------------------
    # NETWORK MODE NOT IMPLEMENTED
    # --------------------------
    Write-Host ""
    Write-Host "[!] Network-mode is NOT implemented in the PowerShell version."
    Write-Host "    Playwright is needed for this action. This dependency may be noisy for Red Team operations"
    Write-Host ""
}

# -----------------------------------------------------------
# SELF-DESTRUCT (NIGHT-OPS)
# -----------------------------------------------------------

function Remove-PlaywrightIfInstalledByTool {
    # Delete Playwright ONLY if the user did NOT have it before KNO ran.
    if (Test-Path $PlaywrightMissingFlag) {
        Write-Host "[*] Removing Playwright installation (installed after KNO)..."

        # Remove dotnet tool
        try {
            & dotnet tool uninstall --global Microsoft.Playwright.CLI 2>$null
        } catch {}

        # Remove browser bundle
        $bundle = Join-Path $env:LOCALAPPDATA "ms-playwright"
        if (Test-Path $bundle) {
            try { Remove-Item -Recurse -Force $bundle } catch {}
        }
    }
}

function Wipe-RecentHistory {
    if (-not (Test-Path $HistoryMarkerFile)) { return }

    $marker = [int](Get-Content $HistoryMarkerFile)
    if (-not (Test-Path $PSHistFile)) { return }

    $lines = Get-Content $PSHistFile

    if ($marker -lt $lines.Count) {
        $keep = $lines[0..($marker-1)]
        $keep | Set-Content $PSHistFile
        Write-Host "[*] Wiped PowerShell history entries created after tool launch."
    }
}

function Run-NightOps {
    param([bool]$RequireConfirm)

    if ($RequireConfirm) {
        Write-Host "[!] --night-ops will attempt to remove this tool and its artifacts."
        Write-Host "    Proceed? [y/N]"
        $resp = Read-Host
        if ($resp.ToLower() -notin @('y','yes')) {
            Write-Host "[-] Aborted."
            return
        }
    }

    Write-Host "[*] Running --night-ops cleanup..."

    # 1. Remove Playwright only if installed after KNO initial run
    Remove-PlaywrightIfInstalledByTool

    # 2. Remove artifact files beginning with kno-url
    $toRemove = @()
    $toRemove += Get-ChildItem -Path $ScriptDir -Filter "kno-url*" -File -ErrorAction SilentlyContinue

    foreach ($f in $toRemove) {
        try {
            Remove-Item -Force $f.FullName
            Write-Host "[*] Removed file: $($f.Name)"
        } catch {}
    }

    # 3. Remove .kno-url state directory
    if (Test-Path $KnoStateDir) {
        try {
            Remove-Item -Recurse -Force $KnoStateDir
            Write-Host "[*] Removed .kno-url state directory."
        } catch {}
    }

    # 4. Self-delete script
    try {
        Write-Host "[*] Removing this script..."
        $pathCopy = $ScriptPath
        Start-Sleep -Milliseconds 200
        & cmd /c "del `"$pathCopy`""
    } catch {}

    # 5. Wipe PowerShell history entries created after KNO started
    Wipe-RecentHistory

    Write-Host "[+] Cleanup complete. Exiting..."

    # Exit process completely
    Start-Sleep -Milliseconds 200
    exit
}

# -----------------------------------------------------------
# PARSE -sd DURATIONS
# -----------------------------------------------------------

function Parse-Duration {
    param([string]$Raw)

    $raw = $Raw.Replace(" ", "").ToLower()

    $total = 0

    # h
    $hMatch = [regex]::Match($raw, '(\d+)h')
    if ($hMatch.Success) { $total += ([int]$hMatch.Groups[1].Value) * 3600 }

    # m
    $mMatch = [regex]::Match($raw, '(\d+)m')
    if ($mMatch.Success) { $total += ([int]$mMatch.Groups[1].Value) * 60 }

    # s
    $sMatch = [regex]::Match($raw, '(\d+)s')
    if ($sMatch.Success) { $total += ([int]$sMatch.Groups[1].Value) }

    if ($total -le 0) { return $null }

    return $total
}
# -----------------------------------------------------------
# RUN HTML MODE
# -----------------------------------------------------------

function Run-HtmlMode {
    param(
        [string]$Url,
        [string[]]$Args
    )

    # Extract search terms
    $searchTerms = @()
    for ($i=0; $i -lt $Args.Count; $i++) {
        if ($Args[$i] -eq '--search' -and $i -lt $Args.Count-1) {
            $searchTerms = $Args[$i+1].Split(',').Trim().ToLower()
        }
    }

    # Handle --full
    if ($Args -contains '--full') {
        Write-Host "[*] Fetching raw HTML from $Url ..."
        $html = Fetch-Html $Url
        if (-not $html) {
            Write-Host "[-] Failed to fetch HTML."
            return
        }
        Write-Host $html
        return
    }

    Write-Host "[*] Fetching HTML from $Url ..."
$html = Fetch-Html $Url
if (-not $html) {
    Write-Host "[-] Could not retrieve HTML."
    return
}

$urls = Extract-UrlsFromHtml -Html $html -BaseUrl $Url
Write-Host ("[*] Raw URLs extracted (pre-filter): {0}" -f $urls.Count)

$blobPresent = $urls | Where-Object { $_ -like 'blob:*' } | Measure-Object | Select-Object -ExpandProperty Count


    # Category filtering
    $parsed = Filter-CategoriesHtml -Args $Args
    $include = $parsed.IncludeCategories
    $exclude = $parsed.ExcludeCategories
    $outputFile = $parsed.OutputFile
    $noMediaMode = $parsed.NoMediaMode

    # Categorize
    $grouped = @{}
    foreach ($u in $urls) {

        # Search filtering
        if (-not (Test-MatchesSearch -Url $u -SearchTerms $searchTerms)) {
            continue
        }

        $cat = Categorize-UrlHtml $u

        if ($include) {
            if (-not ($include.Contains($cat))) { continue }
        }
        if ($exclude) {
            if ($exclude.Contains($cat)) { continue }
        }

        if (-not $grouped.ContainsKey($cat)) {
            $grouped[$cat] = New-Object System.Collections.Generic.List[string]
        }
        $grouped[$cat].Add($u)
    }

    Print-HtmlResults -Grouped $grouped -OutputFile $outputFile -BlobPresent ($blobPresent -gt 0)
}

# -----------------------------------------------------------
# FLAG VALIDATION (UNKNOWN FLAG CHECK)
# -----------------------------------------------------------

function Validate-Flags {
    param([string[]]$Args)

    foreach ($a in $Args) {
        if ($a.StartsWith('-') -and -not ($AllFlags -contains $a)) {
            Write-Host "Error: Unknown flag '$a'. Use -h for help."
            return $false
        }
    }
    return $true
}

# -----------------------------------------------------------
# SCHEDULED SELF-DESTRUCT EXECUTION
# -----------------------------------------------------------

function Execute-SD {
    param(
        [string]$Url,
        [string[]]$Args,
        [int]$Seconds
    )

    Write-Host "[*] Running HTML mode before scheduled self-destruct..."
    Run-HtmlMode $Url $Args

    Write-Host "[*] Self-destruct scheduled in $Seconds seconds..."
    Start-Sleep -Seconds $Seconds

    Write-Host "[+] Executing self-destruct NOW."
    Run-NightOps -RequireConfirm:$false
}

# -----------------------------------------------------------
# MAIN COMMAND HANDLER
# -----------------------------------------------------------

function Handle-Command {
    param([string]$Line)

    $parsed     = Parse-MainInput $Line
    $url        = $parsed.Url
    $args       = $parsed.Args

    # Help
    if ($url -eq 'HELP') {
        Show-Help
        return
    }

    # 1. NIGHT-OPS ONLY (NO OTHER FLAGS)
    if (($args -contains '--night-ops')) {

        # Check if any NON -sd flags accompany --night-ops
        $others = $args | Where-Object { $_ -ne '--night-ops' -and $_ -ne '-sd' }

        if ($others.Count -gt 0 -and -not ($args -contains '-sd')) {
            Write-Host "Error: --night-ops cannot be combined with other flags unless -sd is present."
            return
        }

        # Scheduled self-destruct case
        if ($args -contains '-sd') {
            $sdIndex = $args.IndexOf('-sd')
            if ($sdIndex -lt $args.Count-1) {
                $durationRaw = $args[$sdIndex + 1]
                $seconds = Parse-Duration $durationRaw
                if (-not $seconds) {
                    Write-Host "Error: Invalid duration for -sd. Use formats like 1h15m30s or 90s."
                    return
                }

                Write-Host "[*] Scheduled self-destruct in $seconds seconds..."
                Start-Sleep -Seconds $seconds
                Run-NightOps -RequireConfirm:$false
                return
            } else {
                Write-Host "Error: -sd requires a duration (e.g. 1h15m30s)"
                return
            }
        }

        # Immediate night ops
        Run-NightOps -RequireConfirm:$true
        return
    }

    # 2. URL MUST EXIST (except for pure --night-ops which already returned)
    if (-not $url) {
        Write-Host "[-] No URL detected. Use -h or --help for help."
        return
    }

    # 3. Validate flags
    if (-not (Validate-Flags $args)) {
        return
    }

    # 4. Network mode
if ($args -contains '-n') {
    $hasT    = $args -contains '-t'
    $hasLive = $args -contains '--live'

    # Require either -t <duration> or --live
    if (-not ($hasT -or $hasLive)) {
        Write-Host "[-] Network mode (-n) requires either -t <duration> or --live."
        return
    }

    # If -t is used, make sure it has a duration argument and it's not another flag
    if ($hasT) {
        $tIndex = $args.IndexOf('-t')
        if ($tIndex -lt 0 -or $tIndex -ge ($args.Count - 1)) {
            Write-Host "[-] Network mode (-n) with -t requires a duration (e.g. 30s, 2m, 1m30s, 90s)."
            return
        }
        $tValue = $args[$tIndex + 1]
        if ($tValue.StartsWith('-')) {
            Write-Host "[-] Network mode (-n) with -t requires a duration (e.g. 30s, 2m, 1m30s, 90s)."
            return
        }
    }

    # Only now do we track Playwright state (first valid -n use)
    Ensure-PlaywrightMarkers

    Run-NetworkMode $url $args
    return
}




    # 5. Scheduled self-destruct WITH HTML mode (rare but allowed)
    if ($args -contains '-sd') {
        $sdIndex = $args.IndexOf('-sd')
        if ($sdIndex -ge 0 -and $sdIndex -lt $args.Count-1) {
            $durationRaw = $args[$sdIndex+1]
            $seconds = Parse-Duration $durationRaw
            if (-not $seconds) {
                Write-Host "Error: Invalid duration for -sd."
                return
            }

            # Remove -sd and duration from normal args
            $cleanArgs = $args | Where-Object { $_ -ne '-sd' -and $_ -ne $durationRaw }

            # Run HTML mode
            Run-HtmlMode $url $cleanArgs

            Write-Host "[*] Scheduled self-destruct in $seconds seconds..."
            Start-Sleep -Seconds $seconds
            Run-NightOps -RequireConfirm:$false
            return
        } else {
            Write-Host "Error: -sd requires a duration."
            return
        }
    }

    # 6. Normal HTML mode
    Run-HtmlMode $url $args
}

# -----------------------------------------------------------
# MAIN LOOP (REPL)
# -----------------------------------------------------------

Write-Host "Kusanagi Night Ops: URL Scrapper (PowerShell Edition)"
Write-Host ""

while ($true) {
    $line = Read-Host "Main URL"
    if (-not $line) { continue }

    Handle-Command $line
}

