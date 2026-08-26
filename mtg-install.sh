#!/bin/sh
# Alpine busybox ash supports: set -o pipefail, local, $'...', etc.
# Disable shellcheck POSIX warnings that don't apply to ash.
# shellcheck disable=SC3040,SC3043,SC3001,SC2016,SC2086
#
# mtg-install.sh - Alpine Linux MTProto proxy (mtg) 一键部署脚本
#
# 功能:
#   - fake-TLS 模式（mtg v2.2+ hex secret，对抗 GFW 识别）
#   - multi-arch 支持 (amd64 / arm64 / armv7 / armv6)
#   - 动态获取最新版本 + SHA256 校验
#   - IPv4/IPv6 双栈可选
#   - 输入校验（IP/域名/端口）+ 端口占用检测
#   - OpenRC 服务 + 日志 + stats
#   - 一键卸载 + secret 备份保留
#
# 仓库: https://github.com/Petersrsr/mtg-install
# 上游: https://github.com/9seconds/mtg

set -euo pipefail

# ============================================================
# 卸载
# ============================================================
if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "-u" ]; then
    echo "==> 卸载 mtg..."
    rc-service mtg stop 2>/dev/null || true
    rc-update del mtg default 2>/dev/null || true
    rm -f /etc/init.d/mtg
    rm -f /usr/local/bin/mtg
    rm -rf /opt/mtg

    if [ -f /etc/mtg/secret.bak ]; then
        echo "    [i] 密钥备份保留: /etc/mtg/secret.bak"
        echo "        卸载后如确认不再使用，请手动 rm /etc/mtg/secret.bak"
    else
        rm -rf /etc/mtg
    fi
    echo "==> 卸载完成"
    exit 0
fi

# ============================================================
# 帮助
# ============================================================
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'EOF'
用法: bash mtg-install.sh [选项]

选项:
  (无)              安装 mtg（交互输入配置）
  --uninstall, -u   卸载 mtg（保留 /etc/mtg/secret.bak 备份）
  --help, -h        显示此帮助

支持系统: Alpine Linux（需 root + OpenRC）

更多信息: https://github.com/Petersrsr/mtg-install
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
err()  { printf "${C_ERR}[✗]${C_RST} %s\n" "$*" >&2; }

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
    x86_64)  MTG_ARCH=amd64 ;;
    aarch64) MTG_ARCH=arm64 ;;
    armv7l)  MTG_ARCH=armv7 ;;
    armv6l)  MTG_ARCH=armv6 ;;
    *)
        err "不支持的架构: $ARCH (支持的: x86_64 / aarch64 / armv7 / armv6)"
        exit 1
        ;;
esac
log "检测架构: $ARCH → mtg-$MTG_ARCH"

# ============================================================
# 获取 mtg 最新版本（GitHub Releases API）
# ============================================================
log "查询 mtg 最新版本..."
# 用 timeout 命令强制总超时（busybox wget 不认 --timeout）
MTG_VERSION=$(timeout 10 wget -qO- \
    "https://api.github.com/repos/9seconds/mtg/releases/latest" 2>/dev/null \
    | sed -n 's/.*"tag_name": *"v\?\([^"]*\)".*/\1/p' | head -1 || true)

if [ -z "$MTG_VERSION" ] || ! echo "$MTG_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    warn "无法从 GitHub API 获取最新版本，使用 fallback v2.2.8"
    MTG_VERSION="2.2.8"
fi
log "mtg 版本: v$MTG_VERSION"

# ============================================================
# [1/6] 公网 IP 检测（NAT 友好）
# ============================================================
echo ""
log "[1/6] 检测公网 IP..."

# 工具函数：验证 IPv4 格式
is_valid_ipv4() {
    echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
    for octet in $(echo "$1" | tr '.' ' '); do
        # 强制十进制比较，避免 octet=0 被认作 false
        if [ "${octet:-999}" -gt 255 ] 2>/dev/null; then
            return 1
        fi
    done
    return 0
}

# 工具函数：检测是否私网 IP
is_private_ip() {
    echo "$1" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|127\.|169\.254\.)'
}

# 获取本机第一张网卡 IP（NAT 检测）
get_host_ip() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show 2>/dev/null \
            | awk '/inet / && !/127\.0\.0\.1/ {print $2}' \
            | cut -d/ -f1 | head -1
    fi
}

# 尝试从指定 URL 获取公网 IP
# 用 timeout 命令强制总超时（防 busybox wget DNS 卡死）
try_url() {
    local url="$1"
    local label="${2:-$url}"
    local ip
    printf "    %-28s ... " "$label"
    ip=$(timeout 4 wget -qO- "$url" 2>/dev/null | tr -d '[:space:]' || true)
    if is_valid_ipv4 "$ip"; then
        echo "✓ $ip"
        PUBLIC_IP="$ip"
        return 0
    fi
    echo "✗"
    return 1
}

# 1) NAT 环境检测：本机 IP 是私网 → 推荐手动输入
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

# 2) DNS preflight：先测 DNS 能不能用（避免后面 wget 卡 DNS）
if [ "$NEED_MANUAL" != "1" ]; then
    if ! timeout 3 nslookup github.com >/dev/null 2>&1; then
        warn "DNS 解析测试失败（3s 超时）"
        NEED_MANUAL=1
    fi
fi

# 3) 自动检测：HTTP 优先（避开 TLS 握手慢），每源 4s 总超时
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

# 4) 手动输入：NAT 环境或自动检测失败
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
# [2/6] 伪装域名（校验格式）
# ============================================================
echo ""
log "[2/6] 设置伪装域名（用于生成 secret；fake-TLS 模式下也是 TLS 握手的 SNI 目标）"
echo "    建议: 选择与你 VPS 所在地/运营商相关的域名"
echo "    常用: microsoft.com, cloudflare.com, google.com, amazon.com, apple.com"
while true; do
    printf "    请输入伪装域名 [默认: microsoft.com]: "
    read -r DOMAIN
    DOMAIN="${DOMAIN:-microsoft.com}"
    DOMAIN=$(echo "$DOMAIN" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    # 简单域名格式校验
    if echo "$DOMAIN" | grep -qE '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'; then
        break
    fi
    err "无效的域名格式"
done
log "伪装域名: $DOMAIN"

# ============================================================
# [3/6] 端口（校验范围 + 占用检测）
# ============================================================
echo ""
log "[3/6] 设置监听端口"
echo "    注意: 确保此端口已在 NAT/防火墙中放行"

# 端口占用检测（ss 优先，netstat 兜底）
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

# ============================================================
# [4/6] IPv6 询问（决定 bind-to）
# ============================================================
echo ""
printf "    是否启用 IPv6 监听 (双栈)? [y/N]: "
read -r v6_ans
case "${v6_ans:-n}" in
    [yY]|[yY][eE][sS]) BIND_IP="[::]";  IP_MODE="IPv4+IPv6 (双栈)" ;;
    *)                  BIND_IP="0.0.0.0"; IP_MODE="IPv4 only" ;;
esac
log "监听: $BIND_IP ($IP_MODE)"

# ============================================================
# [5/6] 下载 mtg + SHA256 校验
# ============================================================
echo ""
log "[5/6] 下载 mtg v$MTG_VERSION (linux-$MTG_ARCH)..."

MTG_BIN="/usr/local/bin/mtg"
MTG_DATA="/opt/mtg"
TMP_TARBALL="$(mktemp)"
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_TARBALL" "$TMP_DIR"; }
trap cleanup EXIT

DOWNLOAD_URL="https://github.com/9seconds/mtg/releases/download/v${MTG_VERSION}/mtg-${MTG_VERSION}-linux-${MTG_ARCH}.tar.gz"
SHA256_URL="${DOWNLOAD_URL}.sha256"

NEED_INSTALL=1
if [ -x "$MTG_BIN" ] && "$MTG_BIN" --version 2>/dev/null | grep -q "v${MTG_VERSION}"; then
    log "mtg v$MTG_VERSION 已安装，跳过下载"
    NEED_INSTALL=0
fi

if [ "$NEED_INSTALL" = "1" ]; then
    log "下载 mtg 二进制（v$MTG_VERSION, $MTG_ARCH, 约 5-7MB）"
    log "URL: $DOWNLOAD_URL"
    log "NAT 网络下载可能较慢，最多 120s 超时，请耐心等待..."
    # 用 curl 下载（比 busybox wget 进度条更靠谱）
    # -f: 失败不输出 body  -L: 跟随重定向  -s: 静默（手动显示进度）
    # --connect-timeout: TCP 连接超时  --max-time: 总超时
    if ! timeout 120 curl -fL \
        --connect-timeout 10 --max-time 120 \
        -o "$TMP_TARBALL" \
        -w "    下载完成：%{speed_download} B/s, %{size_download} bytes, 用时 %{time_total}s\n" \
        "$DOWNLOAD_URL" 2>&1; then
        err "下载失败（120s 超时或网络错误）"
        err "请手动验证下载: curl -L $DOWNLOAD_URL"
        err "查看版本: https://github.com/9seconds/mtg/releases"
        exit 1
    fi

    # SHA256 校验
    EXPECTED_SHA=$(timeout 10 wget -qO- "$SHA256_URL" 2>/dev/null | awk '{print $1}' | head -1 || true)
    if [ -n "$EXPECTED_SHA" ]; then
        ACTUAL_SHA=$(sha256sum "$TMP_TARBALL" | awk '{print $1}')
        if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
            err "SHA256 校验失败！"
            echo "    期望: $EXPECTED_SHA"
            echo "    实际: $ACTUAL_SHA"
            exit 1
        fi
        log "SHA256 校验通过 ✅"
    else
        warn "无法获取 SHA256 校验文件（GitHub release 可能未发布 .sha256）"
        printf "    跳过校验继续? [y/N]: "
        read -r cont
        case "${cont:-n}" in
            [yY]|[yY][eE][sS]) ;;
            *) err "已取消"; exit 1 ;;
        esac
    fi

    mkdir -p "$MTG_DATA"
    tar -xzf "$TMP_TARBALL" -C "$TMP_DIR"
    EXTRACTED="$TMP_DIR/mtg-${MTG_VERSION}-linux-${MTG_ARCH}/mtg"
    if [ ! -x "$EXTRACTED" ]; then
        err "解压后未找到二进制文件: $EXTRACTED"
        exit 1
    fi
    install -m 0755 "$EXTRACTED" "$MTG_BIN"

    # 清理旧解压目录（如果之前装过不同版本）
    find "$MTG_DATA" -maxdepth 1 -type d -name 'mtg-*-linux-*' -exec rm -rf {} + 2>/dev/null || true

    INSTALLED_VER=$("$MTG_BIN" --version 2>/dev/null | head -1 || echo "unknown")
    log "mtg 安装完成: $INSTALLED_VER"
fi

# ============================================================
# [6/6] 生成 Secret + 写配置 + 创建服务
# ============================================================
echo ""
log "[6/6] 生成 Secret (fake-TLS hex 模式)..."
SECRET=$("$MTG_BIN" generate-secret --hex "$DOMAIN" 2>/dev/null || true)
if [ -z "$SECRET" ]; then
    err "生成 Secret 失败，请检查域名 '$DOMAIN' 是否正确"
    exit 1
fi
log "Secret: $SECRET"

# 备份 secret（卸载保留，方便重新部署复用）
mkdir -p /etc/mtg
printf 'mtg secret for %s\n%s\n' "$DOMAIN" "$SECRET" > /etc/mtg/secret.bak
chmod 600 /etc/mtg/secret.bak

# 写配置文件
log "写入配置文件 /etc/mtg/mtg.toml..."
cat > /etc/mtg/mtg.toml <<EOF
# mtg 配置文件 - 由 mtg-install.sh 自动生成
# 修改后请运行: rc-service mtg restart
#
# fake-TLS: hex secret 格式（mtg v2.2+ 默认）会触发客户端 fake-TLS 握手
#           服务端仅看流量模式不主动校验域名，可与 SNI 伪装域名不一致
#           建议 SNI 与 secret 生成时使用的域名保持一致以最大化混淆效果

secret = "$SECRET"
bind-to = "$BIND_IP:$PORT"

[network]
timeout = { tcp = "30s", http = "30s", idle = "30s", handshake = "30s" }

[stats]
# 启用统计（mtg stats 子命令查看，或抓 /var/log/mtg.log 中的 stats 行）
enabled = true

[defense.blocklist]
enabled = false
EOF
chmod 600 /etc/mtg/mtg.toml
# 兼容软链（部分文档/老脚本引用 /opt/mtg/mtg.toml）
mkdir -p "$MTG_DATA"
ln -sf /etc/mtg/mtg.toml "$MTG_DATA/mtg.toml"

# 创建 OpenRC 服务
log "创建 OpenRC 服务 /etc/init.d/mtg..."
cat > /etc/init.d/mtg <<'EOF'
#!/sbin/openrc-run

name="mtg"
description="MTProto proxy server (mtg) - https://github.com/9seconds/mtg"
command="/usr/local/bin/mtg"
command_args="run /etc/mtg/mtg.toml"
command_background="yes"
pidfile="/run/mtg.pid"
directory="/opt/mtg"

# 日志会被 openrc 重定向（写入这些文件）
output_log="/var/log/mtg.log"
error_log="/var/log/mtg.err"

depend() {
    need net
    after firewall
}

start_pre() {
    [ -f /etc/mtg/mtg.toml ] || { eerror "配置文件 /etc/mtg/mtg.toml 不存在"; return 1; }
    [ -x /usr/local/bin/mtg ] || { eerror "/usr/local/bin/mtg 不存在或不可执行"; return 1; }
}
EOF
chmod 755 /etc/init.d/mtg

if ! rc-update add mtg default >/dev/null 2>&1; then
    warn "rc-update 失败，请检查 OpenRC 配置"
fi

# 启动服务
if rc-service mtg status >/dev/null 2>&1; then
    rc-service mtg restart >/dev/null 2>&1 || rc-service mtg start
    log "服务已重启"
else
    rc-service mtg start >/dev/null 2>&1 || true
    log "服务已启动"
fi
sleep 1

# 状态校验
if rc-service mtg status 2>&1 | grep -q started; then
    log "服务状态: 运行中 ✅"
else
    err "服务状态: 启动失败 ❌"
    echo ""
    echo "=== 最后 20 行日志 ==="
    tail -n 20 /var/log/mtg.err 2>/dev/null || true
    exit 1
fi

# ============================================================
# 输出结果
# ============================================================
cat <<EOF

==========================================
   🎉 部署完成！
==========================================

  服务器:  $PUBLIC_IP
  端口:    $PORT
  密钥:    $SECRET
  伪装:    $DOMAIN
  监听:    $BIND_IP ($IP_MODE)
  架构:    $MTG_ARCH
  版本:    v$MTG_VERSION
  模式:    fake-TLS (mtg v2.2+ hex secret)

  📁 文件位置:
    配置:    /etc/mtg/mtg.toml           (权限 600)
    备份:    /etc/mtg/secret.bak         (权限 600)
    二进制:  /usr/local/bin/mtg
    日志:    /var/log/mtg.log /var/log/mtg.err
    服务:    /etc/init.d/mtg

  📱 Telegram 一键添加链接:
     https://t.me/proxy?server=$PUBLIC_IP&port=$PORT&secret=$SECRET

  📋 手动添加:
     服务器: $PUBLIC_IP
     端口:   $PORT
     密钥:   $SECRET

  🛠️  管理命令:
     rc-service mtg status           # 查看状态
     rc-service mtg restart          # 重启
     rc-service mtg stop             # 停止
     tail -f /var/log/mtg.log        # 实时日志
     bash mtg-install.sh --uninstall # 卸载 (保留 secret 备份)

==========================================
EOF