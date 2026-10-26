# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# XianyuAutoAgent —— 容器化运行镜像
#
# 设计要点：
#   1. 基础镜像使用 Debian slim（glibc）而非 Alpine（musl）。openai / pydantic-core
#      等依赖的 manylinux wheel 覆盖度更高，可避免构建期触发源码编译（需 gcc/rust）。
#   2. 以非 root 用户（uid/gid 10001）运行，降低容器逃逸风险。
#   3. 使用 dumb-init 作为 PID 1，正确转发 SIGTERM，使 `docker compose down`
#      能快速终止进程，避免等待 10 秒超时后 SIGKILL。
#   4. 配置、数据库、心跳文件统一落在 /app/data 卷内，容器重建不丢数据。
#   5. HEALTHCHECK 依据心跳文件新鲜度判断，连接假死可被编排系统感知。
# ---------------------------------------------------------------------------
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    ENV_FILE=/app/data/.env \
    HEARTBEAT_FILE=/app/data/.heartbeat \
    NON_INTERACTIVE=1 \
    LOG_LEVEL=INFO

# tzdata: 保证日志时间戳为东八区；dumb-init: 信号转发
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends tzdata dumb-init; \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime; \
    echo "$TZ" > /etc/timezone; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 依赖层单独 COPY，源码变更时可命中缓存
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# 非 root 运行账户
RUN set -eux; \
    groupadd --gid 10001 app; \
    useradd --uid 10001 --gid app --create-home --shell /bin/false app

COPY main.py XianyuAgent.py XianyuApis.py context_manager.py ./
COPY utils/ ./utils/
COPY prompts/ ./prompts/
COPY .env.example ./.env.example
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/healthcheck.py /usr/local/bin/healthcheck.py

RUN set -eux; \
    chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.py; \
    mkdir -p /app/data; \
    chown -R app:app /app

USER app

VOLUME ["/app/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD ["python", "/usr/local/bin/healthcheck.py"]

ENTRYPOINT ["dumb-init", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["python", "main.py"]
