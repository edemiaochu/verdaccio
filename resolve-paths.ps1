# Shared config/storage resolver for all toolbox scripts.
# Dot-source it from a script located in the repo root:
#   . "$PSScriptRoot\resolve-paths.ps1"
#
# config.yaml resolution order:
#   1. explicit value passed by the caller / web console
#   2. active-config.txt - the config last used to START verdaccio from this toolbox
#   3. the -c argument of the RUNNING verdaccio process (what is actually serving)
#   4. default: %APPDATA%\verdaccio\config.yaml
#
# Storage is derived from the config: the `storage:` field of the yaml,
# resolved against the config directory (verdaccio default: ./storage).

$script:ActiveConfigStateFile = Join-Path $PSScriptRoot "active-config.txt"

function Resolve-VerdaccioConfig {
    param([string]$Requested)

    if ($Requested) {
        if (Test-Path $Requested) { return $Requested }
        Write-Host "WARN: requested config not found: $Requested"
    }

    if (Test-Path $script:ActiveConfigStateFile) {
        $saved = Get-Content $script:ActiveConfigStateFile -ErrorAction SilentlyContinue |
            Select-Object -First 1
        $saved = "$saved".Trim()
        if ($saved -and (Test-Path $saved)) { return $saved }
    }

    $procs = Get-CimInstance Win32_Process `
        -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        $cmd = "$($p.CommandLine)"
        if ($cmd -notmatch 'verdaccio') { continue }
        if ($cmd -match '(?:^|\s)-c\s+"([^"]+)"') { return $Matches[1] }
        if ($cmd -match "(?:^|\s)-c\s+'([^']+)'") { return $Matches[1] }
        if ($cmd -match '(?:^|\s)-c\s+([^\s"]+)')  { return $Matches[1] }
    }

    return (Join-Path $env:APPDATA "verdaccio\config.yaml")
}

function Resolve-VerdaccioStorage {
    param([string]$ConfigPath)

    $dir = Split-Path -Parent $ConfigPath
    $rel = "storage"

    if ($ConfigPath -and (Test-Path $ConfigPath)) {
        $text = Get-Content $ConfigPath -Raw -ErrorAction SilentlyContinue
        if ($text -match '(?m)^\s*storage\s*:\s*(.+?)\s*(?:#.*)?$') {
            $rel = $Matches[1].Trim().Trim('"').Trim("'")
        }
    }

    if ([System.IO.Path]::IsPathRooted($rel)) { return $rel }
    return [System.IO.Path]::GetFullPath((Join-Path $dir $rel))
}
