#!/bin/sh

set -e

# 卸载功能
if [ "$1" = "--uninstall" ] || [ "$1" = "-u" ]; then
    echo "正在卸载 mtg..."
    rc-service mtg stop 2>/dev/null || true
    rc-update del mtg default 2>/dev/null || true
    rm -f /etc/init.d/mtg
    rm -rf /opt/mtg
    rm -f /usr/local/bin/mtg
    echo "卸载完成"
    exit 0
fi

echo "=========================================="
echo "   MTProto Proxy (mtg) 一键部署脚本"
echo "=========================================="
echo ""

# 检查是否 root
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 权限运行此脚本"
    exit 1
fi

# 检查 Alpine
if [ ! -f /etc/alpine-release ]; then
    echo "警告：此脚本专为 Alpine Linux 设计"
    read -p "是否继续? [y/N]: " confirm
    [ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || exit 1
fi

# 获取公网 IP
echo "[1/6] 检测公网 IP..."
PUBLIC_IP=$(wget -qO- http://ip.sb 2>/dev/null || wget -qO- http://icanhazip.com 2>/dev/null || echo "")
if [ -z "$PUBLIC_IP" ]; then
    echo "    无法自动检测公网 IP"
    printf "    请手动输入你的服务器公网 IP: "
    read PUBLIC_IP
    [ -z "$PUBLIC_IP" ] && { echo "错误：必须提供公网 IP"; exit 1; }
fi
echo "    检测到公网 IP: $PUBLIC_IP"
echo ""

# 输入伪装域名
echo "[2/6] 设置伪装域名"
echo "    建议: 选择与你 VPS 所在地或运营商相关的域名"
echo "    例如: microsoft.com, cloudflare.com, google.com, amazon.com"
printf "    请输入伪装域名 [默认: microsoft.com]: "
read DOMAIN
[ -z "$DOMAIN" ] && DOMAIN="microsoft.com"
echo "    使用域名: $DOMAIN"
echo ""

# 输入端口
echo "[3/6] 设置监听端口"
echo "    注意: 确保此端口已在 NAT/防火墙中放行"
while true; do
    printf "    请输入端口号 [默认: 443]: "
    read PORT
    [ -z "$PORT" ] && PORT="443"
    if echo "$PORT" | grep -qE '^[0-9]+$' && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
        break
    fi
    echo "    错误：端口必须是 1-65535 之间的数字"
done
echo "    使用端口: $PORT"
echo ""

# 下载 mtg
echo "[4/6] 下载并安装 mtg..."
mkdir -p /opt/mtg
cd /opt/mtg

if [ ! -f /usr/local/bin/mtg ]; then
    LATEST_URL="https://github.com/9seconds/mtg/releases/download/v2.2.8/mtg-2.2.8-linux-amd64.tar.gz"
    echo "    下载中: $LATEST_URL"
    wget -q --show-progress "$LATEST_URL" -O mtg.tar.gz 2>/dev/null || wget -q "$LATEST_URL" -O mtg.tar.gz
    tar -xzf mtg.tar.gz
    chmod +x mtg-2.2.8-linux-amd64/mtg
    ln -sf /opt/mtg/mtg-2.2.8-linux-amd64/mtg /usr/local/bin/mtg
    rm -f mtg.tar.gz
    echo "    mtg 安装完成: $(mtg --version | head -1)"
else
    echo "    mtg 已存在: $(mtg --version | head -1)"
fi
echo ""

# 生成 secret
echo "[5/6] 生成 Secret..."
SECRET=$(mtg generate-secret --hex "$DOMAIN" 2>/dev/null)
if [ -z "$SECRET" ]; then
    echo "    错误：生成 Secret 失败，请检查域名是否正确"
    exit 1
fi
echo "    Secret: $SECRET"
echo ""

# 创建配置文件
echo "    创建配置文件..."
cat > /opt/mtg/mtg.toml << EOF
secret = "$SECRET"
bind-to = "0.0.0.0:$PORT"

[network]
timeout = { tcp = "30s", http = "30s", idle = "30s", handshake = "30s" }

[defense.blocklist]
enabled = false
EOF
echo "    配置文件: /opt/mtg/mtg.toml"
echo ""

# 创建 OpenRC 服务
echo "    创建 OpenRC 服务..."
cat > /etc/init.d/mtg << 'EOF'
#!/sbin/openrc-run

name="mtg"
description="MTProto proxy server"
command="/usr/local/bin/mtg"
command_args="run /opt/mtg/mtg.toml"
command_background="yes"
pidfile="/run/mtg.pid"
directory="/opt/mtg"

depend() {
    need net
    after firewall
}
EOF
chmod +x /etc/init.d/mtg
rc-update add mtg default >/dev/null 2>&1
echo "    服务已添加开机自启"
echo ""

# 启动服务
echo "[6/6] 启动服务..."
rc-service mtg restart >/dev/null 2>&1 || rc-service mtg start
sleep 1

if rc-service mtg status | grep -q "started"; then
    echo "    服务状态: 运行中 ✅"
else
    echo "    服务状态: 启动失败 ❌"
    exit 1
fi
echo ""

# 输出结果
echo "=========================================="
echo "   部署完成！"
echo "=========================================="
echo ""
echo "  服务器: $PUBLIC_IP"
echo "  端口:   $PORT"
echo "  密钥:   $SECRET"
echo "  伪装:   $DOMAIN"
echo ""
echo "  一键添加链接:"
echo "  https://t.me/proxy?server=$PUBLIC_IP&port=$PORT&secret=$SECRET"
echo ""
echo "  手动添加:"
echo "    服务器: $PUBLIC_IP"
echo "    端口:   $PORT"  
echo "    密钥:   $SECRET"
echo ""
echo "  管理命令:"
echo "    rc-service mtg status          # 查看状态"
echo "    rc-service mtg restart         # 重启"
echo "    rc-service mtg stop            # 停止"
echo "    bash mtg-install.sh --uninstall # 卸载"
echo ""
echo "=========================================="

