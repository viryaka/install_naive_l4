# 按：
在原脚本不变的前提下，扩展 Caddy 编译配置，集成 **caddy-l4** 与 **cloudflare** 两个插件，提供完整的 NaïveProxy 一键安装与管理体验。

## 功能总览
- 🧩 安装与更新：预编译 / 自编译（含 forwardproxy@naive、caddy-l4、cloudflare）。
- 🔒 Naive 用户管理：新增/改密/删除，生成 Naive 连接 URL 与终端二维码（保存到 `~/_naive_url_`）。
- 🌐 域名与端口：安装时或菜单中可改域名、端口，支持 `file_server` 与 `reverse_proxy` 切换及上游修改。
- 🚦 中转 (Layer4)：可选启用，支持设置落地机 IP/端口；启用中转会自动切换到自编译 Caddy（预编译不含 l4）。
- 🗂️ 多业务域名：绑定域名→本地端口，使用 Cloudflare DNS 插件，安装和菜单均可增/改/删。
- ☁️ Cloudflare：可配置/修改 API Key，供主站与业务域名的 DNS/TLS 使用。
- 🛠️ 配置安全：Caddyfile 块以 `_naive_config_begin_/end_` 包裹；无标记时先提示并自动备份 `Caddyfile.bak_时间戳`，生成前执行 `caddy validate`，失败回滚。
- 📜 配置持久化：`/etc/caddy/naive_config.json` 保存所有输入；Caddyfile 输出到 `/etc/caddy/Caddyfile`。
- 🧹 卸载：移除源列表并卸载 caddy（见下方）。

## 依赖与环境
- 运行环境：Debian/Ubuntu 系发行版，需 root/sudo。
- 依赖：`apt`、`curl`、`wget`、`git`、`jq`、`qrencode`、`xz-utils`、`debian-keyring`、`debian-archive-keyring`、`apt-transport-https`。

## 快速安装
```bash
apt update
apt install -y curl
bash <(curl -L https://github.com/viryaka/install_naive_l4/raw/main/install.sh)
```
- 首次运行：收集域名、端口、模式（file_server 默认 / reverse_proxy 可选）、Cloudflare Key、至少 1 个 Naive 用户、是否开启中转、是否添加业务域名、选择 Caddy 来源（预编译/自编译）。
- 生成后：自动 `caddy validate`，落盘、重启，并输出 Naive URL + 终端 QR。

### 参数化（跳过交互）
```bash
bash <(curl -L https://github.com/viryaka/install_naive_l4/raw/main/install.sh) <domain> [netstack] [port] [username] [password]
```
- `netstack=6`：IPv6 入站，脚本会安装 WARP 获取 IPv4 出站。
- 未提供密码时与用户名相同。

### Caddy 构建模式
- 预编译：从 `klzgrad/forwardproxy` release 获取，失败回退到 `v2.10.0-naive`。
- 自编译：执行 `buildcaddy.sh`，使用最新 Go + `xcaddy`，插件 `forwardproxy@naive` / `caddy-l4` / `cloudflare`。
- **中转启用时强制自编译**（预编译无 l4），菜单“更新 Caddy”同样遵循该约束。

## 菜单功能（运行后默认进入）
1. 查看配置（summary 输出）。
2. 配置中转（启用/禁用 + 落地机 IP/端口；启用会改用自编译）。
3. 管理业务域名（增/改/删：名称、域名、本地端口）。
4. 修改 Cloudflare Key。
5. 管理 Naive 用户（增/改密/删）。
6. 修改域名/端口。
7. 切换 file_server / reverse_proxy，并可修改反代上游。
8. 重新生成 Caddyfile 并重启（含校验、URL/QR 输出）。
9. 更新 Caddy（预编译/重编译，遵守中转→自编译约束）。
10. 退出。

## 配置文件与产物
- 主配置：`/etc/caddy/naive_config.json`
- Caddy 配置：`/etc/caddy/Caddyfile`（生成块用 `_naive_config_begin_/end_` 包裹，未标记时先备份再覆盖）
- 备份：`/etc/caddy/Caddyfile.bak_时间戳`
- Naive 连接信息：`~/_naive_url_`（同步输出终端 QR）

## 手搓步骤 (点击展开)
<details>
  <summary>(点击展开)</summary>

### 安装CaddyV2最新版本
source: https://caddyserver.com/docs/install#debian-ubuntu-raspbian
```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install caddy
```

### 下载 NaïveProxy 作者编译的 caddy（预编译路线）
```bash
cd /tmp
wget https://github.com/klzgrad/forwardproxy/releases/download/caddy2-naive-20221007/caddy-forwardproxy-naive.tar.xz
tar -xf caddy-forwardproxy-naive.tar.xz
cd caddy-forwardproxy-naive
```

### 替换 caddy 程序
```bash
service caddy stop
cp caddy /usr/bin/
```

### 写个简单的 html 页面
```bash
mkdir -p /var/www/html
echo "hello world" > /var/www/html/index.html
```

### 在 Caddyfile 顶部添加 forward_proxy 优先级 + Naive 配置
```bash
{
  order forward_proxy first
}
:自定义端口, 你的naive域名:自定义端口 {
  tls e16d9cb045d7@gmail.com
  forward_proxy {
    basic_auth 用户名 密码
    hide_ip
    hide_via
    probe_resistance
  }
  file_server {
    root /var/www/html
  }
}
```

### 启动 NaiveProxy
```bash
service caddy start
```
</details>

## 卸载
```bash
rm /etc/apt/sources.list.d/caddy-stable.list
apt remove -y caddy
```

## 结合 IP 证书
- 文档参考：https://zelikk.blogspot.com/2025/12/naiveproxy-ip-tls-without-domain.html

## 兼容 V2Ray 前置（提示）
如需与 Caddy V2 前置的 VLESS/VMess 共存：先按教程搭建 V2Ray（https://zelikk.blogspot.com/2022/11/naiveproxy-caddy-v2-vless-vmess-cdn.html），然后将 Caddy 替换为带 Naive 的版本即可。
