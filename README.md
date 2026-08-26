<div align="center">

# MTProto Proxy 一键部署脚本

在 **Alpine Linux** 上使用 OpenRC 一键部署 **Telegram MTProto 代理**，防 GFW 能力拉满。

[![telEgo](https://img.shields.io/badge/telEgo-v0.5.2-blue)](https://github.com/Scratch-net/telego)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)
[![Alpine](https://img.shields.io/badge/Alpine-3.18%2B-red)](https://alpinelinux.org)

</div>

---

## 📑 目录

- [为什么选 telEgo](#-为什么选-telego)
- [快速开始（3 分钟部署）](#-快速开始3-分钟部署)
- [交互输入说明](#-交互输入说明)
- [手动部署指南（重装系统后照着做）](#-手动部署指南重装系统后照着做)
- [TG 链接格式](#-tg-链接格式)
- [配置详解（telego.toml）](#-配置详解telego.toml)
- [管理命令](#-管理命令)
- [文件位置](#-文件位置)
- [特殊环境说明（NAT / LXC）](#-特殊环境说明nat--lxc)
- [故障排查](#-故障排查)
- [CDN 缓存说明](#-cdn-缓存说明)
- [相关链接](#-相关链接)

---

## 🏆 为什么选 telEgo

| 脚本 | 客户端 | 防 GFW | 性能 | 内存 | 推荐 |
|------|--------|--------|------|------|------|
| **`telego-install.sh`** ⭐ | [telEgo](https://github.com/Scratch-net/telego) | ★★★★★ | 4.6 GB/s | ~12MB | **强烈推荐** |
| `mtg-install.sh` | [mtg v2.2](https://github.com/9seconds/mtg) | ★★★☆☆ | ~2 GB/s | ~18MB | 兼容保留 |

### 防 GFW 能力对比

| 防 GFW 特性 | mtg v2.2 | telEgo | 说明 |
|------------|---------|--------|------|
| **TLS Fronting** | ❌ 合成证书 | ✅ **拉真证书** | telEgo 启动时连 mask-host 拉真实证书，GFW 看到的就是真网站的证书 |
| **Probe Resistance** | ⚠️ 部分 | ✅ **完整 splice** | GFW 主动探测时，telEgo 把请求转发给真网站，看到的是真实网页 |
| **DRS**（动态 record 大小） | ❌ | ✅ | 模拟 Chrome/Firefox 的 TLS record 大小变化，统计学检测失效 |
| **Split-TLS** | ❌ | ✅ | 首个 record 1 字节，破坏被动指纹 |
| **Post-quantum key share** | ❌ | ✅ | 兼容 X25519MLKEM768，防降级指纹 |
| **多 secret 单实例** | ❌（需 fork） | ✅ 原生 | 单端口多用户，独立分发/封禁 |
| **Dual Protocol** | ❌ | ✅ | 同一端口同时支持 ee + dd |
| **配置热重载** | ❌ | ✅ | SIGHUP / fsnotify |
| **Prometheus metrics** | ⚠️ | ✅ | 完整监控 |
| **SOCKS5 上游** | ✅ | ✅ | 可叠 Hysteria2 / VLESS |

> 💡 **内存占用**：telEgo ~12MB / mtg ~18MB，**128-256M LXC 都能完美运行**。

---

## 🚀 快速开始（3 分钟部署）

### 安装 telEgo（推荐）

```bash
# 方式 1：下载到本地再跑（推荐，方便保留脚本）
wget -O telego-install.sh https://cdn.jsdelivr.net/gh/Petersrsr/mtg-install@main/telego-install.sh
chmod +x telego-install.sh
bash telego-install.sh

# 方式 2：一行命令直接跑
bash <(wget -O- https://cdn.jsdelivr.net/gh/Petersrsr/mtg-install@main/telego-install.sh)
```

### 安装 mtg v2.2（兼容版）

```bash
bash <(wget -O- https://cdn.jsdelivr.net/gh/Petersrsr/mtg-install@main/mtg-install.sh)
```

### 卸载

```bash
bash telego-install.sh --uninstall   # 或 mtg-install.sh --uninstall
```

卸载会删除服务、二进制、配置目录，但**保留 `/etc/telego/secrets.bak`**（方便以后重新部署复用同一 secret）。

### 其他参数

```bash
bash telego-install.sh --help    # 帮助
bash telego-install.sh --force   # 强制重装（覆盖已有配置，跳过确认）
```

---

## ⌨️ 交互输入说明

脚本是交互式的，按提示依次输入：

| 步骤 | 提示 | 建议值 | 说明 |
|------|------|--------|------|
| 1/6 | 公网 IP | 手动输入 | NAT 环境**强烈建议手动输入**（见下方 NAT 说明） |
| 2/6 | mask-host | `www.google.com` | 伪装域名，必须是 telEgo 能访问的网站 |
| - | secret 数量 | `1` | 1-9 个，分发给不同人 |
| 3/6 | 端口 | `443` | 对外暴露的端口，自动检测占用 |
| - | IPv6 | `n` | NAT 环境建议关 |
| - | secret 名字 | `default` | 每个 secret 的名字（alice/bob/carol） |

> ⚠️ **重要**：安装完成输出的 TG 链接**必须完整复制**，不要手工输入 secret（62 位很长，容易复制错）。

---

## 📖 手动部署指南（重装系统后照着做）

### 前提

- Alpine Linux 3.18+（LXC/VM/物理机均可）
- root 权限
- 能访问外网（telEgo 启动时要连 mask-host:443 拉证书）
- 已配置好端口转发（NAT 环境）

### 步骤

1. **下载脚本**（推荐 jsDelivr，无 CDN 缓存问题）：

```bash
wget -O telego-install.sh https://cdn.jsdelivr.net/gh/Petersrsr/mtg-install@main/telego-install.sh
chmod +x telego-install.sh
```

2. **运行**：

```bash
bash telego-install.sh
```

3. **交互输入**（照这个填）：

```
NAT 提示 → n（选手动输入）
公网 IP → 你的 NAT 网关/宿主公网 IP
mask-host → www.google.com（回车默认）
secret 数量 → 1
端口 → 你映射的端口
IPv6 → n
secret 名字 → default（回车默认）
```

4. **验证**：

```bash
rc-service telego status      # started
ss -ltnp | grep telego        # 端口在监听
```

5. **测试**：把输出的 TG 链接完整复制到 Telegram → 设置 → 数据与存储 → 代理 → 添加

---

## 📱 TG 链接格式

telEgo 提供两种 secret（前缀决定模式）：

| 前缀 | 模式 | 说明 |
|------|------|------|
| `ee...` | FakeTLS | TLS 1.3 包装，**推荐** |
| `dd...` | Obfuscated2 | 原始 Obfuscated2，兼容性更好 |

**ee secret 结构**：`ee` + 16 字节 hex + mask-host hex（共 62 字符）
**dd secret 结构**：`dd` + 16 字节 hex（共 34 字符）

```
https://t.me/proxy?server=YOUR_IP&port=PORT&secret=***
```

脚本会输出**所有 secret 的 ee 和 dd 两种链接**。

---

## ⚙️ 配置详解（telego.toml）

安装后配置文件在 `/etc/telego/telego.toml`，常用配置项：

```toml
[general]
bind-to = "0.0.0.0:443"           # 监听地址和端口
max-connections-per-ip = 100      # DoS 防护（单 IP 最大连接数）
max-ips-per-user = 3              # 防 secret 共享（每用户最多 IP 数）
clock-sync-url = "https://www.cloudflare.com"  # 时钟校准

[secrets]
user1 = "0123456789abcdef0123456789abcdef"     # 多 secret 配置

[tls-fronting]
mask-host = "www.google.com"      # 伪装域名（核心）
enable-drs = true                 # 动态 record 大小（默认开）
enable-split-tls = true           # 首个 record 1 字节（默认开）

[performance]
prefer-ip = "only-ipv4"           # NAT 环境推荐 only-ipv4
idle-timeout = "5m"               # 空闲超时
```

完整配置参考：[telEgo README#configuration](https://github.com/Scratch-net/telego/blob/main/README.md#configuration)

### 添加/删除 secret（不需要重装）

编辑 `/etc/telego/telego.toml` 的 `[secrets]` 段：

```toml
[secrets]
alice = "0123456789abcdef0123456789abcdef"
bob   = "fedcba9876543210fedcba9876543210"
```

然后热重载（部分配置生效）：

```bash
kill -HUP $(pidof telego)
```

或用 `telego generate <mask-host>` 生成新 secret。

---

## 🛠️ 管理命令

### telEgo

```bash
rc-service telego status            # 查看状态
rc-service telego restart           # 重启
rc-service telego stop              # 停止
tail -f /var/log/telego.log         # 实时日志
kill -HUP $(pidof telego)           # 热重载（log-level, idle-timeout 等）
bash telego-install.sh --uninstall  # 卸载 (保留 secret 备份)
```

### mtg v2.2

```bash
rc-service mtg status               # 查看状态
rc-service mtg restart              # 重启
rc-service mtg stop                 # 停止
tail -f /var/log/mtg.log            # 实时日志
bash mtg-install.sh --uninstall     # 卸载 (保留 secret 备份)
```

---

## 📁 文件位置

### telEgo

| 文件 | 说明 | 权限 |
|------|------|------|
| `/usr/local/bin/telego` | telEgo 二进制 | 755 |
| `/etc/telego/telego.toml` | 配置文件 | 600 |
| `/etc/telego/secrets.bak` | Secret 备份（卸载保留） | 600 |
| `/etc/init.d/telego` | OpenRC 服务脚本 | 755 |
| `/var/log/telego.log` | 运行日志 | 644 |
| `/var/log/telego.err` | 错误日志 | 644 |
| `/opt/telego/telego.toml` | 软链 → `/etc/telego/telego.toml` | - |
| `/run/telego.pid` | 进程 PID 文件 | - |

### mtg v2.2

| 文件 | 说明 | 权限 |
|------|------|------|
| `/usr/local/bin/mtg` | mtg 二进制 | 755 |
| `/etc/mtg/mtg.toml` | 配置文件 | 600 |
| `/etc/mtg/secret.bak` | Secret 备份（卸载保留） | 600 |
| `/etc/init.d/mtg` | OpenRC 服务脚本 | 755 |
| `/var/log/mtg.log` | 运行日志 | 644 |
| `/var/log/mtg.err` | 错误日志 | 644 |

---

## 🌐 特殊环境说明（NAT / LXC）

### NAT / LXC 容器（家庭宽带、机房内网、frp/Cloudflare Tunnel 后）

如果你的服务器是 NAT 后的容器，脚本会**自动检测本机是私网 IP**，并提示：

```
[!] 检测到 NAT 环境（本机 IP: 10.0.3.5 是私网地址）
    ┌─────────────────────────────────────────────────────────┐
    │ 重要: 你需要在本机外的 NAT 网关/路由器/LXC宿主 上配置    │
    │       端口转发，把 公网IP:端口 → 容器IP:端口。           │
    │       例: 公网 103.x.x.x:54712 → 本机 10.0.3.5:54712    │
    └─────────────────────────────────────────────────────────┘
    仍要自动检测? [y/N]:
```

输入 `N` 走手动输入，填你对外暴露的公网 IP（NAT 网关、frps、Cloudflare Tunnel 入口等）。

### 端口转发配置示例

| 场景 | 转发规则 |
|------|---------|
| LXC 宿主 (incus/lxc) | `incus config device add <容器> proxy-443 proxy listen=tcp:0.0.0.0:54712 connect=tcp:<容器IP>:54712` |
| iptables DNAT | `iptables -t nat -A PREROUTING -p tcp --dport 54712 -j DNAT --to-destination <容器IP>:54712` |
| frp | `[[proxies]] type = "tcp" local_port = 54712 remote_port = 54712` |
| 家用路由器 | 端口转发：外网 54712 → 内网 <容器IP>:54712 |

### telEgo mask-host 必须能访问

telEgo 启动时**主动连 mask-host:443 拉真实证书**，要求：

1. 容器能解析并 TCP 连 `mask-host:443`
2. NAT 网关或代理允许 HTTPS 出站

如果你的 NAT 容器**没有外网访问**，mask-host 拉不到证书 → telEgo 启动失败。这种情况用 mtg v2.2（不需要拉证书）。

---

## 🔧 故障排查

### 部署时

| 症状 | 原因 | 解决 |
|------|------|------|
| 下载 404 | GitHub release asset 名用下划线 | 脚本已自动处理（`telego_0.5.2_linux_amd64.tar.gz`） |
| 启动失败 `unexpected argument` | OpenRC 服务缺 `-c` | 检查 `/etc/init.d/telego` 有 `run -c` |
| 启动失败 `cannot init config` | 配置文件格式错误 | 检查 `/etc/telego/telego.toml` 语法 |
| 启动失败但日志停在 DC 探测 | 启动慢（探测 11 个 DC + 拉证书）| 等 30s 再看 `ss -ltnp`；新版脚本已自动等待 |
| 启动失败 `handshake timeout` | secret 不匹配 | 检查 TG 里 secret 是否完整（62 位） |
| 下载失败 | 网络问题 | 脚本自动多源 fallback（GitHub → jsDelivr） |

### 客户端连不上

| 症状 | 排查步骤 |
|------|---------|
| TG 一直"连接中" | ① 确认代理开关已启用（蓝色）② 确认 secret 完整复制 ③ 换网络（WiFi ↔ 流量）测试 |
| 显示"不可用" | ① 服务器 `ss -ltnp \| grep 端口` 在监听吗 ② 手机浏览器访问 `https://公网IP:端口` 能打开 Google 吗 |
| 时好时坏 | ① 检查 `/var/log/telego.err` 有没有 `handshake timeout` ② 换 mask-host ③ 换端口 |

### 快速验证服务器是否正常

```bash
# 在服务器上
ss -ltnp | grep telego                    # 端口在监听
tail -f /var/log/telego.err               # 实时日志（看 new connection）
curl -sk https://127.0.0.1:端口 -H "Host: www.google.com" | head   # 返回 Google 首页 = 正常
```

```bash
# 在客户端（手机/电脑）
nc -zv 公网IP 端口                          # TCP 通吗
curl -sk https://公网IP:端口 -H "Host: www.google.com" | head     # 返回 Google = 转发正常
```

---

## ⚠️ CDN 缓存说明

**重要**：GitHub raw 文件被 Fastly CDN 缓存 **5 分钟**，且 **`?v=N` 参数无效**（缓存 key 忽略 query string）。

脚本更新后想立即拿最新版，用 **jsDelivr CDN**（实时，无缓存问题）：

```bash
# ✅ 推荐（实时）
wget -O telego-install.sh https://cdn.jsdelivr.net/gh/Petersrsr/mtg-install@main/telego-install.sh

# ⚠️ 可能有 5 分钟缓存
wget -O telego-install.sh https://raw.githubusercontent.com/Petersrsr/mtg-install/main/telego-install.sh
```

---

## 🔗 相关链接

- [telEgo 上游](https://github.com/Scratch-net/telego) — 推荐使用的 MTProxy 实现
- [mtg 上游](https://github.com/9seconds/mtg) — 兼容保留的 MTProxy 实现
- [telEgo 配置文档](https://github.com/Scratch-net/telego/blob/main/README.md#configuration)
- [telEgo WEB proxy 文档](https://github.com/Scratch-net/telego/blob/main/docs/web-proxy.md)
- [OpenRC 服务文档](https://github.com/OpenRC/openrc/blob/master/service-script-guide.md)

---

## 📝 License

MIT
