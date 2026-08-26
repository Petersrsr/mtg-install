# MTProto Proxy 一键部署脚本

在 Alpine Linux 上使用 [OpenRC](https://github.com/OpenRC/openrc) 一键部署 Telegram MTProto 代理服务。

支持两个实现：

| 脚本 | 客户端 | 防 GFW | 性能 | 推荐 |
|------|--------|--------|------|------|
| **`telego-install.sh`** ⭐ | [telEgo](https://github.com/Scratch-net/telego) | ★★★★★ | 4.6 GB/s | **强烈推荐** |
| `mtg-install.sh` | [mtg v2.2](https://github.com/9seconds/mtg) | ★★★☆☆ | ~2 GB/s | 兼容保留 |

## 🏆 推荐 telEgo 的理由

| 防 GFW 特性 | mtg v2.2 | telEgo |
|------------|---------|--------|
| **TLS Fronting**（拉真证书） | ❌ 合成 | ✅ 拉真 mask cert |
| **Probe Resistance**（探测转发） | ⚠️ partial | ✅ 完整 splice |
| **DRS**（动态 record 大小） | ❌ | ✅ 模拟 Chrome/Firefox |
| **Split-TLS**（首个 record 1 字节） | ❌ | ✅ |
| **Post-quantum key share** | ❌ | ✅ X25519MLKEM768 |
| **多 secret 单实例** | ❌（mtg-multi fork） | ✅ 原生 `[secrets]` |
| **Telegram Desktop WEB 代理** | ❌ | ✅ 业内首创 |
| **Prometheus metrics** | ⚠️ partial | ✅ 完整 |
| **配置热重载** | ❌ | ✅ SIGHUP + fsnotify |
| **SOCKS5 上游** | ✅ | ✅ |

**内存占用**：telEgo ~12MB / mtg ~18MB，**128-256M LXC 都能完美运行**。

---

## 🚀 快速使用

### 安装 telEgo（推荐）

```bash
wget -O telego-install.sh https://raw.githubusercontent.com/Petersrsr/mtg-install/main/telego-install.sh
chmod +x telego-install.sh
bash telego-install.sh
```

或一行命令：

```bash
bash <(wget -O- https://raw.githubusercontent.com/Petersrsr/mtg-install/main/telego-install.sh)
```

### 安装 mtg v2.2（兼容）

```bash
bash <(wget -O- https://raw.githubusercontent.com/Petersrsr/mtg-install/main/mtg-install.sh)
```

### 卸载

```bash
bash telego-install.sh --uninstall   # 或 mtg-install.sh --uninstall
```

卸载会删除服务、二进制、配置目录，但**保留 `/etc/telego/secrets.bak`**（方便以后重新部署复用）。

---

## ✨ telEgo 功能特性

- 🛡️ **TLS Fronting**：启动时主动连 mask-host（如 `www.google.com`）拉真实证书
- 🛡️ **Probe Resistance**：探测请求转发给真网站，GFW 主动探测看到真 Google
- 🛡️ **DRS + Split-TLS**：动态 record 大小 + 首个 record 1 字节，模拟 Chrome/Firefox
- 🛡️ **Post-quantum key share**：兼容 X25519MLKEM768（防降级指纹）
- 🔐 **多 secret 单实例**：单端口多用户（alice / bob / carol），泄露/封禁只影响对应 secret
- 📱 **Dual Protocol**：单端口同时支持 FakeTLS (ee) 和 Obfuscated2 (dd)
- 📜 **完整 toml 配置**：含 `[general] / [secrets] / [tls-fronting] / [performance]`
- 🔄 **热重载**：SIGHUP / fsnotify 部分配置无需重启
- 🧅 **SOCKS5 上游**：可叠 Hysteria2 / VLESS
- 📊 **Prometheus metrics**：可选 `[metrics]` 区块
- 🌐 **WEB 代理**（可选）：Telegram Desktop over HTTPS（需域名 + LE 证书 + nginx）

---

## ✨ mtg v2.2 功能特性（兼容版本）

- 🛡️ **fake-TLS 模式**（mtg v2.2+ hex secret）
- 🌐 **multi-arch** 支持：`amd64` / `arm64` / `armv7` / `armv6`
- 📦 **动态获取最新版本**（GitHub Releases API）
- ✅ **二进制 SHA256 校验**（防中间人篡改）
- 🔍 **输入校验**：公网 IP / 伪装域名 / 端口范围 + 端口占用检测
- 🌐 **IPv4 / IPv6 双栈可选**
- 📊 **stats 启用**（`mtg stats` 查看连接情况）
- 📁 **FHS 合规**：`/etc/mtg/mtg.toml`（权限 600）

---

## 📋 安装步骤（telEgo / mtg 通用）

1. **检测公网 IP**（NAT 友好）：
   - 自动检测本机是否为私网 IP（LXC/NAT 容器/内网穿透场景）
   - NAT 环境**默认推荐手动输入**（自动检测到的是 NAT 网关 IP）
   - DNS preflight + HTTP 优先 + `timeout` 强制 4s 总超时
2. **设置伪装域名**（telEgo 的 mask-host / mtg 的 SNI 伪装）
3. **设置监听端口**（默认 `443`，自动检测端口占用）
4. **询问是否启用 IPv6**（双栈监听）
5. **下载最新版本** + SHA256 校验
6. **生成 secret** + 备份
7. **写入配置**（权限 600）
8. **创建 OpenRC 服务** + 开机自启
9. **启动服务** + 状态校验

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

3. **交互输入**（按提示走）：
   - 公网 IP：NAT 环境选手动输入，填 NAT 网关/宿主公网 IP
   - mask-host：推荐 `www.google.com`（必须能访问）
   - secret 数量：1-9 个（分发给不同人）
   - 端口：填**对外暴露的端口**（宿主映射的那个）
   - IPv6：NAT 环境建议 N

4. **验证**：

```bash
rc-service telego status      # started
ss -ltnp | grep telego        # 端口在监听
```

5. **测试**：把输出的 TG 链接粘贴到 Telegram

### 故障排查

| 症状 | 原因 | 解决 |
|------|------|------|
| 启动失败 `cannot init config` | 配置文件格式错误 | 检查 `/etc/telego/telego.toml` |
| 启动失败 `unexpected argument` | 服务文件缺 `-c` | 检查 `/etc/init.d/telego` 有 `run -c` |
| 启动失败但日志空 | 网络问题拉证书失败 | `tail /var/log/telego.err` |
| TG 连不上 | 端口转发没配 | 宿主加 DNAT 规则 |
| TG 连不上 | 伪装域名被墙 | 换 mask-host 重启 |
| 下载 404 | 版本号错 | 去 releases 页确认 asset 名 |

---

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

### telEgo mask-host 必须能访问

telEgo 启动时**主动连 mask-host:443 拉真实证书**，要求：

1. 容器能解析并 TCP 连 `mask-host:443`
2. NAT 网关或代理允许 HTTPS 出站

如果你的 NAT 容器**没有外网访问**，mask-host 拉不到证书 → telEgo 启动失败。这种情况用 mtg v2.2（不需要拉证书）。

---

## 📱 TG 链接格式

telEgo 提供两种 secret（前缀决定模式）：

| 前缀 | 模式 | 说明 |
|------|------|------|
| `ee...` | FakeTLS | TLS 1.3 包装，**推荐** |
| `dd...` | Obfuscated2 | 原始 Obfuscated2，兼容性更好 |

**ee secret 结构**：`ee` + 16 字节 hex + mask-host hex
**dd secret 结构**：`dd` + 16 字节 hex

TG 链接格式：
```
https://t.me/proxy?server=YOUR_IP&port=PORT&secret=SECRET
```

脚本会输出**所有 secret 的 ee 和 dd 两种链接**。

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

## 🛠️ 管理命令

### telEgo

```bash
rc-service telego status          # 查看状态
rc-service telego restart         # 重启
rc-service telego stop            # 停止
tail -f /var/log/telego.log       # 实时日志
kill -HUP $(pidof telego)         # 热重载（部分配置）
bash telego-install.sh --uninstall # 卸载 (保留 secret 备份)
```

### mtg v2.2

```bash
rc-service mtg status             # 查看状态
rc-service mtg restart            # 重启
rc-service mtg stop               # 停止
tail -f /var/log/mtg.log          # 实时日志
bash mtg-install.sh --uninstall   # 卸载 (保留 secret 备份)
```

---

## ⚠️ CDN 缓存提醒

GitHub raw 文件被 Fastly CDN 缓存 5 分钟（`max-age=300`）。脚本修改后立即跑可能拿到旧版本。

**绕过缓存**（push 后 5 分钟内）：

```bash
bash <(wget -O- "https://raw.githubusercontent.com/Petersrsr/mtg-install/main/telego-install.sh?v=2")
```

加 `?v=N` cache-bust 参数让 CDN miss。

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