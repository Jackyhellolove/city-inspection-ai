# AGENTS.md

本文件是面向所有 AI 编码代理（Codex、DeepSeek、Claude、Cursor 等）的项目级约定。
任何代理在改动代码前都应先读本文件，并遵守其中的规则。
[README.md](./README.md) 是最权威的详细文档，本文件是快速入口与强制约定。

## 项目一句话

城市设施 AI 巡查助手：覆盖「无人机/现场巡查 → AI 识别 → 案件派单处置 → 领导驾驶舱研判 → 报告生成」的完整闭环。

## 强制约定（最重要）

### 1. 模型切换与分支纪律

- 项目最初由 Codex 生成。`codex-checkpoint` 标签（提交 `088839d`，2026-08-16）锁定了切换前的 Codex 代码基线。
- 切换 DeepSeek 后，所有新改动必须提交到 `deepseek/dev` 分支，不得直接改 Codex 基线。
- 之前的 Codex 工作分支 `agent/https-deployment` 保持不动，作为可回退的原始分支。
- 恢复 Codex 状态：

  ```bash
  git switch codex-checkpoint          # 只读快照
  git switch agent/https-deployment    # 切回 Codex 原始分支
  git switch -c codex-recovery codex-checkpoint  # 基于快照新开分支继续开发
  ```

- 对比两个模型的差异：

  ```bash
  git diff codex-checkpoint..deepseek/dev
  ```

- 把 DeepSeek 成果并回 Codex 主线时：

  ```bash
  git switch agent/https-deployment
  git merge deepseek/dev
  ```

- 以后若再次切换模型（换回 Codex 或换其他），按同样方式处理：先打新 tag 锁定当前状态，再新建独立分支，**不要在同一分支混用不同模型的产出**。

### 2. 安全红线（密钥与隐私）

- `.env`、`supabase-config.js`、`amap-config.js` 已被 `.gitignore` 忽略，且存放真实密钥/配置，绝对不要 `git add -f` 强制提交。
- 也不要提交 `__pycache__/`、`*.pyc`。
- 密钥只写入本机 `.env`；公开配置模板统一放 `.env.example`。不要在代码、README、SQL 里硬编码 secret key / service_role key / API Key。
- 提交前确认不包含个人邮箱、真实姓名、手机号等 PII；数据修复类 SQL 脚本若含真实账号，必须先脱敏成 `xxx@example.com` 占位符。

### 3. 技术栈纪律（不要引入新范式）

- 后端用 Python 标准库 `http.server`，不引入 Web 框架或 ORM。
- 前端用原生 HTML/CSS/JS 单文件，不引入框架或构建工具。
- 数据库用 Supabase（Postgres + Auth + Storage + Realtime），前端直连 `supabase-js`；AI 密钥类请求只走后端代理，浏览器不接触密钥。
- 保持「轻依赖」原则：新增第三方依赖前先评估是否真的必要。

## 架构速览

- 后端：`web_app.py`（约 875 行）——静态文件服务 + AI 代理 + 鉴权 + 反向地理编码。
- 前端（均为原生 JS 单文件）：
  - `index.html`——巡查办理台（案件录入、处置闭环、台账、照片 AI）。
  - `command-center.html`——领导驾驶舱（城市一张图、态势研判、AI 评测）。
- 数据库：Supabase，18 张业务表，全部启用 RLS。
- AI：
  - 照片识别：视觉模型（默认 `qwen3-vl-plus`），支持 `openai` / `dashscope` / `compatible` 三种供应商。
  - 态势研判：文本模型（默认 `qwen3.7-plus`），当前仅支持 `dashscope`。
- 地图：Leaflet 1.9.4（`vendor/` 本地依赖）+ 高德 AMap JS API 2.0（可选，加载失败自动降级 Leaflet + OSM）。
- 部署：Render（`render.yaml`），Python 3.13.5，HTTPS。
- PWA：`manifest.json` + `service-worker.js`。

## 本地运行

```bash
python3 web_app.py                      # 浏览器版（主要入口）
python3 web_app.py --test-ai [图片]     # 测试照片 AI 后退出
python3 web_app.py --test-situation-ai  # 测试态势研判 AI 后退出
python3 app.py                          # 早期 Tkinter 桌面版（已边缘化）
```

首次运行前：

```bash
cp .env.example .env                          # 填真实 AI 密钥
cp supabase-config.example.js supabase-config.js  # 填 Supabase 公开配置
cp amap-config.example.js amap-config.js      # 可选，高德地图
```

## 后端接口（web_app.py）

| 方法 | 路径 | 鉴权 | 作用 |
|---|---|---|---|
| GET | `/healthz` | 无 | 健康检查 |
| GET | `/supabase-config.js` | 无 | 注入 Supabase 公开配置 |
| GET | `/amap-config.js` | 无 | 注入高德公开配置 |
| GET | `/api/situation-models` | 管理员 | 返回开放的态势研判模型名单 |
| POST | `/api/analyze-photo` | 登录用户 | 照片 AI 识别代理 |
| POST | `/api/analyze-situation` | 管理员 | 态势 AI 研判代理 |
| POST | `/api/reverse-geocode` | 登录用户 | 坐标反查道路名（Nominatim OSM） |

## 数据库表（18 张）

- 核心业务：`inspection_records`、`inspection_updates`、`inspection_attachments`
- 账号：`profiles`
- 国标目录：`issue_dictionary`、`management_components`、`management_matters`、`component_attribute_definitions`、`matter_attribute_definitions`
- 案件配置：`handling_departments`、`unit_grids`
- AI 留痕：`ai_task_runs`、`ai_task_reviews`
- 知识库：`urban_issue_knowledge`、`urban_issue_knowledge_terms`、`urban_issue_visual_features`、`urban_issue_confusions`、`urban_issue_match_logs`

## SQL 脚本执行顺序（首次部署）

1. 国标目录：`supabase-issue-dictionary.sql` → `supabase-issue-dictionary-v2.sql` → `supabase-gb47678.5-directory.sql`
2. 部件/事项与字段：`supabase-components-matters.sql`（已包含 `supabase-record-standard-fields.sql`）
3. 案件录入配置：`supabase-case-intake-config.sql`
4. AI 留痕：`supabase-ai-audit.sql`
5. 城管知识库：`supabase-urban-knowledge-base.sql`
6. 处置闭环：`supabase-workflow-v3.sql`
7. 账号与权限：`supabase-profile-bootstrap.sql`、`supabase-user-management.sql`、`supabase-assignees.sql`、`supabase-assignee-access.sql`、`supabase-assignee-field-protection.sql`
8. 数据同步：`supabase-photos.sql`、`supabase-attachments.sql`、`supabase-timeline.sql`、`supabase-realtime.sql`
9. 照片 AI 入库：`supabase-ai-analysis.sql`

> 完整说明以 README.md 为准；只读校验脚本（`*-check.sql`、`*-diagnosis.sql`）不会修改数据。

## 参考

- `README.md`：完整功能说明、运行方法、SQL 顺序、部署细节，是权威文档。
- `.env.example`：环境变量模板。
