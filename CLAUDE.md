# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 仓库概览
- 纯 Shell 安装/编译脚本，无其他语言。核心文件：`install.sh`（交互式安装与配置 NaïveProxy+Caddy）、`buildcaddy.sh`（定制 Caddy 编译，含 forwardproxy/l4/cloudflare 插件）、`Caddyfile.example`（示例/模板）、`prd1.md`（需求说明）。
- 运行环境：Debian/Ubuntu 系发行版，需 root/sudo。强依赖 `apt`、`curl`、`wget`、`git`、`jq`、`qrencode`、`xz-utils`、`debian-keyring`、`debian-archive-keyring`、`apt-transport-https`。
- 配置存储：`/etc/caddy/naive_config.json`（脚本自动生成/持久化），Caddy 配置写入 `/etc/caddy/Caddyfile`，脚本写入的块以 `_naive_config_begin_/end_` 包裹。

## 常用命令
- 一键安装（默认交互）：
  ```bash
  apt update
  apt install -y curl
  bash <(curl -L https://github.com/viryaka/install_naive_l4/raw/main/install.sh)
  ```
- 跳过交互直接参数化（熟悉后使用）：
  ```bash
  bash <(curl -L https://github.com/viryaka/install_naive_l4/raw/main/install.sh) <domain> [netstack] [port] [username] [password]
  ```
  - `netstack=6` 表示 IPv6 入站，脚本会安装 WARP 获得 IPv4 出站；未提供密码时与用户名相同。
- 自定义编译 Caddy（含 forwardproxy/l4/cloudflare 插件）：
  ```bash
  bash buildcaddy.sh
  ```
  产物 `./caddy` 会覆盖系统 Caddy（install.sh 中可选 “预编译/重编译”）。
- 安装后进入菜单（已存在配置时默认进入）：`install.sh` 运行后提供菜单，可查看/改配置、重生成 Caddyfile、更新 Caddy 等。
- 卸载 Caddy（README）：
  ```bash
  rm /etc/apt/sources.list.d/caddy-stable.list
  apt remove -y caddy
  ```

## 脚本行为与注意点（install.sh）
- 依赖检查：强制 root，自动 `apt-get update` & 安装依赖。
- 配置流程：
  - 首次运行：采集域名、端口、模式（file_server 默认 / reverse_proxy 可选）、Cloudflare API Key、Naive 用户（至少 1 个）、可选中转（forward 到落地机）、可选业务域名绑定（名称/域名/本地端口）、选择 Caddy 来源（预编译或重编译）。
  - 配置保存到 `/etc/caddy/naive_config.json`，随后生成 Caddyfile，`caddy validate` 校验通过才落盘；失败会回滚。
- 菜单项（主要功能）：
  1) 查看配置
  2) 配置中转（443/80 -> 落地机）
  3) 管理业务域名列表（增改删域名、本地端口）
  4) 修改 Cloudflare Key
  5) 管理 Naive 用户（增/改密/删）
  6) 修改域名/端口
  7) 切换 file_server / reverse_proxy
  8) 重新生成 Caddyfile 并重启（同时打印 Naive 连接 URL 与 QR）
  9) 更新 Caddy（预编译/重编译）
  10) 退出
- Caddy 安装/更新：
  - 预编译：从 `klzgrad/forwardproxy` release 获取 `caddy-forwardproxy-naive.tar.xz`，失败回退到 `v2.10.0-naive`。
  - 重编译：调用 `buildcaddy.sh`（Go 最新版 + `xcaddy`，插件 forwardproxy@naive / caddy-l4 / cloudflare）。
  - 替换：停止服务后复制 `/tmp/caddy` 到 `/usr/bin/`。
- Caddyfile 生成：
  - 全局 `order forward_proxy first`，可选 layer4 中转，主站 forward_proxy + file_server 或 reverse_proxy；业务域名监听 8443 反代到本地端口；Cloudflare DNS TLS 可选。
  - 现有 Caddyfile 无标记块时提示覆盖策略并自动备份（`/etc/caddy/Caddyfile.bak_时间戳`）。
- 产出：Naive 连接 URL 写入 `~/_naive_url_` 并生成终端 QR。

## 配置模板
- `Caddyfile.example` 展示：
  - 全局 http_port 8080，layer4 将 443/80 流量按 SNI/默认路由分发到本地 8443 或远端转发 IP。
  - 多业务域名示例（域名:8443 -> 本地端口，Cloudflare DNS），Naive 区块含 forward_proxy + reverse_proxy 上游。

## 需求背景（prd1.md 摘要）
- 在原本本地 Naive 代理基础上：
  1) 支持中转代理（落地机 IP/端口可配置，安装与单独配置均可选）。
  2) 支持多业务域名绑定本地端口（增改删，单一 Cloudflare key 复用）。
  3) 支持 Caddy 更新（预编译或重编译 l4 版本）。
  4) 保留 file_server，支持切换反代并可改上游。
  5) 上述配置既可安装时设置，也可后续菜单管理。
  6) 本地 Naive 配置可改域名/端口、管理用户。

## 开发/修改提示
- 所有变更需考虑 `_naive_config_begin_/end_` 标记的生成与覆盖逻辑，以及 `caddy validate` 校验。
- 脚本假定 `apt` 环境与 root 权限；不要移除依赖安装步骤或交互校验逻辑。
- `buildcaddy.sh` 会下载并安装最新 Go 到 `/usr/local/go`，覆盖系统 Go；注意潜在副作用。
- 无自动化测试；手动验证路径：运行 install.sh -> 选择预编译或重编译 -> 生成并验证 Caddyfile -> `service caddy restart`。
