param(
    [string]$Out = "",          # 导出目录(默认: <脚本目录>\package-export\<时间戳>)
    [string]$Packages = "",     # 指定包(逗号 / 空格分隔);为空 = 不按包名筛选
    [string]$Scope = "",        # 只导出该 scope(如 @szewtwin)
    [string]$Config = "",       # 源 Verdaccio config(默认自动解析)
    [switch]$IncludeCache,      # 连依赖到的上游缓存包一起导出(依赖闭包)
    [switch]$AllCache,          # 导出 storage 里的全部缓存包(整镜像;包含 IncludeCache 的能力)
    [switch]$Zip,               # 额外打成单个 zip(便于拷贝 / 传输)
    [switch]$DryRun             # 仅预览,不实际导出
)

# 把本机 Verdaccio storage 中已发布的包(全部或指定部分)导出为一个
# 可离线拷贝的目录(或 zip),用于带到无法直连的内网,再由
# import-packages.ps1 导入内网的 npm Registry / Verdaccio 存储。
#
# 导出目录内容:
#   manifest.json            包清单(名称 / 版本 / dist-tags / 每个 tarball 的校验和)
#   packages/<name>/...      各包的 packument(package.json)与全部版本 *.tgz
#   import-packages.ps1      导入脚本(从本脚本同目录复制,目标机器可直接使用)
#   USAGE.txt                使用说明
#
# - 只读源存储:不修改 DB / secret,不需要停止 Verdaccio
# - 每个 tarball 复制时计算 sha1 / sha512 写入 manifest,导入时逐个校验,
#   防止 U 盘等介质拷贝出错

. "$PSScriptRoot\resolve-paths.ps1"

# ----------------------------------------
# 0. 参数校验 / 解析源路径
# ----------------------------------------

$config  = Resolve-VerdaccioConfig $Config
$storage = Resolve-VerdaccioStorage $config
$dbFile  = Join-Path $storage ".verdaccio-db.json"

Write-Host "========================================"
Write-Host " Export Packages (offline migration)"
Write-Host "========================================"
Write-Host "Source storage : $storage"
Write-Host ""
Write-Host "Source Verdaccio does NOT need to be stopped"
Write-Host "(this script only reads the storage)."
Write-Host ""

# ----------------------------------------
# 1. 读取 DB(本地发布名单)——与 clean-cache.ps1 同一判据
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

if ($localNames.Count -eq 0 -and -not $IncludeCache -and -not $AllCache) {
    Write-Host "ERROR: DB package list is empty (no local published packages)."
    Write-Host "Use -Packages to name packages explicitly."
    exit 1
}

# ----------------------------------------
# 2. 扫描 storage,确定导出名单
# ----------------------------------------

function Get-StoragePackageNames {
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
            Write-Host "      will be exported."
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
#   -AllCache     → 整个 storage 的缓存包全部带上(整镜像导出)
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
        Write-Host "      and cannot be exported (installs needing them will fail on target):"
        foreach ($x in $closure.Missing) { Write-Host "  $x" }
    }
    Write-Host ""
}

$plans = [System.Collections.Generic.List[object]]::new()
$missingPkgDirs = [System.Collections.Generic.List[string]]::new()

foreach ($name in $selected) {
    $pkgDir = Join-Path $storage ($name -replace "/", "\")
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

        foreach ($e in @($entries | Sort-Object Time, Ver)) {
            if ($e.Tarball) { $versions.Add($e) }
            else { $missingTarballs.Add($e.Ver) }
        }
    }

    $plans.Add([pscustomobject]@{
        Name            = $name
        Dir             = $pkgDir
        PackumentPath   = $packumentPath
        Time            = $timeMap
        Versions        = $versions
        MissingTarballs = $missingTarballs
        Tags            = $tags
    })
}

if ($missingPkgDirs.Count -gt 0) {
    Write-Host "WARN: $($missingPkgDirs.Count) selected package(s) have no packument"
    Write-Host "      on disk (use clean-db.ps1 to drop stale DB records):"
    foreach ($name in $missingPkgDirs) { Write-Host "  $name" }
    Write-Host ""
}

# ----------------------------------------
# 4. 导出计划预览
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

if (-not $Out) {
    $Out = Join-Path `
        (Join-Path $PSScriptRoot "package-export") `
        (Get-Date -Format "yyyyMMdd-HHmmss")
}

Write-Host "Packages to export      : $($plans.Count) / $($selected.Count)"
Write-Host "Versions to export      : $totalVersions"
Write-Host "Versions w/o tarball    : $missingTotal (skipped, e.g. cache metadata only)"
Write-Host "Total tarball size      : $totalMb MB"
Write-Host "Export to               : $Out"
if ($Zip) { Write-Host "Also create zip         : $Out.zip" }
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
    Write-Host "[DryRun] Nothing exported."
    exit 0
}

# ----------------------------------------
# 5. 导出:复制 tarball(边复制边算校验和)+ packument + manifest
# ----------------------------------------

if (Test-Path -LiteralPath $Out) {
    Write-Host "ERROR: output directory already exists:"
    Write-Host $Out
    Write-Host "Delete it or pass another -Out path."
    exit 1
}

New-Item -ItemType Directory -Path $Out -Force | Out-Null
$packagesRoot = Join-Path $Out "packages"
New-Item -ItemType Directory -Path $packagesRoot -Force | Out-Null

# 复制 + 流式计算 sha1 / sha512,单次读写,内存占用恒定
function Copy-WithHash {
    param([string]$Src, [string]$Dst)

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    $sha512 = [System.Security.Cryptography.SHA512]::Create()
    $buffer = New-Object byte[] 65536

    try {
        $in = [System.IO.File]::OpenRead($Src)
        try {
            $out = [System.IO.File]::Create($Dst)
            try {
                while (($n = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $out.Write($buffer, 0, $n)
                    [void]$sha1.TransformBlock($buffer, 0, $n, $buffer, 0)
                    [void]$sha512.TransformBlock($buffer, 0, $n, $buffer, 0)
                }
                $sha1.TransformFinalBlock($buffer, 0, 0)
                $sha512.TransformFinalBlock($buffer, 0, 0)
            }
            finally { $out.Close() }
        }
        finally { $in.Close() }

        # 注意:哈希值必须在 Dispose 之前取出,Dispose 后 .Hash 为 null
        return [pscustomobject]@{
            Shasum    = [BitConverter]::ToString($sha1.Hash).Replace("-", "").ToLower()
            Integrity = "sha512-" + [Convert]::ToBase64String($sha512.Hash)
        }
    }
    finally {
        $sha1.Dispose()
        $sha512.Dispose()
    }
}

$manifestPackages = [System.Collections.Generic.List[object]]::new()
$done = 0

foreach ($plan in $plans) {
    $done++
    Write-Host "[$done/$($plans.Count)] $($plan.Name)  ($($plan.Versions.Count) version(s))"

    $pkgOutDir = Join-Path $packagesRoot ($plan.Name -replace "/", "\")
    New-Item -ItemType Directory -Path $pkgOutDir -Force | Out-Null

    # packument 原文复制:导入端(-Storage 模式)合并版本 / 保留 time 用
    Copy-Item `
        -LiteralPath $plan.PackumentPath `
        -Destination (Join-Path $pkgOutDir "package.json") `
        -Force

    $verEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($v in $plan.Versions) {
        $fileName = Split-Path -Leaf $v.Tarball
        $dst = Join-Path $pkgOutDir $fileName
        $hash = Copy-WithHash $v.Tarball $dst

        $verEntries.Add([pscustomobject]@{
            version   = $v.Ver
            file      = ("packages/" + ($plan.Name -replace "\\", "/") + "/" + $fileName)
            size      = $v.Size
            shasum    = $hash.Shasum
            integrity = $hash.Integrity
        })
        Write-Host "  + $($plan.Name)@$($v.Ver)  ($([math]::Round($v.Size / 1MB, 2)) MB)"
    }

    $manifestPackages.Add([pscustomobject]@{
        name            = $plan.Name
        distTags        = $plan.Tags
        time            = $plan.Time
        missingTarballs = @($plan.MissingTarballs)
        versions        = @($verEntries)
    })
}

$manifest = [pscustomobject]@{
    format         = "verdaccio-export/1"
    created        = (Get-Date).ToUniversalTime().ToString("o")
    sourceConfig   = $config
    sourceStorage  = $storage
    packages       = @($manifestPackages)
}

$manifestPath = Join-Path $Out "manifest.json"
$json = $manifest | ConvertTo-Json -Depth 100

[System.IO.File]::WriteAllText(
    $manifestPath,
    $json,
    [System.Text.UTF8Encoding]::new($false))

Write-Host ""
Write-Host "manifest.json written."

# 导入脚本随包携带:内网机器解压后无需整个工具箱即可导入
$importScript = Join-Path $PSScriptRoot "import-packages.ps1"
if (Test-Path -LiteralPath $importScript) {
    Copy-Item -LiteralPath $importScript -Destination (Join-Path $Out "import-packages.ps1") -Force
    Write-Host "import-packages.ps1 bundled."
}
else {
    Write-Host "WARN: import-packages.ps1 not found next to this script,"
    Write-Host "      bundle does not include the import script."
}

# 使用说明
$usage = @"
Verdaccio 离线迁移包(由 export-packages.ps1 生成)
生成时间: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
内容    : $($plans.Count) 个包 / $totalVersions 个版本 / $totalMb MB

=== 导入方法(在内网机器上操作)===

解压 / 拷贝本目录后,在目录内执行以下任一方式。

【方式 A】发布到内网 npm Registry(通用,需要 npm):
  powershell -ExecutionPolicy Bypass -File .\import-packages.ps1 -Bundle . -Registry http://<内网服务器>:4873

  预览不实际导入:  在上面命令后加 -DryRun
  需要 token 时:   在上面命令后加 -Token <npm token>
                   (或先 npm login --registry <内网地址>)
  执行时输入确认词 IMPORT(与命令行二次确认一致)

【方式 B】直接复制进 Verdaccio 存储目录(无需 npm,保留原发布时间):
  1. 停止目标机器上的 Verdaccio
  2. 执行:
     powershell -ExecutionPolicy Bypass -File .\import-packages.ps1 -Bundle . -Storage <目标 storage 目录>

  说明:包会复制进 storage 并写入 .verdaccio-db.json 的列表
  (secret 原样保留,执行前自动备份 DB);目标上已存在的包按版本增量合并。

导入前可用 -DryRun 预览;每个 tarball 会按 manifest.json 中的校验和
逐一核对,拷贝损坏会被拦截。

【重要】完全离线的内网:私有包的外部依赖(如 flatbuffers、yargs 等
上游公共包)需要一并带过去。导出时加 -IncludeCache(或在工具箱界面
勾选「包含依赖到的缓存包」)会自动按依赖闭包把这些公共包连同它们的
依赖一起打进迁移包;否则内网 npm install 会因缺少依赖而失败。
"@

[System.IO.File]::WriteAllText(
    (Join-Path $Out "USAGE.txt"),
    $usage,
    [System.Text.UTF8Encoding]::new($true))

Write-Host "USAGE.txt written."

# ----------------------------------------
# 6. 打包 zip(可选)
# ----------------------------------------

if ($Zip) {
    Write-Host ""
    Write-Host "Creating zip..."
    $zipPath = "$Out.zip"
    try {
        Compress-Archive `
            -Path (Join-Path $Out "*") `
            -DestinationPath $zipPath `
            -ErrorAction Stop
        Write-Host "Zip created: $zipPath"
    }
    catch {
        Write-Host "WARN: zip failed ($($_.Exception.Message))."
        Write-Host "The folder itself is complete and usable."
    }
}

# ----------------------------------------
# 7. 汇总
# ----------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host " Export completed"
Write-Host "========================================"
Write-Host ""
Write-Host "Packages exported : $($plans.Count)"
Write-Host "Versions exported : $totalVersions"
Write-Host "Total size        : $totalMb MB"
if ($missingTotal -gt 0) {
    Write-Host "No local tarball  : $missingTotal (skipped)"
}
Write-Host "Export directory  : $Out"
if ($Zip) { Write-Host "Zip archive       : $Out.zip" }
Write-Host ""
Write-Host "Take the folder / zip to the intranet, then import with"
Write-Host "import-packages.ps1 (see USAGE.txt inside the export)."
