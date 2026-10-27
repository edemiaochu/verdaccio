# 包迁移使用说明

把本机 Verdaccio 中已发布的包迁移到**另一台 npm 服务器 / 另一个 Registry**。
两条路径,按网络情况选:

| 路径 | 适用场景 | 工具 |
| --- | --- | --- |
| **在线迁移** | 本机能直接访问目标 Registry | `migrate-packages.ps1` |
| **离线迁移** | 目标在内网 / 无法直连,需要介质拷贝 | `export-packages.ps1` → 拷贝 → `import-packages.ps1` |

三种工具在 Web 控制台「包管理」组都有对应卡片(🚚 迁移包 / 📤 导出包 / 📥 导入包),
弹窗均可预览、可 DryRun,与命令行行为一致。

---

## 一、在线迁移(migrate-packages.ps1)

把包**逐版本 `npm publish`** 到目标 Registry,适用于任意 npm 兼容服务
(另一台 Verdaccio / Nexus / Artifactory / npmjs)。

### 常用命令

```powershell
# 预览(不实际发布,随时可用)
.\migrate-packages.ps1 -Registry http://192.168.1.10:4873 -DryRun

# 迁移全部本地已发布的包
.\migrate-packages.ps1 -Registry http://192.168.1.10:4873

# 只迁移某个 scope
.\migrate-packages.ps1 -Registry http://192.168.1.10:4873 -Scope @szewtwin

# 只迁移指定包
.\migrate-packages.ps1 -Registry http://192.168.1.10:4873 -Packages "@szewtwin/core-common, internal-tools"

# 目标需要 token 认证时
.\migrate-packages.ps1 -Registry http://192.168.1.10:4873 -Token <npm token>
```

执行时输入确认词 **`MIGRATE`**。

### 参数一览

| 参数 | 说明 |
| --- | --- |
| `-Registry <url>` | **必填**,目标 Registry 地址 |
| `-Packages <a,b,c>` | 只迁移指定包(逗号 / 空格分隔) |
| `-Scope <@scope>` | 只迁移该 scope 下的包(可与 `-Packages` 取交集) |
| `-Token <token>` | 目标的认证 token;留空则用本机 `npm login` 登录态 |
| `-Access public\|restricted` | 发往 npmjs 等公共源的 scoped 包需要 `public` |
| `-IncludeCache` | 连**依赖到的**上游缓存包一起迁(依赖闭包) |
| `-AllCache` | 连 storage 里全部缓存包一起迁(整镜像) |
| `-DryRun` | 仅预览 |
| `-Config <path>` | 指定源 config(默认自动解析) |

### 行为说明

- **源 Verdaccio 无需停止**:只读 storage,不修改 DB / secret
- 目标上已存在的同名同版本**自动跳过** → 可重复执行(断点续传 / 增量同步)
- 发布完成后按源包的 `dist-tags` 补齐 tag(latest / rc 等)
- **限制**:版本的"更新时间"无法保留,目标上显示的是迁移时间(npm publish 协议限制)

### 认证说明

- 目标**需要登录**才能发布时:先 `npm login --registry <目标>`,或传 `-Token`
- npm 客户端对 **scoped 包强制要求认证**(即使目标允许匿名发布),
  没有 token 会报 `ENEEDAUTH` 并中止 —— 提示明确,补上认证重跑即可
- npmjs 开了 2FA 的账号请改用 Automation Token

---

## 二、离线迁移(export → 拷贝 → import)

目标在内网、与本机不互通时,把包导出成**迁移包**,用 U 盘等介质带进去再导入。

```
本机                            介质 / 传输              内网机器
export-packages.ps1  ──►   迁移包目录 / zip   ──►  import-packages.ps1
(只读 storage)            (U盘等带入内网)        (导入 Registry / storage)
```

### 2.1 导出(在本机执行)

```powershell
# 预览
.\export-packages.ps1 -DryRun

# 导出全部本地包,自动生成到 脚本目录\package-export\<时间戳>\
.\export-packages.ps1

# 导出指定包,并打成单个 zip 便于拷贝
.\export-packages.ps1 -Packages "@szewtwin/core-common, internal-tools" -Zip

# 按 scope 导出
.\export-packages.ps1 -Scope @szewtwin -Zip

# ★完全离线的内网:连依赖到的公共包一起带上(见下文「依赖闭包」)
.\export-packages.ps1 -IncludeCache -Zip
```

导出**不需要确认词**(只读操作),源 Verdaccio 无需停止。

| 参数 | 说明 |
| --- | --- |
| `-Out <目录>` | 导出位置(默认 `package-export\<时间戳>`) |
| `-Packages` / `-Scope` | 选包(同在线迁移) |
| `-IncludeCache` | 依赖闭包:把选中包依赖到的缓存包一起导出 |
| `-AllCache` | 全部缓存包(整镜像导出) |
| `-Zip` | 额外打成单个 zip |
| `-DryRun` | 仅预览 |

**迁移包内容**:

```
verdaccio-export-<时间戳>/
├── manifest.json        包清单 + 每个 tarball 的 sha1/sha512 校验和
├── packages/<name>/
│   ├── package.json     原始 packument(保留发布时间等元数据)
│   └── *.tgz            该包全部本地版本
├── import-packages.ps1  导入脚本(自包含,内网机器无需整个工具箱)
└── USAGE.txt            简要使用说明
```

### 2.2 依赖闭包:外部依赖必须一起带(重要)

私有包会依赖上游公共包(`flatbuffers`、`yargs` 等)。这些包不会自动进迁移包,
**完全离线的内网**如果缺了它们,`npm install` 会因解析不到依赖而失败。

- 勾选界面「包含依赖到的缓存包」或命令行加 **`-IncludeCache`**:
  自动按包名递归(dependencies / peerDependencies / optionalDependencies),
  把依赖到的缓存包连同它们的依赖一起打包(体量只有全部缓存的零头)
- storage 里没有的依赖会在导出时列出警告(目标端解析不到)
- 需要整个 npm 镜像都搬过去才用 `-AllCache`

### 2.3 拷贝

把迁移包目录(或 zip)用 U 盘 / 传输工具带入内网。导入时会逐 tarball
按 manifest 的 sha1 **校验和核对**,介质拷贝损坏会被直接拦截。

### 2.4 导入(在内网机器执行)

内网机器只需要 **PowerShell** + 迁移包(里面自带 `import-packages.ps1`)。
两种模式二选一:

**方式 A:发布到内网 npm Registry(通用,需要 npm)**

```powershell
.\import-packages.ps1 -Bundle D:\mig-bundle.zip -Registry http://10.0.0.5:4873

# 预览 / token / 发往公共源的 scoped 包
.\import-packages.ps1 -Bundle D:\mig-bundle -Registry http://10.0.0.5:4873 -DryRun
.\import-packages.ps1 -Bundle D:\mig-bundle -Registry http://10.0.0.5:4873 -Token <npm token>
.\import-packages.ps1 -Bundle D:\mig-bundle -Registry https://registry.npmjs.org -Access public
```

- 逐版本 `npm publish`,目标已有的同名同版本自动跳过,可重复执行
- 适用于任意 npm 兼容 Registry;需要 npm CLI 与发布权限
  (先 `npm login --registry <内网地址>`,或用 `-Token`)
- 发布后的更新时间为迁移时间

**方式 B:直接复制进 Verdaccio storage(无需 npm,无损迁移)**

```powershell
# 1. 停止目标机器上的 Verdaccio
# 2. 导入(Storage = 目标 Verdaccio 的 storage 目录)
.\import-packages.ps1 -Bundle D:\mig-bundle -Storage D:\verdaccio\storage
```

- 复制 packument + tarball 并写入 `.verdaccio-db.json` 列表
- **保留原发布时间**(tarball 地址由 Verdaccio 对外提供时自动改写,无需处理)
- 目标上已存在的包按**版本增量合并**;执行前自动备份目标 DB,secret 原样保留
- 占用该 storage 的 Verdaccio 运行中会拒绝执行(按 storage 归属精确判断)

| 参数 | 说明 |
| --- | --- |
| `-Bundle <目录或 zip>` | **必填**,迁移包 |
| `-Registry <url>` | 模式 A:发布到该 Registry |
| `-Storage <路径>` | 模式 B:复制进该 Verdaccio storage(与 `-Registry` 二选一) |
| `-Token` / `-Access` | 模式 A 的认证 / 访问级别 |
| `-DryRun` | 仅预览 |

执行时输入确认词 **`IMPORT`**。每个 tarball 先校验后导入,损坏 / 缺失会提前报错。

---

## 三、完整实操案例:私有包离线迁入内网 Verdaccio

目标:把 `@szewtwin` 全部私有包(含依赖)迁到内网 `10.0.0.5` 的 Verdaccio,
内网完全离线。

```powershell
# ── 本机 ──────────────────────────────────────────────
# 1. 预览要导出的内容(确认范围与体量)
.\export-packages.ps1 -Scope @szewtwin -IncludeCache -DryRun

# 2. 导出并打包
.\export-packages.ps1 -Scope @szewtwin -IncludeCache -Zip
#    → package-export\<时间戳>\  与  package-export\<时间戳>.zip

# ── U盘拷贝 zip 到内网 ────────────────────────────────

# ── 内网机器(目标 Verdaccio 所在)────────────────────
# 3. 停止 Verdaccio
# 4. 导入(存储模式,保留发布时间)
powershell -ExecutionPolicy Bypass -File .\import-packages.ps1 `
    -Bundle D:\verdaccio-export-20261027-120000.zip `
    -Storage D:\verdaccio\storage
#    确认词 IMPORT

# 5. 启动 Verdaccio,验证
npm install @szewtwin/core-common --registry http://10.0.0.5:4873
```

如果内网 Registry 已有可用的上游源(能解析公共依赖),第 2 步可以不加 `-IncludeCache`。

---

## 四、常见问题

**Q: 导入后版本的"更新时间"不对?**
在线迁移(与存储模式的版本合并)不保留原发布时间,显示的是迁移时间;
存储模式**首次整包复制**原样保留。npm 安装不受影响。

**Q: 内网 npm install 报 404 缺 `flatbuffers` 之类?**
外部公共依赖没有一起迁移 —— 导出时加 `-IncludeCache`,或给内网 Registry 配上游源。

**Q: 报 `ENEEDAUTH` / 401?**
scoped 包的发布必须有认证。`npm login --registry <目标>` 或传 `-Token` 后重跑
(已有版本会自动跳过,不会重复发布)。

**Q: 已经迁过一次,又发布了新版本,怎么同步?**
重新导出 / 迁移一遍即可:目标上已有的版本自动跳过,只会上新缺的版本
(存储模式按版本增量合并),`dist-tags` 会更新到最新状态。

**Q: name@version 的列表(如包列表导出的 specs)能用于迁移吗?**
`-Packages` 只接受纯包名(`name@version` 会被当成包名而找不到);迁移以**包**为单位,
自动包含该包的全部本地版本。「按列表删除包」(`remove-package-list.ps1`)则可以直接
读 specs 列表(版本号忽略,按整个包删除)。

**Q: 迁移包能直接打开看吗?**
可以,`manifest.json` 是可读的包清单;`packages/` 下就是每个包的
packument 与 tarball 原文件。

---

## 五、相关文件

| 文件 | 说明 |
| --- | --- |
| `migrate-packages.ps1` | 在线迁移 |
| `export-packages.ps1` | 导出迁移包 |
| `import-packages.ps1` | 导入迁移包(自包含,可随迁移包携带) |
| `npm-guide.md` | npm 客户端使用私服的常规配置 |
| `README.md` | 工具箱总览 |
