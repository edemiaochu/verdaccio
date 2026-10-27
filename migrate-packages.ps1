param(
    [Parameter(Mandatory = $true)]
    [string]$Registry,          # 目标 Registry(另一台 Verdaccio / Nexus / npmjs 等)

    [string]$Packages = "",     # 指定包(逗号 / 空格分隔);为空 = 不按包名筛选
    [string]$Scope = "",        # 只迁移该 scope(如 @szewtwin)
    [string]$Token = "",        # 目标 Registry 的认证 token(可选)
    [string]$Access = "",       # public / restricted(可选,发往 npmjs 等公共源的 scoped 包需要 public)
    [string]$Config = "",       # 源 Verdaccio config(默认自动解析)
    [switch]$IncludeCache,      # 连依赖到的上游缓存包一起迁移(依赖闭包)
    [switch]$AllCache,          # 迁移 storage 里的全部缓存包(整镜像;包含 IncludeCache 的能力)
    [switch]$DryRun             # 仅预览,不实际发布
)

# 把本机 Verdaccio storage 中已发布的包(全部或指定部分)迁移到另一个 npm Registry。
#
# 原理:storage 里每个包目录下有 packument(package.json)与全部版本的
# *.tgz;对每个版本执行 `npm publish <tarball> --registry <目标>`,
# 最后按源 packument 的 dist-tags 补齐 tag。
#
# - 源 Verdaccio 无需停止:只读 storage,不修改 DB / secret
# - 目标上已存在的同名同版本自动跳过 → 迁移可重复执行(断点续传)
# - 认证:-Token 直接提供 token,否则使用本机 npm 对目标的登录态
#   (先 npm login --registry <目标>);token 只写入临时 npmrc,不落盘到用户配置
# - 限制:版本的"更新时间"无法保留,目标上显示的是迁移时间
#
# stdin 协议(Web 控制台管道输入时):
#   第 1 行 = token(可空),第 2 行 = 确认词 MIGRATE(仅非 DryRun 时读取)

. "$PSScriptRoot\resolve-paths.ps1"

# ----------------------------------------
# 0. 参数校验 / 解析源路径
# ----------------------------------------

if ($Registry -notmatch '^https?://[^\s''"]+$') {
    Write-Host "ERROR: target registry URL is invalid (must be http(s)://...):"
    Write-Host "  $Registry"
    exit 1
}
$Registry = $Registry.TrimEnd('/')

if ($Access -and $Access -notin @("public", "restricted")) {
    Write-Host "ERROR: -Access must be 'public' or 'restricted': $Access"
    exit 1
}

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: npm not found in PATH."
    exit 1
}

$config  = Resolve-VerdaccioConfig $Config
$storage = Resolve-VerdaccioStorage $config
$dbFile  = Join-Path $storage ".verdaccio-db.json"

Write-Host "========================================"
Write-Host " Migrate Packages to Another Registry"
Write-Host "========================================"
Write-Host "Source storage : $storage"
Write-Host "Target registry: $Registry"
Write-Host ""
Write-Host "Source Verdaccio does NOT need to be stopped"
Write-Host "(this script only reads the storage)."
Write-Host ""

# ----------------------------------------
# 1. 读取 DB(本地发布名单)——与 clean-cache.ps1 同一判据:
#    .verdaccio-db.json 的 list 只记录本地 publish 过的包,
#    上游缓存包不会写入 list
# ----------------------------------------

if (-not (Test-Path $dbFile)) {
    Write-Host "ERROR: DB file not found:"
    Write-Host $dbFile
    exit 1
}

try {
    $db = Get-Content $dbFile -Raw | ConvertFrom-Json
}
catch {
    Write-Host "ERROR: DB file is corrupted / not valid JSON:"
    Write-Host $dbFile
    exit 1
}

$localNames = @($db.list)
$localSet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal)
foreach ($name in $localNames) {
    [void]$localSet.Add("$name")
}

if ($localNames.Count -eq 0) {
    Write-Host "NOTE: DB package list is empty (no local published packages)."
    if (-not $IncludeCache -and -not $AllCache) {
        Write-Host "Use -Packages to name packages explicitly."
    }
    Write-Host ""
}

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
# 2. 扫描 storage,确定迁移名单
# ----------------------------------------

function Get-StoragePackageNames {
    # 顶层普通目录 = 包名;@scope 目录下的子目录 = @scope/name
    $names = [System.Collections.Generic.List[string]]::new()
    $rootDirs = Get-ChildItem `
        -LiteralPath $storage `
        -Directory `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike ".*" }

    foreach ($dir in $rootDirs) {
        if ($dir.Name.StartsWith("@")) {
            foreach ($sub in Get-ChildItem `
                -LiteralPath $dir.FullName `
                -Directory `
                -ErrorAction SilentlyContinue) {
                $names.Add("$($dir.Name)/$($sub.Name)")
            }
        }
        else {
            $names.Add($dir.Name)
        }
    }
    return $names
}

$explicit = @()
if ($Packages) {
    $explicit = @($Packages -split '[,;\s]+' | Where-Object { $_ })
}

$selected = [System.Collections.Generic.List[string]]::new()

if ($explicit.Count -gt 0) {
    # 指定包:必须在 storage 中存在;允许指定缓存包(只迁本地有 tarball 的版本)
    $bad = $false
    foreach ($name in $explicit) {
        $dir = Join-Path $storage ($name -replace "/", "\")
        if (-not (Test-Path -LiteralPath $dir)) {
            Write-Host "ERROR: package not found in storage: $name"
            $bad = $true
            continue
        }
        if (-not $localSet.Contains($name)) {
            Write-Host "NOTE: $name is an upstream-cached package (not in the"
            Write-Host "      local DB list); only versions with local tarballs"
            Write-Host "      will be migrated."
        }
        if (-not $selected.Contains($name)) { $selected.Add($name) }
    }
    if ($bad) { exit 1 }
}
else {
    foreach ($name in $localNames) { $selected.Add($name) }
}

if ($Scope) {
    $scoped = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $selected) {
        if ($name.StartsWith($Scope + "/")) { $scoped.Add($name) }
    }
    $selected = $scoped
}

if ($selected.Count -eq 0) {
    Write-Host "ERROR: no packages matched the selection."
    Write-Host "Local published packages : $($localNames.Count)"
    Write-Host "Filters                  : Packages='$Packages' Scope='$Scope' IncludeCache=$IncludeCache AllCache=$AllCache"
    exit 1
}

# ----------------------------------------
# 3. 读取每个包的 packument,整理版本清单(计划)
# ----------------------------------------

function Resolve-TarballPath {
    param(
        [string]$PkgDir,
        [string]$Version,
        [string]$TarballUrl
    )

    # 磁盘上的 tarball 文件名 = URL 中 /-/ 之后一段去掉 @scope/ 前缀
    #   .../@szewtwin/core-common/-/@szewtwin/core-common-5.9.1.tgz
    #   → 磁盘 core-common-5.9.1.tgz
    $names = [System.Collections.Generic.List[string]]::new()
    if ($TarballUrl) {
        $file = ($TarballUrl -split '\?')[0].TrimEnd('/')
        $file = ($file -split '/-/')[-1]
        if ($file) {
            $names.Add($file)
            if ($file -match '^@[^/]+/(.+)$') { $names.Add($Matches[1]) }
        }
    }

    foreach ($n in $names) {
        $p = Join-Path $PkgDir $n
        if (Test-Path -LiteralPath $p) { return $p }
    }

    # 兜底:按版本号后缀匹配
    $hit = Get-ChildItem `
        -LiteralPath $PkgDir `
        -Filter "*.tgz" `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*-$Version.tgz" } |
        Select-Object -First 1

    if ($hit) { return $hit.FullName }
    return $null
}

# ----------------------------------------
# 3.5 缓存包处理:
#   -IncludeCache → 依赖闭包:选中包每个(有 tarball 的)版本的
#                   dependencies / peerDependencies / optionalDependencies,
#                   凡 storage 里有目录的都带上(按包名递归)。
#                   覆盖"内网装包缺公共依赖"的场景,体量只有全部缓存的零头
#   -AllCache     → 整个 storage 的缓存包全部带上(整镜像迁移)
# ----------------------------------------

function Add-DependencyClosure {
    param([System.Collections.Generic.List[string]]$Selected)

    $visited = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)
    foreach ($name in $Selected) { [void]$visited.Add($name) }

    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($name in $Selected) { $queue.Enqueue($name) }

    $added = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()

    while ($queue.Count -gt 0) {
        $name = $queue.Dequeue()
        $pkgDir = Join-Path $storage ($name -replace "/", "\")
        $packumentPath = Join-Path $pkgDir "package.json"
        if (-not (Test-Path -LiteralPath $packumentPath)) { continue }

        try { $m = Get-Content $packumentPath -Raw | ConvertFrom-Json }
        catch { continue }

        if (-not $m.PSObject.Properties["versions"]) { continue }

        foreach ($p in $m.versions.PSObject.Properties) {
            # 只看会被带走的版本:无本地 tarball 的版本目标端装不上,其依赖无需跟
            $tgz = Resolve-TarballPath $pkgDir $p.Name "$($p.Value.dist.tarball)"
            if (-not $tgz) { continue }

            foreach ($field in @("dependencies", "peerDependencies", "optionalDependencies")) {
                if (-not $p.Value.PSObject.Properties[$field]) { continue }
                foreach ($dep in $p.Value.PSObject.Properties[$field].Value.PSObject.Properties) {
                    $depName = $dep.Name
                    if (-not $visited.Add($depName)) { continue }

                    $depDir = Join-Path $storage ($depName -replace "/", "\")
                    if (Test-Path -LiteralPath $depDir) {
                        $Selected.Add($depName)
                        $added.Add($depName)
                        $queue.Enqueue($depName)
                    }
                    else {
                        $missing.Add("$depName@$($dep.Value) (needed by $name)")
                    }
                }
            }
        }
    }

    return [pscustomobject]@{ Added = $added; Missing = $missing }
}

if ($AllCache) {
    foreach ($name in Get-StoragePackageNames) {
        if (-not $localSet.Contains($name) -and -not $selected.Contains($name)) {
            $selected.Add($name)
        }
    }
    Write-Host "AllCache: every cached package in storage is included."
    Write-Host ""
}
elseif ($IncludeCache) {
    $closure = Add-DependencyClosure $selected
    Write-Host "Dependency closure (-IncludeCache): +$($closure.Added.Count) cached package(s)."
    if ($closure.Missing.Count -gt 0) {
        Write-Host "WARN: $($closure.Missing.Count) dependency(ies) are NOT in storage"
        Write-Host "      and cannot be migrated (installs needing them will fail on target):"
        foreach ($x in $closure.Missing) { Write-Host "  $x" }
    }
    Write-Host ""
}

$plans = [System.Collections.Generic.List[object]]::new()
$missingPkgDirs = [System.Collections.Generic.List[string]]::new()

foreach ($name in $selected) {
    $pkgDir = Join-Path $storage ($name -replace "/", "\")
    if (-not (Test-Path -LiteralPath $pkgDir)) {
        $missingPkgDirs.Add($name)
        continue
    }

    $packumentPath = Join-Path $pkgDir "package.json"
    if (-not (Test-Path -LiteralPath $packumentPath)) {
        $missingPkgDirs.Add($name)
        continue
    }

    try {
        $m = Get-Content $packumentPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Host "WARN: packument corrupted, skipping: $name"
        continue
    }

    $timeMap = $null
    if ($m.PSObject.Properties["time"]) { $timeMap = $m.PSObject.Properties["time"].Value }

    $tags = @{}
    if ($m.PSObject.Properties["dist-tags"]) {
        foreach ($p in $m.PSObject.Properties["dist-tags"].Value.PSObject.Properties) {
            $tags[$p.Name] = "$($p.Value)"
        }
    }

    $verProps = $null
    if ($m.PSObject.Properties["versions"]) { $verProps = $m.PSObject.Properties["versions"].Value }

    $versions = [System.Collections.Generic.List[object]]::new()
    $missingTarballs = [System.Collections.Generic.List[string]]::new()

    if ($verProps) {
        $entries = foreach ($p in $verProps.PSObject.Properties) {
            $ver = $p.Name
            $tgz = Resolve-TarballPath $pkgDir $ver "$($p.Value.dist.tarball)"
            $size = [long]0
            if ($tgz) { $size = (Get-Item -LiteralPath $tgz).Length }

            $ts = [DateTime]::MinValue
            if ($timeMap) {
                $tProp = $timeMap.PSObject.Properties[$ver]
                if ($tProp -and $tProp.Value) {
                    try {
                        $ts = [DateTime]::Parse(
                            "$($tProp.Value)",
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind)
                    }
                    catch { }
                }
            }

            [pscustomobject]@{
                Ver     = $ver
                Tarball = $tgz
                Size    = $size
                Time    = $ts
            }
        }

        # 发布时间在前(目标上 latest 顺序才正常);无时间记录的排在最后
        foreach ($e in @($entries | Sort-Object Time, Ver)) {
            if ($e.Tarball) { $versions.Add($e) }
            else { $missingTarballs.Add($e.Ver) }
        }
    }

    $plans.Add([pscustomobject]@{
        Name            = $name
        Dir             = $pkgDir
        Versions        = $versions
        MissingTarballs = $missingTarballs
        Tags            = $tags
    })
}

if ($missingPkgDirs.Count -gt 0) {
    Write-Host "WARN: $($missingPkgDirs.Count) selected package(s) have no folder /"
    Write-Host "      packument on disk (use clean-db.ps1 to drop stale DB records):"
    foreach ($name in $missingPkgDirs) { Write-Host "  $name" }
    Write-Host ""
}

# ----------------------------------------
# 4. 迁移计划预览
# ----------------------------------------

$totalVersions = 0
$missingTotal = 0
$totalBytes = [long]0

foreach ($plan in $plans) {
    $totalVersions += $plan.Versions.Count
    $missingTotal += $plan.MissingTarballs.Count
    foreach ($v in $plan.Versions) { $totalBytes += $v.Size }
}
$totalMb = [math]::Round($totalBytes / 1MB, 1)

Write-Host "Packages selected       : $($plans.Count) / $($selected.Count) (skipped $($missingPkgDirs.Count))"
Write-Host "Versions to publish     : $totalVersions"
Write-Host "Versions w/o tarball    : $missingTotal (skipped, e.g. cache metadata only)"
Write-Host "Total tarball size      : $totalMb MB"
Write-Host ""

foreach ($plan in $plans) {
    $verList = @($plan.Versions | ForEach-Object { $_.Ver }) -join ", "
    if (-not $verList) { $verList = "(no local tarball)" }
    Write-Host ("  {0}  [{1}]" -f $plan.Name, $verList)
    if ($plan.MissingTarballs.Count -gt 0) {
        # 缓存包可能有几百个纯元数据版本,只展示前几个避免刷屏
        $missShow = @($plan.MissingTarballs | Select-Object -First 5) -join ", "
        if ($plan.MissingTarballs.Count -gt 5) {
            $missShow += ", ... (共 $($plan.MissingTarballs.Count) 个)"
        }
        Write-Host "      no local tarball: $missShow"
    }
}
Write-Host ""

if ($DryRun) {
    Write-Host "[DryRun] Nothing published."
    exit 0
}

# ----------------------------------------
# 5. 认证准备:临时 npmrc(仅在 -Token 提供时生成,用完即删)
# ----------------------------------------

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
    # ForEach-Object { "$_" }:stderr 走的是 ErrorRecord,转成纯文本,
    # 去掉 PowerShell 的 NativeCommandError 包装噪音
    $output = "" | & npm @all 2>&1 | ForEach-Object { "$_" } | Out-String

    return [pscustomobject]@{
        Code   = $LASTEXITCODE
        Output = "$output".Trim()
    }
}

$tempNpmrc = $null

if ($Token) {
    $uri = [Uri]$Registry
    $regPath = $uri.AbsolutePath
    if (-not $regPath.EndsWith("/")) { $regPath += "/" }
    # npm 的 registry 认证键: //<host><path>/:_authToken
    $authKey = "//" + $uri.Authority + $regPath + ":_authToken"

    $tempNpmrc = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ("verdaccio-migrate-" + [Guid]::NewGuid().ToString("N") + ".npmrc")

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

# ----------------------------------------
# 6. 预检:目标可达 + 已认证
# ----------------------------------------

Write-Host "Checking target registry..."

$ping = Invoke-Npm @("ping", "--registry", $Registry) $tempNpmrc
if ($ping.Code -ne 0) {
    Write-Host "ERROR: target registry is not reachable:"
    Write-Host $Registry
    if ($ping.Output) { Write-Host $ping.Output }
    exit 1
}

$whoami = Invoke-Npm @("whoami", "--registry", $Registry) $tempNpmrc
if ($whoami.Code -eq 0 -and $whoami.Output) {
    Write-Host "Logged in as: $($whoami.Output)"
}
else {
    # 未登录不一定失败:不少 registry(含 Verdaccio 默认配置)允许匿名发布。
    # 真正需要认证时,第一个版本的发布会以 401 立即中止整个迁移。
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

# ----------------------------------------
# 7. 二次确认
# ----------------------------------------

Write-Host ""
if ([Console]::IsInputRedirected) {
    $answer = [Console]::In.ReadLine()
}
else {
    $answer = Read-Host 'Type "MIGRATE" to confirm'
}

if ("$answer".Trim() -ne "MIGRATE") {
    Write-Host "Cancelled."
    exit 0
}

# ----------------------------------------
# 8. 逐版本发布到目标 Registry
# ----------------------------------------

function Test-AlreadyPublished([string]$output) {
    # 目标上已有该版本时各 registry 的报错措辞
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

        $publishArgs = @("publish", $v.Tarball, "--registry", $Registry, "--ignore-scripts")
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
            Write-Host "  ! $label AUTH FAILED - aborting migration"
            if ($result.Output) { Write-Host $result.Output }
            exit 1
        }
        else {
            Write-Host "  ! $label FAILED"
            if ($result.Output) { Write-Host $result.Output }
            $failed++
            $failedList.Add($label)
        }
    }

    # 按源 packument 的 dist-tags 补齐 tag(重跑时也是幂等的)
    foreach ($tag in @($plan.Tags.Keys | Sort-Object)) {
        $ver = $plan.Tags[$tag]
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

# ----------------------------------------
# 9. 汇总
# ----------------------------------------

if ($tempNpmrc -and (Test-Path $tempNpmrc)) {
    Remove-Item -LiteralPath $tempNpmrc -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "========================================"
Write-Host " Migration completed"
Write-Host "========================================"
Write-Host ""
Write-Host "Packages processed : $($plans.Count)"
Write-Host "Versions published : $published"
Write-Host "Already on target  : $skipped (skipped)"
Write-Host "Versions failed    : $failed"
Write-Host "Tags set           : $tagDone"
Write-Host "Tags failed        : $tagFailed"

if ($missingTotal -gt 0) {
    Write-Host "No local tarball   : $missingTotal (skipped)"
}

if ($failedList.Count -gt 0) {
    Write-Host ""
    Write-Host "Failed versions:"
    foreach ($label in $failedList) { Write-Host "  $label" }
}

Write-Host ""
Write-Host "Verify on the target with:"
Write-Host "  npm view <package> --registry $Registry"

if ($failed -gt 0 -or $tagFailed -gt 0) {
    exit 1
}
