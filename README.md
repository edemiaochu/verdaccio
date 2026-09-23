# verdaccio

本地 Verdaccio npm 私服(`http://localhost:4873`)管理脚本与 Web 控制台。

## Web 控制台(推荐)

双击 **`run-ui.bat`**(或 `cd ui && node server.js`),浏览器自动打开 `http://localhost:4874`:

- 点击卡片即可执行全部脚本,输出实时流式显示在底部日志面板
- **启动可自定义 config.yaml 路径**(弹窗输入,自动记住上次使用的路径)
- **包列表**:浏览全部包的名称 / 版本 / 更新时间,支持搜索与 scope 筛选,可单删
- **删除 Scope 全部包**:一键删除同一 scope(如 `@szewtwin`)下的所有包,弹窗会预览将删除的包列表
- 危险操作(删包 / 删 scope / 删除全部包 / 轮换 Secret)需在弹窗中输入确认词,与命令行二次确认一致
- 删除指定包时可从数据库包列表下拉选择
- npm 登录通过弹窗填写用户名 / 密码 / 邮箱
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

## 命令行脚本

| 脚本 | 作用 | 备注 |
| --- | --- | --- |
| `start-background.ps1` | 后台启动 Verdaccio | 可选 `-Config <path>`,日志写入 `D:\verdaccio\logs` |
| `start.ps1` | 前台启动 Verdaccio | 可选 `-Config <path>`,占用控制台 |
| `stop.ps1` | 停止 Verdaccio | 结束占用 4873 端口的进程 |
| `status.ps1` | 查看运行状态 | 进程 + ping |
| `test.ps1` | 连通性测试 | npm ping / view |
| `backup-db.ps1` | 备份 DB | 备份到 `D:\verdaccio\db-backups` |
| `check-db.ps1` | 检查失效包 | 列出 DB 中磁盘已丢失的包 |
| `clean-db.ps1` | 清理失效记录 | 需先停止 Verdaccio,自动备份 |
| `remove-package.ps1 <name>` | 删除单个包 | 需先停止,确认词 `DELETE` |
| `remove-scope.ps1 <scope>` | 删除 scope 下全部包 | 如 `@szewec`,需先停止,确认词 `DELETE` |
| `remove-all-packages.ps1` | 删除全部包 | 需先停止,确认词 `DELETE ALL` |
| `rotate-secret.ps1` | 轮换 Secret | 所有 token 失效,确认词 `ROTATE` |
| `login.ps1` | npm 登录 | 需 Verdaccio 在线 |

每个脚本都有对应的 `run-*.bat` 双击运行。

## 关键路径

- 配置:`C:\Users\lenovo\.config\verdaccio\config.yaml`
- 存储 / DB:`C:\Users\lenovo\.config\verdaccio\storage`
- DB 备份:脚本目录 `db-backups\`、`D:\verdaccio\db-backups\`
