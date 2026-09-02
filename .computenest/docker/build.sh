#!/bin/bash
# OpenClaw 社区版 —— EcsImage 部署物构建脚本
#
# 由计算巢托管构建在 cn-hongkong 的 ECS 上执行（基础镜像
# aliyun/services/computenest/images/aliyun_3_2104_docker_26 已预装 Docker 26）。
# 香港地域可直连 ghcr.io 与 npm，构建期把镜像与插件全部烘进系统盘，
# 运行期零外网依赖，规避 ghcr.io 在大陆不可达的问题。
set -euxo pipefail

APP_DIR=/opt/openclaw
REPO_URL="${REPO_URL:-https://github.com/aliyun-computenest/quickstart-clawdbot.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/openclaw/openclaw:latest}"
LOCAL_IMAGE=openclaw-cn:latest
SRC_DIR="${SRC_DIR:-/tmp/openclaw-src}"

# ── 1. 宿主机依赖 ──────────────────────────────────────────────────────────
# jq 用于配置改写，openssl 生成 gateway token，python3 用于 computenest-cli
dnf install -y git jq openssl python3 python3-pip

# 避免容器网段与用户 VPC 网段冲突；已有 daemon.json 时做合并而不是覆盖
mkdir -p /etc/docker
if [ -s /etc/docker/daemon.json ]; then
  jq '. + { "default-address-pools": [ { "base": "10.255.0.0/16", "size": 24 } ] }' \
    /etc/docker/daemon.json > /tmp/daemon.json
else
  echo '{ "default-address-pools": [ { "base": "10.255.0.0/16", "size": 24 } ] }' > /tmp/daemon.json
fi
mv /tmp/daemon.json /etc/docker/daemon.json
systemctl enable --now docker
systemctl restart docker

# ── 2. 拉取部署资产 ───────────────────────────────────────────────────────
# 调用方（部署物构建的 CommandContent）可能已经 clone 过一份并通过 SRC_DIR 传入，
# 此时直接复用，避免重复克隆
if [ -d "$SRC_DIR/.computenest/docker" ]; then
  echo "INFO: 复用已有源码目录 $SRC_DIR"
else
  rm -rf "$SRC_DIR"
  git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$SRC_DIR"
fi
mkdir -p "$APP_DIR"
cp -a "$SRC_DIR/.computenest/docker/." "$APP_DIR/"
chmod +x "$APP_DIR/run-cmd.sh"

# 保持与原 SWAS 镜像一致的入口路径，令 3 个 OOS 自定义运维操作与"选择ECS"模板零改动可用
mkdir -p /opt/.swas
ln -sfn "$APP_DIR/run-cmd.sh" /opt/.swas/run-cmd.sh

# ── 3. computenest-cli（Skills 安装用，沿用原镜像的 venv 路径）────────────
# Alibaba Cloud Linux 3 自带的 python3 版本偏低，computenest-cli 的依赖链装不上，
# 因此用 uv 独立装一份 Python 3.12。venv 路径保持 /opt/computenest-env 不变，
# 令 RunSkillsCommand 里的 `source /opt/computenest-env/bin/activate` 零改动。
export UV_NO_CACHE=1
export UV_PYTHON_INSTALL_MIRROR=https://mirrors.ustc.edu.cn/github-release/astral-sh/python-build-standalone
export UV_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/
UV_BIN="$HOME/.local/bin/uv"
if [ ! -x "$UV_BIN" ]; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$PATH"

uv python install 3.12
uv venv /opt/computenest-env --python 3.12
uv pip install --python /opt/computenest-env/bin/python computenest-cli
/opt/computenest-env/bin/computenest-cli skillhub install --help > /dev/null

# ── 4. 构建运行镜像 ───────────────────────────────────────────────────────
docker pull "$OPENCLAW_IMAGE"
docker build --build-arg OPENCLAW_IMAGE="$OPENCLAW_IMAGE" -t "$LOCAL_IMAGE" "$APP_DIR"

BASE_DIGEST=$(docker image inspect "$OPENCLAW_IMAGE" -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}')
IMAGE_UID=$(docker run --rm --entrypoint id "$LOCAL_IMAGE" -u)
IMAGE_GID=$(docker run --rm --entrypoint id "$LOCAL_IMAGE" -g)
cat > "$APP_DIR/image.env" <<EOF
OPENCLAW_LOCAL_IMAGE=$LOCAL_IMAGE
OPENCLAW_BASE_IMAGE=$OPENCLAW_IMAGE
OPENCLAW_BASE_DIGEST=$BASE_DIGEST
OPENCLAW_UID=$IMAGE_UID
OPENCLAW_GID=$IMAGE_GID
OPENCLAW_BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
cat "$APP_DIR/image.env"

# ── 5. 把镜像内 /home/node/.openclaw 预导出到宿主机，供 bind-mount 使用 ────
# seed 逻辑与「重置服务」运维操作共用 run-cmd.sh 的实现，避免两处维护。
"$APP_DIR/run-cmd.sh" seed-data

# ── 6. 冒烟测试 ───────────────────────────────────────────────────────────
# 跟随上游 latest 意味着插件与主程序的兼容性没有版本锁保证，构建期必须验证：
# gateway 能起来、3 个插件能被 Node 解析加载。任一失败则构建失败，不产出坏镜像。
"$APP_DIR/run-cmd.sh" init
"$APP_DIR/run-cmd.sh" config "sk-smoke-test-placeholder" domestic
# 只启用插件、不配置 channels：插件模块会被加载（验证 ESM 解析），但不会去连接外部平台
"$APP_DIR/run-cmd.sh" enable-plugins
"$APP_DIR/run-cmd.sh" start
"$APP_DIR/run-cmd.sh" wait-ready 600

sleep 20
docker compose -f "$APP_DIR/docker-compose.yaml" logs --no-color openclaw > /tmp/smoke.log
tail -300 /tmp/smoke.log
if grep -q "Cannot find module" /tmp/smoke.log; then
  echo "ERROR: 冒烟测试发现插件模块解析失败，请检查插件与 OpenClaw 版本兼容性" >&2
  exit 1
fi
# gateway 自查不通过时会拒绝启动并进入崩溃重启循环，端口照样通，只能靠日志识别。
if grep -q "Gateway start blocked" /tmp/smoke.log; then
  echo "ERROR: gateway 拒绝启动（配置被判定为不完整或被篡改），详见上方日志" >&2
  exit 1
fi
# 有插件初始化失败时 gateway 照样会正常监听端口，只在日志里留一行，必须显式拦。
if grep -q "plugin(s) failed to initialize" /tmp/smoke.log; then
  echo "ERROR: 有插件初始化失败：" >&2
  grep -E "plugin\(s\) failed to initialize|failed to load from" /tmp/smoke.log >&2
  exit 1
fi
# 只认 gateway 自己打印的已加载插件清单。不能全文 grep 插件名 —— 插件名同样会出现在
# 加载失败的报错行里，那样插件缺失也会被误判为通过（上一版就是这么放过一个坏镜像的）。
loaded=$(grep -o 'http server listening ([0-9]* plugins: [^)]*' /tmp/smoke.log \
  | tail -1 | sed 's/.*plugins: //' || true)
if [ -z "$loaded" ]; then
  echo "ERROR: 日志里没有 gateway 的已加载插件清单，无法确认插件状态" >&2
  exit 1
fi
echo "INFO: gateway 已加载插件：$loaded"
missing_plugins=""
for plugin in dingtalk-connector wecom-openclaw-plugin openclaw-qqbot; do
  # 清单形如 "a, b, c; 2.6s"，去空格并把分号也当分隔符，再做整词匹配
  case ",$(echo "$loaded" | tr -d ' ' | tr ';' ',')," in
    *",$plugin,"*) ;;
    *) missing_plugins="$missing_plugins $plugin" ;;
  esac
done
if [ -n "$missing_plugins" ]; then
  echo "ERROR: 以下渠道插件不在 gateway 的已加载清单中：$missing_plugins" >&2
  exit 1
fi
echo "INFO: 冒烟测试通过，gateway 与 3 个渠道插件均正常"

# ── 7. 清理，交付干净的镜像 ───────────────────────────────────────────────
docker compose -f "$APP_DIR/docker-compose.yaml" down --remove-orphans
"$APP_DIR/run-cmd.sh" seed-data
rm -rf "$SRC_DIR" /tmp/smoke.log /root/.cache/pip
docker image prune -f
# 以下为镜像交付前的清理与安全加固，与其他计算巢服务的镜像构建口径保持一致。
# 注意必须跑在上面 seed-data 之后：清理会清空 /tmp 与日志，先把数据目录坐实。

# ── 8. 账号与密码安全清理 ─────────────────────────────────────────────────
echo ">>> 开始清理用户账号与密码..."

exclude_users=("root" "admin")

# 锁定 root 和 admin 密码
sed -i 's/^\(root:\)[^:]*/\1!!/' /etc/shadow
sed -i 's/^\(admin:\)[^:]*/\1!!/' /etc/shadow

# 遍历所有用户，清理非排除用户
while IFS=: read -r username _ uid _ _ homedir user_shell; do
    # 跳过系统用户（UID < 1000，除 root/admin）
    if [[ $uid -lt 1000 ]] && [[ ! " ${exclude_users[*]} " =~ " $username " ]]; then
        continue
    fi

    # 检查 shell 是否为交互式 shell
    case "$user_shell" in
        */bash|*/sh|*/zsh)
            if [[ ! " ${exclude_users[*]} " =~ " $username " ]]; then
                # 检查密码是否已锁定（末尾 || true 必不可少：本脚本开了 pipefail，
                # 若用户不在 /etc/shadow 里 grep 会返回 1，直接把构建给终结掉）
                pass=$(grep "^${username}:" /etc/shadow | cut -d: -f2 || true)
                if [[ "$pass" == "!" || "$pass" == "!!" || "$pass" == *\!* || "$pass" == "*" ]]; then
                    echo "  -> 跳过已锁定用户: $username"
                    continue
                fi

                echo "  -> 删除用户: $username"
                userdel -r "$username" 2>/dev/null || true
                if [[ -d "$homedir" ]]; then
                    rm -rf "$homedir" 2>/dev/null || true
                fi
            fi
            ;;
    esac
done < /etc/passwd

# 清理 .DEL 结尾目录
while IFS=: read -r _ _ _ _ _ homedir user_shell; do
    case "$user_shell" in
        */bash|*/sh|*/zsh)
            if [[ -d "$homedir" ]]; then
                find "$homedir" -maxdepth 1 -type d -name '*.DEL' -exec rm -rf {} + 2>/dev/null || true
            fi
            ;;
    esac
done < /etc/passwd

# ── 9. 日志与缓存清理 ─────────────────────────────────────────────────────
echo ">>> 开始清理日志与缓存..."

rm -rf /var/log/anaconda/* \
       /var/log/ecsgo.log* \
       /var/log/cron-* \
       /var/log/btmp-* \
       /var/log/maillog-* \
       /var/log/messages-* \
       /var/log/secure-* \
       /var/log/spooler-* \
       /var/log/yum.log-* \
       /var/log/boot.log-* \
       /var/log/sa/* \
       /var/log/conman* \
       /var/log/journal/* \
       /var/log/cloud-init.log \
       /var/log/cloud-init-output.log

# 清空剩余日志文件内容（避免 inode 占用）
find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true

# 清理包管理缓存
if command -v dnf &> /dev/null; then
    dnf clean all
elif command -v yum &> /dev/null; then
    yum clean all
fi

# 清理其他残留
rm -rf /var/lib/yum/history/* \
       /var/lib/dnf/history* \
       /var/lib/dhclient/* \
       /var/lib/dhcp/* \
       /var/lib/aliyun_init/* \
       /var/lib/cloud/* \
       /tmp/* \
       /etc/ssh/sshd_config.d/*

# 清理阿里云辅助日志
if [[ -d /usr/local/share/aliyun-assist/ ]]; then
    find /usr/local/share/aliyun-assist/ -name "log" -type d -exec rm -rf {} + 2>/dev/null || true
fi

# ── 10. 安全加固 ──────────────────────────────────────────────────────────
echo ">>> 开始安全加固..."

# 禁用非必要服务（docker 必须保留，不在此列表）
systemctl disable --now firewalld update-motd.service systemd-resolved.service rpcbind.service rpcbind.socket 2>/dev/null || true

# 重置 SSH 配置
sed -i '/PasswordAuthentication/d' /etc/ssh/sshd_config
echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
rm -f /etc/ssh/ssh_host_*

# 锁定 root 密码（双重保险）
# 注意此处正则要把第二个冒号一并匹配掉，否则会向 /etc/shadow 插入一个空字段，
# 使后续字段整体错位（lastchg 变空、maxdays 变 0）。
passwd -l root 2>/dev/null || true
sed -i 's/^root:[^:]*:/root:*:/' /etc/shadow

# 清理 SSH 授权密钥
rm -f /root/.ssh/* 2>/dev/null || true

# ── 11. 历史记录与临时文件清理 ────────────────────────────────────────────
echo ">>> 清理命令历史与临时文件..."

for user_home in /home/* /root; do
    if [[ -d "$user_home" ]]; then
        history_file="$user_home/.bash_history"
        if [[ -f "$history_file" ]]; then
            > "$history_file"
        fi
        rm -f "$user_home"/.{viminfo,bashrc,bash_profile,profile} 2>/dev/null || true
    fi
done

# 清理 hosts 中的云厂商标识
sed -i '/iZ.*Z/d; /AliYun\|Aliyun\|debug/d' /etc/hosts

# ── 12. 交付前自检 ────────────────────────────────────────────────────────
# 容器运行时要解析百炼与各 IM 平台域名。上面禁用了 systemd-resolved，
# 如果 resolv.conf 仍指向它的 stub（127.0.0.53），实例起来后容器 DNS 会全挂。
if grep -qE '^nameserver[[:space:]]+127\.0\.0\.53' /etc/resolv.conf; then
  echo "ERROR: /etc/resolv.conf 指向 systemd-resolved stub，禁用该服务会导致容器 DNS 失效" >&2
  exit 1
fi
# docker 必须仍为开机自启，否则实例重启后容器不会回来
systemctl is-enabled docker
# 数据目录必须完整，且镜像元信息与运维入口健在
test -d "$APP_DIR/data/extensions"
test -L "$APP_DIR/data/node_modules/openclaw"
test -s "$APP_DIR/image.env"
test -L /opt/.swas/run-cmd.sh
docker image inspect "$LOCAL_IMAGE" > /dev/null

sync; sync; sync
echo "INFO: OpenClaw 部署物构建完成，基础镜像 digest: $BASE_DIGEST"
