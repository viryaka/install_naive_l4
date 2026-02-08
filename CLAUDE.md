# CLAUDE.md

本文件用于指导 Claude Code 在本仓库工作，确保脚本全部功能覆盖、编辑安全与一致性。

## 仓库概览
- 纯 Shell：`install.sh`（主安装/配置/菜单），`buildcaddy.sh`（自编译 Caddy），`Caddyfile.example`（模板），`prd1.md`（需求）。
- 运行环境：Debian/Ubuntu，需 root/sudo；强依赖 `apt`、`curl`、`wget`、`git`、`jq`、`qrencode`、`xz-utils`、`debian-keyring`、`debian-archive-keyring`、`apt-transport-https`。
- 配置存储：`/etc/caddy/naive_config.json`；Caddy 配置写入 `/etc/caddy/Caddyfile`，生成块以 `_naive_config_begin_` / `_naive_config_end_` 包裹。

## 核心功能一览（install.sh）
- 安装/更新 Caddy：预编译（klzgrad release，失败回退 v2.10.0-naive）或自编译（`buildcaddy.sh`，含 forwardproxy@naive / caddy-l4 / cloudflare）。中转启用时自动改为自编译（预编译无 l4）。
- 初始配置：域名、端口、模式（file_server 默认 / reverse_proxy 可选）、Cloudflare Key、至少 1 个 Naive 用户、中转开关+落地机、业务域名列表（名称/域名/本地端口）、Caddy 来源选择。
- 菜单（10 项）：
  1) 查看配置
  2) 配置中转（启用/禁用 + 落地机 IP/端口；启用强制自编译）
  3) 管理业务域名（增/改/删）
  4) 修改 Cloudflare Key
  5) 管理 Naive 用户（增/改密/删）
  6) 修改域名/端口
  7) 切换 file_server / reverse_proxy（可改上游）
  8) 重新生成 Caddyfile 并重启（校验 + Naive URL/QR 输出）
  9) 更新 Caddy（预编译/重编译，受中转约束）
  10) 退出
- 生成与校验：写入临时 Caddyfile → `caddy validate` → 失败回滚；若原文件无标记块则提示并自动备份 `/etc/caddy/Caddyfile.bak_时间戳`。
- 输出：Naive 连接 URL（base64）写入 `~/_naive_url_`，并打印终端 QR。

## 自编译脚本（buildcaddy.sh）
- 获取最新 Go，安装到 `/usr/local/go`（会覆盖系统 Go）。
- `xcaddy build` 插件：`forwardproxy@naive`、`caddy-l4`、`cloudflare`；产物复制到当前目录 `./caddy`（install.sh 会再覆盖系统 `/usr/bin/caddy`）。

## Caddyfile 示例要点（Caddyfile.example）
- 全局：`order forward_proxy first`，`http_port 8080` 避免自动占 80。
- Layer4 中转示例：443/80 按 SNI/默认路由分发到本地 8443 或远端落地机。
- 业务域名模板：domain:8443 -> 本地端口，Cloudflare DNS，绑定 127.0.0.1。
- Naive 区块：:8443 与本地域名:8443，Cloudflare TLS，forward_proxy + 可选 reverse_proxy 上游。

## 需求约束（prd1.md 摘要）
- 中转可选；启用需 caddy-l4（故必须自编译）。
- 业务域名可安装时或菜单管理，复用单一 Cloudflare Key。
- 支持 Caddy 更新（预编译 / 重编译）。
- 保留 file_server，允许切换反代并改上游。
- Naive 本地配置可改域名/端口与用户。

## 开发/修改注意
- 始终保留并正确生成 `_naive_config_begin_/end_` 包裹块；处理无标记时的备份/覆盖策略。
- 不移除依赖安装、root 检查、交互校验逻辑。
- 修改涉及生成/校验流程时，确保 `caddy validate` 前后逻辑与回滚不被破坏。
- 自编译会覆盖 `/usr/local/go` 与 `/usr/bin/caddy`，需在说明中提醒。
- 无自动化测试；手动验证路径：运行 install.sh → 选择预编译或自编译 → 生成并验证 Caddyfile → `service caddy restart`。

## 常用命令
- 一键安装（交互）：
  ```bash
  apt update
  apt install -y curl
  bash <(curl -L https://github.com/viryaka/install_naive_l4/raw/main/install.sh)
  ```
- 参数化（跳过交互）：
  ```bash
  bash <(curl -L https://github.com/viryaka/install_naive_l4/raw/main/install.sh) <domain> [netstack] [port] [username] [password]
  # netstack=6 时安装 WARP 获得 IPv4 出站；缺省密码=用户名
  ```
- 自编译 Caddy：
  ```bash
  bash buildcaddy.sh
  ```

## 产物与路径
- 主配置：`/etc/caddy/naive_config.json`
- Caddy 配置：`/etc/caddy/Caddyfile`（标记块包裹；未标记先备份再覆盖）
- 备份：`/etc/caddy/Caddyfile.bak_时间戳`
- Naive URL：`~/_naive_url_`（同步终端二维码）

## 变更检查清单（自查）
- 菜单 1~10 功能是否覆盖、提示是否准确。
- 中转→自编译强制逻辑是否保留。
- 生成流程：标记块、备份、临时文件验证与回滚是否完好。
- Caddy 版本来源描述是否完整（预编译 fallback、自编译插件与 Go 覆盖提示）。
- 依赖/权限假设未被删除或弱化。

