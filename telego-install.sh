#!/bin/sh
# shellcheck disable=SC3040,SC3043,SC3001,SC2016,SC2086
#
# telego-install.sh - Alpine Linux telEgo (Telegram MTProxy) 一键部署脚本
#
# telEgo: https://github.com/Scratch-net/telego
#
# 特性:
#   - TLS Fronting (启动时拉真 mask-host 证书)
#   - Probe Resistance (探测请求转给真网站)
#   - DRS (Dynamic Record Sizer) + Split-TLS
#   - Post-quantum key share 兼容
#   - 多 secret 单实例 (单端口多用户)
#   - Dual Protocol (ee FakeTLS + dd Obfuscated2)
#   - 配置文件热重载 (SIGHUP / fsnotify)
#   - SOCKS5 上游 (可叠 Hysteria2 / VLESS)
#   - Prometheus metrics
#
# 对比 mtg v2.2:
#   - 防 GFW 能力: ★★★ → ★★★★★ (TLS Fronting + Probe Resistance + DRS)
#   - 性能: 4.6 GB/s (vs ~2 GB/s)
#   - 内存: ~12MB (vs ~18MB)
#   - 128-256M LXC 完美运行
#
# 仓库: https://github.com/Petersrsr/mtg-install

set -euo pipefail

# ============================================================
# 卸载
# ============================================================
if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "-u" ]; then
    echo "==> 卸载 telEgo..."
    rc-service telego stop 2>/dev/null || true
    rc-update del telego default 2>/dev/null || true
    rm -f /etc/init.d/telego
    rm -f /usr/local/bin/telego
    rm -rf /opt/telego

    if [ -f /etc/telego/secrets.bak ]; then
        echo "    [i] Secret 备份保留: /etc/telego/secrets.bak"
        echo "        卸载后如确认不再使用，请手动 rm /etc/telego/secrets.bak"
    else
        rm -rf /etc/telego
    fi
    echo "==> 卸载完成"
    exit 0
fi

# ============================================================
# 帮助
# ============================================================
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'EOF'
用法: bash telego-install.sh [选项]

选项:
  (无)              安装 telEgo（交互输入配置）
  --uninstall, -u   卸载 telEgo（保留 /etc/telego/secrets.bak 备份）
  --help, -h        显示此帮助

支持系统: Alpine Linux（需 root + OpenRC）

更多信息: https://github.com/Petersrsr/mtg-install
上游项目: https://github.com/Scratch-net/telego
EOF
    exit 0
fi

# ============================================================
# 颜色/输出
# ============================================================
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    C_OK='\033[0;32m'; C_WARN='\033[0;33m'; C_ERR='\033[0;31m'; C_RST='\033[0m'
else
    C_OK=''; C_WARN=''; C_ERR=''; C_RST=''
fi
log()  { printf "${C_OK}[+]${C_RST} %s\n" "$*"; }
warn() { printf "${C_WARN}[!]${C_RST} %s\n" "$*" >&2; }
err()  { printf "${C_ERR}[x]${C_RST} %s\n" "$*" >&2; }

# ============================================================
# 前置检查
# ============================================================
# Alpine 检查（非 Alpine 警告 + 二次确认）
if [ ! -f /etc/alpine-release ]; then
    warn "此脚本专为 Alpine Linux 设计（需 OpenRC）"
    printf "是否继续? [y/N]: "
    read -r confirm
    case "${confirm:-n}" in
        [yY]|[yY][eE][sS]) ;;
        *) err "已取消"; exit 1 ;;
    esac
fi

# root 检查
if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 权限运行此脚本"
    exit 1
fi

# 依赖安装
log "安装依赖 (wget tar curl ca-certificates openssl)..."
apk add --no-cache wget tar curl ca-certificates openssl >/dev/null 2>&1 || {
    err "依赖安装失败，请检查 apk 源配置"
    exit 1
}

# ============================================================
# 架构检测
# ============================================================
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)        TELEGO_ARCH=amd64 ;;
    aarch64)       TELEGO_ARCH=arm64 ;;
    armv7l|armv6l) TELEGO_ARCH=arm ;;
    *)
        err "不支持的架构: $ARCH (支持的: x86_64 / aarch64 / armv7 / armv6)"
        exit 1
        ;;
esac
log "检测架构: $ARCH → telego-$TELEGO_ARCH"

# ============================================================
# 获取 telEgo 最新版本（GitHub Releases API）
# ============================================================
log "查询 telEgo 最新版本..."
TELEGO_VERSION=$(timeout 10 wget -qO- \
    "https://api.github.com/repos/Scratch-net/telego/releases/latest" 2>/dev/null \
    | sed -n 's/.*"tag_name": *"v\?\([^"]*\)".*/\1/p' | head -1 || true)

if [ -z "$TELEGO_VERSION" ] || ! echo "$TELEGO_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    warn "无法从 GitHub API 获取最新版本，使用 fallback v0.5.2"
    TELEGO_VERSION="0.5.2"
fi
log "telEgo 版本: v$TELEGO_VERSION"

# ============================================================
# [1/6] 公网 IP 检测（NAT 友好）
# ============================================================
echo ""
log "[1/6] 检测公网 IP..."

is_valid_ipv4() {
    echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
    for octet in $(echo "$1" | tr '.' ' '); do
        if [ "${octet:-999}" -gt 255 ] 2>/dev/null; then
            return 1
        fi
    done
    return 0
}

is_private_ip() {
    echo "$1" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|127\.|169\.254\.)'
}

get_host_ip() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show 2>/dev/null \
            | awk '/inet / && !/127\.0\.0\.1/ {print $2}' \
            | cut -d/ -f1 | head -1
    fi
}

try_url() {
    local url="$1"
    local label="${2:-$url}"
    local ip
    printf "    %-28s ... " "$label"
    ip=$(timeout 4 wget -qO- "$url" 2>/dev/null | tr -d '[:space:]' || true)
    if is_valid_ipv4 "$ip"; then
        echo "OK $ip"
        PUBLIC_IP="$ip"
        return 0
    fi
    echo "FAIL"
    return 1
}

# NAT 环境检测
HOST_IP=$(get_host_ip)
NEED_MANUAL=0
if [ -n "$HOST_IP" ] && is_private_ip "$HOST_IP"; then
    warn "检测到 NAT 环境（本机 IP: $HOST_IP 是私网地址）"
    echo "    自动检测只能拿到 NAT 网关的公网 IP，"
    echo "    这与你的端口转发/内网穿透后的对外 IP 可能不同。"
    echo "    NAT 环境强烈推荐手动输入。"
    printf "    仍要自动检测? [y/N]: "
    read -r auto_ans
    case "${auto_ans:-n}" in
        [yY]|[yY][eE][sS]) ;;
        *) NEED_MANUAL=1 ;;
    esac
fi

# DNS preflight
if [ "$NEED_MANUAL" != "1" ]; then
    if ! timeout 3 nslookup github.com >/dev/null 2>&1; then
        warn "DNS 解析测试失败（3s 超时）"
        NEED_MANUAL=1
    fi
fi

# 自动检测
PUBLIC_IP=""
if [ "$NEED_MANUAL" != "1" ]; then
    log "自动检测公网 IP（HTTP 优先，每源最多 4s）"
    for entry in \
        "http://api.ipify.org|api.ipify.org" \
        "http://ifconfig.me/ip|ifconfig.me" \
        "http://ip.sb|ip.sb" \
        "http://icanhazip.com|icanhazip.com" \
        "https://api.ipify.org|api.ipify.org (HTTPS)"; do
        url="${entry%%|*}"
        label="${entry##*|}"
        try_url "$url" "$label" && break
    done
fi

# 手动输入
if [ -z "$PUBLIC_IP" ]; then
    echo ""
    if [ "$NEED_MANUAL" = "1" ]; then
        warn "请输入对外暴露的公网 IP"
        echo "    提示: 这是 NAT 网关/路由器/穿透隧道的公网 IP，不是容器内 IP"
    else
        warn "自动检测失败，请手动输入公网 IP"
    fi
    while true; do
        printf "    公网 IP: "
        read -r PUBLIC_IP
        PUBLIC_IP=$(echo "${PUBLIC_IP:-}" | tr -d '[:space:]')
        if is_valid_ipv4 "$PUBLIC_IP"; then
            break
        fi
        err "无效的 IPv4 地址"
    done
fi
log "公网 IP: $PUBLIC_IP"

# ============================================================
# [2/6] mask-host（必填，TLS Fronting 核心）
# ============================================================
echo ""
log "[2/6] 设置 mask-host（TLS Fronting 核心配置）"
echo "    mask-host 用于:"
echo "    1) 启动时拉取该网站真实 TLS 证书（防止合成证书被识别）"
echo "    2) 探测请求转发给该网站（GFW 主动探测看到真网站）"
echo "    3) 客户端 SNI 伪装（看起来像访问该网站）"
echo ""
echo "    常用 mask-host（必须 TLS 1.3 + 真实可达）:"
echo "      - www.google.com        （推荐 - Google CDN）"
echo "      - www.microsoft.com    （推荐 - 微软）"
echo "      - www.cloudflare.com   （推荐 - Cloudflare）"
echo "      - www.apple.com        （备选）"
echo "      - www.bing.com         （备选）"
echo ""
echo "    [重要] 必须选 telEgo 启动时能访问到的网站！"
echo "    如 NAT 容器无外网，请先确认可以访问该域名，否则启动失败"
echo ""
while true; do
    printf "    请输入 mask-host [默认: www.google.com]: "
    read -r MASK_HOST
    MASK_HOST="${MASK_HOST:-www.google.com}"
    MASK_HOST=$(echo "$MASK_HOST" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    if echo "$MASK_HOST" | grep -qE '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'; then
        break
    fi
    err "无效的域名格式"
done
log "mask-host: $MASK_HOST"

# ============================================================
# Secret 数量（单实例多用户）
# ============================================================
echo ""
log "设置 secret 数量（每个 secret 对应一个独立 TG 链接）"
echo "    用途: 分发给不同人/不同群，任一泄露/封禁只影响对应 secret"
echo "    例: alice / bob / carol，3 个 secret 共用一个实例"
echo ""
while true; do
    printf "    生成几个 secret? [默认: 1, 最多 9]: "
    read -r N_SECRETS
    N_SECRETS="${N_SECRETS:-1}"
    if echo "$N_SECRETS" | grep -qE '^[0-9]+$' && [ "$N_SECRETS" -ge 1 ] && [ "$N_SECRETS" -le 9 ]; then
        break
    fi
    err "数量必须是 1-9 之间的数字"
done
log "secret 数量: $N_SECRETS"

# ============================================================
# [3/6] 端口（校验范围 + 占用检测）
# ============================================================
echo ""
log "[3/6] 设置监听端口"
echo "    注意: 确保此端口已在 NAT/防火墙中放行"

port_in_use() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH "sport = :$p" 2>/dev/null | grep -q LISTEN && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":$p$" && return 0
    fi
    return 1
}

while true; do
    printf "    请输入端口号 [默认: 443]: "
    read -r PORT
    PORT="${PORT:-443}"
    if echo "$PORT" | grep -qE '^[0-9]+$' && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
        if port_in_use "$PORT"; then
            warn "端口 $PORT 似乎已被占用"
            printf "    仍要继续? [y/N]: "
            read -r cont
            case "${cont:-n}" in
                [yY]|[yY][eE][sS]) break ;;
                *) continue ;;
            esac
        else
            break
        fi
    else
        err "端口必须是 1-65535 之间的数字"
    fi
done
log "端口: $PORT"

# IPv6 询问
echo ""
printf "    是否启用 IPv6 监听 (双栈)? [y/N]: "
read -r v6_ans
case "${v6_ans:-n}" in
    [yY]|[yY][eE][sS]) BIND_IP="[::]";  IP_MODE="IPv4+IPv6 (双栈)" ;;
    *)                  BIND_IP="0.0.0.0"; IP_MODE="IPv4 only" ;;
esac
log "监听: $BIND_IP ($IP_MODE)"

# ============================================================
# [4/6] 下载 telEgo + SHA256 校验
# ============================================================
echo ""
log "[4/6] 下载 telEgo v$TELEGO_VERSION (linux-$TELEGO_ARCH)..."

TELEGO_BIN="/usr/local/bin/telego"
TELEGO_DATA="/opt/telego"
TMP_TARBALL="$(mktemp)"
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_TARBALL" "$TMP_DIR"; }
trap cleanup EXIT

# 注意: GitHub release asset 名用下划线分隔，不是短横线
#   实际: telego_0.5.2_linux_amd64.tar.gz
DOWNLOAD_URL="https://github.com/Scratch-net/telego/releases/download/v${TELEGO_VERSION}/telego_${TELEGO_VERSION}_linux_${TELEGO_ARCH}.tar.gz"
CHECKSUM_URL="https://github.com/Scratch-net/telego/releases/download/v${TELEGO_VERSION}/checksums.txt"

NEED_INSTALL=1
# telEgo 的 zerolog 输出到 stderr，必须 2>&1 合并
if [ -x "$TELEGO_BIN" ] && "$TELEGO_BIN" version 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -q "${TELEGO_VERSION}"; then
    log "telEgo v$TELEGO_VERSION 已安装，跳过下载"
    NEED_INSTALL=0
fi

if [ "$NEED_INSTALL" = "1" ]; then
    log "下载 telEgo 二进制（v$TELEGO_VERSION, $TELEGO_ARCH, 约 6MB）"
    log "URL: $DOWNLOAD_URL"
    log "NAT 网络下载可能较慢，最多 120s 超时，请耐心等待..."
    if ! timeout 120 curl -fL \
        --connect-timeout 10 --max-time 120 \
        -o "$TMP_TARBALL" \
        -w "    下载完成：%{speed_download} B/s, %{size_download} bytes, 用时 %{time_total}s\n" \
        "$DOWNLOAD_URL" 2>&1; then
        err "下载失败（120s 超时或网络错误）"
        err "请手动验证下载: curl -L $DOWNLOAD_URL"
        err "查看版本: https://github.com/Scratch-net/telego/releases"
        exit 1
    fi

    # SHA256 校验（checksums.txt 含所有架构，grep 提取对应行）
    # 注意: GitHub URL 用 "-" 分隔，checksums.txt 用 "_" 分隔
    CHECKSUM_FILE=$(echo "telego-${TELEGO_VERSION}-linux-${TELEGO_ARCH}.tar.gz" | tr '-' '_')
    EXPECTED_SHA=$(timeout 10 wget -qO- "$CHECKSUM_URL" 2>/dev/null \
        | awk -v file="$CHECKSUM_FILE" '$2 == file {print $1}' | head -1 || true)
    if [ -n "$EXPECTED_SHA" ]; then
        ACTUAL_SHA=$(sha256sum "$TMP_TARBALL" | awk '{print $1}')
        if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
            err "SHA256 校验失败！"
            echo "    期望: $EXPECTED_SHA"
            echo "    实际: $ACTUAL_SHA"
            exit 1
        fi
        log "SHA256 校验通过 OK"
    else
        warn "无法获取 SHA256 校验文件（checksums.txt 中未找到对应行）"
        printf "    跳过校验继续? [y/N]: "
        read -r cont
        case "${cont:-n}" in
            [yY]|[yY][eE][sS]) ;;
            *) err "已取消"; exit 1 ;;
        esac
    fi

    mkdir -p "$TELEGO_DATA"
    tar -xzf "$TMP_TARBALL" -C "$TMP_DIR"
    EXTRACTED="$TMP_DIR/telego"
    if [ ! -x "$EXTRACTED" ]; then
        err "解压后未找到二进制文件: $EXTRACTED"
        exit 1
    fi
    install -m 0755 "$EXTRACTED" "$TELEGO_BIN"
    log "telEgo 安装完成: $("$TELEGO_BIN" version 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | head -1 || echo unknown)"
fi

# ============================================================
# [5/6] 生成 N 个 Secret + 写配置
# ============================================================
echo ""
log "[5/6] 生成 $N_SECRETS 个 secret + 写入配置..."

mkdir -p /etc/telego

# 备份所有 secret（卸载保留）
: > /etc/telego/secrets.bak  # 清空（用 : no-op 避免 SC2188）

# 收集所有 TG 链接（ee + dd）
TG_URLS_EE=""
TG_URLS_DD=""

i=1
while [ "$i" -le "$N_SECRETS" ]; do
    if [ "$N_SECRETS" = "1" ]; then
        DEFAULT_NAME="default"
    else
        DEFAULT_NAME="user${i}"
    fi
    printf "    secret #%d 名字 [%s]: " "$i" "$DEFAULT_NAME"
    read -r USER_NAME
    USER_NAME="${USER_NAME:-$DEFAULT_NAME}"
    USER_NAME=$(echo "$USER_NAME" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    # 简化校验：字母数字下划线短横
    if ! echo "$USER_NAME" | grep -qE '^[a-z0-9_-]{1,32}$'; then
        err "无效的名字（只允许字母数字下划线短横线，1-32 字符）"
        i=$((i + 1))
        continue
    fi

    log "[$i/$N_SECRETS] 生成 secret for $USER_NAME"

    # telEgo generate 输出格式 (zerolog + ANSI 颜色):
    #   2026-... INF generated secret (use ee for FakeTLS, dd for raw)
    #     dd_link=tg://...secret=ddXXX...
    #     ee_link=tg://...secret=eeXXX+host_hex
    #     secret=XXX                       <- 末尾的纯 32 字符 hex secret
    #
    # 提取步骤:
    #   1. 去 ANSI 颜色 (telEgo 默认带颜色)
    #   2. grep -oE 抓所有 "secret=32字符hex"
    #   3. tail -1 取最后一个 (即纯 secret=XXX)
    GEN_OUTPUT=$(timeout 10 "$TELEGO_BIN" generate "$MASK_HOST" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' || true)
    SECRET_HEX=$(echo "$GEN_OUTPUT" | grep -oE 'secret=[0-9a-f]{32}\b' | tail -1 | sed 's/secret=//')

    if [ -z "$SECRET_HEX" ] || [ "${#SECRET_HEX}" != "32" ]; then
        err "生成 secret 失败（长度 ${#SECRET_HEX:-0}）"
        echo "telEgo generate 输出:"
        echo "$GEN_OUTPUT" | head -10
        echo ""
        echo "可能原因:"
        echo "  1. telEgo 二进制损坏 - 重新下载"
        echo "  2. mask-host 格式不正确 - 必须是小写域名"
        exit 1
    fi
    log "    secret: $SECRET_HEX"

    # 追加到 secrets.bak
    printf '%s | %s\n' "$USER_NAME" "$SECRET_HEX" >> /etc/telego/secrets.bak

    # 拼 TG 链接（ee = FakeTLS, dd = Obfuscated2）
    # ee secret = "ee" + secret + mask_host_hex
    # dd secret = "dd" + secret
    EE_SECRET="ee${SECRET_HEX}$(printf '%s' "$MASK_HOST" | od -An -tx1 | tr -d ' \n')"
    DD_SECRET="dd${SECRET_HEX}"
    EE_URL="https://t.me/proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${EE_SECRET}"
    DD_URL="https://t.me/proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${DD_SECRET}"

    TG_URLS_EE="${TG_URLS_EE}${EE_URL}\n"
    TG_URLS_DD="${TG_URLS_DD}${DD_URL}\n"

    i=$((i + 1))
done
chmod 600 /etc/telego/secrets.bak

# ============================================================
# 写入 telEgo 配置（重新生成 toml，因为上面循环不知道所有 secret）
# ============================================================
log "写入配置文件 /etc/telego/telego.toml..."

# 重建 [secrets] 段（从 secrets.bak 读取）
SECRETS_TOML=""
while IFS='|' read -r name hex; do
    name=$(echo "$name" | tr -d '[:space:]')
    hex=$(echo "$hex" | tr -d '[:space:]')
    [ -z "$name" ] && continue
    SECRETS_TOML="${SECRETS_TOML}${name} = \"${hex}\"
"
done < /etc/telego/secrets.bak

cat > /etc/telego/telego.toml <<EOF
# telEgo 配置文件 - 由 telego-install.sh 自动生成
# 修改后请运行: rc-service telego restart（或 SIGHUP 热重载部分配置）
# 配置参考: https://github.com/Scratch-net/telego/blob/main/README.md#configuration

[general]
# 网络监听
bind-to = "$BIND_IP:$PORT"

# 日志级别: trace, debug, info, warn, error
log-level = "info"

# DoS 防护（单 IP 最大连接数，0 = 不限）
max-connections-per-ip = 100

# 防 secret 共享（每个用户最多几个 IP，0 = 不限）
max-ips-per-user = 3
ip-block-timeout = "5m"

# VPS 时钟不准时启动校准（避免拒绝合法客户端）
clock-sync-url = "https://www.cloudflare.com"

# 多 secret 配置（每个名字一个独立 TG 链接）
# 用 telego generate <mask-host> 生成 32 字符 hex 填入
[secrets]
$SECRETS_TOML
# TLS fronting 核心配置（防 GFW 关键）
[tls-fronting]
# mask-host: 用于拉真实证书 + 探测转发 + SNI 伪装
mask-host = "$MASK_HOST"
# mask-port = 443           # mask-host 端口（默认 443）
# cert-host = mask-host     # 拉证书主机（默认 = mask-host）
# cert-port = mask-port     # 拉证书端口（默认 = mask-port）
# splice-host = mask-host   # 探测转发目标（默认 = mask-host；可指向本机 nginx）
# splice-port = mask-port   # 探测转发端口（默认 = mask-port）
# mask-sni-safelist = []     # SNI 转发白名单（如 ["www.microsoft.com"]）

# Anti-DPI 记录整形（默认开启，强烈推荐保留）
enable-drs = true            # Dynamic Record Sizer（模拟 Chrome/Firefox）
enable-split-tls = true      # 第一个 ApplicationData 记录 1 字节

# 性能调优
[performance]
prefer-ip = "only-ipv4"      # NAT 环境推荐 only-ipv4
# prefer-ip = "prefer-ipv4"  # 双栈偏好 IPv4
# prefer-ip = "prefer-ipv6"  # 双栈偏好 IPv6
# prefer-ip = "only-ipv6"    # 仅 IPv6
idle-timeout = "5m"
num-event-loops = 0          # 0 = 自动（所有 CPU 核）

# 可选：SOCKS5 上游（DC 连接走 SOCKS5，叠 Hysteria2/VLESS）
# [upstream]
# socks5 = "127.0.0.1:1080"

# 可选：Prometheus metrics
# [metrics]
# bind-to = "127.0.0.1:9090"
# path = "/metrics"

# 可选：WEB proxy (Telegram Desktop over HTTPS) - 需要自己的域名 + LE 证书 + nginx
# [web-proxy]
# enabled = true
# hostname = "proxy.example.com"   # 必须是 LE 证书的域名
# carrier = "https-lanes"
# bind-to = "127.0.0.1:8080"
# trusted-proxy-cidrs = ["127.0.0.1/32"]
EOF
chmod 600 /etc/telego/telego.toml

# 兼容软链（部分文档引用 /opt/telego/telego.toml）
mkdir -p "$TELEGO_DATA"
ln -sf /etc/telego/telego.toml "$TELEGO_DATA/telego.toml"

# ============================================================
# [6/6] 创建 OpenRC 服务 + 启动
# ============================================================
echo ""
log "[6/6] 创建 OpenRC 服务 /etc/init.d/telego..."
cat > /etc/init.d/telego <<'EOF'
#!/sbin/openrc-run

name="telego"
description="telEgo - MTProxy with TLS Fronting (https://github.com/Scratch-net/telego)"
command="/usr/local/bin/telego"
command_args="run -c /etc/telego/telego.toml"
command_background="yes"
pidfile="/run/telego.pid"

# 日志（如果 rsyslog/syslog-ng 启动了会收集）
output_log="/var/log/telego.log"
error_log="/var/log/telego.err"

depend() {
    need net
    after firewall
}

start_pre() {
    [ -f /etc/telego/telego.toml ] || { eerror "配置文件 /etc/telego/telego.toml 不存在"; return 1; }
    [ -x /usr/local/bin/telego ] || { eerror "/usr/local/bin/telego 不存在或不可执行"; return 1; }
    # telEgo 启动时会连 mask-host 拉证书，需要网络可达
}
EOF
chmod 755 /etc/init.d/telego

if ! rc-update add telego default >/dev/null 2>&1; then
    warn "rc-update 失败，请检查 OpenRC 配置"
fi

# 启动服务
if rc-service telego status >/dev/null 2>&1; then
    rc-service telego restart >/dev/null 2>&1 || rc-service telego start
    log "服务已重启"
else
    rc-service telego start >/dev/null 2>&1 || true
    log "服务已启动"
fi
sleep 1

# 状态校验
if rc-service telego status 2>&1 | grep -q started; then
    log "服务状态: 运行中 OK"
else
    err "服务状态: 启动失败"
    echo ""
    echo "=== 最后 20 行日志 ==="
    tail -n 20 /var/log/telego.err 2>/dev/null || true
    echo ""
    echo "=== 提示 ==="
    echo "telEgo 启动时会主动连 $MASK_HOST 拉取真实 TLS 证书"
    echo "请确认:"
    echo "  1. 容器能访问外网 (能解析 $MASK_HOST 并 TCP 连 443)"
    echo "  2. NAT 网关或代理允许 HTTPS 出站"
    echo "  3. /var/log/telego.err 看具体错误"
    exit 1
fi

# ============================================================
# 输出结果
# ============================================================
cat <<EOF

==========================================
   🎉 telEgo 部署完成！
==========================================

  服务器:    $PUBLIC_IP
  端口:      $PORT
  mask-host: $MASK_HOST
  监听:      $BIND_IP ($IP_MODE)
  架构:      $TELEGO_ARCH
  版本:      v$TELEGO_VERSION

  防 GFW:
    - TLS Fronting:      真实证书 ✅
    - Probe Resistance: 探测转发 ✅
    - DRS:              ApplicationData 动态大小 ✅
    - Split-TLS:        首个 record 1 字节 ✅
    - PQ keyshare:      X25519MLKEM768 兼容 ✅

  📁 文件位置:
    配置:    /etc/telego/telego.toml           (权限 600)
    备份:    /etc/telego/secrets.bak           (权限 600, 卸载保留)
    二进制:  /usr/local/bin/telego
    日志:    /var/log/telego.log /var/log/telego.err
    服务:    /etc/init.d/telego

  📱 Telegram 代理链接（$N_SECRETS 个 secret × 2 模式）:
EOF

i=1
while IFS='|' read -r name hex; do
    name=$(echo "$name" | tr -d '[:space:]')
    hex=$(echo "$hex" | tr -d '[:space:]')
    [ -z "$name" ] && continue
    EE_SECRET="ee${hex}$(printf '%s' "$MASK_HOST" | od -An -tx1 | tr -d ' \n')"
    DD_SECRET="dd${hex}"
    echo ""
    echo "  ── #${i} [$name] ──"
    echo "    🔒 FakeTLS (推荐): https://t.me/proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${EE_SECRET}"
    echo "    🔓 Obfuscated2:    https://t.me/proxy?server=${PUBLIC_IP}&port=${PORT}&secret=${DD_SECRET}"
    i=$((i + 1))
done < /etc/telego/secrets.bak

cat <<EOF

  🛠️  管理命令:
     rc-service telego status          # 查看状态
     rc-service telego restart         # 重启
     rc-service telego stop            # 停止
     tail -f /var/log/telego.log       # 实时日志
     bash telego-install.sh --uninstall # 卸载 (保留 secret 备份)

  💡 热重载配置:
     kill -HUP \$(pidof telego)        # 部分配置（log-level, idle-timeout）无需重启
     # 或编辑 /etc/telego/telego.toml 后 telego 自动检测（fsnotify）

==========================================
EOF