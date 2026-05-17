# MTProto Proxy (mtg) 一键部署脚本

在 Alpine Linux 上一键部署 [mtg](https://github.com/9seconds/mtg) MTProto 代理服务。

## 功能

- 自动检测公网 IP
- 自定义伪装域名和端口
- 自动生成密钥和配置文件
- 创建 OpenRC 服务并设置开机自启
- 生成 Telegram 一键添加链接
- 支持一键卸载

## 系统要求

- **操作系统：** Alpine Linux（其他发行版可能需要适配）
- **权限：** root

## 使用方法

### 安装

```bash
wget -O mtg-install.sh https://raw.githubusercontent.com/Petersrsr/mtg-install/main/mtg-install.sh
chmod +x mtg-install.sh
bash mtg-install.sh
```

或直接运行：

```bash
bash <(wget -O- https://raw.githubusercontent.com/Petersrsr/mtg-install/main/mtg-install.sh)
```

### 卸载

```bash
bash mtg-install.sh --uninstall
```

## 安装流程

脚本会依次完成以下步骤：

1. 检测公网 IP（自动检测或手动输入）
2. 设置伪装域名（默认 `microsoft.com`）
3. 设置监听端口（默认 `443`）
4. 下载并安装 mtg v2.2.8
5. 生成密钥和配置文件
6. 创建服务并启动

## 安装后管理

```bash
rc-service mtg status    # 查看状态
rc-service mtg restart   # 重启服务
rc-service mtg stop      # 停止服务
```

## 配置文件

- 程序路径：`/usr/local/bin/mtg`
- 配置文件：`/opt/mtg/mtg.toml`
- 服务文件：`/etc/init.d/mtg`

## 注意事项

- 确保所选端口已在 NAT/防火墙中放行
- 伪装域名建议选择与 VPS 所在地或运营商相关的域名
- 安装完成后请保存输出的密钥信息
