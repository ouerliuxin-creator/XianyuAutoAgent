# Docker 部署指南

本文档描述如何以容器方式运行 XianyuAutoAgent，以及相比原版编排文件做了哪些修正。

---

## 1. 为什么原版 Docker 配置无法直接使用

仓库原有 `Dockerfile` / `docker-compose.yml` 存在以下问题，均已在本分支修复：

| # | 问题 | 影响 | 修复方式 |
|---|------|------|----------|
| 1 | `docker-compose.yml` 为 **UTF-16LE + BOM** 编码 | `docker compose` 的 YAML 解析器按 UTF-8 读取，通常直接报解析错误 | 转为 UTF-8 无 BOM |
| 2 | compose 使用 `image: shaxiu/xianyuautoagent:latest` 而非 `build: .` | 本地改动代码后无法生效，实际运行的是上游镜像 | 改为本地构建，镜像名 `xianyu-autoagent:local` |
| 3 | `./.env:/app/.env` 文件挂载 | 宿主机 `.env` 不存在时，Docker 会创建一个**同名目录**挂载进去，程序读不到配置且报错隐晦 | 配置迁移到 `./data/.env`，由入口脚本初始化并自检 |
| 4 | 代码中两处 `input()` | 容器内无 TTY，缺配置或触发风控时抛 `EOFError`，只剩 traceback | 增加非交互分支，以退出码 78 明确报错 |
| 5 | Cookie 自动刷新写回 `.env` | 若配置不在持久化卷内，容器重建后回到旧 Cookie，反复触发风控 | `.env` 位于 `./data` 卷，写回即持久化 |

另外补充了三项生产环境常用能力：非 root 运行、`dumb-init` 信号转发、基于心跳文件的 `HEALTHCHECK`。

---

## 2. 目录与数据布局

```
XianyuAutoAgent/
├── Dockerfile                 # 镜像定义（python:3.11-slim + 非 root）
├── docker-compose.yml         # 编排（本地 build + 健康检查 + 日志轮转）
├── docker/
│   ├── entrypoint.sh          # 启动前配置校验、生成 data/.env
│   └── healthcheck.py         # 心跳文件新鲜度探针
├── data/                      # ← 挂载卷，需持久化，勿提交到 Git
│   ├── .env                   # 配置（含刷新后的 Cookie）
│   ├── chat_history.db        # SQLite 会话历史
│   └── .heartbeat             # 健康检查心跳
└── prompts/                   # ← 只读挂载，改完重启容器即生效
```

---

## 3. 快速开始

### 3.1 准备配置

```bash
mkdir -p data
cp .env.example data/.env
```

编辑 `data/.env`，至少填写 `API_KEY` 与 `COOKIES_STR` 两项。

> 未填写时容器不会启动，日志会明确提示缺哪一项，并以退出码 78 结束。

### 3.2 构建并启动

```bash
docker compose up -d --build
```

### 3.3 查看状态与日志

```bash
docker compose ps            # STATUS 列应显示 (healthy)
docker compose logs -f       # 跟踪日志，Ctrl+C 退出不影响容器
```

### 3.4 停止与清理

```bash
docker compose down          # 停止并移除容器，data/ 卷保留
docker compose down -v       # 连卷一起删除（会丢失会话历史）
```

---

## 4. 配置项

容器通过环境变量注入的运行时参数（均在 `docker-compose.yml` 的 `environment` 段，可在宿主机 `.env` 中覆盖）：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `TZ` | `Asia/Shanghai` | 时区，影响日志时间戳 |
| `LOG_LEVEL` | `INFO` | 日志级别；排查问题可临时设 `DEBUG` |
| `SIMULATE_HUMAN_TYPING` | `False` | 是否模拟人工打字延迟 |
| `TOGGLE_KEYWORDS` | `。` | 人工接管切换关键词 |
| `HEARTBEAT_INTERVAL` | `15` | WebSocket 心跳间隔（秒） |
| `HEARTBEAT_TIMEOUT` | `5` | 心跳响应超时（秒） |
| `TOKEN_REFRESH_INTERVAL` | `3600` | Token 刷新间隔（秒） |
| `MANUAL_MODE_TIMEOUT` | `3600` | 人工接管超时（秒） |
| `MESSAGE_EXPIRE_TIME` | `300000` | 消息过期时间（毫秒） |
| `ENV_FILE` | `/app/data/.env` | 配置文件路径，一般无需修改 |
| `HEARTBEAT_FILE` | `/app/data/.heartbeat` | 心跳文件路径，一般无需修改 |

**`API_KEY` 与 `COOKIES_STR` 刻意不通过 `environment` 注入。**
原因：`load_dotenv()` 默认不覆盖已存在的环境变量。若二者由容器环境变量提供，
Cookie 刷新后写入文件的新值会被启动时的旧值覆盖，重启后依旧使用过期 Cookie，
进而反复触发风控。二者统一由 `data/.env` 承载即可闭环。

---

## 5. 常见问题

### 5.1 容器反复重启

```bash
docker compose logs --tail=50
```

按日志定位：

- 退出码 `78` 且提示 `API_KEY`/`COOKIES_STR`：配置未填或仍是占位符；
- 日志出现 `触发风控 RGV587_ERROR`：Cookie 已失效。进入闲鱼网页版 → 点击消息 → 通过滑块 → 重新复制 Cookie 写入 `data/.env`，然后 `docker compose restart`；
- 日志出现 `Login失败` / `Cookie已失效`：同上。

### 5.2 状态一直为 `starting` 或 `unhealthy`

`HEALTHCHECK` 依据 `/app/data/.heartbeat` 的修改时间判断。启动后 90 秒内（`start_period`）不计入失败，
之后若心跳超过 180 秒未更新则标记 unhealthy。常见原因：

- 容器内网络无法访问 `wss-goofish.dingtalk.com`（检查宿主机代理/防火墙）；
- Cookie 失效导致连接建立失败。

### 5.3 Linux 宿主机权限报错

容器以 uid/gid `10001` 运行，绑定挂载的宿主目录需可写：

```bash
sudo chown -R 10001:10001 ./data
```

Windows / macOS 的 Docker Desktop 会自动处理映射，通常无需该步骤。

### 5.4 修改提示词后未生效

`prompts/` 为只读挂载，编辑宿主机文件后重启容器即可：

```bash
docker compose restart
```

代码同时支持运行时热重载（`XianyuReplyBot.reload_prompts`），但需通过外部信号触发，
常规做法仍是重启容器。

### 5.5 想在容器内手动输入新 Cookie

不支持。容器的标准输入不是 TTY，程序会直接以退出码 78 退出。
这是刻意设计：无人值守场景不应依赖交互输入。请修改 `data/.env` 后重启。

---

## 6. 仅用 Docker、不用 Compose

```bash
docker build -t xianyu-autoagent:local .

docker run -d \
  --name xianyu-autoagent \
  --restart unless-stopped \
  -e TZ=Asia/Shanghai \
  -e LOG_LEVEL=INFO \
  -v "$(pwd)/data:/app/data" \
  -v "$(pwd)/prompts:/app/prompts:ro" \
  xianyu-autoagent:local
```

---

## 7. 推送到自己的 GitHub 仓库

```bash
git remote remove origin
git remote add origin https://github.com/<你的用户名>/<仓库名>.git
git push -u origin main
```

> 本机若配置了 `url.insteadOf` 代理重写（`gh-proxy.com`），推送会失败。
> 可临时绕过：
> `git -c url."https://github.com/".insteadOf= push -u origin main`

首次创建远程仓库时，若远端已有 `README.md`，先 `git pull --rebase origin main` 再推送。
