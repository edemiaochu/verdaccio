# verdaccio

本地 Verdaccio npm 私服(`http://localhost:4873`)管理脚本与 Web 控制台。

## Web 控制台(推荐)

双击 **`run-ui.vbs`** 即可**无黑框静默启动**,浏览器自动打开 `http://localhost:4874`;在页面右上角「✕ 退出」可关闭服务。需要查看服务日志时用 `run-ui.bat`(带控制台窗口)。

- 点击卡片即可执行全部脚本,输出实时流式显示在底部日志面板
- **启动可自定义 config.yaml 路径**(弹窗输入,自动记住上次使用的路径;留空则自动跟随实际使用的配置)
- **包列表**:浏览全部包的名称 / 版本 / 更新时间,支持搜索与 scope 筛选,可单删,可一键导出为 JSON 文件(完整版含版本列表与 dist-tags;简洁版仅包名数组,可勾选「带版本」输出 `包名@版本`)
- **迁移包到其他 Registry**:把本地已发布的包(全部 / 指定 Scope / 指定包)逐版本发布到另一台 npm 服务器或另一个 Registry;支持 token 认证、预览(DryRun),目标已存在的同名同版本自动跳过(可重复执行),源 Verdaccio 无需停止
- **离线迁移(导出 / 导入)**:目标在无法直连的内网时,先导出为文件夹 / zip(含 tarball、sha1 校验清单、导入脚本与说明),拷贝到内网后导入到 Registry 或 Verdaccio 存储;每个 tarball 按校验和核对,介质拷贝损坏会被拦截
- **删除 Scope 全部包**:一键删除同一 scope(如 `@szewtwin`)下的所有包,弹窗会预览将删除的包列表
- 危险操作(删包 / 按列表删包 / 删 scope / 删除全部包 / 迁移包 / 轮换 Secret)需在弹窗中输入确认词,与命令行二次确认一致
- 删除指定包时可从数据库包列表下拉选择
- npm 注册 / 登录通过弹窗填写用户名 / 密码 / 邮箱
- **上游服务器**:管理 config.yaml 的 uplinks 拉取源(增 / 改 / 删,npm 官方 / 淘宝 / 腾讯镜像快捷填充;删除时自动清理 packages 中的 proxy 引用;每次写入自动备份到 `config-backups\`,可一键重启生效)
- **远程连接指引**:展示本机局域网 IP、其他电脑接入本私服的完整配置(npm 命令 / .npmrc 内容,一键复制),并自动检测局域网是否可访问、给出开启步骤
- 顶部实时显示 Verdaccio 在线状态,支持一键终止正在运行的命令

控制台仅监听 `127.0.0.1`,无任何 npm 依赖(纯 Node 内置模块)。

## 让其他电脑使用本私服

Verdaccio 默认只监听 `localhost`,局域网内其他电脑无法连接。开启方法:

1. `config.yaml` 添加一行(重启 Verdaccio 生效):

   ```yaml
   listen: 0.0.0.0:4873
   ```

2. 管理员 PowerShell 放行防火墙:

   ```powershell
   netsh advfirewall firewall add rule name="Verdaccio" dir=in action=allow protocol=TCP localport=4873
   ```

3. 在目标电脑上(假设本机 IP 为 `172.20.10.2`):

   ```bash
   npm config set registry http://172.20.10.2:4873
   npm login --registry http://172.20.10.2:4873 --auth-type=legacy
   ```

以上内容均可在 Web 控制台「远程连接」卡片中查看并一键复制,IP 与可连接状态会自动检测。

## 迁移到另一台服务器 / 内网

详细使用说明(参数表 / 实操案例 / 常见问题)见 **[migration-guide.md](migration-guide.md)**。要点:

- **网络可达**:Web 控制台「迁移包到其他 Registry」,或命令行 `migrate-packages.ps1 -Registry <url>`;支持 `-Scope` / `-Packages` 选包、`-DryRun` 预览,目标已有的同名同版本自动跳过,可重复执行。
- **无法直连(内网)**:离线三步走:
  1. 本机执行 `export-packages.ps1`(加 `-Zip` 打成单个 zip),得到迁移包 —— 内含 tarball、`manifest.json` 校验清单、`import-packages.ps1` 与 `USAGE.txt`;
  2. 用 U 盘 / 传输工具把迁移包带入内网;
  3. 内网机器执行 `import-packages.ps1 -Bundle <迁移包> -Registry <内网地址>` 逐版本发布(需要 npm);若目标是 Verdaccio 且可直接操作其磁盘,改用 `-Storage <storage 路径>` 直接复制(无需 npm,保留原发布时间,需先停止目标 Verdaccio)。
- 每个 tarball 按 manifest 的 sha1 逐一校验,介质拷贝损坏会被拦截;导入可重复执行(已有版本跳过 / 按版本增量合并)。
- **完全离线的内网**还要把外部依赖一起带过去:导出时勾选「包含依赖到的缓存包」(命令行加 `-IncludeCache`),会**自动按依赖闭包**把上游公共包(如 `flatbuffers`、`yargs`)连同它们的依赖一并导出,否则内网装包时解析不到这些依赖;需要整镜像迁移全部缓存时用 `-AllCache`。

## 命令行脚本

| 脚本 | 作用 | 备注 |
| --- | --- | --- |
| `start-background.ps1` | 后台启动 Verdaccio | 可选 `-Config <path>`,日志写入 `C:\lk\01_work\verdaccio\logs` |
| `start.ps1` | 前台启动 Verdaccio | 可选 `-Config <path>`,占用控制台 |
| `stop.ps1` | 停止 Verdaccio | 结束占用 4873 端口的进程 |
| `status.ps1` | 查看运行状态 | 进程 + ping |
| `test.ps1` | 连通性测试 | npm ping / view |
| `backup-db.ps1` | 备份 DB | 备份到 `C:\lk\01_work\verdaccio\db-backups` |
| `check-db.ps1` | 检查失效包 | 列出 DB 中磁盘已丢失的包 |
| `clean-db.ps1` | 清理失效记录 | 需先停止 Verdaccio,自动备份 |
| `clean-cache.ps1` | 清空上游缓存包 | 保留本地发布的包,需先停止,确认词 `CLEAN CACHE`,`-DryRun` 仅预览 |
| `migrate-packages.ps1` | 迁移包到其他 Registry | `-Registry <url>` 必填;`-Scope` / `-Packages` 选包,`-IncludeCache` 连依赖到的缓存包(依赖闭包)、`-AllCache` 全部缓存包,`-DryRun` 仅预览,确认词 `MIGRATE`;源无需停止,目标已有版本自动跳过 |
| `export-packages.ps1` | 导出包(离线迁移) | 生成迁移包目录(tarball + manifest 校验清单 + 导入脚本 + 说明),`-Zip` 打成单个 zip,`-Scope` / `-Packages` 选包,`-IncludeCache` 连依赖到的缓存包(依赖闭包)、`-AllCache` 全部缓存包 |
| `import-packages.ps1` | 导入包(离线迁移) | `-Bundle <目录或 zip>` 必填;`-Registry <url>` 发布到 Registry 或 `-Storage <路径>` 复制进 Verdaccio storage(需停止目标);逐 tarball 校验和核对,确认词 `IMPORT` |
| `remove-package.ps1 <name>` | 删除单个包 | 需先停止,确认词 `DELETE` |
| `remove-package-list.ps1 <file>` | 按列表删除包 | 读取包列表文件(JSON / 文本,与包列表导出格式互通)批量删除整个包;预览后确认词 `DELETE LIST`,自动备份 DB |
| `remove-scope.ps1 <scope>` | 删除 scope 下全部包 | 如 `@szewec`,需先停止,确认词 `DELETE` |
| `remove-all-packages.ps1` | 删除全部包 | 需先停止,确认词 `DELETE ALL` |
| `rotate-secret.ps1` | 轮换 Secret | 所有 token 失效,确认词 `ROTATE` |
| `register.ps1` | 注册新用户 | 直接调用 registry API(注册即登录),需 Verdaccio 在线 |
| `login.ps1` | npm 登录 | 直接调用 registry API,需 Verdaccio 在线 |

每个脚本都有对应的 `run-*.bat` 双击运行。

## 关键路径(自动跟随实际使用的配置)

所有脚本与控制台 API 按以下顺序解析 Verdaccio 的 `config.yaml`:

1. 显式传入(启动卡片的 config 路径;Web 控制台启动时会记录到 `active-config.txt`)
2. 工具箱上次启动使用的配置(`active-config.txt`)
3. **正在运行的 Verdaccio 进程的 `-c` 参数**(实际正在生效的配置)
4. 默认 `%APPDATA%\verdaccio\config.yaml`

存储目录从该 yaml 的 `storage:` 字段解析(相对路径基于 config 所在目录,未配置时为 `./storage`)。包列表弹窗标题会显示当前使用的存储路径。环境变量 `VERDACCIO_CONFIG` / `VERDACCIO_STORAGE` 可强制覆盖。

- DB 备份:脚本目录 `db-backups\`、`C:\lk\01_work\verdaccio\db-backups\`
