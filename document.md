**技术方案与分工文档（Flutter Reader 问答 AI）**
- 项目栈：Flutter 前端（`flutter_reader`）+ FastAPI 后端（`server`）+ 对象存储（COS/MinIO，可选）+ LLM（Zhipu/OpenAI，可选）。
- 示例后端地址：`API_BASE_URL=http://124.221.177.174:8000`。

**整体架构**
- 前端：Flutter Web/移动端，通过 `API_BASE_URL` 调用后端；在伴读模式下随阅读位置传入 `position`。
- 后端：FastAPI 提供认证、预签名上传/下载、AI 语料生成（切片）、上下文问答接口。
- 存储：COS（推荐）或 MinIO 用于书籍原文与切片语料存储；本地开发可先用内置数据目录。
- LLM：Zhipu 或 OpenAI 提供模型推理，后端抽象了“快速/专业”双模型接口，可根据场景切换。

**关键流程**
- 登录与鉴权：用户通过邮件验证码注册并登录；客户端持 `accessToken` 调用鉴权接口。
- 云上传与预签名：前端请求后端生成预签名 URL，将书籍文件 PUT 到对象存储。
- 语料生成（`/ai/ingest`）：后端下载原文、抽取文本、切片为 `chunks.jsonl`，生成摘要；用于后续问答检索。
- 上下文问答（`/ai/query`）：前端传入问题与当前阅读位置；后端根据阅读进度在“目前为止的文本”范围内选取上下文，调用 LLM 返回答案。

**接口规范**
- 认证相关
  - `POST /auth/request-code`：申请验证码（开发环境返回 `devCode`）。
  - `POST /auth/register`：注册并返回令牌。
  - `POST /auth/login` / `POST /auth/login-code`：登录并返回令牌。
  - `POST /auth/refresh`：刷新令牌。
  - `GET /auth/me`：查询当前用户。
- 存储预签名
  - `POST /storage/presign/put`：生成上传 URL。请求体：`{ "key": "books/<bookId>.<ext>", "contentType": "..." }`。
  - `GET /storage/presign/get?key=<对象键>`：生成下载 URL。
- 语料生成
  - `POST /ai/ingest`：触发书籍语料生成。请求体：`{ "bookId": "...", "fileType": "epub|txt|pdf" }`。
- 上下文问答
  - `POST /ai/query`：根据当前进度回答问题。请求体：
    - `bookId`：书籍标识。
    - `question`：问题文本。
    - `position`：当前阅读位置（字符索引/偏移，与切片的 `start`/`end` 同尺度）。
    - `companionMode`：是否启用“伴读”，启用后仅用“目前为止的文本”作为检索范围。
  - 响应：`{ "answer": "...", "citations": [ { "chunkId": "...", "text": "...", "range": [start,end] } ], "model": "...", "usedCompanionMode": true }`。

**数据结构**
- 书籍原文：`books/<bookId>.<ext>`。
- 切片语料：`books/<bookId>/chunks.jsonl`，每行一个 JSON：
  - 典型字段：`{ "id": "<chunkId>", "start": <charIndex>, "end": <charIndex>, "text": "<片段文本>", "title": "<可选章标题>" }`。
- 摘要：`books/<bookId>/summary.txt`（可选，用于快速预览）。
- 定位规则：`position` 与 `chunk.start/end` 同尺度，伴读模式下仅选择 `end <= position` 的片段作为候选上下文。

**前端配置与集成**
- 运行开发模式（固定端口与后端默认 CORS 对齐）：  
  - `flutter run -d chrome --web-port 55119 --dart-define API_BASE_URL=http://124.221.177.174:8000`
- 启用云同步（导入后自动上传并触发 `/ai/ingest`）：  
  - 在上面命令追加 `--dart-define ENABLE_CLOUD_SYNC=true`
- 传递阅读位置与伴读开关：
  - 在提问时，`ai_service.dart` 会构造请求至 `/ai/query`，确保参数包括 `bookId`、`question`、`position`、`companionMode`。
- CORS 来源：后端 `.env` 的 `CORS_ORIGINS` 要包含前端来源（如 `http://localhost:55119`），否则浏览器会拦截跨域。

**后端环境与配置（`server/.env`）**
- 基础参数
  - `SECRET_KEY=<随机字符串>`
  - `DATA_DIR=/opt/flutter_reader/server/data`
  - `CORS_ORIGINS=http://localhost:55119,http://127.0.0.1:55119`
- 存储后端（任选其一）
  - COS：`STORAGE_BACKEND=cos`、`COS_BUCKET`、`COS_REGION`、`COS_SECRET_ID`、`COS_SECRET_KEY`、`COS_SCHEME=https`、`STORAGE_URL_EXPIRES=600`
  - MinIO：`STORAGE_BACKEND=minio`、`STORAGE_ENDPOINT`、`STORAGE_BUCKET`、`STORAGE_ACCESS_KEY`、`STORAGE_SECRET_KEY`、`STORAGE_REGION`、`STORAGE_SECURE=true|false`
- LLM 提供商（可后期开启）
  - `LLM_PROVIDER=<zhipu|openai|none>`、`GLM_API_KEY` 或 `OPENAI_API_KEY`
  - `LLM_MODEL_FAST`、`LLM_MODEL_PRO`、`LLM_MAX_INPUT_TOKENS`、`LLM_MAX_OUTPUT_TOKENS`

**部署与运维**
- 开发模式：  
  - 安装依赖：`pip install -r server/requirements.txt`  
  - 启动后端：`uvicorn server.main:app --host 0.0.0.0 --port 8000`  
  - 安全组：开放 `8000` 端口（建议只开放给开发机 IP）。
- 生产模式（域名 + HTTPS + 反向代理）
  - 绑定域名至服务器公网 IP，配置证书（Let’s Encrypt）。
  - Nginx 反向代理 `https://api.your-domain.com` → `http://127.0.0.1:8000`（参考 `server/deploy/nginx.conf.example`）。
  - 进程托管：systemd 服务，`ExecStart` 使用 `uvicorn server.main:app --host 127.0.0.1 --port 8000`。
  - 日志：`journalctl -u flutter-reader-api -f` 与 Nginx 访问/错误日志。

**伴读问答策略（目前为止的文本）**
- 基线策略：在伴读模式下，检索集合限制为 `end <= position` 的片段，从中选取若干最相关片段作为上下文。
- 相关性选择：可使用关键字匹配、BM25、或向量检索（后续可选）进行打分；控制总上下文 token 不超过 `LLM_MAX_INPUT_TOKENS`。
- 提示词设计：系统提示约束回答必须基于引用片段，避免越权猜测；模型选择“快速/专业”根据问题复杂度自动或手动切换。
- 引用返回：响应包含 `citations`，便于前端在 UI 中高亮引用来源。

**分工与里程碑**
- 前端工程
  - 接入认证与令牌管理，完善登录/注册流程。
  - 集成云上传与 `/ai/ingest` 调用，展示处理进度与错误提示。
  - 在阅读器中维护当前 `position`，提问时传入 `companionMode=true` 与 `position`。
  - 渲染回答与引用片段，提供“仅基于已读内容”开关。
- 后端工程
  - 完成 `/storage/presign`、`/ai/ingest`、`/ai/query` 的稳定实现与错误处理。
  - 语料切片与元数据（`start/end`）计算；限流与重试。
  - CORS、认证与令牌刷新；日志与结构化错误返回。
- AI 工程
  - 设计检索策略（基线关键字/简单相似度 → 向量检索可选）。
  - 提示词模板与模型参数调优；答案结构化（引用、局限说明）。
  - 评测用例与线下基准，度量准确率与幻觉率。
- 运维工程
  - 部署与监控：Nginx + systemd，日志收集与告警。
  - 密钥管理与滚动；安全组与 HTTPS。
  - 对象存储桶策略与生命周期管理。

**验收标准**
- 书籍导入后，能生成 `chunks.jsonl`，前端显示“已生成语料”。
- 在伴读模式下提问，回答仅依据“目前为止的文本”范围，返回至少 1 条有效引用。
- 常见错误（未登录、CORS、存储未配置、模型未配置）均有明确用户提示。
- 端到端延迟满足目标（如 <3s 快速问答，<10s 专业问答）。

**测试与验证**
- 鉴权：注册、登录、刷新令牌流程正常。
- 存储：预签名 PUT/GET 测试能读写 `books/test.txt`。
- 语料生成：导入书籍后 `/ai/ingest` 成功，生成 `chunks.jsonl`。
- 伴读问答：在不同 `position` 下，回答变化与引用范围符合预期。
- 前端 CORS：前端来源在 `CORS_ORIGINS` 白名单内，浏览器无跨域报错。

**安全与合规**
- 生产环境使用 HTTPS；限制安全组来源 IP。
- 不将密钥与 `SECRET_KEY` 入库；使用环境变量或密钥管理。
- 日志不含敏感文本；可用采样与脱敏策略。
- 限流与基础防护，避免滥用与账单爆炸。

**常见问题与排错**
- CORS 报错：在 `server/.env` 添加真实前端来源，重启后端。
- 501 未启用云存储：`STORAGE_BACKEND` 未配置为 `cos|minio`。
- 403 权限错误：COS 桶/区域/密钥不匹配或策略未开放预签名访问。
- 模型错误：`LLM_PROVIDER` 或 API Key 未配置；先运行“快速”本地开发路径。

**附录：示例命令**
- 开发运行前端：  
  - `flutter run -d chrome --web-port 55119 --dart-define API_BASE_URL=http://124.221.177.174:8000`
- 申请验证码并注册：  
  - `curl -s -X POST http://124.221.177.174:8000/auth/request-code -H "Content-Type: application/json" -d "{\"email\":\"you@example.com\",\"password\":\"\"}"`
  - `curl -s -X POST http://124.221.177.174:8000/auth/register -H "Content-Type: application/json" -d "{\"email\":\"you@example.com\",\"password\":\"secret123\",\"name\":\"you\",\"code\":\"<devCode>\"}"`
- 预签名上传与下载：  
  - `curl -s -X POST http://124.221.177.174:8000/storage/presign/put -H "Authorization: Bearer <accessToken>" -H "Content-Type: application/json" -d "{\"key\":\"books/test.txt\",\"contentType\":\"text/plain\"}"`
  - `curl -X PUT -H "Content-Type: text/plain" --data-binary "hello storage" "<url>"`
  - `curl -s "http://124.221.177.174:8000/storage/presign/get?key=books/test.txt" -H "Authorization: Bearer <accessToken>"`
