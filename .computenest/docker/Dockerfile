# OpenClaw 社区版（计算巢）运行镜像
#
# 在上游官方镜像基础上做二次构建，只做两件事：
#   1. 预装 4 个渠道插件（钉钉 / 企业微信 / QQ / 飞书），避免运行期访问 npm；
#   2. 把宿主包 /app 暴露给插件，解决新版插件 ESM 裸导入解析失败的问题。
#
# 不覆盖 ENTRYPOINT / CMD，沿用上游的 `tini -s -- node openclaw.mjs gateway`。
ARG OPENCLAW_IMAGE=ghcr.io/openclaw/openclaw:latest
FROM ${OPENCLAW_IMAGE}

# 渠道插件版本。服务当前策略是跟随上游 latest；若需锁版本改成具体版本号即可。
ARG DINGTALK_PLUGIN="@dingtalk-real-ai/dingtalk-connector@latest"
ARG WECOM_PLUGIN="@wecom/wecom-openclaw-plugin@latest"
ARG QQBOT_PLUGIN="@tencent-connect/openclaw-qqbot@latest"
# 飞书渠道的官方插件是 @openclaw/feishu（渠道注册表 channel-catalog.json 里登记的就是它），
# 与主程序同版本号同步发布。注意不要错认成第三方的 @larksuite/openclaw-lark，那个包的
# 发布产物缺 dist、装上必然加载失败。
ARG FEISHU_PLUGIN="@openclaw/feishu@latest"

USER root

# 下载并展开渠道插件到 OpenClaw 扩展目录
RUN mkdir -p /home/node/.openclaw/extensions && \
    cd /home/node/.openclaw/extensions && \
    npm pack "${DINGTALK_PLUGIN}" && \
    npm pack "${WECOM_PLUGIN}" && \
    npm pack "${QQBOT_PLUGIN}" && \
    npm pack "${FEISHU_PLUGIN}" && \
    for pkg in *.tgz; do \
        dir=$(echo "$pkg" | sed 's/-[0-9].*//'); \
        mkdir -p "$dir" && tar -xzf "$pkg" -C "$dir" --strip-components=1 && rm "$pkg" && \
        if [ -f "$dir/package.json" ]; then (cd "$dir" && npm install --omit=dev); fi; \
    done && \
    npm cache clean --force

# 把宿主包 /app（包名 openclaw）暴露给插件扩展，否则新版插件里的 ESM 裸导入
# `openclaw/plugin-sdk/core` 无法被 Node 解析，插件注册会报 Cannot find module。
RUN mkdir -p /home/node/.openclaw/node_modules && \
    ln -sfn /app /home/node/.openclaw/node_modules/openclaw

# 预建运行期目录，构建部署物时会连同 extensions 一起导出到宿主机做 bind-mount
RUN mkdir -p /home/node/.openclaw/workspace \
             /home/node/.openclaw/computenest-skillhub-skills && \
    chown -R node:node /home/node/.openclaw

USER node
