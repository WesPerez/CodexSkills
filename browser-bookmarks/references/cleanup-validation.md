# 备份、清理与验证

## 备份级别

### 书签级

至少保存 live `Bookmarks` 和 `Bookmarks.bak`，记录 hash、文件时间、profile 和 audit 结果。适合整理、迁移和单 profile 还原。

### 完整冷备份

云端全量重置、密码/历史风险、账号/profile 重建时，浏览器完全关闭后备份整个 `User Data`：

- 验证源/备份文件数和总字节数。
- 比对 `Local State`、Bookmarks、Preferences、Secure Preferences、Login Data、History、Web Data、Network/Cookies 等存在文件的 hash。
- 不输出密码、Cookie、令牌或连接信息内容。
- 完整冷备份中的加密数据库通常只在原 Windows 用户/机器可还原，不替代可移植密码导出。

## 进程和文件边界

- 主窗口关闭不等于浏览器退出。检查 `--no-startup-window`、扩展、GPU、network/storage service 子进程。
- 只有用户授权关闭目标浏览器，或进程由本任务从零进程状态启动且 PID/父子关系可证明时，才停止。
- 不按 `msedge`/`chrome` 关键词宽泛杀进程；先确认 profile、命令行和归属。
- 浏览器运行时不要覆盖 live Bookmarks、Preferences 或 Favicons。

## 临时扩展

- 源目录被加载引用时不要删除。
- 先移除/停用扩展，再检查进程命令行、Preferences、Local State 和注册表外部扩展引用。
- `Secure Preferences` 可能保留已卸载扩展的签名历史。源目录、活动配置、启动参数和进程都消失时，它通常是惰性记录；不要直接删除签名字段，否则可能重置用户原有扩展。

## 隔离 profile

- 只用于云端下载验证或故障复现。
- 不复制权威 profile 的 Bookmarks/Sync Data 冒充干净接收端。
- 登录属于认证边界；不要读取或伪造凭据。
- 验证结束后先退出并确认进程，再删除本任务创建的隔离目录和登录缓存。

## 验证清单

- JSON 可解析。
- checksum 存储值与计算值一致。
- URL 身份、文件夹数、重复组符合预期。
- 完整树和同级顺序匹配 baseline。
- 书签栏根部 URL 顺序保持。
- API/file 比较已规范化 `title/name` 和根名差异。
- 启动、同步窗口和重启后都复验。
- 云端任务有隔离接收端证据；否则明确 `部分验证-云端未知`。
- favicon 使用 live DB 覆盖率，不用复制后 hash 冒充持久结果。

## 清理

只清本任务创建且有直接归属证据的：临时扩展、隔离 profile、监听器、回调日志、候选文件、SQLite 快照、任务标签页和任务启动进程。

默认保留唯一有效回滚点。需要合并多份本任务备份时，先生成并验证最终包，再删除同任务散落备份。不要删除浏览器原生 `.bak/.msbak`、用户历史备份或归属不明目录。

最终报告只写实际发生的清理、刻意保留的残留和原因，不输出空审计套话。
