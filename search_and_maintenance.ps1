#Requires -Version 5.1
<#
.SYNOPSIS
    Search and maintenance engine for the Library — a local-first AI second brain.

.DESCRIPTION
    Pure-PowerShell (no external dependencies). Targets PowerShell 7+ and degrades
    gracefully to Windows PowerShell 5.1. Parses YAML front matter across every note,
    and performs deep search plus a suite of maintenance operations.

    The script's philosophy: FIND, DON'T DECIDE. Destructive or structural changes
    (merging, archiving) only run candidates as REPORTS unless you pass -Apply.
    Metadata-only refreshes (RecalcTokens, Validate auto-stamp) write by default but
    support -DryRun.

.PARAMETER Action
    Search | Duplicates | RecalcTokens | Prune | Validate | Stats | Touch | Reindex

.PARAMETER VaultPath
    Root of the vault. Defaults to the directory containing this script.

.PARAMETER Query
    Free-text query (Search). Matched against body and/or front matter per -SearchIn.

.PARAMETER Field
    A single YAML field name to match precisely (Search, with -Value).

.PARAMETER Value
    The value to match for -Field (Search).

.PARAMETER Mode
    Broad (fuzzy, case-insensitive, partial, multi-field) | Precise (exact). Default Broad.

.PARAMETER SearchIn
    Body | FrontMatter | Both. Where free-text -Query is searched. Default Both.

.PARAMETER Regex
    Treat -Query / -Value as a regular expression.

.PARAMETER Domain / Topic / Subtopic / Status / DocumentType / Sensitivity
    Convenience precise filters on the matching front-matter field.

.PARAMETER Tag / Ontology / Keyword
    List-membership filters (note matches if the list contains the value).

.PARAMETER MinConfidence
    Only notes with confidence_score >= this value.

.PARAMETER CreatedAfter / CreatedBefore / UpdatedAfter / UpdatedBefore / AccessedBefore
    Date-range filters (YYYY-MM-DD).

.PARAMETER Threshold
    Similarity threshold 0..1 for Duplicates. Default 0.40.

.PARAMETER Shingle
    Shingle size (words) for similarity. Default 3.

.PARAMETER OlderThanDays
    RecalcTokens: only recompute notes whose token_last_reviewed is older than this. Default 60.

.PARAMETER StaleDays
    Prune: notes whose last_accessed is older than this become archive candidates. Default 365.

.PARAMETER IncludeArchive / IncludeTemplates
    Include 04_Archive / _Templates in the working set (excluded by default).

.PARAMETER Apply
    Perform the destructive/structural side effect (move to Archive, stamp cluster ids).

.PARAMETER DryRun
    Preview metadata writes without saving.

.PARAMETER Report
    Write timestamped CSV + JSON output to <Vault>\.maintenance\.

.EXAMPLE
    .\search_and_maintenance.ps1 -Action Search -Query "datastore latency" -Mode Broad

.EXAMPLE
    .\search_and_maintenance.ps1 -Action Search -Field domain -Value "Information Technology" -Mode Precise

.EXAMPLE
    .\search_and_maintenance.ps1 -Action Duplicates -Threshold 0.45 -Report

.EXAMPLE
    .\search_and_maintenance.ps1 -Action RecalcTokens -OlderThanDays 60

.EXAMPLE
    .\search_and_maintenance.ps1 -Action Prune -StaleDays 365            # report only
    .\search_and_maintenance.ps1 -Action Prune -StaleDays 365 -Apply     # actually archive

.EXAMPLE
    .\search_and_maintenance.ps1 -Action Validate -Report
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Search','Duplicates','RecalcTokens','Prune','Validate','Stats','Touch','Reindex')]
    [string]$Action,

    [string]$VaultPath = $PSScriptRoot,

    # --- Search ---
    [string]$Query,
    [string]$Field,
    [string]$Value,
    [ValidateSet('Broad','Precise')] [string]$Mode = 'Broad',
    [ValidateSet('Body','FrontMatter','Both')] [string]$SearchIn = 'Both',
    [switch]$Regex,
    [string]$Domain,
    [string]$Topic,
    [string]$Subtopic,
    [string]$Status,
    [string]$DocumentType,
    [string]$Sensitivity,
    [string]$Tag,
    [string]$Ontology,
    [string]$Keyword,
    [double]$MinConfidence = -1,
    [string]$CreatedAfter,
    [string]$CreatedBefore,
    [string]$UpdatedAfter,
    [string]$UpdatedBefore,
    [string]$AccessedBefore,

    # --- Duplicates ---
    [double]$Threshold = 0.40,
    [int]$Shingle = 3,

    # --- Maintenance ---
    [int]$OlderThanDays = 60,
    [int]$StaleDays = 365,

    # --- Scope / behavior ---
    [switch]$IncludeArchive,
    [switch]$IncludeTemplates,
    [switch]$Apply,
    [switch]$DryRun,
    [switch]$Report,

    # --- Touch ---
    [string]$Path
)

# ============================================================================ #
#  CONSTANTS
# ============================================================================ #
$Script:SchemaVersion   = '1.0'
$Script:SystemFiles     = @('README.md','instructions.md','Map_of_Content.md')
$Script:RequiredFields  = @('uid','title','domain','topic','document_type','tags',
                            'summary','status','context_tokens','token_last_reviewed',
                            'confidence_score','sensitivity','schema_version',
                            'date_created','last_updated','last_accessed')
$Script:ValidStatus      = @('Idea','Needs Deep Research','Draft','In Review','Final','Deprecated')
$Script:ValidSensitivity = @('public','internal','private','secret')
$Script:MaintDir         = Join-Path $VaultPath '.maintenance'

if (-not (Test-Path -LiteralPath $VaultPath)) {
    throw "VaultPath not found: $VaultPath"
}

# ============================================================================ #
#  HELPERS
# ============================================================================ #

function Write-Info { param([string]$m) Write-Host $m -ForegroundColor Cyan }
function Write-Warn { param([string]$m) Write-Host $m -ForegroundColor Yellow }
function Write-Ok   { param([string]$m) Write-Host $m -ForegroundColor Green }

# ---------------------------------------------------------------------------- #
#  CONCURRENCY / RESILIENT I/O (universal; no external dependencies)
# ---------------------------------------------------------------------------- #
# These make the script safe to run alongside other writers (Obsidian, the AI,
# a cloud-sync client) on ANY platform: transient file locks are retried, every
# note write is atomic (temp + atomic replace, so a reader never sees a partial
# file), and only one maintenance WRITE run executes at a time (single-instance
# lock). They depend only on .NET methods present on PowerShell 5.1 and 7+.

function Invoke-WithRetry {
    # Run a scriptblock, retrying transient sharing-violation / lock errors with
    # increasing backoff. Non-transient errors (e.g. file-not-found) are rethrown
    # immediately. Returns the scriptblock's output.
    param(
        [Parameter(Mandatory)] [scriptblock]$Action,
        [int]$MaxAttempts = 6,
        [int]$DelayMs = 120
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return (& $Action)
        }
        catch [System.IO.IOException] {
            if ($_.Exception -is [System.IO.FileNotFoundException] -or
                $_.Exception -is [System.IO.DirectoryNotFoundException]) { throw }
            if ($attempt -eq $MaxAttempts) { throw }
            Start-Sleep -Milliseconds ($DelayMs * $attempt)
        }
        catch [System.UnauthorizedAccessException] {
            if ($attempt -eq $MaxAttempts) { throw }
            Start-Sleep -Milliseconds ($DelayMs * $attempt)
        }
    }
}

function Get-FileTextRetry {
    # Read a file as raw text, retrying transient locks. Returns '' for empty/null.
    param([string]$FilePath)
    $txt = Invoke-WithRetry { Get-Content -LiteralPath $FilePath -Raw -ErrorAction Stop }
    if ($null -eq $txt) { return '' }
    return $txt
}

function Write-FileAtomic {
    # Write UTF-8 (no BOM) to a temp file in the SAME directory, then atomically
    # replace the target. Readers see either the old or the new file, never a
    # half-written one. Works on PS 5.1 and 7+, Windows / macOS / Linux.
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter(Mandatory)] [string]$Content
    )
    $dir = [System.IO.Path]::GetDirectoryName($FilePath)
    if ([string]::IsNullOrEmpty($dir)) { $dir = '.' }
    # ".tmp" extension keeps these out of the *.md note scan and easy to sync-ignore.
    $tmp = Join-Path $dir ('.smtmp_' + [System.IO.Path]::GetRandomFileName() + '.tmp')
    $enc = New-Object System.Text.UTF8Encoding($false)
    $bak = $tmp + '.bak'
    try {
        Invoke-WithRetry { [System.IO.File]::WriteAllText($tmp, $Content, $enc) }
        if (Test-Path -LiteralPath $FilePath) {
            # Atomic same-volume replace (rename semantics). A real backup path is
            # required on PS 5.1 (a null/empty backup arg is rejected); we delete it
            # immediately after. ignoreMetadataErrors=$true for cloud-synced volumes.
            Invoke-WithRetry { [System.IO.File]::Replace($tmp, $FilePath, $bak, $true) }
        } else {
            Invoke-WithRetry { [System.IO.File]::Move($tmp, $FilePath) }
        }
    }
    finally {
        if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Enter-VaultLock {
    # Single-instance write lock via an exclusively-created lock file. Returns
    # $true if acquired. A lock older than -StaleMinutes is treated as a crashed
    # run and reclaimed. Portable (no OS-specific named mutex required).
    param([string]$LockPath, [int]$StaleMinutes = 60)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $fs = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew,
                    [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("pid=$PID`nstarted=$(Get-Date -Format o)`n")
                $fs.Write($bytes, 0, $bytes.Length)
            } finally { $fs.Dispose() }
            return $true
        }
        catch {
            # Lock exists: reclaim it only if it is stale.
            try {
                $info = Get-Item -LiteralPath $LockPath -ErrorAction Stop
                if ($info.LastWriteTime -lt (Get-Date).AddMinutes(-$StaleMinutes)) {
                    Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
                    continue
                }
            } catch { }
            return $false
        }
    }
    return $false
}

function Exit-VaultLock {
    param([string]$LockPath)
    if ($LockPath) { Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue }
}

function Get-StringHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
        $hash  = $sha.ComputeHash($bytes)
        return -join ($hash | ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }
}

function Get-Normalized {
    # Normalize body for hashing/comparison: \n line endings, trimmed trailing ws.
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $t = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    $lines = $t -split "`n" | ForEach-Object { $_.TrimEnd() }
    return ($lines -join "`n").Trim()
}

function Get-TokenEstimate {
    # Mirror of instructions.md: round(max(chars/4, words*0.75))
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 0 }
    $chars = $Text.Length
    $words = (($Text -split '\s+') | Where-Object { $_ -ne '' }).Count
    return [int][math]::Round([math]::Max($chars / 4.0, $words * 0.75))
}

function Get-WordCount {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 0 }
    return (($Text -split '\s+') | Where-Object { $_ -ne '' }).Count
}

function Clear-YamlScalar {
    param([string]$v)
    if ($null -eq $v) { return '' }
    $v = $v.Trim()
    if ($v.Length -ge 2) {
        if (($v.StartsWith('"') -and $v.EndsWith('"')) -or
            ($v.StartsWith("'") -and $v.EndsWith("'"))) {
            $v = $v.Substring(1, $v.Length - 2)
        }
    }
    return $v
}

function ConvertFrom-FrontMatter {
    # Minimal YAML parser sufficient for this schema: scalars, inline lists [a, b],
    # and block lists ("- item" on following lines). Returns an ordered hashtable.
    param([string]$FmText)
    $map   = [ordered]@{}
    $lines = $FmText -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*#' -or $line.Trim() -eq '') { continue }
        if ($line -match '^([A-Za-z0-9_\-]+):\s*(.*)$') {
            $key = $matches[1]
            $val = $matches[2]
            if ($val -eq '') {
                # Possible block list on following indented "- " lines
                $list = @()
                while (($i + 1) -lt $lines.Count -and $lines[$i + 1] -match '^\s*-\s*(.*)$') {
                    $list += (Clear-YamlScalar $matches[1])
                    $i++
                }
                if ($list.Count -gt 0) { $map[$key] = $list } else { $map[$key] = '' }
            }
            elseif ($val -match '^\[(.*)\]$') {
                $inner = $matches[1].Trim()
                if ($inner -eq '') { $map[$key] = @() }
                else { $map[$key] = @($inner -split ',' | ForEach-Object { Clear-YamlScalar $_ }) }
            }
            else {
                $map[$key] = Clear-YamlScalar $val
            }
        }
    }
    return $map
}

function Format-YamlValue {
    param($Value)
    if ($Value -is [System.Array]) {
        return '[' + (($Value | ForEach-Object { [string]$_ }) -join ', ') + ']'
    }
    return [string]$Value
}

function Update-FrontMatterFields {
    # Surgically update/insert specific front-matter fields, preserving everything else.
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter(Mandatory)] [hashtable]$Updates,
        [switch]$Preview
    )
    $raw = Get-FileTextRetry $FilePath
    $raw = $raw.TrimStart([char]0xFEFF)   # strip UTF-8 BOM if present
    if ($raw -notmatch "(?s)^---\r?\n(.*?)\r?\n---\r?\n?(.*)$") {
        Write-Warn "  No front matter; skipped: $FilePath"
        return $false
    }
    # Optimistic-concurrency baseline: remember the file's write time at read.
    $stampAtRead = [System.IO.File]::GetLastWriteTimeUtc($FilePath)
    $fm   = $matches[1]
    $body = $matches[2]
    foreach ($k in $Updates.Keys) {
        $rendered = Format-YamlValue $Updates[$k]
        $pattern  = "(?m)^" + [regex]::Escape($k) + ":.*$"
        if ($fm -match $pattern) {
            $fm = [regex]::Replace($fm, $pattern, ("{0}: {1}" -f $k, $rendered))
        } else {
            $fm = $fm.TrimEnd() + "`n" + ("{0}: {1}" -f $k, $rendered)
        }
    }
    $out = "---`n" + $fm.Trim() + "`n---`n" + $body
    if ($Preview) {
        Write-Host "  [DryRun] would update $([System.IO.Path]::GetFileName($FilePath)): $($Updates.Keys -join ', ')"
        return $true
    }
    # Compare-and-swap: if another writer (human, AI, sync) changed the file since
    # we read it, do NOT clobber their edit. Skip; the next run will pick it up.
    $stampNow = [System.IO.File]::GetLastWriteTimeUtc($FilePath)
    if ($stampNow -ne $stampAtRead) {
        Write-Warn "  Skipped (changed by another writer during update): $FilePath"
        return $false
    }
    # Atomic, BOM-free write.
    Write-FileAtomic -FilePath $FilePath -Content $out
    return $true
}

function Get-Notes {
    # Load every note into a rich object: path, relative folder, front matter, body.
    param(
        [switch]$WithArchive,
        [switch]$WithTemplates
    )
    $all = Get-ChildItem -LiteralPath $VaultPath -Recurse -File -Filter *.md -ErrorAction SilentlyContinue
    $notes = New-Object System.Collections.Generic.List[object]
    foreach ($f in $all) {
        $rel = $f.FullName.Substring($VaultPath.Length).TrimStart('\','/')
        if ($rel -like '.maintenance*') { continue }
        if ($Script:SystemFiles -contains $f.Name -and ($rel -notmatch '[\\/]')) { continue }
        # Skip hidden folders (any dir segment starting with '.') and meta folders
        # (dir segment starting with '_', e.g. _capabilities, _system) — but NOT
        # _Templates, which is governed by -WithTemplates below.
        if ($rel -match '(^|[\\/])\.[^\\/]+[\\/]') { continue }
        if ($rel -match '(^|[\\/])_(?!Templates([\\/]|$))[^\\/]*[\\/]') { continue }
        if (-not $WithArchive   -and $rel -match '^04_Archive([\\/]|$)') { continue }
        if (-not $WithTemplates -and $rel -match '(^|[\\/])_Templates([\\/]|$)') { continue }
        # Structural content of chunked works / datasets is content, not notes —
        # within such a folder only index.md is the note (see _capabilities/).
        if ($rel -match '(^|[\\/])chunks[\\/]') { continue }
        if (@('source.md','manifest.md','profile.md') -contains $f.Name) { continue }
        # Reference tooling dir holds docs/code, not notes.
        if ($rel -match '(^|[\\/])bin[\\/]') { continue }

        $raw = Get-FileTextRetry $f.FullName
        $raw = $raw.TrimStart([char]0xFEFF)   # strip UTF-8 BOM if present
        $fm = [ordered]@{}; $body = $raw
        if ($raw -match "(?s)^---\r?\n(.*?)\r?\n---\r?\n?(.*)$") {
            $fm   = ConvertFrom-FrontMatter $matches[1]
            $body = $matches[2]
        }
        $topFolder = ($rel -split '[\\/]')[0]
        $notes.Add([pscustomobject]@{
            Path       = $f.FullName
            Rel        = $rel
            Name       = $f.Name
            Folder     = $topFolder
            FM         = $fm
            Body       = $body
            NormBody   = (Get-Normalized $body)
        })
    }
    return $notes
}

function Get-FMValue {
    param($Note, [string]$Key)
    if ($Note.FM.Contains($Key)) { return $Note.FM[$Key] }
    return $null
}

function Test-DateOlderThan {
    param([string]$DateStr, [int]$Days)
    if ([string]::IsNullOrWhiteSpace($DateStr)) { return $true }  # missing = treat as stale
    try { $d = [datetime]::Parse($DateStr) } catch { return $true }
    return $d -lt (Get-Date).AddDays(-$Days)
}

function Get-Shingles {
    param([string]$Text, [int]$K = 3)
    $clean = ($Text.ToLowerInvariant() -replace '[^a-z0-9\s]', ' ') -replace '\s+', ' '
    $words = @($clean.Trim() -split ' ' | Where-Object { $_ -ne '' })
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($words.Count -lt $K) {
        foreach ($w in $words) { [void]$set.Add($w) }
        return $set
    }
    for ($i = 0; $i -le $words.Count - $K; $i++) {
        [void]$set.Add(($words[$i..($i + $K - 1)] -join ' '))
    }
    return $set
}

function Get-Jaccard {
    param($SetA, $SetB)
    if ($SetA.Count -eq 0 -or $SetB.Count -eq 0) { return 0.0 }
    $inter = 0
    if ($SetA.Count -le $SetB.Count) { $small = $SetA; $large = $SetB }
    else { $small = $SetB; $large = $SetA }
    foreach ($s in $small) { if ($large.Contains($s)) { $inter++ } }
    $union = $SetA.Count + $SetB.Count - $inter
    if ($union -eq 0) { return 0.0 }
    return [math]::Round($inter / [double]$union, 4)
}

function Save-Report {
    param([string]$BaseName, $Data)
    if (-not (Test-Path -LiteralPath $Script:MaintDir)) {
        New-Item -ItemType Directory -Path $Script:MaintDir -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $csv   = Join-Path $Script:MaintDir ("{0}_{1}.csv"  -f $BaseName, $stamp)
    $json  = Join-Path $Script:MaintDir ("{0}_{1}.json" -f $BaseName, $stamp)
    try { $Data | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8 } catch {}
    $Data | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $json -Encoding UTF8
    Write-Ok "  Report: $csv"
    Write-Ok "  Report: $json"
}

# ============================================================================ #
#  ACTION: Search
# ============================================================================ #
function Invoke-Search {
    $notes = Get-Notes -WithArchive:$IncludeArchive -WithTemplates:$IncludeTemplates
    $results = foreach ($n in $notes) {

        # ---- Precise single-field match ----
        if ($Field) {
            $fv = Get-FMValue $n $Field
            if ($null -eq $fv) { continue }
            if ($fv -is [System.Array]) { $hay = $fv -join "`n" } else { $hay = [string]$fv }
            if ($Regex) {
                $hit = $hay -match $Value
            } elseif ($Mode -eq 'Precise') {
                if ($fv -is [System.Array]) { $hit = ($fv -contains $Value) } else { $hit = ($hay -eq $Value) }
            } else {
                $hit = $hay -like "*$Value*"
            }
            if (-not $hit) { continue }
        }

        # ---- Convenience precise filters ----
        if ($Domain       -and (Get-FMValue $n 'domain')        -ne $Domain)        { continue }
        if ($Topic        -and (Get-FMValue $n 'topic')         -ne $Topic)         { continue }
        if ($Subtopic     -and (Get-FMValue $n 'subtopic')      -ne $Subtopic)      { continue }
        if ($Status       -and (Get-FMValue $n 'status')        -ne $Status)        { continue }
        if ($DocumentType -and (Get-FMValue $n 'document_type') -ne $DocumentType)  { continue }
        if ($Sensitivity  -and (Get-FMValue $n 'sensitivity')   -ne $Sensitivity)   { continue }

        # ---- List membership filters ----
        if ($Tag) {
            $t = Get-FMValue $n 'tags'
            if (-not ($t -is [System.Array]) -or ($t -notcontains $Tag)) { continue }
        }
        if ($Ontology) {
            $o = Get-FMValue $n 'ontology'
            if (-not ($o -is [System.Array]) -or ($o -notcontains $Ontology)) { continue }
        }
        if ($Keyword) {
            $k = Get-FMValue $n 'keywords'
            if (-not ($k -is [System.Array]) -or ($k -notcontains $Keyword)) { continue }
        }

        # ---- Confidence ----
        if ($MinConfidence -ge 0) {
            $c = Get-FMValue $n 'confidence_score'
            if ($null -eq $c -or [double]$c -lt $MinConfidence) { continue }
        }

        # ---- Date ranges ----
        if ($CreatedAfter   -and (Get-FMValue $n 'date_created') -and [datetime](Get-FMValue $n 'date_created') -lt [datetime]$CreatedAfter)  { continue }
        if ($CreatedBefore  -and (Get-FMValue $n 'date_created') -and [datetime](Get-FMValue $n 'date_created') -gt [datetime]$CreatedBefore) { continue }
        if ($UpdatedAfter   -and (Get-FMValue $n 'last_updated') -and [datetime](Get-FMValue $n 'last_updated') -lt [datetime]$UpdatedAfter)  { continue }
        if ($UpdatedBefore  -and (Get-FMValue $n 'last_updated') -and [datetime](Get-FMValue $n 'last_updated') -gt [datetime]$UpdatedBefore) { continue }
        if ($AccessedBefore -and (Get-FMValue $n 'last_accessed') -and [datetime](Get-FMValue $n 'last_accessed') -gt [datetime]$AccessedBefore) { continue }

        # ---- Free-text query ----
        if ($Query) {
            $fmText = ($n.FM.GetEnumerator() | ForEach-Object {
                        if ($_.Value -is [System.Array]) { $v = $_.Value -join ' ' } else { $v = [string]$_.Value }
                        "$($_.Key) $v"
                      }) -join "`n"
            switch ($SearchIn) {
                'Body'        { $hay = $n.Body }
                'FrontMatter' { $hay = $fmText }
                default       { $hay = $fmText + "`n" + $n.Body }
            }
            if ($Regex) {
                $hit = $hay -match $Query
            } elseif ($Mode -eq 'Precise') {
                $hit = $hay -clike "*$Query*"
            } else {
                # Broad: every whitespace token must appear (AND), case-insensitive
                $terms = $Query -split '\s+' | Where-Object { $_ -ne '' }
                $hit = $true
                foreach ($term in $terms) { if ($hay -notlike "*$term*") { $hit = $false; break } }
            }
            if (-not $hit) { continue }
        }

        [pscustomobject]@{
            Title      = Get-FMValue $n 'title'
            UID        = Get-FMValue $n 'uid'
            Folder     = $n.Folder
            Domain     = Get-FMValue $n 'domain'
            Topic      = Get-FMValue $n 'topic'
            Status     = Get-FMValue $n 'status'
            Type       = Get-FMValue $n 'document_type'
            Tokens     = Get-FMValue $n 'context_tokens'
            Confidence = Get-FMValue $n 'confidence_score'
            Updated    = Get-FMValue $n 'last_updated'
            Summary    = Get-FMValue $n 'summary'
            Rel        = $n.Rel
        }
    }

    $results = @($results)
    Write-Info "`n$($results.Count) match(es) [$Mode]:`n"
    if ($results.Count) {
        $results | Format-Table Title, Folder, Domain, Topic, Status, Tokens, Updated, Rel -AutoSize | Out-Host
    }
    if ($Report -and $results.Count) { Save-Report 'search' $results }
    return $results
}

# ============================================================================ #
#  ACTION: Duplicates  (find like / common / duplicate notes -> candidates)
# ============================================================================ #
function Invoke-Duplicates {
    $notes = @(Get-Notes -WithArchive:$IncludeArchive -WithTemplates:$IncludeTemplates)
    Write-Info "Scanning $($notes.Count) notes for similarity (threshold $Threshold, shingle $Shingle)..."

    # Pre-compute shingle sets + exact-content hashes.
    foreach ($n in $notes) {
        Add-Member -InputObject $n -NotePropertyName Shingles -NotePropertyValue (Get-Shingles $n.NormBody $Shingle) -Force
        Add-Member -InputObject $n -NotePropertyName Hash     -NotePropertyValue (Get-StringHash $n.NormBody) -Force
    }

    # Exact duplicates by body hash.
    $exact = $notes | Group-Object Hash | Where-Object { $_.Count -gt 1 }

    # Pairwise near-duplicate detection.
    $pairs = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $notes.Count; $i++) {
        for ($j = $i + 1; $j -lt $notes.Count; $j++) {
            $a = $notes[$i]; $b = $notes[$j]
            $sim = Get-Jaccard $a.Shingles $b.Shingles

            # Light metadata boost: shared domain/topic + overlapping tags.
            $bonus = 0.0
            if ((Get-FMValue $a 'domain') -and (Get-FMValue $a 'domain') -eq (Get-FMValue $b 'domain')) { $bonus += 0.03 }
            if ((Get-FMValue $a 'topic')  -and (Get-FMValue $a 'topic')  -eq (Get-FMValue $b 'topic'))  { $bonus += 0.03 }
            $ta = Get-FMValue $a 'tags'; $tb = Get-FMValue $b 'tags'
            if ($ta -is [System.Array] -and $tb -is [System.Array]) {
                $shared = @($ta | Where-Object { $tb -contains $_ }).Count
                if ($shared -gt 0) { $bonus += [math]::Min(0.06, $shared * 0.02) }
            }
            $score = [math]::Round([math]::Min(1.0, $sim + $bonus), 4)
            if ($score -ge $Threshold) {
                $pairs.Add([pscustomobject]@{ A = $a; B = $b; Score = $score; TextSim = $sim })
            }
        }
    }

    # Union-Find clustering over qualifying pairs.
    $parent = @{}
    function Find($x) { while ($parent[$x] -ne $x) { $parent[$x] = $parent[$parent[$x]]; $x = $parent[$x] } return $x }
    foreach ($n in $notes) { $parent[$n.Rel] = $n.Rel }
    foreach ($p in $pairs) {
        $ra = Find $p.A.Rel; $rb = Find $p.B.Rel
        if ($ra -ne $rb) { $parent[$ra] = $rb }
    }
    $clusters = @{}
    foreach ($p in $pairs) {
        $root = Find $p.A.Rel
        if (-not $clusters.ContainsKey($root)) { $clusters[$root] = New-Object 'System.Collections.Generic.HashSet[string]' }
        [void]$clusters[$root].Add($p.A.Rel)
        [void]$clusters[$root].Add($p.B.Rel)
    }

    $clusterReport = New-Object System.Collections.Generic.List[object]
    $cid = 0
    foreach ($root in $clusters.Keys) {
        $cid++
        $members = @($clusters[$root])
        $clusterId = ("cluster-{0:yyyyMMdd}-{1:D3}" -f (Get-Date), $cid)
        $best = ($pairs | Where-Object { $members -contains $_.A.Rel -and $members -contains $_.B.Rel } |
                 Sort-Object Score -Descending | Select-Object -First 1).Score
        foreach ($m in $members) {
            $note = $notes | Where-Object { $_.Rel -eq $m } | Select-Object -First 1
            $clusterReport.Add([pscustomobject]@{
                ClusterId  = $clusterId
                PeakScore  = $best
                Title      = Get-FMValue $note 'title'
                UID        = Get-FMValue $note 'uid'
                Domain     = Get-FMValue $note 'domain'
                Topic      = Get-FMValue $note 'topic'
                Tokens     = Get-FMValue $note 'context_tokens'
                Rel        = $note.Rel
            })
        }

        # Optionally stamp cluster_id + merge_candidates for the AI to review.
        if ($Apply) {
            foreach ($m in $members) {
                $note = $notes | Where-Object { $_.Rel -eq $m } | Select-Object -First 1
                $others = @()
                foreach ($mm in $members) {
                    if ($mm -eq $m) { continue }
                    $o = $notes | Where-Object { $_.Rel -eq $mm } | Select-Object -First 1
                    $u = Get-FMValue $o 'uid'
                    if ($u) { $others += $u }
                }
                Update-FrontMatterFields -FilePath $note.Path -Preview:$DryRun -Updates @{
                    cluster_id       = $clusterId
                    merge_candidates = $others
                    last_maintained  = (Get-Date -Format 'yyyy-MM-dd')
                } | Out-Null
            }
        }
    }

    Write-Host ""
    if ($exact) {
        Write-Warn "EXACT-CONTENT duplicates (identical body):"
        foreach ($g in $exact) {
            Write-Host ("  [{0}] {1}" -f $g.Count, (($g.Group | ForEach-Object { $_.Rel }) -join '  |  '))
        }
        Write-Host ""
    }
    $clusterCount = ($clusterReport | Select-Object -ExpandProperty ClusterId -Unique | Measure-Object).Count
    Write-Info "$clusterCount near-duplicate cluster(s):"
    if ($clusterReport.Count) {
        $clusterReport | Sort-Object ClusterId, Rel |
            Format-Table ClusterId, PeakScore, Title, Domain, Topic, Tokens, Rel -AutoSize | Out-Host
    }
    Write-Warn "`nThese are CANDIDATES only. Hand them to the AI to decide: MERGE / SYNTHESIZE-NEW / KEEP-SEPARATE."
    if ($Apply) { Write-Ok "cluster_id + merge_candidates stamped onto notes for AI review." }

    if ($Report) { Save-Report 'duplicates' $clusterReport }
    return $clusterReport
}

# ============================================================================ #
#  ACTION: RecalcTokens
# ============================================================================ #
function Invoke-RecalcTokens {
    $notes = @(Get-Notes -WithArchive:$IncludeArchive -WithTemplates:$IncludeTemplates)
    $today = Get-Date -Format 'yyyy-MM-dd'
    $touched = New-Object System.Collections.Generic.List[object]
    foreach ($n in $notes) {
        $reviewed = Get-FMValue $n 'token_last_reviewed'
        if (-not (Test-DateOlderThan $reviewed $OlderThanDays)) { continue }

        $tokens = Get-TokenEstimate $n.Body
        $words  = Get-WordCount     $n.Body
        $hash   = Get-StringHash    $n.NormBody
        $ok = Update-FrontMatterFields -FilePath $n.Path -Preview:$DryRun -Updates @{
            context_tokens      = $tokens
            word_count          = $words
            content_hash        = $hash
            token_last_reviewed = $today
            last_maintained     = $today
        }
        if ($ok) {
            $touched.Add([pscustomobject]@{
                Title = Get-FMValue $n 'title'; Rel = $n.Rel
                OldReviewed = $reviewed; NewTokens = $tokens; Words = $words
            })
        }
    }
    if ($DryRun) { $suffix = ' [DryRun]' } else { $suffix = '' }
    Write-Ok "Recalculated $($touched.Count) note(s) older than $OlderThanDays days$suffix."
    if ($touched.Count) { $touched | Format-Table Title, NewTokens, Words, Rel -AutoSize | Out-Host }
    if ($Report -and $touched.Count) { Save-Report 'recalc_tokens' $touched }
    return $touched
}

# ============================================================================ #
#  ACTION: Prune  (unused-note -> archive candidates)
# ============================================================================ #
function Invoke-Prune {
    $notes = @(Get-Notes)   # active set only; archive excluded by design
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($n in $notes) {
        if ((Get-FMValue $n 'pinned') -eq 'true') { continue }
        $accessed = Get-FMValue $n 'last_accessed'
        if (Test-DateOlderThan $accessed $StaleDays) {
            $candidates.Add([pscustomobject]@{
                Title = Get-FMValue $n 'title'; UID = Get-FMValue $n 'uid'
                Folder = $n.Folder; LastAccessed = $accessed
                Status = Get-FMValue $n 'status'; Rel = $n.Rel; Path = $n.Path
            })
        }
    }
    Write-Warn "$($candidates.Count) note(s) not accessed in $StaleDays+ days (archive candidates):"
    if ($candidates.Count) { $candidates | Format-Table Title, Folder, LastAccessed, Status, Rel -AutoSize | Out-Host }

    if ($Apply -and $candidates.Count) {
        $today = Get-Date -Format 'yyyy-MM-dd'
        foreach ($c in $candidates) {
            $destDir = Join-Path $VaultPath '04_Archive'
            $sub = Split-Path $c.Rel -Parent
            if ($sub) { $destDir = Join-Path $destDir $sub }
            if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            Update-FrontMatterFields -FilePath $c.Path -Updates @{ last_maintained = $today } | Out-Null
            $dest = Join-Path $destDir (Split-Path $c.Rel -Leaf)
            Invoke-WithRetry { Move-Item -LiteralPath $c.Path -Destination $dest -Force -ErrorAction Stop }
            Write-Host "  Archived: $($c.Rel)"
        }
        Write-Ok "Moved $($candidates.Count) note(s) to 04_Archive."
    } elseif ($candidates.Count) {
        Write-Warn "`nReport only. Re-run with -Apply (after human approval) to archive."
    }
    if ($Report -and $candidates.Count) { Save-Report 'prune_candidates' ($candidates | Select-Object Title,UID,Folder,LastAccessed,Status,Rel) }
    return $candidates
}

# ============================================================================ #
#  ACTION: Validate  (schema integrity, links, proxy targets)
# ============================================================================ #
function Invoke-Validate {
    $notes = @(Get-Notes -WithArchive:$IncludeArchive -WithTemplates:$IncludeTemplates)
    # Build a lookup of known uids + titles + filenames for link resolution.
    $known = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($n in $notes) {
        $u = Get-FMValue $n 'uid';   if ($u) { [void]$known.Add([string]$u) }
        $t = Get-FMValue $n 'title'; if ($t) { [void]$known.Add([string]$t) }
        [void]$known.Add([System.IO.Path]::GetFileNameWithoutExtension($n.Name))
    }
    # System docs are valid link targets even though they aren't scanned as notes.
    foreach ($sf in $Script:SystemFiles) { [void]$known.Add([System.IO.Path]::GetFileNameWithoutExtension($sf)) }

    $issues = New-Object System.Collections.Generic.List[object]
    foreach ($n in $notes) {
        $add = { param($sev,$msg) $issues.Add([pscustomobject]@{ Severity=$sev; Issue=$msg; Title=(Get-FMValue $n 'title'); Rel=$n.Rel }) }

        if ($n.FM.Count -eq 0) { & $add 'ERROR' 'Missing front matter entirely'; continue }

        foreach ($req in $Script:RequiredFields) {
            if (-not $n.FM.Contains($req) -or [string]::IsNullOrWhiteSpace([string]$n.FM[$req])) {
                & $add 'ERROR' "Missing required field: $req"
            }
        }
        # Enum checks
        $st = Get-FMValue $n 'status'
        if ($st -and ($Script:ValidStatus -notcontains $st)) { & $add 'WARN' "Unknown status: $st" }
        $se = Get-FMValue $n 'sensitivity'
        if ($se -and ($Script:ValidSensitivity -notcontains $se)) { & $add 'WARN' "Unknown sensitivity: $se" }
        $sv = Get-FMValue $n 'schema_version'
        if ($sv -and $sv -ne $Script:SchemaVersion) { & $add 'INFO' "schema_version $sv != $($Script:SchemaVersion) (migration may be needed)" }

        # Date parse checks
        foreach ($df in @('date_created','last_updated','last_accessed','token_last_reviewed','review_due','archive_after')) {
            $dv = Get-FMValue $n $df
            if ($dv) { try { [void][datetime]::Parse($dv) } catch { & $add 'ERROR' "Unparseable date in $df : $dv" } }
        }
        # Confidence range
        $cf = Get-FMValue $n 'confidence_score'
        if ($cf -and ($null -ne ($cf -as [double]))) { if ([double]$cf -lt 0 -or [double]$cf -gt 1) { & $add 'WARN' "confidence_score out of 0..1: $cf" } }

        # Proxy note checks
        if ((Get-FMValue $n 'document_type') -eq 'Proxy-Note') {
            $ta = Get-FMValue $n 'target_artifact'
            if (-not $ta) { & $add 'ERROR' 'Proxy-Note missing target_artifact' }
            else {
                if ([System.IO.Path]::IsPathRooted($ta)) { $full = $ta } else { $full = Join-Path $VaultPath $ta }
                if (-not (Test-Path -LiteralPath $full)) { & $add 'ERROR' "target_artifact not found on disk: $ta" }
            }
        }

        # Broken wikilinks in body + relational fields
        $linkText = $n.Body
        foreach ($rf in @('related','parent','moc','superseded_by')) {
            $rv = Get-FMValue $n $rf
            if ($rv) {
                if ($rv -is [System.Array]) { $linkText += "`n" + ($rv -join "`n") }
                else { $linkText += "`n" + [string]$rv }
            }
        }
        foreach ($lm in [regex]::Matches($linkText, '\[\[([^\]\|]+)(\|[^\]]+)?\]\]')) {
            $target = ($lm.Groups[1].Value -split '#')[0].Trim()   # drop any #heading anchor
            if ($target) {
                $leaf = ($target -split '[\\/]')[-1]                # allow path-style [[folder/index]]
                if (-not ($known.Contains($target) -or $known.Contains($leaf))) {
                    & $add 'WARN' "Broken wikilink: [[$target]]"
                }
            }
        }
    }

    $errs  = @($issues | Where-Object Severity -eq 'ERROR')
    $warns = @($issues | Where-Object Severity -eq 'WARN')
    $infos = @($issues | Where-Object Severity -eq 'INFO')
    Write-Host ""
    Write-Info "Validation across $($notes.Count) notes: $($errs.Count) errors, $($warns.Count) warnings, $($infos.Count) info."
    if ($issues.Count) {
        $issues | Sort-Object Severity, Rel | Format-Table Severity, Issue, Title, Rel -AutoSize | Out-Host
    } else { Write-Ok "  Clean. No schema problems found." }
    if ($Report -and $issues.Count) { Save-Report 'validation' $issues }
    return $issues
}

# ============================================================================ #
#  ACTION: Stats  (vault dashboard)
# ============================================================================ #
function Invoke-Stats {
    $notes   = @(Get-Notes -WithArchive)
    $active  = @($notes | Where-Object { $_.Folder -ne '04_Archive' })
    $stale   = @($active | Where-Object { Test-DateOlderThan (Get-FMValue $_ 'token_last_reviewed') $OlderThanDays })
    $orphans = @($active | Where-Object {
        $r = Get-FMValue $_ 'related'; $mo = Get-FMValue $_ 'moc'
        (-not ($r -is [System.Array]) -or $r.Count -eq 0) -and [string]::IsNullOrWhiteSpace([string]$mo)
    })
    $totalTokens = 0
    foreach ($a in $active) { $ct = Get-FMValue $a 'context_tokens'; if ($null -ne ($ct -as [int])) { $totalTokens += [int]$ct } }

    Write-Info "`n================  VAULT STATS  ================"
    Write-Host  ("  Notes total ........ {0}" -f $notes.Count)
    Write-Host  ("  Active ............. {0}" -f $active.Count)
    Write-Host  ("  Archived ........... {0}" -f ($notes.Count - $active.Count))
    Write-Host  ("  Total tokens ....... {0}" -f $totalTokens)
    Write-Host  ("  Stale token est. ... {0} (> {1}d)" -f $stale.Count, $OlderThanDays)
    Write-Host  ("  Orphans (no links) . {0}" -f $orphans.Count)

    Write-Info "`n  By folder:"
    $active | Group-Object Folder | Sort-Object Name | ForEach-Object { Write-Host ("    {0,-14} {1}" -f $_.Name, $_.Count) }
    Write-Info "`n  By status:"
    $active | Group-Object { Get-FMValue $_ 'status' } | Sort-Object Count -Descending | ForEach-Object { Write-Host ("    {0,-22} {1}" -f $_.Name, $_.Count) }
    Write-Info "`n  By domain:"
    $active | Group-Object { Get-FMValue $_ 'domain' } | Sort-Object Count -Descending | ForEach-Object { Write-Host ("    {0,-22} {1}" -f $_.Name, $_.Count) }
    Write-Info "`n  By document_type:"
    $active | Group-Object { Get-FMValue $_ 'document_type' } | Sort-Object Count -Descending | ForEach-Object { Write-Host ("    {0,-22} {1}" -f $_.Name, $_.Count) }
    Write-Info "`n  By sensitivity:"
    $active | Group-Object { Get-FMValue $_ 'sensitivity' } | Sort-Object Count -Descending | ForEach-Object { Write-Host ("    {0,-22} {1}" -f $_.Name, $_.Count) }
    Write-Host "==============================================`n"
}

# ============================================================================ #
#  ACTION: Touch  (telemetry: bump last_accessed + access_count)
# ============================================================================ #
function Invoke-Touch {
    if (-not $Path) { throw "Touch requires -Path <note.md>" }
    if ([System.IO.Path]::IsPathRooted($Path)) { $full = $Path } else { $full = Join-Path $VaultPath $Path }
    if (-not (Test-Path -LiteralPath $full)) { throw "Note not found: $full" }
    $raw = Get-Content -LiteralPath $full -Raw
    $count = 0
    if ($raw -match "(?m)^access_count:\s*(\d+)") { $count = [int]$matches[1] }
    Update-FrontMatterFields -FilePath $full -Preview:$DryRun -Updates @{
        last_accessed = (Get-Date -Format 'yyyy-MM-dd')
        access_count  = ($count + 1)
    } | Out-Null
    Write-Ok "Touched: $Path (access_count -> $($count + 1))"
}

# ============================================================================ #
#  ACTION: Reindex  (build a fast index of all front matter)
# ============================================================================ #
function Invoke-Reindex {
    $notes = @(Get-Notes -WithArchive -WithTemplates:$IncludeTemplates)
    $index = foreach ($n in $notes) {
        [pscustomobject]@{
            uid            = Get-FMValue $n 'uid'
            title          = Get-FMValue $n 'title'
            folder         = $n.Folder
            domain         = Get-FMValue $n 'domain'
            topic          = Get-FMValue $n 'topic'
            subtopic       = Get-FMValue $n 'subtopic'
            document_type  = Get-FMValue $n 'document_type'
            status         = Get-FMValue $n 'status'
            tags           = (Get-FMValue $n 'tags')     -join ';'
            ontology       = (Get-FMValue $n 'ontology') -join ';'
            context_tokens = Get-FMValue $n 'context_tokens'
            confidence     = Get-FMValue $n 'confidence_score'
            sensitivity    = Get-FMValue $n 'sensitivity'
            last_updated   = Get-FMValue $n 'last_updated'
            last_accessed  = Get-FMValue $n 'last_accessed'
            summary        = Get-FMValue $n 'summary'
            rel            = $n.Rel
        }
    }
    if (-not (Test-Path -LiteralPath $Script:MaintDir)) { New-Item -ItemType Directory -Path $Script:MaintDir -Force | Out-Null }
    $idxJson = Join-Path $Script:MaintDir 'index.json'
    $idxCsv  = Join-Path $Script:MaintDir 'index.csv'
    $index | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $idxJson -Encoding UTF8
    $index | Export-Csv -LiteralPath $idxCsv -NoTypeInformation -Encoding UTF8
    Write-Ok "Indexed $($index.Count) notes -> $idxJson"
    return $index
}

# ============================================================================ #
#  DISPATCH
# ============================================================================ #
# Single-instance write lock: only actions that MODIFY notes need it. Read-only
# actions (Search, Stats, Validate, Reindex) run freely and never block, since
# atomic writes guarantee they never see a half-written file. A -DryRun never
# writes, so it doesn't take the lock either.
$writeActions = @('RecalcTokens','Touch')
$needsLock = ($writeActions -contains $Action) -or
             ((@('Prune','Duplicates') -contains $Action) -and $Apply)
if ($DryRun) { $needsLock = $false }

$lockPath = $null
if ($needsLock) {
    if (-not (Test-Path -LiteralPath $Script:MaintDir)) {
        New-Item -ItemType Directory -Path $Script:MaintDir -Force | Out-Null
    }
    $lockPath = Join-Path $Script:MaintDir '.lock'
    if (-not (Enter-VaultLock -LockPath $lockPath)) {
        Write-Warn "Another maintenance write is already running (lock held at $lockPath)."
        Write-Warn "Exiting without changes to avoid a conflict. Retry once it finishes."
        $lockPath = $null   # we don't own it; don't release it in finally
        return
    }
}

try {
    # Functions render their own formatted tables via Out-Host and write reports
    # to .maintenance. Their return values are for dot-sourcing/pipeline use;
    # suppress them here so interactive console output is not duplicated.
    switch ($Action) {
        'Search'       { Invoke-Search       | Out-Null }
        'Duplicates'   { Invoke-Duplicates   | Out-Null }
        'RecalcTokens' { Invoke-RecalcTokens | Out-Null }
        'Prune'        { Invoke-Prune        | Out-Null }
        'Validate'     { Invoke-Validate     | Out-Null }
        'Stats'        { Invoke-Stats }
        'Touch'        { Invoke-Touch }
        'Reindex'      { Invoke-Reindex      | Out-Null }
    }
}
finally {
    if ($lockPath) { Exit-VaultLock -LockPath $lockPath }
}
