#!/bin/sh
# ---------------------------------------------------------------------------
# 容器入口脚本：在 Python 进程启动前完成环境自检。
#
# 目标是「快速失败 + 可读报错」。原项目在缺少配置时会调用 input() 等待终端输入，
# 容器内没有 TTY，只会抛出 EOFError 并留下一屏 traceback，难以定位。这里改为
# 启动前校验，并以退出码 78（EX_CONFIG）明确告知是配置问题。
# ---------------------------------------------------------------------------
set -eu

log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() { printf '[entrypoint][ERROR] %s\n' "$*" >&2; exit 78; }

ENV_FILE="${ENV_FILE:-/app/data/.env}"
HEARTBEAT_FILE="${HEARTBEAT_FILE:-/app/data/.heartbeat}"

# --- 1. 挂载点自检 -------------------------------------------------------
# 宿主机上 .env 不存在时，Docker 会把「文件挂载」退化成「目录挂载」，
# 表现为 /app/data/.env 变成空目录，程序读不到任何配置。此处显式识别。
if [ -d "$ENV_FILE" ]; then
    die "$ENV_FILE 是一个目录而非文件。
    常见原因：宿主机上的 .env 不存在时被 Docker 自动创建为目录。
    处理方式：删除该目录，并在宿主机创建配置文件后重新启动。"
fi

DATA_DIR="$(dirname "$ENV_FILE")"
mkdir -p "$DATA_DIR" 2>/dev/null || true
if [ ! -w "$DATA_DIR" ]; then
    die "数据目录 $DATA_DIR 不可写。
    Linux 宿主机请执行：sudo chown -R 10001:10001 <宿主机 data 目录>"
fi

# --- 2. 首次运行生成配置文件 --------------------------------------------
# 让 Cookie 自动刷新（XianyuApis.update_env_cookies）能落盘，容器重建后不丢。
if [ ! -f "$ENV_FILE" ]; then
    log "未找到 $ENV_FILE，依据当前环境变量生成初始配置"
    : > "$ENV_FILE"
    for key in API_KEY COOKIES_STR MODEL_BASE_URL MODEL_NAME TOGGLE_KEYWORDS SIMULATE_HUMAN_TYPING; do
        eval "value=\${$key:-}"
        if [ -n "$value" ]; then
            printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
        fi
    done
fi

# --- 3. 提示词文件自检 ---------------------------------------------------
# 代码对每个角色先找 <name>.txt，找不到再回落 <name>_example.txt。
PROMPT_DIR="${PROMPT_DIR:-/app/prompts}"
for name in classify_prompt price_prompt tech_prompt default_prompt; do
    if [ ! -f "$PROMPT_DIR/$name.txt" ] && [ ! -f "$PROMPT_DIR/${name}_example.txt" ]; then
        die "缺少提示词文件：$PROMPT_DIR/$name.txt 或 $PROMPT_DIR/${name}_example.txt。
    请确认 ./prompts 目录已正确挂载，且包含四个 *_example.txt 模板。"
    fi
done

# --- 4. 必填配置校验 -----------------------------------------------------
read_env() {
    # 优先环境变量，其次配置文件
    eval "value=\${$1:-}"
    if [ -z "$value" ] && [ -f "$ENV_FILE" ]; then
        value="$(sed -n "s/^$1=//p" "$ENV_FILE" | head -n 1)"
    fi
    printf '%s' "$value"
}

API_KEY_VAL="$(read_env API_KEY)"
COOKIES_STR_VAL="$(read_env COOKIES_STR)"

case "$API_KEY_VAL" in
    "")
        die "API_KEY 未配置。请在 $ENV_FILE 中设置，或通过环境变量 API_KEY 传入。" ;;
    "默认使用通义千问,apikey通过百炼模型平台获取")
        die "API_KEY 仍为模板占位符，请替换为真实密钥（阿里云百炼或其他兼容 OpenAI 协议的模型平台）。" ;;
esac

case "$COOKIES_STR_VAL" in
    "")
        die "COOKIES_STR 未配置。请在 $ENV_FILE 中设置，或通过环境变量 COOKIES_STR 传入。" ;;
    "your_cookies_here")
        die "COOKIES_STR 仍为模板占位符。请在闲鱼网页版登录后，从浏览器开发者工具复制完整 Cookie。" ;;
esac

if [ ! -f "$HEARTBEAT_FILE" ]; then
    : > "$HEARTBEAT_FILE" 2>/dev/null || true
fi

log "配置校验通过，启动命令：$*"
exec "$@"
