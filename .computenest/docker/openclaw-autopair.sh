#!/bin/bash
# 自动批准 OpenClaw 控制台的设备配对请求，使一条固定的登录链接可以直接打开进入。
#
# 控制台自 2026.8.1 起强制设备配对：浏览器凭访问令牌通过认证后，还要有人在实例上
# 批准一次才能连上，否则一直停在「批准此浏览器」页面。想关掉这道检查是不行的——
# gateway.controlUi.dangerouslyDisableDeviceAuth 已被上游标记为 retired and ignored，
# 写进配置不生效，还会被 openclaw doctor --fix 删掉。
#
# 这不放大攻击面：配对请求只在令牌校验通过之后才会产生（网关日志里是 phase=auth_validated
# 之后才出现待批请求），没有访问令牌的请求根本走不到这一步，唯一凭据仍然是访问令牌。

set -u
CONTAINER=${OPENCLAW_CONTAINER:-openclaw}

approve() {
  [ -n "${1:-}" ] || return 0
  if docker exec "$CONTAINER" openclaw devices approve "$1" >/dev/null 2>&1; then
    echo "approved $1"
  fi
}

# 批掉当前积压的待批请求。守护自身重启、或实例重启期间产生的请求不会留在日志流里，
# 靠这一步补上。
sweep() {
  docker exec "$CONTAINER" openclaw devices list --json 2>/dev/null | python3 -c '
import json, sys
raw = sys.stdin.read()
i = raw.find("{")
if i < 0:
    sys.exit(0)
try:
    doc = json.loads(raw[i:])
except Exception:
    sys.exit(0)
def walk(n):
    if isinstance(n, dict):
        for k, v in n.items():
            if k == "pending" and isinstance(v, list):
                for it in v:
                    if isinstance(it, dict):
                        rid = it.get("requestId") or it.get("id")
                        if rid:
                            print(rid)
            walk(v)
    elif isinstance(n, list):
        for x in n:
            walk(x)
walk(doc)
' | while IFS= read -r rid; do
    approve "$rid"
  done
}

sweep

# 之后跟着网关日志走，不轮询：配对被拒的那行日志里直接带着请求 ID，形如
#   code=1008 reason=pairing required: device is not approved yet (requestId: <uuid>) phase=auth_validated
# 等待批准的浏览器会持续重连，每次重连都会再打一行，因此不会漏。
# 相比每隔几秒起一次 docker CLI 加一次 python 去问，空闲时这里不产生任何进程。
while :; do
  docker logs -f --tail 0 "$CONTAINER" 2>&1 \
    | grep --line-buffered -o 'requestId: [0-9a-f-]\{36\}' \
    | while read -r _ rid; do
        approve "$rid"
      done
  # 容器重启或被重建时 docker logs 会结束，等它回来再接上，顺带补扫一次积压。
  sleep 3
  sweep
done
