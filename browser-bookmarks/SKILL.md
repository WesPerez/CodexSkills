---
name: browser-bookmarks
description: 安全审计、整理、迁移、备份、还原和修复 Chromium 浏览器书签及同步。用于 Edge/Chrome 收藏夹分类、Bookmarks/checksum、书签栏习惯保留、跨浏览器迁移、favicon、同步开关自动切换、多电脑不一致、云端旧树回弹或重复、Bookmarks 被阻塞、InvalidMessage、云同步重置和逐台恢复。不用于仅打开网页、单次添加普通书签、纯密码管理或一般浏览器性能问题。
---

# 浏览器书签

## 工作契约

输入：目标浏览器与 profile、用户真实目标、权威书签来源、需保留的操作习惯、允许的浏览器关闭/配置修改/云端副作用边界。

输出：权威 baseline、备份路径、实际变更方式、本地/运行时/云端三层证据、同步状态、清理结果、回滚方式和残余风险。

状态标签：

- `只读审计`
- `已创建兜底备份`
- `本地树已验证`
- `同步开关已修改-引擎未验证`
- `同步引擎已验证`
- `云端已隔离验证`
- `可还原`
- `部分验证-云端未知`
- `阻塞-需要关闭浏览器`
- `阻塞-需要认证`
- `阻塞-需要明确授权`

## 五层状态模型

始终分开判断，不要把任一层成功写成整体成功：

1. **本地文件**：`Bookmarks`、`Bookmarks.bak`、checksum、完整树和顺序。
2. **运行时书签模型**：`chrome.bookmarks` API 或浏览器启动后实际加载的树。
3. **同步开关**：profile 的 `Preferences.sync.bookmarks`。
4. **同步引擎**：Bookmarks 数据类型是否 configured、上传/下载、阻塞或提交失败。
5. **云端实体**：服务器是否只有权威树，还是同时保留新旧 GUID 树、残树或异常实体。

`sync.bookmarks=true` 只证明配置值；本地数量稳定只证明没有立即回流。只有隔离接收 profile/设备重新下载并与 baseline 完整匹配，才可标记 `云端已隔离验证`。

## 核心步骤

### 1. 定位精确对象

1. 默认处理 Microsoft Edge；用户明确说 Chrome 时才切换。
2. 从 `Local State` 读取 `profile.last_used` 和 profile 映射，不凭 `Default`、目录时间或显示名猜测。
3. 记录浏览器、user-data-dir、profile、账号类型、当前进程、收藏夹同步开关和其他同步类型。
4. 定义权威来源：当前 live、某份备份、Edge、Chrome 或指定设备。多设备不一致时，没有权威 baseline 就不执行合并或重建。

完成标准：目标 profile 与权威来源都有可验证路径，未把其他 profile 或另一浏览器带入范围。

### 2. 冻结并建立 baseline

1. 只读运行 `scripts/chromium_bookmarks_audit.mjs`。
2. 任何变更前至少备份 live `Bookmarks` 和 `Bookmarks.bak`；云端重置、密码/历史风险或整 profile 修复时做完整 `User Data` 冷备份。
3. baseline 至少记录 URL/文件夹数、重复组、顶级节点、书签栏根部 URL 顺序、完整树签名、checksum 和文件哈希。
4. 权威书签可能继续被同步改写时，先关闭收藏夹同步，再重新备份和审计。

完成标准：存在一份已解析、checksum 正确、可定位且不被后续步骤覆盖的权威 baseline。

### 3. 选择分支

- **同步不一致、开关、阻塞、回弹、整树重复、云端重置、多设备恢复**：完整读取 [sync-recovery.md](references/sync-recovery.md)。
- **整理、分类、去重、Edge/Chrome 迁移、直接文件兜底、bookmarklet**：读取 [organization-migration.md](references/organization-migration.md)。
- **书签网站图标、Favicons 数据库、灰色地球图标**：读取 [favicon-recovery.md](references/favicon-recovery.md)。
- **备份级别、临时扩展、进程/标签页归属、残留与最终报告**：读取 [cleanup-validation.md](references/cleanup-validation.md)。

### 4. 使用浏览器认可的变更路径

优先级：

1. `chrome.bookmarks` API 或浏览器原生导入/设置事件。
2. 浏览器完全关闭后的受控配置/文件修改。
3. 直接替换 JSON 只作兜底，不把它描述为云端覆盖。

整理或重建书签时，临时 MV3 扩展只申请 `bookmarks` 等最小权限；使用执行锁、精确路径/节点约束、结果报告和短同步观察。内部页面被官方插件 URL policy 拦截时不要绕过；但这不等于同步开关必须交给用户手点，满足下节条件时可直接修改 `Preferences.sync.bookmarks`。

### 5. 自动切换收藏夹同步

浏览器完全关闭、用户已授权该同步方向、profile 精确且云端风险已判断时，使用：

```powershell
node scripts/edge_bookmark_sync_switch.mjs --preferences "<Profile>/Preferences" --inspect
node scripts/edge_bookmark_sync_switch.mjs --preferences "<Profile>/Preferences" --set disabled --expect enabled --backup-dir "<stage-backup>"
node scripts/edge_bookmark_sync_switch.mjs --preferences "<Profile>/Preferences" --set enabled --expect disabled --backup-dir "<stage-backup>"
```

脚本必须：拒绝运行中的目标浏览器；拒绝 `keep_everything_synced=true`、策略控制、缺失/非布尔字段、重复 JSON 键和旧值断言不符；只修改根对象下 `sync.bookmarks` 的布尔 token；保留其他字节；每次切换创建独立备份和 manifest；覆盖前复查源文件未被并发改写；flush、原子替换并复读验证。

不要直接用 PowerShell `ConvertTo-Json` 或普通 `JSON.parse`/`JSON.stringify` 重写整个 `Preferences`。大整数、转义、字段布局和无关内容可能被改写。

脚本成功后状态只能是 `同步开关已修改-引擎未验证`。随后启动浏览器，验证：

- 值没有被恢复。
- Bookmarks 引擎真正 configured/stopped。
- 0/30/60/120 秒的本地树与 baseline 关系符合预期。
- 日志没有 `InvalidMessage`、阻塞或失败提交。

历史实证同时出现过两种结果：离线改值后引擎没有重新配置；以及彻底关闭浏览器、隔离旧活动书签后改值并启动，成功触发云端下载。技能必须以运行后证据裁决，不能把任一案例外推为必然。

### 6. 分层验证

本地层：JSON 可解析、checksum 正确、URL 身份和完整树/顺序符合 baseline。

运行时层：浏览器启动/重启后数量、重复组和树不回滚；API 树与文件树比较时规范化 `title/name` 和根节点名称差异。

同步引擎层：配置值与日志一致；界面显示开启但日志出现 `Blocked types: Bookmarks`、`Failed to download types: Bookmarks`、`Allow fail: Bookmarks` 时，判定为引擎阻塞。

云端层：用完全隔离、已认证且只开启收藏夹的接收 profile/设备重新下载，完整树和顺序必须匹配 baseline。无法取得第二认证环境时标记 `部分验证-云端未知`，不要宣称云端已干净。

### 7. 清理和交付

只清理由本任务明确创建的临时扩展、隔离 profile、监听器、日志、候选文件和任务启动的进程/标签页。不要清浏览器原生备份、用户扩展、Cookie、密码、历史、Sync Data 或归属不明文件。

最终报告必须列出：

- 浏览器/profile 与权威 baseline。
- 备份路径和可还原范围。
- 本地、运行时、同步引擎、云端各自的验证状态。
- 开关变更方式；若直接改 Preferences，列出 before/after、备份和引擎验证。
- 书签数量、文件夹数、重复组、完整树/顺序和 checksum。
- 云端重置或外部访问等副作用。
- 清理内容、保留内容、浏览器进程/标签页和残余风险。

## 授权矩阵

- 只读文件、日志、profile 定位和审计：任务范围内直接执行。
- 关闭目标浏览器、备份、修改 `Preferences.sync.bookmarks`、恢复书签：用户明确要求修复/切换同步或授权自动处理后执行；先满足安全前置。
- 开启收藏夹同步：会立即产生云端读写。只有权威 baseline、其他设备隔离和云端方向明确时执行。
- 重置 Microsoft Edge 云端同步：会清除服务器上的全部 Edge 同步类型，不只是收藏夹，必须有明确授权和完整冷备份。
- Google 全量同步清除、密码 CSV、批量访问书签 URL、触碰 Cookie/历史/自动填充：分别需要明确授权，不能从一般书签授权推导。
- Cookie/网站登录态通常不是 Edge 常规云同步类型。不要承诺云端重置后“重新上传 Cookie”。

## 脚本

```powershell
node scripts/chromium_bookmarks_audit.mjs --bookmarks "<Profile>/Bookmarks" --json
node scripts/chromium_bookmarks_audit.mjs --bookmarks "<Profile>/Bookmarks" --baseline "<backup>/Bookmarks" --json
node scripts/edge_bookmark_sync_switch.mjs --preferences "<Profile>/Preferences" --inspect
```

审计脚本只规范化 scheme、host 和 HTTP(S) 默认端口；path、query、fragment、userinfo 和大小写保持原样。Edge checksum 可能包含 `workspaces_v2`，必须按实际根节点顺序计算。
