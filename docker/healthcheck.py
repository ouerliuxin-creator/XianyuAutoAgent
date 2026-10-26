#!/usr/bin/env python3
"""容器健康检查探针。

判定依据是心跳文件的新鲜度：进程存活但 WebSocket 假死（收不到心跳响应）时，
心跳文件不再更新，从而被 Docker / 编排系统判定为 unhealthy 并触发重启。

退出码：0 = healthy，1 = unhealthy（Docker 约定）。
"""
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

# 心跳间隔默认 15s，超过 3 个周期未更新即视为异常，留足网络抖动余量。
DEFAULT_MAX_AGE = 180


def main() -> int:
    path = Path(os.getenv("HEARTBEAT_FILE", "/app/data/.heartbeat"))
    try:
        max_age = int(os.getenv("HEALTHCHECK_MAX_AGE", str(DEFAULT_MAX_AGE)))
    except ValueError:
        max_age = DEFAULT_MAX_AGE

    if not path.exists():
        print(f"unhealthy: 心跳文件不存在: {path}")
        return 1

    age = time.time() - path.stat().st_mtime
    if age > max_age:
        print(f"unhealthy: 心跳已停滞 {age:.0f}s（阈值 {max_age}s）")
        return 1

    print(f"healthy: 心跳延迟 {age:.0f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
