param(
    [Parameter(Mandatory = $true)]
    [string]$Bundle,           # 导出目录或 zip(export-packages.ps1 的产物)

    [string]$Registry = "",    # 模式A:逐版本发布到该 npm Registry(需要 npm)
    [string]$Storage = "",     # 模式B:直接复制进 Verdaccio storage(需要先停止目标)
    [string]$Token = "",       # 模式A 的认证 token(可选)
    [string]$Access = "",      # public / restricted(可选,发往 npmjs 等公共源的 scoped 包需要 public)
    [switch]$DryRun            # 仅预览,不实际导入
)

# 把 export-packages.ps1 导出的离线迁移包导入内网。本脚本自包含
# (不依赖工具箱其他文件),可随迁移包一起拷到内网机器单独运行。
#
# 两种导入模式(二选一):
#   -Registry <url>  逐版本 npm publish 到内网 npm Registry(通用,
#                    适用于 Verdaccio / Nexus / npmjs 等;目标上已存在的
#                    同名同版本自动跳过,可重复执行)
#   -Storage <path>  直接复制进一个 Verdaccio 的 storage 目录(无需 npm,
#                    原样保留发布时间;目标上已存在的包按版本增量合并;
#                    需要先停止目标 Verdaccio,执行前自动备份其 DB)
#
# 每个 tarball 会按 manifest.json 的 sha1 逐一校验,介质拷贝损坏会被拦截。
#
# stdin 协议(Web 控制台管道输入时):
#   第 1 行 = token(可空),第 2 行 = 确认词 IMPORT(仅非 DryRun 时读取)

# ----------------------------------------
# 0. 参数校验
# ----------------------------------------

$useRegistry = [bool]$Registry
$useStorage = [bool]$Storage

if ($useRegistry -eq $useStorage) {
    Write-Host "ERROR: specify exactly one target:"
    Write-Host "  -Registry <url>   publish to an npm registry (needs npm)"
    Write-Host "  -Storage <path>   copy into a Verdaccio storage directory"
    exit 1
}

if ($useRegistry -and $Registry -notmatch '^https?://[^\s''"]+$') {
    Write-Host "ERROR: target registry URL is invalid (must be http(s)://...):"
    Write-Host "  $Registry"
    exit 1
}
if ($useRegistry) { $Registry = $Registry.TrimEnd('/') }

if ($Access -and $Access -notin @("public", "restricted")) {
    Write-Host "ERROR: -Access must be 'public' or 'restricted': $Access"
    exit 1
}

if ($useStorage) {
    $Storage = $Storage.TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $Storage -PathType Container)) {
        Write-Host "ERROR: storage directory not found:"
        Write-Host "  $Storage"
        exit 1
    }
}

# ----------------------------------------
# 1. 打开迁移包:目录直接用,zip 解压到临时目录
# ----------------------------------------

Write-Host "========================================"
Write-Host " Import Packages (offline migration)"
Write-Host "========================================"
Write-Host "Bundle: $Bundle"

$tempDir = $null
$bundleDir = $null

if (Test-Path -LiteralPath $Bundle -PathType Container) {
    $bundleDir = (Resolve-Path -LiteralPath $Bundle).Path
}
elseif (Test-Path -LiteralPath $Bundle -PathType Leaf) {
    $tempDir = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ("verdaccio-import-" + [Guid]::NewGuid().ToString("N"))
    Write-Host "Expanding zip to temp..."
    try {
        Expand-Archive `
            -LiteralPath $Bundle `
            -DestinationPath $tempDir `
            -ErrorAction Stop
    }
    catch {
        Write-Host "ERROR: cannot expand zip:"
        Write-Host $_.Exception.Message
        exit 1
    }
    $bundleDir = $tempDir
}
else {
    Write-Host "ERROR: bundle not found (need an export directory or .zip):"
    Write-Host "  $Bundle"
    exit 1
}

$manifestPath = Join-Path $bundleDir "manifest.json"
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Host "ERROR: manifest.json not found in bundle:"
    Write-Host $bundleDir
    if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    exit 1
}

try {
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "ERROR: manifest.json is corrupted / not valid JSON."
    if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    exit 1
}

if ("$($manifest.format)" -notlike "verdaccio-export/*") {
    Write-Host "ERROR: unknown manifest format: $($manifest.format)"
    if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    exit 1
}

$bundlePackages = @($manifest.packages)

if ($bundlePackages.Count -eq 0) {
    Write-Host "ERROR: bundle contains no packages."
    if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    exit 1
}

Write-Host "Created: $($manifest.created)"
Write-Host "Packages in bundle: $($bundlePackages.Count)"
Write-Host ""

# 读取 token(stdin 第 1 行是 token 槽位,无论是否用参数提供都要对齐协议)
if ([Console]::IsInputRedirected) {
    $stdinToken = [Console]::In.ReadLine()
    if (-not $Token) { $Token = "$stdinToken" }
}
elseif (-not $Token) {
    $Token = Read-Host "Target auth token (leave blank to use npm login state)"
}
$Token = "$Token".Trim()

# ----------------------------------------
# 2. 校验每个 tarball(存在 + sha1)—— 防介质拷贝损坏
# ----------------------------------------

function Get-FileShasum([string]$Path) {
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $hash = $sha1.ComputeHash($bytes)
    }
    finally { $sha1.Dispose() }
    return [BitConverter]::ToString($hash).Replace("-", "").ToLower()
}

$plans = [System.Collections.Generic.List[object]]::new()
$corrupt = [System.Collections.Generic.List[string]]::new()
$missingFiles = [System.Collections.Generic.List[string]]::new()

foreach ($pkg in $bundlePackages) {
    $versions = [System.Collections.Generic.List[object]]::new()

    foreach ($v in @($pkg.versions)) {
        $fileRel = "$($v.file)"
        $fileAbs = Join-Path $bundleDir ($fileRel -replace "/", "\")

        if (-not (Test-Path -LiteralPath $fileAbs)) {
            $missingFiles.Add("$($pkg.name)@$($v.version)  ($fileRel)")
            continue
        }

        $shasum = Get-FileShasum $fileAbs
        if ("$($v.shasum)" -and $shasum -ne "$($v.shasum)") {
            $corrupt.Add("$($pkg.name)@$($v.version)  sha1 mismatch ($fileRel)")
            continue
        }

        $versions.Add([pscustomobject]@{
            Ver     = "$($v.version)"
            FileRel = $fileRel
            FileAbs = $fileAbs
            Size    = [long]$v.size
        })
    }

    $plans.Add([pscustomobject]@{
        Name     = "$($pkg.name)"
        Versions = $versions
        Tags     = $pkg.distTags
        # bundle 里的 packument 原文(-Storage 合并模式用)
        PackumentPath = Join-Path `
            (Join-Path $bundleDir ("packages\" + ("$($pkg.name)" -replace "/", "\"))) `
            "package.json"
        MissingTarballs = @($pkg.missingTarballs)
    })
}

if ($missingFiles.Count -gt 0) {
    Write-Host "ERROR: $($missingFiles.Count) tarball(s) listed in manifest are missing:"
    foreach ($x in $missingFiles) { Write-Host "  $x" }
    Write-Host "The bundle is incomplete. Re-export or re-copy it."
    if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    exit 1
}

if ($corrupt.Count -gt 0) {
    Write-Host "ERROR: $($corrupt.Count) tarball(s) FAILED checksum verification:"
    foreach ($x in $corrupt) { Write-Host "  $x" }
    Write-Host "The bundle was corrupted during copy / transfer. Re-export it."
    if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    exit 1
}

Write-Host "Checksum verification: all tarballs OK."

# ----------------------------------------
# 3. 导入计划预览
# ----------------------------------------

$totalVersions = 0
$totalBytes = [long]0
$missingTotal = 0

foreach ($plan in $plans) {
    $totalVersions += $plan.Versions.Count
    $missingTotal += $plan.MissingTarballs.Count
    foreach ($v in $plan.Versions) { $totalBytes += $v.Size }
}
$totalMb = [math]::Round($totalBytes / 1MB, 1)

if ($useRegistry) {
    Write-Host "Target registry     : $Registry"
}
else {
    Write-Host "Target storage      : $Storage"
    Write-Host "Target mode         : direct copy (Verdaccio storage)"
}

Write-Host "Packages to import  : $($plans.Count)"
Write-Host "Versions to import  : $totalVersions"
if ($missingTotal -gt 0) {
    Write-Host "Versions w/o tarball: $missingTotal (skipped, metadata not merged)"
}
Write-Host "Total tarball size  : $totalMb MB"
Write-Host ""

foreach ($plan in $plans) {
    $verList = @($plan.Versions | ForEach-Object { $_.Ver }) -join ", "
    if (-not $verList) { $verList = "(no tarball)" }
    Write-Host ("  {0}  [{1}]" -f $plan.Name, $verList)
}
Write-Host ""

if ($DryRun) {
    Write-Host "[DryRun] Nothing imported."
    if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    exit 0
}

# ----------------------------------------
# 4. 二次确认(两个模式共用)
# ----------------------------------------

Write-Host ""
if ([Console]::IsInputRedirected) {
    $answer = [Console]::In.ReadLine()
}
else {
    $answer = Read-Host 'Type "IMPORT" to confirm'
}

if ("$answer".Trim() -ne "IMPORT") {
    Write-Host "Cancelled."
    if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    exit 0
}

# ========================================================================
# 模式A:逐版本 npm publish 到目标 Registry
# ========================================================================

if ($useRegistry) {

    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: npm not found in PATH (required for -Registry mode)."
        Write-Host "Use -Storage mode instead if the target is a Verdaccio."
        if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
        exit 1
    }

    function Invoke-Npm {
        param(
            [string[]]$NpmArgs,
            [string]$UserConfig
        )

        $all = $NpmArgs
        if ($UserConfig) { $all += @("--userconfig", $UserConfig) }
        # --loglevel error:压掉 publish 时的 Tarball Contents 等 notice 噪音,只留错误
        $all += @("--loglevel", "error")

        # 空管道喂给 npm 的 stdin:即使 npm 想交互(如 2FA OTP)也只会得到 EOF,
        # 不会卡住等待 Web 控制台已关闭的输入。
        # ForEach-Object { "$_" }:stderr 走的是 ErrorRecord,转成纯文本
        $output = "" | & npm @all 2>&1 | ForEach-Object { "$_" } | Out-String

        return [pscustomobject]@{
            Code   = $LASTEXITCODE
            Output = "$output".Trim()
        }
    }

    # 认证:临时 npmrc(仅在 -Token 提供时生成,用完即删)
    $tempNpmrc = $null
    if ($Token) {
        $uri = [Uri]$Registry
        $regPath = $uri.AbsolutePath
        if (-not $regPath.EndsWith("/")) { $regPath += "/" }
        $authKey = "//" + $uri.Authority + $regPath + ":_authToken"

        $tempNpmrc = Join-Path `
            ([System.IO.Path]::GetTempPath()) `
            ("verdaccio-import-" + [Guid]::NewGuid().ToString("N") + ".npmrc")

        [System.IO.File]::WriteAllLines(
            $tempNpmrc,
            @("registry=$Registry", "$authKey=$Token"),
            [System.Text.UTF8Encoding]::new($false))

        Write-Host "Auth: using provided token (temp npmrc, deleted at exit)."
    }
    else {
        Write-Host "Auth: using npm login state for the target registry."
    }
    Write-Host ""

    # 预检:目标可达
    Write-Host "Checking target registry..."
    $ping = Invoke-Npm @("ping", "--registry", $Registry) $tempNpmrc
    if ($ping.Code -ne 0) {
        Write-Host "ERROR: target registry is not reachable:"
        Write-Host $Registry
        if ($ping.Output) { Write-Host $ping.Output }
        if ($tempNpmrc -and (Test-Path $tempNpmrc)) { Remove-Item -LiteralPath $tempNpmrc -Force -ErrorAction SilentlyContinue }
        if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
        exit 1
    }

    $whoami = Invoke-Npm @("whoami", "--registry", $Registry) $tempNpmrc
    if ($whoami.Code -eq 0 -and $whoami.Output) {
        Write-Host "Logged in as: $($whoami.Output)"
    }
    else {
        # 未登录不一定失败:不少 registry 允许匿名发布;
        # 真正需要认证时,第一个版本的发布会以 401 立即中止整个导入
        if ($whoami.Output -match 'E401|E403|401 Unauthorized|403 Forbidden|ENEEDAUTH') {
            Write-Host "WARN: not logged in to the target registry."
            Write-Host "If the target requires authentication, either run:"
            Write-Host "  npm login --registry $Registry"
            Write-Host "or pass a token:  -Token <npm token>"
        }
        else {
            Write-Host "WARN: npm whoami failed (registry may not support it), continuing..."
        }
    }

    function Test-AlreadyPublished([string]$output) {
        return $output -match 'EPUBLISHCONFLICT|E409|409 Conflict|previously published|cannot publish over|already (present|exists|published)'
    }

    $published = 0
    $skipped = 0
    $failed = 0
    $tagDone = 0
    $tagFailed = 0
    $failedList = [System.Collections.Generic.List[string]]::new()
    $okVersions = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)

    $pkgIndex = 0
    foreach ($plan in $plans) {
        $pkgIndex++
        Write-Host ""
        Write-Host "[$pkgIndex/$($plans.Count)] $($plan.Name)  ($($plan.Versions.Count) version(s))"

        foreach ($v in $plan.Versions) {
            $label = "$($plan.Name)@$($v.Ver)"

            $publishArgs = @("publish", $v.FileAbs, "--registry", $Registry, "--ignore-scripts")
            if ($Access) { $publishArgs += @("--access", $Access) }

            $result = Invoke-Npm $publishArgs $tempNpmrc

            if ($result.Code -eq 0) {
                Write-Host "  + $label"
                $published++
                [void]$okVersions.Add($v.Ver)
            }
            elseif (Test-AlreadyPublished $result.Output) {
                Write-Host "  = $label (already on target, skipped)"
                $skipped++
                [void]$okVersions.Add($v.Ver)
            }
            elseif ($result.Output -match 'E401|401 Unauthorized|ENEEDAUTH') {
                Write-Host "  ! $label AUTH FAILED - aborting import"
                if ($result.Output) { Write-Host $result.Output }
                if ($tempNpmrc -and (Test-Path $tempNpmrc)) { Remove-Item -LiteralPath $tempNpmrc -Force -ErrorAction SilentlyContinue }
                if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
                exit 1
            }
            else {
                Write-Host "  ! $label FAILED"
                if ($result.Output) { Write-Host $result.Output }
                $failed++
                $failedList.Add($label)
            }
        }

        # 按 manifest 的 dist-tags 补齐 tag(重跑幂等)
        foreach ($tag in @($plan.Tags.PSObject.Properties.Name | Sort-Object)) {
            $ver = "$($plan.Tags.PSObject.Properties[$tag].Value)"
            if (-not $okVersions.Contains($ver)) {
                Write-Host "  tag $tag -> $ver skipped (version not on target)"
                continue
            }

            $tagArgs = @("dist-tag", "add", "$($plan.Name)@$ver", $tag, "--registry", $Registry)
            $r = Invoke-Npm $tagArgs $tempNpmrc

            if ($r.Code -eq 0) {
                Write-Host "  tag $tag -> $ver"
                $tagDone++
            }
            else {
                Write-Host "  tag $tag -> $ver FAILED"
                if ($r.Output) { Write-Host $r.Output }
                $tagFailed++
            }
        }
    }

    if ($tempNpmrc -and (Test-Path $tempNpmrc)) {
        Remove-Item -LiteralPath $tempNpmrc -Force -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "========================================"
    Write-Host " Import completed"
    Write-Host "========================================"
    Write-Host ""
    Write-Host "Packages processed : $($plans.Count)"
    Write-Host "Versions published : $published"
    Write-Host "Already on target  : $skipped (skipped)"
    Write-Host "Versions failed    : $failed"
    Write-Host "Tags set           : $tagDone"
    Write-Host "Tags failed        : $tagFailed"

    if ($failedList.Count -gt 0) {
        Write-Host ""
        Write-Host "Failed versions:"
        foreach ($label in $failedList) { Write-Host "  $label" }
    }

    Write-Host ""
    Write-Host "Verify on the target with:"
    Write-Host "  npm view <package> --registry $Registry"

    if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }

    if ($failed -gt 0 -or $tagFailed -gt 0) { exit 1 }
    exit 0
}

# ========================================================================
# 模式B:直接复制进 Verdaccio storage(无需 npm,保留发布时间)
# ========================================================================

$dbFile = Join-Path $Storage ".verdaccio-db.json"

if (-not (Test-Path -LiteralPath $dbFile)) {
    Write-Host "ERROR: not a Verdaccio storage directory (.verdaccio-db.json missing):"
    Write-Host $Storage
    if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    exit 1
}

try {
    $db = Get-Content $dbFile -Raw | ConvertFrom-Json
}
catch {
    Write-Host "ERROR: target DB is corrupted / not valid JSON:"
    Write-Host $dbFile
    Write-Host "Nothing was imported."
    if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    exit 1
}

if ($null -eq $db -or [string]::IsNullOrWhiteSpace("$($db.secret)")) {
    Write-Host "ERROR: target DB is empty or the secret is missing."
    Write-Host "Nothing was imported."
    if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    exit 1
}

# 目标 Verdaccio 必须先停止:运行中写 storage 会损坏元数据
function Get-RunningVerdaccioStorages {
    $result = [System.Collections.Generic.List[string]]::new()
    $procs = Get-CimInstance Win32_Process `
        -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue

    foreach ($p in $procs) {
        $cmd = "$($p.CommandLine)"
        if ($cmd -notmatch 'verdaccio') { continue }

        $cfg = $null
        if ($cmd -match '(?:^|\s)-c\s+"([^"]+)"') { $cfg = $Matches[1] }
        elseif ($cmd -match "(?:^|\s)-c\s+'([^']+)'") { $cfg = $Matches[1] }
        elseif ($cmd -match '(?:^|\s)-c\s+([^\s"]+)') { $cfg = $Matches[1] }
        if (-not $cfg) { $cfg = Join-Path $env:APPDATA "verdaccio\config.yaml" }

        $rel = "storage"
        if (Test-Path -LiteralPath $cfg) {
            $text = Get-Content $cfg -Raw -ErrorAction SilentlyContinue
            if ($text -match '(?m)^\s*storage\s*:\s*(.+?)\s*(?:#.*)?$') {
                $rel = $Matches[1].Trim().Trim('"').Trim("'")
            }
            $dir = Split-Path -Parent $cfg
            if ([System.IO.Path]::IsPathRooted($rel)) {
                $result.Add([System.IO.Path]::GetFullPath($rel))
            }
            else {
                $result.Add([System.IO.Path]::GetFullPath((Join-Path $dir $rel)))
            }
        }
    }
    return $result
}

$targetStorageFull = [System.IO.Path]::GetFullPath($Storage)
foreach ($running in Get-RunningVerdaccioStorages) {
    if ([string]::Equals($running, $targetStorageFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "ERROR: a running Verdaccio is using this storage:"
        Write-Host $targetStorageFull
        Write-Host "Stop it first, then run the import again."
        if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
        exit 1
    }
}

# DB 备份(与本目录 .verdaccio-db-before-import-<时间戳>.json)
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupFile = Join-Path $Storage ".verdaccio-db-before-import-$timestamp.json"
Copy-Item $dbFile $backupFile

Write-Host "Target DB backup:"
Write-Host "  $backupFile"
Write-Host ""

# ----------------------------------------
# 复制 / 合并
# ----------------------------------------

function Copy-IntoStorage {
    param($Plan)

    $name = $Plan.Name
    $dstDir = Join-Path $Storage ($name -replace "/", "\")
    $bundlePkgDir = Join-Path $bundleDir ("packages\" + ($name -replace "/", "\"))

    if (-not (Test-Path -LiteralPath $dstDir)) {
        # 全新包:整个目录复制(packument + 全部 tarball)
        New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
        Copy-Item -Path (Join-Path $bundlePkgDir "*") -Destination $dstDir -Force
        Write-Host "  + $name  (copied, $($Plan.Versions.Count) version(s))"
        return "copied"
    }

    # 已存在:版本级增量合并(bundle 有而目标没有的版本)
    $tPkg = Join-Path $dstDir "package.json"
    if (-not (Test-Path -LiteralPath $tPkg) -or -not (Test-Path -LiteralPath $Plan.PackumentPath)) {
        Write-Host "  ! $name  FAILED (packument missing on one side)"
        return "failed"
    }

    try {
        $t = Get-Content $tPkg -Raw | ConvertFrom-Json
        $b = Get-Content $Plan.PackumentPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Host "  ! $name  FAILED (packument corrupted)"
        return "failed"
    }

    if (-not $t.PSObject.Properties["versions"] -or -not $t.versions) {
        $t | Add-Member -NotePropertyName "versions" -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    $added = 0
    foreach ($v in $Plan.Versions) {
        if ($t.versions.PSObject.Properties[$v.Ver]) { continue }

        $srcFile = Join-Path $bundleDir ($v.FileRel -replace "/", "\")
        Copy-Item -LiteralPath $srcFile -Destination (Join-Path $dstDir (Split-Path -Leaf $srcFile)) -Force

        $bVer = $b.versions.PSObject.Properties[$v.Ver].Value
        $t.versions | Add-Member -NotePropertyName $v.Ver -NotePropertyValue $bVer -Force
        $added++
    }

    if ($added -eq 0) {
        Write-Host "  = $name  (all versions already present, skipped)"
        return "skipped"
    }

    # dist-tags:指向的版本在合并后的集合里才生效
    if (-not $t.PSObject.Properties["dist-tags"] -or -not $t.'dist-tags') {
        $t | Add-Member -NotePropertyName "dist-tags" -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if ($b.PSObject.Properties["dist-tags"] -and $b.'dist-tags') {
        foreach ($p in $b.'dist-tags'.PSObject.Properties) {
            if ($t.versions.PSObject.Properties["$($p.Value)"]) {
                $t.'dist-tags' | Add-Member -NotePropertyName $p.Name -NotePropertyValue "$($p.Value)" -Force
            }
        }
    }

    # time:合并 bundle 的时间记录(保留原发布时间)
    if (-not $t.PSObject.Properties["time"] -or -not $t.time) {
        $t | Add-Member -NotePropertyName "time" -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if ($b.PSObject.Properties["time"] -and $b.time) {
        foreach ($p in $b.time.PSObject.Properties) {
            $t.time | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
        }
    }
    $t.time | Add-Member `
        -NotePropertyName "modified" `
        -NotePropertyValue (Get-Date).ToUniversalTime().ToString("o") `
        -Force

    $json = $t | ConvertTo-Json -Compress -Depth 100
    [System.IO.File]::WriteAllText(
        $tPkg,
        $json,
        [System.Text.UTF8Encoding]::new($false))

    Write-Host "  + $name  (merged, $added new version(s))"
    return "merged"
}

$copied = 0
$merged = 0
$mergeSkipped = 0
$mergeFailed = 0

$pkgIndex = 0
foreach ($plan in $plans) {
    $pkgIndex++
    Write-Host "[$pkgIndex/$($plans.Count)] $($plan.Name)"
    switch (Copy-IntoStorage $plan) {
        "copied" { $copied++ }
        "merged" { $merged++ }
        "skipped" { $mergeSkipped++ }
        default { $mergeFailed++ }
    }
}

# DB 列表合并(保留 secret):导入的包名加入 list
$secret = $db.secret
$existing = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal)
foreach ($name in @($db.list)) { [void]$existing.Add("$name") }

$addedNames = [System.Collections.Generic.List[string]]::new()
foreach ($plan in $plans) {
    if (-not $existing.Contains($plan.Name)) { $addedNames.Add($plan.Name) }
}

if ($addedNames.Count -gt 0) {
    $db.list = @($db.list) + @($addedNames)
}
$db.secret = $secret

$json = $db | ConvertTo-Json -Compress -Depth 100
[System.IO.File]::WriteAllText(
    $dbFile,
    $json,
    [System.Text.UTF8Encoding]::new($false))

Write-Host ""
Write-Host "========================================"
Write-Host " Import completed"
Write-Host "========================================"
Write-Host ""
Write-Host "Packages copied (new) : $copied"
Write-Host "Packages merged       : $merged (new versions added)"
Write-Host "Already complete      : $mergeSkipped (skipped)"
Write-Host "Failed                : $mergeFailed"
Write-Host "DB names added        : $($addedNames.Count)"
Write-Host "DB backup             : $backupFile"
Write-Host "DB secret preserved   : YES"
Write-Host ""
Write-Host "Start Verdaccio on the target machine to use the packages."
Write-Host "Note: tarball URLs are rewritten by Verdaccio when serving,"
Write-Host "so copied packages work regardless of the old source address."

if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }

if ($mergeFailed -gt 0) { exit 1 }
exit 0
