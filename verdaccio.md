可以。你这个 Windows + NVM + Verdaccio 环境，建议统一成一套 **PowerShell `.ps1` 脚本**，把启动、停止、检查、DB 清理、备份、日志查看都固定下来。

下面假设你的 Verdaccio 配置和数据目录都是：

```
C:\Users\lenovo\.config\verdaccio\
├── config.yaml
├── htpasswd
└── storage\
    ├── .verdaccio-db.json
    ├── @szewec\
    └── @szewtwin\
```

另外你当前 Verdaccio 命令是：

```
C:\nvm4w\nodejs\verdaccio.cmd
```

------

# 一、最常用的几个命令

## 1. 启动 Verdaccio

```
verdaccio -c "C:\Users\lenovo\.config\verdaccio\config.yaml"
```

默认一般监听：

```
http://localhost:4873
```

------

## 2. 停止 Verdaccio

如果 Verdaccio 就在当前 PowerShell 窗口运行：

```
Ctrl + C
```

这是最推荐的停止方式。

如果 Verdaccio 在后台运行，可以：

```
Get-Process node
```

找到对应进程后：

```
Stop-Process -Id <PID>
```

例如：

```
Stop-Process -Id 12345
```

如果你确定机器上没有其他重要 Node 进程，也可以：

```
taskkill /F /IM node.exe
```

⚠️ 这个会杀掉**所有 Node.js 进程**，所以不建议作为日常停止方式。

------

# 二、建议建立一个 Verdaccio 工作目录

例如：

```
D:\verdaccio\
```

里面放：

```
D:\verdaccio\
├── start.ps1
├── stop.ps1
├── status.ps1
├── backup-db.ps1
├── clean-db.ps1
└── check-db.ps1
```

以后基本就是：

```
.\start.ps1
.\stop.ps1
.\status.ps1
```

------

# 三、启动脚本 `start.ps1`

创建：

```
D:\verdaccio\start.ps1
```

内容：

```
$config = "C:\Users\lenovo\.config\verdaccio\config.yaml"

Write-Host "========================================"
Write-Host " Starting Verdaccio"
Write-Host "========================================"
Write-Host "Config:"
Write-Host $config
Write-Host ""

if (-not (Test-Path $config)) {
    Write-Host "ERROR: config.yaml not found!"
    exit 1
}

Write-Host "Starting..."
Write-Host ""

verdaccio -c $config
```

运行：

```
cd D:\verdaccio
.\start.ps1
```

------

# 四、后台启动脚本 `start-background.ps1`

如果你不想一直占着 PowerShell 窗口：

```
D:\verdaccio\start-background.ps1
```

内容：

```
$config = "C:\Users\lenovo\.config\verdaccio\config.yaml"
$logDir = "D:\verdaccio\logs"

if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$stdout = "$logDir\verdaccio-$timestamp.log"
$stderr = "$logDir\verdaccio-$timestamp-error.log"

Write-Host "Starting Verdaccio in background..."
Write-Host "Config: $config"
Write-Host "Log:    $stdout"

Start-Process `
    -FilePath "verdaccio.cmd" `
    -ArgumentList "-c `"$config`"" `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr `
    -WindowStyle Hidden

Write-Host ""
Write-Host "Verdaccio started."
```

运行：

```
.\start-background.ps1
```

------

# 五、检查 Verdaccio 状态

创建：

```
D:\verdaccio\status.ps1
```

内容：

```
Write-Host "========================================"
Write-Host " Verdaccio Status"
Write-Host "========================================"

$processes = Get-Process node -ErrorAction SilentlyContinue

if ($null -eq $processes) {
    Write-Host "No Node.js process found."
}
else {
    Write-Host "Node.js processes:"
    $processes | Select-Object Id, ProcessName, StartTime
}

Write-Host ""
Write-Host "Checking http://localhost:4873 ..."

try {
    $response = Invoke-WebRequest `
        -Uri "http://localhost:4873/-/ping" `
        -UseBasicParsing `
        -TimeoutSec 3

    Write-Host "Verdaccio is ONLINE"
    Write-Host "HTTP Status: $($response.StatusCode)"
}
catch {
    Write-Host "Verdaccio is OFFLINE"
}
```

运行：

```
.\status.ps1
```

如果正常：

```
Verdaccio is ONLINE
HTTP Status: 200
```

------

# 六、停止 Verdaccio

这里有个问题：

**Windows 上可能同时有多个 Node.js 服务。**

所以不建议直接：

```
taskkill /F /IM node.exe
```

可以先找到监听 `4873` 的进程。

创建：

```
D:\verdaccio\stop.ps1
Write-Host "========================================"
Write-Host " Stopping Verdaccio"
Write-Host "========================================"

$connections = Get-NetTCPConnection `
    -LocalPort 4873 `
    -State Listen `
    -ErrorAction SilentlyContinue

if ($null -eq $connections) {
    Write-Host "Verdaccio is not running on port 4873."
    exit 0
}

foreach ($connection in $connections) {

    $pid = $connection.OwningProcess

    Write-Host "Found process:"
    Write-Host "PID: $pid"

    $process = Get-Process -Id $pid -ErrorAction SilentlyContinue

    if ($null -ne $process) {
        Write-Host "Process: $($process.ProcessName)"
        Write-Host "Stopping..."

        Stop-Process -Id $pid -Force

        Write-Host "Stopped."
    }
}

Write-Host ""
Write-Host "Verdaccio stopped."
```

运行：

```
.\stop.ps1
```

------

# 七、备份 Verdaccio DB

这个对你现在的情况非常重要。

创建：

```
D:\verdaccio\backup-db.ps1
$storage = "C:\Users\lenovo\.config\verdaccio\storage"
$dbFile = Join-Path $storage ".verdaccio-db.json"

$backupDir = "D:\verdaccio\db-backups"

if (-not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
}

if (-not (Test-Path $dbFile)) {
    Write-Host "ERROR: DB file not found:"
    Write-Host $dbFile
    exit 1
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$backupFile = Join-Path `
    $backupDir `
    ".verdaccio-db-$timestamp.json"

Copy-Item $dbFile $backupFile

Write-Host "DB backup completed."
Write-Host ""
Write-Host "Original:"
Write-Host $dbFile
Write-Host ""
Write-Host "Backup:"
Write-Host $backupFile
```

运行：

```
.\backup-db.ps1
```

例如：

```
D:\verdaccio\db-backups\
└── .verdaccio-db-20260920-163500.json
```

------

# 八、检查 DB 中哪些 package 已经不存在

这个就是你现在最需要的。

创建：

```
D:\verdaccio\check-db.ps1
$storage = "C:\Users\lenovo\.config\verdaccio\storage"
$dbFile = Join-Path $storage ".verdaccio-db.json"

if (-not (Test-Path $dbFile)) {
    Write-Host "ERROR: DB not found:"
    Write-Host $dbFile
    exit 1
}

$db = Get-Content $dbFile -Raw | ConvertFrom-Json

$missing = @()
$existing = @()

foreach ($package in $db.list) {

    $packagePath = Join-Path `
        $storage `
        ($package -replace "/", "\")

    $packageJson = Join-Path `
        $packagePath `
        "package.json"

    if (Test-Path $packageJson) {
        $existing += $package
    }
    else {
        $missing += $package
    }
}

Write-Host "========================================"
Write-Host " Verdaccio DB Check"
Write-Host "========================================"

Write-Host ""
Write-Host "Total packages : $($db.list.Count)"
Write-Host "Existing       : $($existing.Count)"
Write-Host "Missing        : $($missing.Count)"

Write-Host ""
Write-Host "========== MISSING PACKAGES =========="

$missing | ForEach-Object {
    Write-Host "REMOVE: $_"
}

Write-Host ""
Write-Host "========================================"
```

运行：

```
.\check-db.ps1
```

你应该会看到：

```
Total packages : 220
Existing       : 90
Missing        : 130

========== MISSING PACKAGES ==========

REMOVE: @iproject/core-backend
REMOVE: @iproject/core-frontend
REMOVE: @iproject/appui-react
REMOVE: @szew/bis-core-schema
REMOVE: @szew/units-schema
...
```

而：

```
@szewec/bis-core-schema
@szewec/units-schema
@szewtwin/core-backend
@szewtwin/core-frontend
```

如果实际存在，就不会出现在 `REMOVE` 中。

------

# 九、自动清理 DB

最后才是这个。

创建：

```
D:\verdaccio\clean-db.ps1
$storage = "C:\Users\lenovo\.config\verdaccio\storage"
$dbFile = Join-Path $storage ".verdaccio-db.json"

$backupDir = "D:\verdaccio\db-backups"

Write-Host "========================================"
Write-Host " Verdaccio DB Cleanup"
Write-Host "========================================"

# ----------------------------------------
# 1. 检查 DB
# ----------------------------------------

if (-not (Test-Path $dbFile)) {
    Write-Host "ERROR: DB file not found:"
    Write-Host $dbFile
    exit 1
}

# ----------------------------------------
# 2. 检查 Verdaccio 是否仍在运行
# ----------------------------------------

$connections = Get-NetTCPConnection `
    -LocalPort 4873 `
    -State Listen `
    -ErrorAction SilentlyContinue

if ($null -ne $connections) {

    Write-Host ""
    Write-Host "ERROR: Verdaccio is still running."
    Write-Host "Please stop Verdaccio first."
    Write-Host ""
    Write-Host "Use:"
    Write-Host "    .\stop.ps1"

    exit 1
}

# ----------------------------------------
# 3. 创建 backup
# ----------------------------------------

if (-not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$backupFile = Join-Path `
    $backupDir `
    ".verdaccio-db-before-clean-$timestamp.json"

Copy-Item $dbFile $backupFile

Write-Host ""
Write-Host "Backup created:"
Write-Host $backupFile

# ----------------------------------------
# 4. 读取 DB
# ----------------------------------------

$db = Get-Content $dbFile -Raw | ConvertFrom-Json

$originalCount = $db.list.Count

# ----------------------------------------
# 5. 保留 secret
# ----------------------------------------

$secret = $db.secret

# ----------------------------------------
# 6. 检查 package
# ----------------------------------------

$removed = @()
$kept = @()

foreach ($package in $db.list) {

    $packagePath = Join-Path `
        $storage `
        ($package -replace "/", "\")

    $packageJson = Join-Path `
        $packagePath `
        "package.json"

    if (Test-Path $packageJson) {

        $kept += $package

    }
    else {

        $removed += $package
    }
}

# ----------------------------------------
# 7. 显示清理结果
# ----------------------------------------

Write-Host ""
Write-Host "Original packages : $originalCount"
Write-Host "Keep packages     : $($kept.Count)"
Write-Host "Remove packages   : $($removed.Count)"

Write-Host ""
Write-Host "========== REMOVE =========="

foreach ($package in $removed) {
    Write-Host $package
}

# ----------------------------------------
# 8. 修改 DB
# ----------------------------------------

$db.list = @($kept)

# 确保 secret 原样保存
$db.secret = $secret

# ----------------------------------------
# 9. 写回
# ----------------------------------------

$json = $db | ConvertTo-Json -Compress

[System.IO.File]::WriteAllText(
    $dbFile,
    $json,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host ""
Write-Host "========================================"
Write-Host " Cleanup completed."
Write-Host "========================================"

Write-Host ""
Write-Host "DB:"
Write-Host $dbFile

Write-Host ""
Write-Host "Secret preserved:"
Write-Host $db.secret

Write-Host ""
Write-Host "Backup:"
Write-Host $backupFile
```

运行：

```
.\clean-db.ps1
```

------

# 十、清理之后验证

先检查 DB：

```
.\check-db.ps1
```

理论上应该：

```
Total packages : 90
Existing       : 90
Missing        : 0
```

然后启动：

```
.\start.ps1
```

------

# 十一、测试 Verdaccio

另外建议做一个 `test.ps1`：

```
Write-Host "Testing Verdaccio..."
Write-Host ""

npm --registry http://localhost:4873 ping

Write-Host ""
Write-Host "Testing @szewec/bis-core-schema..."

npm --registry http://localhost:4873 view @szewec/bis-core-schema

Write-Host ""
Write-Host "Testing @szewtwin/core-backend..."

npm --registry http://localhost:4873 view @szewtwin/core-backend
```

运行：

```
.\test.ps1
```

------

# 十二、最终你平时就记这几个

以后基本不用记一堆命令了：

```
D:\verdaccio\
│
├── start.ps1             ← 前台启动
├── start-background.ps1  ← 后台启动
├── stop.ps1              ← 停止
├── status.ps1            ← 查看状态
├── test.ps1              ← 测试 registry
├── backup-db.ps1         ← 备份 DB
├── check-db.ps1          ← 检查 DB
└── clean-db.ps1          ← 清理 DB
```

### 日常使用

```
# 启动
.\start.ps1

# 查看
.\status.ps1

# 测试
.\test.ps1

# 停止
.\stop.ps1
```

### DB 出问题时

```
# 1. 停止
.\stop.ps1

# 2. 检查
.\check-db.ps1

# 3. 备份 + 清理
.\clean-db.ps1

# 4. 再启动
.\start.ps1

# 5. 测试
.\test.ps1
```

**这里最关键的一点是 `clean-db.ps1` 不会删除 package storage，也不会删除 `secret`，它只修改 `.verdaccio-db.json` 的 `list`。** 这正适合你现在 `@iproject` / `@szew` 已经从 storage 删除、但 DB 仍然残留的情况。Verdaccio 的 local storage 确实维护独立的 package list，因此单纯删除目录不会自动等价于从这个索引中删除。

下面是新增的两个核心脚本。

### `remove-package.ps1`

```
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$PackageName
)

$storage = "C:\Users\lenovo\.config\verdaccio\storage"
$dbFile = Join-Path $storage ".verdaccio-db.json"
$backupDir = Join-Path $PSScriptRoot "db-backups"

Write-Host "========================================"
Write-Host " Remove Verdaccio Package"
Write-Host "========================================"
Write-Host "Package: $PackageName"
Write-Host ""

if (-not (Test-Path $dbFile)) {
    Write-Host "ERROR: DB file not found:"
    Write-Host $dbFile
    exit 1
}

# Verdaccio 必须先停止
$connections = Get-NetTCPConnection `
    -LocalPort 4873 `
    -State Listen `
    -ErrorAction SilentlyContinue

if ($null -ne $connections) {
    Write-Host "ERROR: Verdaccio is still running."
    Write-Host "Please run .\stop.ps1 first."
    exit 1
}

$db = Get-Content $dbFile -Raw | ConvertFrom-Json

# 保存 secret
$secret = $db.secret

# package name -> storage path
$packagePath = Join-Path `
    $storage `
    ($PackageName -replace "/", "\")

$existsInDb = @($db.list) -contains $PackageName
$existsOnDisk = Test-Path $packagePath

Write-Host "In DB   : $existsInDb"
Write-Host "On disk : $existsOnDisk"
Write-Host "Path    : $packagePath"
Write-Host ""

if (-not $existsInDb -and -not $existsOnDisk) {
    Write-Host "Package does not exist in DB or storage."
    exit 0
}

# 创建 backup
if (-not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$backupFile = Join-Path `
    $backupDir `
    ".verdaccio-db-before-remove-$timestamp.json"

Copy-Item $dbFile $backupFile

Write-Host "DB backup:"
Write-Host $backupFile
Write-Host ""

# 二次确认
$answer = Read-Host "Type DELETE to confirm"

if ($answer -ne "DELETE") {
    Write-Host "Cancelled."
    exit 0
}

# 删除 storage
if (Test-Path $packagePath) {
    Remove-Item `
        -LiteralPath $packagePath `
        -Recurse `
        -Force

    Write-Host "Storage directory deleted."
}

# 删除 DB 中的 package
$kept = @(
    $db.list | Where-Object {
        $_ -ne $PackageName
    }
)

$db.list = $kept

# 明确保留 secret
$db.secret = $secret

# 写回 DB
$json = $db | ConvertTo-Json -Compress

[System.IO.File]::WriteAllText(
    $dbFile,
    $json,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host ""
Write-Host "========================================"
Write-Host " Package removed"
Write-Host "========================================"
Write-Host "Package: $PackageName"
Write-Host "DB updated."
Write-Host "Secret preserved: YES"
Write-Host "Backup: $backupFile"
```

使用：

```
.\remove-package.ps1 "@szewec/bis-core-schema"
```

或者：

```
.\remove-package.ps1 "@szewtwin/core-backend"
```

------

### `remove-all-packages.ps1`

```
$storage = "C:\Users\lenovo\.config\verdaccio\storage"
$dbFile = Join-Path $storage ".verdaccio-db.json"
$backupDir = Join-Path $PSScriptRoot "db-backups"

Write-Host "========================================"
Write-Host " REMOVE ALL VERDACCIO PACKAGES"
Write-Host "========================================"
Write-Host ""

if (-not (Test-Path $dbFile)) {
    Write-Host "ERROR: DB file not found:"
    Write-Host $dbFile
    exit 1
}

# Verdaccio 必须停止
$connections = Get-NetTCPConnection `
    -LocalPort 4873 `
    -State Listen `
    -ErrorAction SilentlyContinue

if ($null -ne $connections) {
    Write-Host "ERROR: Verdaccio is still running."
    Write-Host "Please run .\stop.ps1 first."
    exit 1
}

$db = Get-Content $dbFile -Raw | ConvertFrom-Json

# 保存 secret
$secret = $db.secret

$originalPackages = @($db.list)

# storage 下的 package namespace
$packageDirs = Get-ChildItem `
    -LiteralPath $storage `
    -Directory `
    -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -ne ".git"
    }

Write-Host "Storage:"
Write-Host "  $storage"
Write-Host ""

Write-Host "Packages in DB    : $($originalPackages.Count)"
Write-Host "Storage folders   : $($packageDirs.Count)"
Write-Host ""

Write-Host "WARNING:"
Write-Host "This will DELETE ALL Verdaccio package storage."
Write-Host "The DB file itself will NOT be deleted."
Write-Host "The DB package list will be cleared."
Write-Host "The Verdaccio secret will be preserved."
Write-Host ""

# 强制确认
$answer = Read-Host 'Type "DELETE ALL" to confirm'

if ($answer -ne "DELETE ALL") {
    Write-Host "Cancelled."
    exit 0
}

# backup
if (-not (Test-Path $backupDir)) {
    New-Item `
        -ItemType Directory `
        -Path $backupDir |
        Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$backupFile = Join-Path `
    $backupDir `
    ".verdaccio-db-before-remove-all-$timestamp.json"

Copy-Item $dbFile $backupFile

Write-Host ""
Write-Host "DB backup created:"
Write-Host $backupFile
Write-Host ""

# 删除 package storage
foreach ($dir in $packageDirs) {

    Write-Host "Deleting:"
    Write-Host "  $($dir.FullName)"

    Remove-Item `
        -LiteralPath $dir.FullName `
        -Recurse `
        -Force
}

# 清空 DB package list
$db.list = @()

# 保留 secret
$db.secret = $secret

$json = $db | ConvertTo-Json -Compress

[System.IO.File]::WriteAllText(
    $dbFile,
    $json,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host ""
Write-Host "========================================"
Write-Host " All packages removed"
Write-Host "========================================"
Write-Host ""
Write-Host "DB: $dbFile"
Write-Host "Backup: $backupFile"
Write-Host ""
Write-Host "Package list cleared : YES"
Write-Host "Secret preserved     : YES"
```

使用：

```
.\remove-all-packages.ps1
```

然后输入：

```
DELETE ALL
```

------

## BAT 文件

### `run-remove-package.bat`

```
@echo off

powershell -ExecutionPolicy Bypass ^
    -File "%~dp0remove-package.ps1" %*

pause
```

这样可以直接：

```
run-remove-package.bat "@szewec/bis-core-schema"
```

------

### `run-remove-all-packages.bat`

```
@echo off

powershell -ExecutionPolicy Bypass ^
    -File "%~dp0remove-all-packages.ps1"

pause
```

运行：

```
run-remove-all-packages.bat
```

------

## 其他原来的脚本

这些保持之前的版本即可：

```
start.ps1
start-background.ps1
stop.ps1
status.ps1
test.ps1
backup-db.ps1
check-db.ps1
clean-db.ps1
```

对应 BAT：

```
run-start.bat
run-start-background.bat
run-stop.bat
run-status.bat
run-test.bat
run-backup-db.bat
run-check-db.bat
run-clean-db.bat
```

### 最终你实际最常用的命令

```
# 查看 Verdaccio
.\status.ps1

# 启动
.\start.ps1

# 停止
.\stop.ps1

# 检查 DB
.\check-db.ps1

# 清理 DB 中已经不存在的包
.\clean-db.ps1

# 删除一个指定包
.\remove-package.ps1 "@szewec/bis-core-schema"

# 删除全部包
.\remove-all-packages.ps1

# 测试
.\test.ps1
```

**注意一个关键点：**你现在的 storage 里有 `@szewec`、`@szewtwin` 等 namespace。`remove-all-packages.ps1` 会把 storage 下的这些 namespace 目录也删掉，然后把 DB `list` 清空；所以这个命令是真正的“全部删除”，不是仅仅清理 DB。



对，刚才我只给了新增的两个 BAT，**原来的 8 个 BAT 没有把代码完整列出来**。下面把全部 BAT 一次性补齐，你直接复制即可。

### 1. `run-start.bat`

```
@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0start.ps1"
pause
```

### 2. `run-start-background.bat`

```
@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0start-background.ps1"
pause
```

### 3. `run-stop.bat`

```
@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0stop.ps1"
pause
```

### 4. `run-status.bat`

```
@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0status.ps1"
pause
```

### 5. `run-test.bat`

```
@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0test.ps1"
pause
```

### 6. `run-backup-db.bat`

```
@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0backup-db.ps1"
pause
```

### 7. `run-check-db.bat`

```
@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0check-db.ps1"
pause
```

### 8. `run-clean-db.bat`

```
@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0clean-db.ps1"
pause
```

### 9. `run-remove-package.bat`

这个需要把命令行参数传给 PowerShell：

```
@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0remove-package.ps1" %*
pause
```

使用：

```
run-remove-package.bat "@szewec/bis-core-schema"
```

### 10. `run-remove-all-packages.bat`

```
@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0remove-all-packages.ps1"
pause
```

------

所以最终 **10 个 BAT 文件**就是：

```
run-start.bat
run-start-background.bat
run-stop.bat
run-status.bat
run-test.bat
run-backup-db.bat
run-check-db.bat
run-clean-db.bat
run-remove-package.bat
run-remove-all-packages.bat
```

对应关系：

```
run-start.bat
    ↓
start.ps1

run-start-background.bat
    ↓
start-background.ps1

run-stop.bat
    ↓
stop.ps1

run-status.bat
    ↓
status.ps1

run-test.bat
    ↓
test.ps1

run-backup-db.bat
    ↓
backup-db.ps1

run-check-db.bat
    ↓
check-db.ps1

run-clean-db.bat
    ↓
clean-db.ps1

run-remove-package.bat
    ↓
remove-package.ps1

run-remove-all-packages.bat
    ↓
remove-all-packages.ps1
```

这样整个工具目录就完整了。



## 1. `ps1/rotate-secret.ps1`

```
$storage = "C:\Users\lenovo\.config\verdaccio\storage"
$dbFile = Join-Path $storage ".verdaccio-db.json"

# 因为当前脚本位于：
# verdaccio-tools-windows\ps1\
# 所以工具根目录是上一级
$toolRoot = Split-Path $PSScriptRoot -Parent

$backupDir = Join-Path $toolRoot "backups"

Write-Host "========================================"
Write-Host " Verdaccio Secret Rotation"
Write-Host "========================================"
Write-Host ""

# ----------------------------------------
# 检查 DB
# ----------------------------------------

if (-not (Test-Path $dbFile)) {
    Write-Host "ERROR: DB file not found:"
    Write-Host $dbFile
    exit 1
}

# ----------------------------------------
# 检查 Verdaccio 是否正在运行
# ----------------------------------------

$connections = Get-NetTCPConnection `
    -LocalPort 4873 `
    -State Listen `
    -ErrorAction SilentlyContinue

if ($null -ne $connections) {
    Write-Host "ERROR: Verdaccio is still running."
    Write-Host ""
    Write-Host "Please run:"
    Write-Host "  ..\bat\run-stop.bat"
    Write-Host ""
    exit 1
}

# ----------------------------------------
# 读取 DB
# ----------------------------------------

try {
    $db = Get-Content $dbFile -Raw | ConvertFrom-Json
}
catch {
    Write-Host "ERROR: Failed to read Verdaccio DB."
    Write-Host $_.Exception.Message
    exit 1
}

if ($null -eq $db.secret -or [string]::IsNullOrWhiteSpace($db.secret)) {
    Write-Host "ERROR: Existing secret was not found."
    exit 1
}

$oldSecretLength = $db.secret.Length

# ----------------------------------------
# 创建备份目录
# ----------------------------------------

if (-not (Test-Path $backupDir)) {
    New-Item `
        -ItemType Directory `
        -Path $backupDir |
        Out-Null
}

# ----------------------------------------
# 备份 DB
# ----------------------------------------

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$backupFile = Join-Path `
    $backupDir `
    ".verdaccio-db-before-secret-rotation-$timestamp.json"

Copy-Item `
    -LiteralPath $dbFile `
    -Destination $backupFile `
    -Force

Write-Host "DB backup created:"
Write-Host "  $backupFile"
Write-Host ""

# ----------------------------------------
# 二次确认
# ----------------------------------------

Write-Host "WARNING:"
Write-Host "Rotating the Verdaccio secret will invalidate"
Write-Host "existing Verdaccio authentication tokens."
Write-Host ""
Write-Host "After rotation, users must login again."
Write-Host ""

$answer = Read-Host 'Type "ROTATE" to continue'

if ($answer -ne "ROTATE") {
    Write-Host ""
    Write-Host "Cancelled."
    exit 0
}

# ----------------------------------------
# 使用 Windows Cryptographic RNG
# ----------------------------------------

$characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

try {
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes)

    $newSecretChars = New-Object char[] 32

    for ($i = 0; $i -lt 32; $i++) {
        $newSecretChars[$i] =
            $characters[$bytes[$i] % $characters.Length]
    }

    $newSecret = -join $newSecretChars
}
finally {
    $rng.Dispose()
}

# ----------------------------------------
# 修改 secret
#
# list 完全保留
# ----------------------------------------

$db.secret = $newSecret

# ----------------------------------------
# 写回 JSON
# ----------------------------------------

try {
    $json = $db | ConvertTo-Json -Compress -Depth 100

    [System.IO.File]::WriteAllText(
        $dbFile,
        $json,
        [System.Text.UTF8Encoding]::new($false)
    )
}
catch {
    Write-Host "ERROR: Failed to write Verdaccio DB."
    Write-Host $_.Exception.Message
    Write-Host ""
    Write-Host "Your original DB backup is still available:"
    Write-Host $backupFile
    exit 1
}

# ----------------------------------------
# 验证写入
# ----------------------------------------

try {
    $verifyDb = Get-Content $dbFile -Raw | ConvertFrom-Json

    if ($null -eq $verifyDb.secret) {
        throw "Secret is missing after write."
    }

    if ($verifyDb.secret.Length -ne 32) {
        throw "Secret length is not 32."
    }
}
catch {
    Write-Host "ERROR: Secret verification failed."
    Write-Host $_.Exception.Message
    Write-Host ""
    Write-Host "Backup:"
    Write-Host $backupFile
    exit 1
}

# ----------------------------------------
# 完成
# ----------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host " Secret rotation completed"
Write-Host "========================================"
Write-Host ""
Write-Host "DB:"
Write-Host "  $dbFile"
Write-Host ""
Write-Host "Old secret length:"
Write-Host "  $oldSecretLength"
Write-Host ""
Write-Host "New secret length:"
Write-Host "  32"
Write-Host ""
Write-Host "Secret changed : YES"
Write-Host "Package list   : PRESERVED"
Write-Host "Backup created : YES"
Write-Host ""
Write-Host "The new secret is intentionally NOT displayed."
Write-Host ""
Write-Host "Existing authentication tokens are now invalid."
Write-Host "Run npm login again to obtain a new token."
Write-Host ""
```

这里特意**不会把新 secret 打印出来**，避免 secret 出现在终端历史、日志或者截图里。

------

## 2. `bat/run-rotate-secret.bat`

因为 BAT 和 PS1 分开了一个目录，所以使用 `..\ps1\`：

```
@echo off

powershell -ExecutionPolicy Bypass ^
    -File "%~dp0..\ps1\rotate-secret.ps1"

pause
```

然后直接双击：

```
bat\run-rotate-secret.bat
```

它会要求：

```
Type "ROTATE" to continue:
```

输入：

```
ROTATE
```

才会真正执行。

------

## 3. 执行后的效果

假设原来：

```
{
  "list": [
    "@szewec/bis-core-schema",
    "@szewtwin/core-backend"
  ],
  "secret": "旧secret"
}
```

执行：

```
run-rotate-secret.bat
```

之后会变成：

```
{
  "list": [
    "@szewec/bis-core-schema",
    "@szewtwin/core-backend"
  ],
  "secret": "新的32字符secret"
}
```

注意：

```
list
 ↓
完全不变

secret
 ↓
更换

storage
 ↓
完全不动
```

所以它和：

```
remove-package
remove-all-packages
clean-db
```

是完全独立的。

------

## 4. 更换以后重新登录

Secret 更换完成后，启动 Verdaccio：

```
run-start.bat
```

然后重新登录：

```
npm login --registry http://localhost:4873 --auth-type=legacy
```

或者创建/登录用户：

```
npm adduser --registry http://localhost:4873 --auth-type=legacy
```

然后检查：

```
npm --registry http://localhost:4873 whoami
```

最后：

```
npm --registry http://localhost:4873 ping
```

------

### 现在整个管理工具就有 3 种不同的清理/安全操作

```
clean-db
    ↓
只清理 DB 中已经不存在的包
    ↓
不删除实际 package


remove-package
    ↓
删除指定 package
    ↓
storage + DB


remove-all-packages
    ↓
删除所有 package
    ↓
storage + DB list


rotate-secret
    ↓
更换 Verdaccio secret
    ↓
package 不动
    ↓
旧 token 全部失效
```

这四个操作的边界就比较清楚了。