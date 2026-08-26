# MTProto Proxy (mtg) 一键部署脚本

在 Alpine Linux 上使用 [OpenRC](https://github.com/OpenRC/openrc) 一键部署 [mtg](https://github.com/9seconds/mtg) MTProto 代理服务。

## ✨ 功能特性

- 🛡️ **fake-TLS 模式**（mtg v2.2+ hex secret，对抗 GFW 识别）
- 🌐 **multi-arch** 支持：`amd64` / `arm64` / `armv7` / `armv6`
- 📦 **动态获取最新版本**（GitHub Releases API，无需手动改脚本）
- ✅ **二进制 SHA256 校验**（防止中间人篡改）
- 🔍 **输入校验**：公网 IP / 伪装域名 / 端口范围 + 端口占用检测
- 🌐 **IPv4 / IPv6 双栈可选**
- 📊 **stats 启用**（`mtg stats` 查看连接情况）
- 📁 **FHS 合规**：`/etc/mtg/mtg.toml`（权限 600）
- 🔑 **secret 备份保留**（卸载后 `/etc/mtg/secret.bak` 仍存在，方便复用）
- 📜 **完整日志**：`/var/log/mtg.log` / `var/log/mtg.err`
- 🧹 **一键卸载**

## 🖥️ 系统要求

- **操作系统**：Alpine Linux（3.18+）
- **Init 系统**：OpenRC（Alpine 默认）
- **权限**：root
- **架构**：x86_64 / aarch64 / armv7 / armv6

## 🚀 快速使用

### 安装

```bash
wget -O mtg-install.sh https://raw.githubusercontent.com/Petersrsr/mtg-install/main/mtg-install.sh
chmod +x mtg-install.sh
bash mtg-install.sh
```

或一行命令：

```bash
bash <(wget -O- https://raw.githubusercontent.com/Petersrsr/mtg-install/main/mtg-install.sh)
```

### 卸载

```bash
bash mtg-install.sh --uninstall
```

卸载会删除服务、二进制、配置目录，但**保留 `/etc/mtg/secret.bak`**（方便以后重新部署复用同一密钥）。

### 帮助

```bash
bash mtg-install.sh --help
```

## 📋 安装步骤

脚本会依次完成：

1. **检测公网 IP**（NAT 友好）：
   - 自动检测本机是否为私网 IP（LXC/NAT 容器/内网穿透场景）
   - NAT 环境**默认推荐手动输入**（自动检测到的是 NAT 网关 IP，可能与端口转发后的对外 IP 不同）
   - DNS preflight（避免 wget 卡在 DNS 查询）
   - HTTP 优先（避开 TLS 握手慢）+ `timeout` 强制 4s 总超时
   - 4 个 API 兑底：ipify / ifconfig.me / ip.sb / icanhazip.com
2. **设置伪装域名**（默认 `microsoft.com`，建议改成 VPS 所在地相关域名）
3. **设置监听端口**（默认 `443`，会自动检测端口占用）
4. **询问是否启用 IPv6**（双栈监听）
5. **下载 mtg 最新版本** + SHA256 校验
6. **生成 fake-TLS hex secret** + 备份
7. **写入配置** `/etc/mtg/mtg.toml`（权限 600）
8. **创建 OpenRC 服务** + 开机自启
9. **启动服务** + 状态校验

## 🌐 特殊环境说明

### NAT / LXC 容器（家庭宽公网、机房内网穿透、frp/Cloudflare Tunnel 后）

如果你的服务器是 NAT 后的容器（家里 NAT、机房内网、frp 后面），脚本会**自动检测本机是私网 IP**，并提示：

```
[!] 检测到 NAT 环境（本机 IP: 10.0.3.5 是私网地址）
    自动检测只能拿到 NAT 网关的公网 IP，
    这与你的端口转发/内网穿透后的对外 IP 可能不同。
    NAT 环境强烈推荐手动输入。
    仍要自动检测? [y/N]:
```

输入 `N` 走手动输入，填你对外暴露的公网 IP（NAT 网关、frps、Cloudflare Tunnel 入口等）。

### 为什么手动输入更可靠

NAT 环境下，客户端实际连接的是 **NAT 网关 / 穿透隧道的公网 IP**，不是容器本身的 IP。脚本自动检测只能拿到出口网关的 IP，不一定是端口转发后的地址。手动输入能避免 TG 代理连不上的坑。

## 🛠️ 管理命令

```bash
rc-service mtg status          # 查看状态
rc-service mtg restart         # 重启
rc-service mtg stop            # 停止
rc-update show | grep mtg      # 查看开机自启
tail -f /var/log/mtg.log       # 实时日志
tail -f /var/log/mtg.err       # 错误日志
```

## 📁 文件位置

| 文件 | 说明 | 权限 |
|------|------|------|
| `/usr/local/bin/mtg` | mtg 二进制 | 755 |
| `/etc/mtg/mtg.toml` | 配置文件 | 600 |
| `/etc/mtg/secret.bak` | 密钥备份（卸载保留） | 600 |
| `/etc/init.d/mtg` | OpenRC 服务脚本 | 755 |
| `/var/log/mtg.log` | 运行日志 | 644 |
| `/var/log/mtg.err` | 错误日志 | 644 |
| `/opt/mtg/mtg.toml` | 软链 → `/etc/mtg/mtg.toml` | - |
| `/run/mtg.pid` | 进程 PID 文件 | - |

## ⚠️ 注意事项

- **端口放行**：确保所选端口已在 NAT / 防火墙中放行
- **伪装域名**：建议选择与 VPS 所在地 / 运营商相关的域名，最大化混淆效果
- **fake-TLS 模式**：客户端需使用 hex secret 链接（脚本输出的链接已自动兼容）
- **secret 备份**：卸载后 `/etc/mtg/secret.bak` 仍存在；确认不再使用请手动删除
- **重启生效**：修改 `mtg.toml` 后需执行 `rc-service mtg restart`

## 🔗 相关链接

- [mtg 上游项目](https://github.com/9seconds/mtg)
- [mtg 配置文档](https://github.com/9seconds/mtg#configuration)
- [OpenRC 服务文档](https://github.com/OpenRC/openrc/blob/master/service-script-guide.md)

## 📝 License

MIT