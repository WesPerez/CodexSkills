---
name: browser-bookmarks
description: 安全整理、去重、迁移、备份、还原或检查 Chromium 系浏览器书签/收藏夹，尤其是 Microsoft Edge 和 Google Chrome 配置目录中的 `Bookmarks` 文件。用户要求清理 Edge/Chrome 收藏夹、保留书签栏使用习惯、跨文件夹归类、把 Edge 书签复制到 Chrome、处理同步覆盖或重复书签树、校验备份、处理书签 checksum，或分析 favicon/同步副作用时使用。
---

# 浏览器书签

## 工作契约

输入：目标浏览器、配置目录、用户意图、需要保留的使用习惯，以及是否授权关闭浏览器窗口或后台进程。

输出：备份路径、整理前后清单、实际变更方式、验证证据、清理报告和可回滚说明。

状态标签：`只读审计`、`已创建备份`、`已通过API变更`、`已使用文件兜底`、`可还原`、`同步部分验证`、`阻塞-需要关闭浏览器`、`阻塞-需要用户授权`、`阻塞-云端状态未知`。

交接规则：只有用户明确要求控制 Chrome 或依赖现有 Chrome 登录状态时，才交给 `chrome:control-chrome`；需要内置浏览器时交给 `browser:control-in-app-browser`；只有必须操作原生桌面界面时才交给 `computer-use:computer-use`。书签任务优先使用本地文件检查和 Chromium 书签 API。

## 开始检查

1. 精确确认浏览器和配置目录。在这个 Windows 环境里，除非用户明确说 Chrome，否则默认处理 Microsoft Edge。Edge 通常位于 `%LOCALAPPDATA%\Microsoft\Edge\User Data\<Profile>`，Chrome 通常位于 `%LOCALAPPDATA%\Google\Chrome\User Data\<Profile>`。如果活动 profile 不清楚，先读 `Local State`。
2. 记录用户是否授权关闭窗口或后台进程。未授权时，关闭窗口、结束进程前必须询问；已授权时，也只关闭目标浏览器进程，并解释后台进程为何存在。
3. 任何变更前，先给 live `Bookmarks` 文件创建带时间戳的备份。处理图标问题前，也要备份 `Favicons`。
4. 对当前文件运行 `scripts/chromium_bookmarks_audit.mjs`。如果用户要求保留书签栏习惯，变更后还要带 `--baseline` 对备份做对比。
5. 变更前先定义保留规则：书签栏根部独立 URL、高频固定文件夹、作为快捷入口刻意重复的 URL、移动端/同步根节点，以及用户明确说不要合并的文件夹。

## 决策路径

- 只读诊断、备份规划或还原规划：只检查文件并输出报告；除非必要，不启动浏览器。
- 整理单个 live Edge/Chrome profile：先基于离线副本生成候选方案，再通过临时本地扩展调用 `chrome.bookmarks` API 应用。不要把直接替换 JSON 当作首选方案。
- 将 Edge 复制到 Chrome，或修复 Chrome 同步后的书签：先比较 URL 集合。Chrome 同步在线时，优先通过 Chrome 书签 API 做增量添加，或在明确需要时清空并重建可写桌面根节点。直接改文件只是兜底。
- 从备份还原：关闭浏览器，把选定备份复制为 `Bookmarks`，验证 JSON 和 checksum，再启动浏览器，并等待短暂同步窗口后复查。
- 处理 favicon：不要承诺通过复制或编辑 `Favicons` 就能持久修好图标。Chrome 可能用内存状态覆盖手工 SQLite 修改。可靠刷新通常需要让 Chrome 实际加载对应书签页面。

## 安全变更流程

live 书签变更优先使用临时 MV3 扩展：

- `manifest_version: 3`
- `permissions: ["bookmarks"]`
- 可选回调地址权限，例如 `http://127.0.0.1:<port>/*`
- 后台 service worker 调用 `chrome.bookmarks.getTree`、`getChildren`、`create`、`move`、`removeTree`
- 使用类似 `organizePromise` 的执行锁，避免 `onInstalled` 和 `onStartup` 并发执行
- 生成本地回调报告，记录数量、移动节点、跳过节点和错误

保持变更保守：

- 用户要保留原习惯时，不移动书签栏根部独立 URL。
- 只有分类明显错误，或用户授权更大范围整理时，才跨顶级分类移动文件夹。
- 不要把书签栏独立 URL 合并进文件夹，除非用户明确要求。
- 不要碰移动端或同步根节点，除非用户明确要求。
- 除非是在修复云同步产生的重复整棵书签树，或执行明确还原任务，否则避免大范围删除/重建。
- Chrome 同步恢复场景里，通过书签 API 清空并重建可写桌面根节点，有时比反复关闭 Chrome 后编辑文件更稳，因为 API 操作会被同步系统视为用户意图。

PowerShell 启动参数提醒：包含空格的 profile 参数必须作为一个完整引号参数传入，例如 `--profile-directory="Profile 1" --load-extension="<extDir>" --no-first-run --no-startup-window`。错误拆成 `--profile-directory=Profile 1` 可能会创建错误目录，例如 `User Data\Profile`。

## 文件兜底

只有在浏览器已关闭、已有备份，并且 API 或导入路径不可用/不适合时，才直接编辑 `Bookmarks` JSON。编辑后必须：

- 重新计算 Chromium 书签 checksum。Edge profile 可能包含 `roots.workspaces_v2`；如果只哈希 `bookmark_bar`、`other`、`synced`，当前 Edge 文件可能校验失败。
- 尽量保留原有节点形状和字段，不要发明不必要字段。
- 除非任务就是去重或删除，否则保持 URL 身份稳定。
- 启动浏览器并等待同步窗口后复查，因为云同步可能回滚或合并直接文件修改。

文件兜底适合临时扩展无法注册时的 Chrome 增量恢复，但在同步开启的完整树替换场景里很脆弱。

## 验证标准

报告成功前，收集这些证据：

- 当前文件能解析为 JSON。
- 文件存在 checksum 时，存储值和计算值一致。
- URL 身份被保留，或所有删除项都明确列为预期删除。
- 用户要求保留书签栏习惯时，书签栏根部 URL 顺序不变。
- 顶级分类和关键文件夹数量符合计划。
- 理解重复 URL 组：区分刻意保留的快捷入口和意外重复的整树/文件夹。
- 同步可能覆盖结果时，浏览器已重启或至少短暂观察过。
- 本任务创建的临时扩展目录、回调监听器和标签页已关闭，或带理由保留。

云端书签状态通常没有官方直接 JSON 下载。最稳的检查方式是使用干净临时 profile 登录同一账号并开启书签同步，再检查或导出那个 profile。

## 清理和汇报

只清理能证明属于当前任务的产物：临时扩展目录、本地回调日志、生成的候选文件，以及本任务误创建的 profile。除非用户明确要求删除回滚点，否则保留备份。

不要删除浏览器原生文件，例如 `Bookmarks.bak`、`Bookmarks.msbak`、扩展状态、Cookie、密码或同步数据，除非用户明确要求删除精确目标，并且风险已经说明。

最终报告必须包含：备份路径、变更方式、验证数量、保留的使用习惯、执行过的清理、保留的备份、留下的浏览器进程/标签页，以及仍存在的同步不确定性。

## 脚本

使用 `scripts/chromium_bookmarks_audit.mjs` 产生确定性的只读证据：

```bash
node scripts/chromium_bookmarks_audit.mjs --bookmarks "<profile>/Bookmarks" --json
node scripts/chromium_bookmarks_audit.mjs --bookmarks "<profile>/Bookmarks" --baseline "<backup>" --json
```

脚本会报告根节点数量、书签栏根部独立 URL、重复 URL 组、URL 集合差异和 checksum 状态。
