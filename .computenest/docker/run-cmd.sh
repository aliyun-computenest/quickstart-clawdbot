#!/bin/bash
# OpenClaw 社区版（计算巢）宿主机运维入口
#
# 部署物构建期会把本脚本软链到 /opt/.swas/run-cmd.sh，保持与原 SWAS 镜像一致的命令面
# （config / set-channel / restart / get-token / get-url），因此 3 个 OOS 自定义运维操作
# 与"选择ECS"模板无需改动即可复用。
#
# 所有配置改写都在宿主机侧用 jq 完成，写临时文件后 rename，天然原子，
# 不再需要 `openclaw config set` 的乐观锁重试。
#
# 用法：
#   run-cmd.sh init                              初始化数据目录、生成 gateway token 与基础配置
#   run-cmd.sh config <apiKey> [domestic|intl]   写入百炼 API Key 与 baseUrl
#   run-cmd.sh set-channel <type> <id> <secret>  配置渠道，type: dingtalk|wecom|qqbot
#   run-cmd.sh set-model <provider/model>        切换默认模型
#   run-cmd.sh set-skills-dir [containerDir]     把 Skills 目录写入 skills.load.extraDirs
#   run-cmd.sh enable-plugins                    仅加载 3 个渠道插件（构建期冒烟测试用）
#   run-cmd.sh start | stop | restart | status | logs
#   run-cmd.sh wait-ready [timeoutSeconds]       等待 gateway 端口就绪
#   run-cmd.sh seed-data                         用镜像内的初始内容重建数据目录（会清空现有数据）
#   run-cmd.sh reset [apiKey] [domestic|intl]    重置为初始状态并重新拉起（保留访问令牌）
#   run-cmd.sh get-token                         输出 gateway 访问令牌
#   run-cmd.sh get-url                           输出访问地址与令牌

# 允许被 `sh run-cmd.sh ...` 调用（OOS 模板里就是这么写的），不依赖 sh 恰好是 bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi

set -euo pipefail

APP_DIR=/opt/openclaw
DATA_DIR="$APP_DIR/data"
CONFIG_FILE="$DATA_DIR/openclaw.json"
TOKEN_FILE="$DATA_DIR/.gateway_token"
COMPOSE_FILE="$APP_DIR/docker-compose.yaml"
SERVICE_NAME=openclaw
GATEWAY_PORT=18789

# 容器内的配置目录，宿主机 $DATA_DIR 即挂载到此路径。写进配置文件的路径必须用容器视角。
CONTAINER_CONFIG_DIR=/home/node/.openclaw

# 可用 OPENCLAW_MODEL 环境变量覆盖，便于后续换代不必重刷镜像
DEFAULT_MODEL="${OPENCLAW_MODEL:-bailian/qwen3.8-max}"
BASE_URL_DOMESTIC="https://dashscope.aliyuncs.com/compatible-mode/v1"
BASE_URL_INTL="https://dashscope-intl.aliyuncs.com/compatible-mode/v1"

# 构建期写入的镜像元信息：OPENCLAW_UID / OPENCLAW_GID / OPENCLAW_BASE_DIGEST
if [ -f "$APP_DIR/image.env" ]; then
  # shellcheck disable=SC1091
  . "$APP_DIR/image.env"
fi
RUN_UID="${OPENCLAW_UID:-1000}"
RUN_GID="${OPENCLAW_GID:-1000}"

compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

# ---------------------------------------------------------------------------
# 配置读写
# ---------------------------------------------------------------------------

# 从 stdin 读入完整 JSON，校验后原子落盘
write_config() {
  local tmp
  tmp=$(mktemp "$DATA_DIR/.openclaw.json.XXXXXX")
  cat > "$tmp"
  if ! jq -e . "$tmp" > /dev/null 2>&1; then
    echo "ERROR: 生成的配置不是合法 JSON，已放弃写入" >&2
    rm -f "$tmp"
    exit 1
  fi
  chown "$RUN_UID:$RUN_GID" "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$CONFIG_FILE"
}

# edit_config <jq-filter> [jq 选项...]
edit_config() {
  local filter="$1"
  shift
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: $CONFIG_FILE 不存在，请先执行 run-cmd.sh init" >&2
    exit 1
  fi
  jq "$@" "$filter" "$CONFIG_FILE" | write_config
}

cmd_init() {
  mkdir -p "$DATA_DIR/workspace" "$DATA_DIR/computenest-skillhub-skills"

  if [ ! -s "$TOKEN_FILE" ]; then
    openssl rand -hex 24 > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
  fi
  local token
  token=$(cat "$TOKEN_FILE")

  if [ -f "$CONFIG_FILE" ]; then
    # 已初始化过：只补齐 gateway 段，不覆盖用户在控制台上的其他改动
    edit_config '
      .gateway.mode = "local"
      | .gateway.port = 18789
      | .gateway.bind = "lan"
      | .gateway.auth = { mode: "token", token: $token }
    ' --arg token "$token"
  else
    jq -n \
      --arg token "$token" \
      --arg model "$DEFAULT_MODEL" \
      --arg baseUrl "$BASE_URL_DOMESTIC" \
      --arg workspace "$CONTAINER_CONFIG_DIR/workspace" \
      '{
        agents: {
          defaults: {
            model: { primary: $model },
            workspace: $workspace
          }
        },
        models: {
          mode: "merge",
          providers: {
            bailian: {
              baseUrl: $baseUrl,
              apiKey: "",
              api: "openai-completions",
              models: []
            }
          }
        },
        commands: {
          native: "auto",
          nativeSkills: "auto",
          restart: true
        },
        gateway: {
          # mode 必填。缺了它新版 gateway 会判定配置被篡改并拒绝启动：
          # "Gateway start blocked: existing config is missing gateway.mode"
          mode: "local",
          port: 18789,
          bind: "lan",
          http: { endpoints: { chatCompletions: { enabled: true } } },
          controlUi: {
            allowedOrigins: ["*"],
            dangerouslyAllowHostHeaderOriginFallback: true,
            allowInsecureAuth: true
          },
          auth: { mode: "token", token: $token }
        },
        plugins: { entries: {} },
        channels: {}
      }' | write_config
  fi

  chown -R "$RUN_UID:$RUN_GID" "$DATA_DIR"
}

cmd_config() {
  local api_key="${1:-}"
  local site="${2:-domestic}"
  if [ -z "$api_key" ]; then
    echo "ERROR: 缺少百炼 API Key" >&2
    exit 1
  fi
  local base_url="$BASE_URL_DOMESTIC"
  if [ "$site" != "domestic" ]; then
    base_url="$BASE_URL_INTL"
  fi
  edit_config '
    .models.mode = "merge"
    | .models.providers.bailian.api = "openai-completions"
    | .models.providers.bailian.baseUrl = $baseUrl
    | .models.providers.bailian.apiKey = $key
    | .models.providers.bailian.models = (.models.providers.bailian.models // [])
    | .agents.defaults.model.primary = (
        if ((.agents.defaults.model.primary // "") == "") then $model
        else .agents.defaults.model.primary end
      )
  ' --arg key "$api_key" --arg baseUrl "$base_url" --arg model "$DEFAULT_MODEL"
  echo "INFO: 已写入百炼 API Key（site=${site}）"
}

cmd_set_model() {
  local model="${1:-}"
  if [ -z "$model" ]; then
    echo "ERROR: 缺少模型名，格式 provider/model" >&2
    exit 1
  fi
  edit_config '.agents.defaults.model.primary = $model' --arg model "$model"
  echo "INFO: 默认模型已切换为 $model"
}

# 渠道类型 -> 插件包名。plugins.entries 的 key 是插件包名，channels 的 key 由插件自身约定，
# 两者并不总是一致（钉钉两边都叫 dingtalk-connector，其余两个 channels key 是短名）。
plugin_of() {
  case "$1" in
    dingtalk)     echo "dingtalk-connector" ;;
    wecom)        echo "wecom-openclaw-plugin" ;;
    qqbot)        echo "openclaw-qqbot" ;;
    *)            return 1 ;;
  esac
}

cmd_set_channel() {
  local type="${1:-}" id="${2:-}" secret="${3:-}"
  local block plugin
  case "$type" in
    dingtalk)
      block=$(jq -n --arg id "$id" --arg secret "$secret" '{
        "dingtalk-connector": {
          enabled: true,
          clientId: $id,
          clientSecret: $secret,
          ackText: "任务已接收",
          groupSessionScope: "group",
          separateSessionByConversation: true,
          sharedMemoryAcrossConversations: false
        }
      }')
      ;;
    wecom)
      block=$(jq -n --arg id "$id" --arg secret "$secret" '{
        wecom: {
          enabled: true,
          connectionMode: "websocket",
          botId: $id,
          secret: $secret,
          streamPlaceholderContent: "正在思考...",
          welcomeText: "你好！我是 AI 助手",
          dm: { policy: "open" }
        }
      }')
      ;;
    qqbot|qq)
      type=qqbot
      block=$(jq -n --arg id "$id" --arg secret "$secret" '{
        qqbot: { enabled: true, appId: $id, clientSecret: $secret }
      }')
      ;;
    feishu|lark)
      # 飞书渠道暂时下线，原因见 Dockerfile 里 LARK_PLUGIN 处的说明：上游发布包缺 dist
      # 目录，插件无法被加载。这里宁可明确报错，也不能写下一份永远不会生效的渠道配置。
      # 上游修好后，把本分支恢复成原来的 feishu 配置块、并同步恢复 Dockerfile 与
      # plugin_of / enable-plugins / build.sh 冒烟清单里的 openclaw-lark 即可。
      echo "ERROR: 飞书渠道暂不可用（上游插件 @larksuite/openclaw-lark 发布产物缺少 dist，无法加载）" >&2
      exit 1
      ;;
    *)
      echo "ERROR: 不支持的渠道类型 '$type'，可选 dingtalk|wecom|qqbot" >&2
      exit 1
      ;;
  esac
  if [ -z "$id" ] || [ -z "$secret" ]; then
    echo "ERROR: 渠道 $type 缺少凭据参数" >&2
    exit 1
  fi
  plugin=$(plugin_of "$type")
  # 逐 key 覆盖，只更新目标渠道，已配置的其他渠道保持不变
  edit_config '
    .channels = ((.channels // {}) + $block)
    | .plugins.entries[$plugin] = { enabled: true }
  ' --argjson block "$block" --arg plugin "$plugin"
  echo "INFO: 渠道 ${type} 已配置（插件 ${plugin} 已启用）"
}

cmd_enable_plugins() {
  edit_config '
    .plugins.entries = ((.plugins.entries // {}) + {
      "dingtalk-connector": { enabled: true },
      "wecom-openclaw-plugin": { enabled: true },
      "openclaw-qqbot": { enabled: true }
    })
  '
  echo "INFO: 3 个渠道插件已置为加载状态"
}

cmd_set_skills_dir() {
  local dir="${1:-$CONTAINER_CONFIG_DIR/computenest-skillhub-skills/}"
  mkdir -p "$DATA_DIR/computenest-skillhub-skills"
  edit_config '
    .skills.load.extraDirs = ((.skills.load.extraDirs // []) | if index($dir) then . else . + [$dir] end)
    | .skills.load.watch = true
    | .skills.load.watchDebounceMs = 250
  ' --arg dir "$dir"
  chown -R "$RUN_UID:$RUN_GID" "$DATA_DIR/computenest-skillhub-skills"
  echo "INFO: 已配置 skills.load.extraDirs: $dir"
}

# ---------------------------------------------------------------------------
# 生命周期
# ---------------------------------------------------------------------------

cmd_start() {
  cmd_init
  compose up -d --remove-orphans
}

cmd_stop() {
  compose stop "$SERVICE_NAME"
}

cmd_restart() {
  cmd_init
  if [ -n "$(compose ps -q "$SERVICE_NAME" 2>/dev/null || true)" ]; then
    compose restart "$SERVICE_NAME"
  else
    compose up -d --remove-orphans
  fi
}

cmd_status() {
  compose ps
}

cmd_logs() {
  compose logs --tail "${1:-200}" "$SERVICE_NAME"
}

cmd_wait_ready() {
  local timeout="${1:-300}" waited=0 code
  # 这里不能只做 TCP 连接探测。compose 做了端口映射后，docker-proxy 在容器刚创建时
  # 就开始监听宿主端口，容器内进程即使在崩溃重启循环里，connect 一样会成功，
  # 于是 0 秒就误报「已就绪」。必须发真实 HTTP 请求、拿到状态码才算 gateway 在应答
  # （401 也算就绪，说明进程活着且鉴权已生效）。
  while [ "$waited" -lt "$timeout" ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
      "http://127.0.0.1:$GATEWAY_PORT/" 2>/dev/null || true)
    if [ -n "$code" ] && [ "$code" != "000" ]; then
      echo "INFO: OpenClaw gateway 已就绪（${waited}s，HTTP $code）"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  echo "ERROR: 等待 OpenClaw gateway 就绪超时（${timeout}s），近期日志：" >&2
  compose logs --tail 200 "$SERVICE_NAME" >&2 || true
  return 1
}

# ---------------------------------------------------------------------------
# 数据目录与重置
# ---------------------------------------------------------------------------

# 把镜像里 /home/node/.openclaw 的初始内容导出到宿主机数据目录。
# 直接 bind-mount 空目录会遮蔽镜像内烘好的 extensions 与 node_modules 软链，
# 因此数据目录必须先由镜像 seed 出来。构建期与重置操作共用这一份实现。
cmd_seed_data() {
  local image="${OPENCLAW_LOCAL_IMAGE:-openclaw-cn:latest}" cid
  rm -rf "$DATA_DIR"
  mkdir -p "$DATA_DIR"
  cid=$(docker create "$image")
  docker cp -a "$cid:$CONTAINER_CONFIG_DIR/." "$DATA_DIR/"
  docker rm -f "$cid" > /dev/null
  # 软链是绝对路径指向 /app，在宿主机上是断链，挂回容器后有效
  test -d "$DATA_DIR/extensions"
  test -L "$DATA_DIR/node_modules/openclaw"
  mkdir -p "$DATA_DIR/workspace" "$DATA_DIR/computenest-skillhub-skills"
  chown -R "$RUN_UID:$RUN_GID" "$DATA_DIR"
  echo "INFO: 数据目录已由镜像 $image 重建，扩展：$(ls -1 "$DATA_DIR/extensions" | tr '\n' ' ')"
}

# 重置到初始状态：清空配置、会话、工作区与已安装的 Skills。
# 不再更换系统盘（Docker 化后镜像内容就在本地），因此也不需要实例密码，
# 重置耗时从分钟级降到秒级。访问令牌会被保留，用户已保存的控制台链接继续可用。
cmd_reset() {
  local api_key="${1:-}" site="${2:-domestic}" token=""
  if [ -f "$TOKEN_FILE" ]; then
    token=$(cat "$TOKEN_FILE")
  elif [ -f "$CONFIG_FILE" ]; then
    token=$(jq -r '.gateway.auth.token // empty' "$CONFIG_FILE")
  fi

  # 先停掉容器，避免它继续往即将被删除的数据目录里写
  compose down --remove-orphans || true

  cmd_seed_data

  if [ -n "$token" ]; then
    printf '%s\n' "$token" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    chown "$RUN_UID:$RUN_GID" "$TOKEN_FILE"
  fi

  cmd_init
  if [ -n "$api_key" ]; then
    cmd_config "$api_key" "$site"
  fi
  compose up -d --remove-orphans
  cmd_wait_ready 600
  echo "INFO: OpenClaw 已重置完成。此前通过 SkillHub 安装的 Skills 需重新执行「变更Skill配置」。"
}

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------

cmd_get_token() {
  if [ -f "$CONFIG_FILE" ]; then
    jq -r '.gateway.auth.token // empty' "$CONFIG_FILE"
  elif [ -f "$TOKEN_FILE" ]; then
    cat "$TOKEN_FILE"
  fi
}

instance_ip() {
  local ip
  ip=$(curl -sf -m 3 http://100.100.100.200/latest/meta-data/eipv4 2>/dev/null || true)
  if [ -z "$ip" ]; then
    ip=$(curl -sf -m 3 http://100.100.100.200/latest/meta-data/private-ipv4 2>/dev/null || true)
  fi
  echo "$ip"
}

cmd_get_url() {
  local ip token
  ip=$(instance_ip)
  token=$(cmd_get_token)
  echo "控制台地址: http://${ip}:${GATEWAY_PORT}"
  echo "访问令牌: ${token}"
}

# ---------------------------------------------------------------------------
# 入口分发
# ---------------------------------------------------------------------------

case "${1:-}" in
  init)            shift; cmd_init "$@" ;;
  config)          shift; cmd_config "$@" ;;
  set-model)       shift; cmd_set_model "$@" ;;
  set-channel)     shift; cmd_set_channel "$@" ;;
  enable-plugins)  shift; cmd_enable_plugins "$@" ;;
  set-skills-dir)  shift; cmd_set_skills_dir "$@" ;;
  start)           shift; cmd_start "$@" ;;
  stop)            shift; cmd_stop "$@" ;;
  restart)         shift; cmd_restart "$@" ;;
  status)          shift; cmd_status "$@" ;;
  logs)            shift; cmd_logs "$@" ;;
  wait-ready)      shift; cmd_wait_ready "$@" ;;
  seed-data)       shift; cmd_seed_data "$@" ;;
  reset)           shift; cmd_reset "$@" ;;
  get-token)       shift; cmd_get_token "$@" ;;
  get-url)         shift; cmd_get_url "$@" ;;
  ""|help|-h|--help)
    sed -n '/^# 用法：/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "ERROR: 未知子命令 '$1'，执行 run-cmd.sh help 查看用法" >&2
    exit 1
    ;;
esac
