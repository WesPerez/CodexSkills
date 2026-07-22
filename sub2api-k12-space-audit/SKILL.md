---
name: sub2api-k12-space-audit
description: 按 `credentials.chatgpt_account_id` 只读审计 Sub2API PostgreSQL 中的 K12/OpenAI OAuth Space：统计本地可调度账号、active/deleted、401/402、无错误删除行，并检查指定 Space 或前缀。用户询问本地库 K12 Space 库存、红点/失效原因、某 Space 还剩多少本地可用账号或需要脱敏账号列表时使用。不要用于论坛收集 Space ID、浏览器 exchange 验证、上游额度探测、账号包导入或显示名整理。
---

# Sub2API K12 Space 只读审计

## 范围

从 Sub2API PostgreSQL 生成 K12 Space ID 本地可用性报告。Space ID 是 `accounts.credentials->>'chatgpt_account_id'`；它是 workspace/account 维度，同一个值可由多个 K12 账号共享。

按目标分流：

- 论坛收集 K12 Space/Workspace ID：使用 `$linux-do-k12-space-id`。
- 浏览器 session exchange 验证：使用 `$k12check`。
- 账号包、上游额度、转换、导入、备份或绑组：使用 `$k12-sub2api-ops`。
- 显示名排序整理：使用 `$sub2api-account-organizer`。
- 本地数据库 Space 统计：使用本技能。

## 安全边界

- 把 `credentials`、token、数据库 dump 和管理员认证视为秘密。不得输出 access/session/refresh/ID token、Authorization header 或完整 credentials JSON。
- 默认只查询数据库，不调用 ChatGPT/OpenAI usage、quota、test 或 refresh endpoint。
- 审计期间不得删除、软删除、停调度、重绑、刷新或清理任何账号。
- 执行前必须通过 compose、部署配置和用户确认核实环境、容器、数据库用户、数据库和 schema；不能根据容器名猜环境。脚本要求全部显式传入，没有生产默认值，并在 stderr 输出不含凭据的目标摘要。
- 生产只读查询保持最小范围；脚本使用只读事务、15 秒 statement timeout、2 秒 lock timeout 和 30 秒进程 timeout。
- `active-accounts` 会输出账号名、组名和时间戳，仅在用户明确要求账号明细时运行；邮箱脱敏，原始错误文本只分类不回显，默认最多 200 行。
- 明确说明 `local_available` 只代表 Sub2API 本地可调度，不证明 OpenAI 上游真实可用。

## 本地可用定义

K12 OpenAI OAuth 账号同时满足以下条件才计为 `local_available`：

- `platform = 'openai'`
- `type = 'oauth'`
- `credentials->>'plan_type' = 'k12'`
- `deleted_at is null`
- `status = 'active'`
- `schedulable is true`
- `temp_unschedulable_until is null or temp_unschedulable_until <= now()`
- top-level `expires_at` is null or in the future
- numeric `credentials.expires_at`, when present, is in the future

这个谓词有意不证明上游可用性。上游 `401`、`402` 和 quota 状态需要独立、明确授权的探测，且可能消耗额度。

## 工作流

1. 核实环境、PostgreSQL 容器、用户、数据库和 schema，并评估查询影响。
2. 用 `summary` 查看总量。
3. 用 `spaces` 查看每个 Space 一行的统计。
4. 对疑似 Space 用 `space --space-prefix <prefix>` 或 `--space-id <id>`。
5. 只有用户要求列出账号时才用 `active-accounts`，必要时用 `--limit` 收窄。
6. 分开解释红点类结果：deleted `401` 是 token/账号认证失败；deleted `402` 是 workspace/account 停用或计费异常的较强本地信号；无错误删除行只有本地删除事实；`local_available > 0` 仅代表仍可本地调度。
7. 明确报告是否运行过上游探测；普通数据库统计应写明未运行。

## 脚本

使用捆绑脚本执行确定性只读查询：

```bash
python3 /root/.codex/skills/sub2api-k12-space-audit/scripts/k12_space_audit.py \
  --environment <environment> --postgres-container <container> \
  --pg-user <user> --pg-db <database> --pg-schema <schema> \
  summary

python3 /root/.codex/skills/sub2api-k12-space-audit/scripts/k12_space_audit.py \
  --environment <environment> --postgres-container <container> \
  --pg-user <user> --pg-db <database> --pg-schema <schema> \
  spaces

python3 /root/.codex/skills/sub2api-k12-space-audit/scripts/k12_space_audit.py \
  --environment <environment> --postgres-container <container> \
  --pg-user <user> --pg-db <database> --pg-schema <schema> \
  space --space-prefix cf8e512

python3 /root/.codex/skills/sub2api-k12-space-audit/scripts/k12_space_audit.py \
  --environment <environment> --postgres-container <container> \
  --pg-user <user> --pg-db <database> --pg-schema <schema> \
  active-accounts --space-id <space-id> --limit 100
```

脚本通过 `docker exec` 和 `psql` 执行固定 `SELECT` 查询，并使用 `BEGIN TRANSACTION READ ONLY`、显式 `search_path`、超时和 `ON_ERROR_STOP` 作为第二层保护。

## 引用

修改本地可用谓词、增加列或解释 SQL 到 Sub2API 状态的映射前，读取 `references/queries.md`。
