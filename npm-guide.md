# npm 私服(Verdaccio)使用指南

本机私服地址:`http://localhost:4873`;局域网接入用 `http://<本机IP>:4873`(详见 README「让其他电脑使用本私服」)。

## 1. 将 npm 配置为使用私服

```bash
# 指向私服(写入用户级 ~/.npmrc,全局生效)
npm config set registry http://localhost:4873

# 验证
npm config get registry
npm ping

# 切回官方源
npm config set registry https://registry.npmjs.org
```

其他方式:

| 方式 | 命令 / 做法 | 生效范围 |
| --- | --- | --- |
| 用户级(默认) | `npm config set registry <url>` | 当前用户所有项目 |
| 项目级 | 项目根目录建 `.npmrc`,写入 `registry=http://localhost:4873` | 仅该项目 |
| 临时使用 | `npm install --registry http://localhost:4873` | 仅本次命令 |

局域网其他电脑接入(假设私服主机 IP 为 `172.20.10.2`):

```bash
npm config set registry http://172.20.10.2:4873
npm login --registry http://172.20.10.2:4873 --auth-type=legacy
```

前提:私服主机 `config.yaml` 配置 `listen: 0.0.0.0:4873` 并放行防火墙 4873 端口。

## 2. 常见问题:PowerShell 禁止运行脚本

执行 `npm ...` 报错:

```
npm : 无法加载文件 C:\Program Files\nodejs\npm.ps1，因为在此系统上禁止运行脚本。
(about_Execution_Policies)
```

原因:Windows PowerShell 默认执行策略为 `Restricted`,禁止运行任何 `.ps1`;而 PowerShell 下 `npm` 命令会优先匹配到 `npm.ps1`。

**方法一:放开当前用户执行策略(推荐,一次性解决,无需管理员)**

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

提示确认时输入 `Y`,然后重新执行 npm 命令。
`RemoteSigned`:本地脚本可直接运行,网络下载的脚本需签名,是官方推荐的日常安全级别。

**方法二:不改策略,绕过 `.ps1`**

```powershell
npm.cmd config set registry http://localhost:4873
```

或改用 cmd(而非 PowerShell)运行 npm,同样不会触发限制。

## 3. 注册用户与登录

npm 中「注册」和「登录」是同一个命令(`npm adduser` 是 `npm login` 的别名):
账号不存在 → 注册并登录;已存在 → 登录。成功后 token 自动写入 `~/.npmrc`。

```bash
npm login --registry http://localhost:4873 --auth-type=legacy
```

按提示输入用户名、密码、邮箱。

> **`--auth-type=legacy` 必须加**:npm 9+ 默认走网页登录,Verdaccio 不支持,
> 加此参数才回到传统用户名/密码交互。全局 registry 已指向私服时可省略 `--registry`。

```bash
# 查看当前登录身份
npm whoami --registry http://localhost:4873

# 退出登录
npm logout --registry http://localhost:4873
```

## 4. 本仓库封装好的工具(免手敲命令)

| 方式 | 说明 |
| --- | --- |
| `run-register.bat` / `register.ps1` | 注册新用户(直接调 registry API,注册即登录) |
| `run-login.bat` / `login.ps1` | 登录(直接调 API,自动写 token 到 `.npmrc`) |
| `run-ui.vbs`(Web 控制台) | 浏览器打开 `http://localhost:4874`,弹窗填用户名/密码/邮箱完成注册登录;「远程连接」卡片含局域网接入的完整命令,支持一键复制并自动检测本机 IP |
