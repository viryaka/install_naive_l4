#!/usr/bin/env bash
set -euo pipefail

# ===============================
# 彩色输出与通用函数
# ===============================
red='\e[91m'
green='\e[92m'
yellow='\e[93m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'
_red() { echo -e "${red}$*${none}"; }
_green() { echo -e "${green}$*${none}"; }
_yellow() { echo -e "${yellow}$*${none}"; }
_magenta() { echo -e "${magenta}$*${none}"; }
_cyan() { echo -e "${cyan}$*${none}"; }
error() { echo -e "\n${red}输入错误!${none}\n"; }
pause() { read -rsp "$(echo -e "按 ${green}Enter 回车键${none} 继续....或按 ${red}Ctrl + C${none} 取消.")" -d $'\n'; echo; }

run_with_context() {
  local label="$1"
  shift
  local rc
  set +e
  "$@"
  rc=$?
  set -euo pipefail
  if [[ ${rc} -ne 0 ]]; then
    _red "${label} 失败"
    return ${rc}
  fi
  return 0
}

# ===============================
# 常量与默认配置
# ===============================
CONFIG_PATH="/etc/caddy/naive_config.json"
CADDYFILE="/etc/caddy/Caddyfile"
DEFAULT_CONFIG='{
  "naive_domain": "",
  "naive_port": 443,
  "mode": "file_server",
  "reverse_upstream": "https://example.org",
  "users": [],
  "transit": {"enabled": false, "forward_ip": "", "forward_port": 443},
  "cloudflare_key": "",
  "services": [],
  "caddy_source": "prebuilt"
}'
FALLBACK_FORWARDPROXY_TAG="v2.10.0-naive"
DEFAULT_SELF_BUILT_VERSION="v2.10.0-naive"

config="${DEFAULT_CONFIG}"
# 确保 set -u 下有默认值，避免未赋值引用
LAST_CADDY_MODULE_STATUS="未检测 (未运行 get_local_caddy_info)"

# ===============================
# 依赖检查
# ===============================
ensure_deps() {
  if [[ ${EUID} -ne 0 ]]; then
    _red "请使用 root 用户或 sudo 运行此脚本"
    exit 1
  fi
  apt-get -y update
  apt-get -y install curl wget sudo git jq qrencode xz-utils debian-keyring debian-archive-keyring apt-transport-https
}

# ===============================
# 配置读写
# ===============================
clean_users() {
  config=$(echo "${config}" | jq '
    .users |= (
      [ .[]?
        | {name: ((.name // "" ) | tostring | gsub("^\\s+|\\s+$"; "")), password: (.password // "")}
        | select(.name != "")
      ]
    )
  ')
}

load_config() {
  if [[ -f "${CONFIG_PATH}" ]]; then
    config=$(cat "${CONFIG_PATH}" 2>/dev/null || echo "${DEFAULT_CONFIG}")
  else
    mkdir -p "$(dirname "${CONFIG_PATH}")"
    echo "${DEFAULT_CONFIG}" > "${CONFIG_PATH}"
    config="${DEFAULT_CONFIG}"
  fi
  clean_users
}

save_config() {
  local tmp_file
  clean_users
  tmp_file=$(mktemp)
  echo "${config}" | jq '.' > "${tmp_file}"
  install -d -m 755 "$(dirname "${CONFIG_PATH}")"
  install -m 600 "${tmp_file}" "${CONFIG_PATH}"
  chown root:root "${CONFIG_PATH}"
  rm -f "${tmp_file}"
}

cfg_get() {
  echo "${config}" | jq -r "$1"
}

cfg_set() {
  # $1: jq expression
  config=$(echo "${config}" | jq "$1")
}

ensure_transit_build_source() {
  local transit_enabled caddy_source changed=0
  transit_enabled=$(cfg_get '.transit.enabled')
  caddy_source=$(cfg_get '.caddy_source')
  if [[ "${transit_enabled}" == "true" && "${caddy_source}" == "prebuilt" ]]; then
    cfg_set '.caddy_source="build"'
    _yellow "已启用中转，预编译 Caddy 不含 caddy-l4，自动切换为自编译以支持中转"
    changed=1
  fi
  if [[ ${changed} -eq 1 ]]; then
    return 0
  fi
  return 1
}

# ===============================
# 版本获取与比对
# ===============================
fetch_latest_naive_tag() {
  local tag
  tag=$(curl -s https://api.github.com/repos/klzgrad/forwardproxy/releases/latest | jq -r '.tag_name' 2>/dev/null || echo "${FALLBACK_FORWARDPROXY_TAG}")
  if [[ -z "${tag}" || "${tag}" == "null" ]]; then
    tag="${FALLBACK_FORWARDPROXY_TAG}"
  fi
  echo "${tag}"
}

get_local_caddy_info() {
  local bin="$(command -v caddy || true)" version cfg_version modules has_forwardproxy has_l4
  local module_status="未包含naive插件，未包含caddy-l4插件"
  LAST_CADDY_MODULE_STATUS="${module_status}"

  if [[ -z "${bin}" ]]; then
    LAST_CADDY_MODULE_STATUS="${module_status}"
    echo "未安装"
    return
  fi

  version=$(caddy version 2>/dev/null | awk '{print $3}' || true)
  cfg_version=$(cfg_get '.caddy_version')
  if [[ -z "${version}" || "${version}" == "unknown" ]]; then
    if [[ -n "${cfg_version}" && "${cfg_version}" != "null" ]]; then
      version="${cfg_version}"
    else
      version="unknown"
    fi
  fi

  modules=$(caddy list-modules 2>/dev/null || true)
  if [[ -n "${modules}" ]]; then
    if echo "${modules}" | grep -Eq 'forward[_-]?proxy|forwardproxy'; then
      has_forwardproxy="yes"
    else
      has_forwardproxy="no"
    fi
    if echo "${modules}" | grep -Eq '(^|\.)layer4(\.|$)'; then
      has_l4="yes"
    else
      has_l4="no"
    fi
  else
    has_forwardproxy="unknown"
    has_l4="unknown"
  fi

  if [[ "${has_forwardproxy}" == "yes" && "${has_l4}" == "yes" ]]; then
    module_status="已包含naive和caddy-l4插件"
  elif [[ "${has_forwardproxy}" == "yes" && "${has_l4}" == "no" ]]; then
    module_status="已包含naive插件，未包含caddy-l4插件"
  elif [[ "${has_forwardproxy}" == "no" && "${has_l4}" == "yes" ]]; then
    module_status="已包含caddy-l4插件，未包含naive插件"
  else
    module_status="未包含naive插件，未包含caddy-l4插件"
  fi

  LAST_CADDY_MODULE_STATUS="${module_status}"
  echo "${version} (naive: ${module_status})"
  return 0
}

get_local_build_tag_hint() {
  # 自编译若无法解析版本，可直接使用固定基线（本次按预编译 v2.10.0 作为自编译版本号）
  echo "self-built (基于 ${DEFAULT_SELF_BUILT_VERSION}，含 forwardproxy@naive + caddy-l4)"
}

# ===============================
# 输入校验与提示
# ===============================
validate_domain() { [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]]; }
validate_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$|^([0-9a-fA-F:]+)$ ]]; }
validate_port() { local p="$1"; [[ ${p} -ge 1 && ${p} -le 65535 && ${p} -ne 80 ]]; }
validate_user() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

prompt_domain() {
  local value=""
  while :; do
    read -rp "请输入域名: " value
    if [[ -n "${value}" && $(validate_domain "${value}" && echo 1) ]]; then
      echo "${value}"; return
    fi
    error
  done
}

prompt_port() {
  local default_port="$1" value=""
  while :; do
    read -rp "请输入端口(非80, 默认${default_port}): " value
    [[ -z "${value}" ]] && value="${default_port}"
    if validate_port "${value}"; then
      echo "${value}"; return
    fi
    error
  done
}

prompt_ip() {
  local value=""
  while :; do
    read -rp "请输入落地机IP: " value
    if validate_ip "${value}"; then
      echo "${value}"; return
    fi
    error
  done
}

prompt_yes_no() {
  local prompt="$1" default_ans="$2" timeout="${3:-0}" newline_before="${4:-false}" ans
  # 规范默认提示：默认是 Y 则 "Y/n"，默认是 N 则 "y/N"
  local suffix_default="Y/n"
  [[ "${default_ans}" == "N" ]] && suffix_default="y/N"
  [[ "${newline_before}" == "true" ]] && echo
  while :; do
    if [[ "${timeout}" -gt 0 ]]; then
      if ! read -rt "${timeout}" -rp "${prompt} (${suffix_default}, 默认${default_ans}, ${timeout}s 超时默认): " ans; then
        ans="${default_ans}"
        echo
      fi
    else
      read -rp "${prompt} (${suffix_default}, 默认${default_ans}): " ans
    fi
    [[ -z "${ans}" ]] && ans="${default_ans}"
    case "$ans" in
      [yY]) echo "Y"; return ;;
      [nN]) echo "N"; return ;;
      *) error ;;
    esac
  done
}

prompt_user_pwd() {
  local uname pwd
  while :; do
    read -rp "请输入用户名(字母数字._-): " uname
    if validate_user "${uname}"; then break; else error; fi
  done
  while :; do
    read -rsp "请输入密码: " pwd
    echo
    [[ -n "${pwd}" ]] && break || error
  done
  echo "${uname}:${pwd}"
}

# ===============================
# Caddy 安装/更新
# ===============================
add_caddy_repo() {
  if ! run_with_context "获取 Caddy GPG key" bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes"; then
    return 1
  fi
  if ! run_with_context "写入 Caddy 源 list" bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null"; then
    return 1
  fi
  if ! run_with_context "apt-get update" sudo apt-get update; then
    return 1
  fi
  if ! run_with_context "apt-get install caddy" sudo apt-get install -y caddy; then
    return 1
  fi
  systemctl enable caddy
}

download_prebuilt() {
  local tag url dl_log
  tag=$(fetch_latest_naive_tag)
  url="https://github.com/klzgrad/forwardproxy/releases/download/${tag}/caddy-forwardproxy-naive.tar.xz"
  dl_log=$(mktemp)
  _yellow "下载预编译Caddy (${tag}) -> ${url}"
  cd /tmp
  rm -rf caddy-forwardproxy-naive caddy-forwardproxy-naive.tar.xz
  if ! run_with_context "下载预编译包" wget "${url}" >"${dl_log}" 2>&1; then
    _red "下载失败，使用回退版本 ${FALLBACK_FORWARDPROXY_TAG}"
    url="https://github.com/klzgrad/forwardproxy/releases/download/${FALLBACK_FORWARDPROXY_TAG}/caddy-forwardproxy-naive.tar.xz"
    if ! run_with_context "下载回退预编译包" wget "${url}" >"${dl_log}" 2>&1; then
      _red "回退版本下载仍失败，日志如下："
      cat "${dl_log}" >&2
      rm -f "${dl_log}"
      return 1
    fi
  fi
  if ! run_with_context "解压预编译包" tar -xf caddy-forwardproxy-naive.tar.xz >"${dl_log}" 2>&1; then
    _red "解压预编译包失败，日志如下："
    cat "${dl_log}" >&2
    rm -f "${dl_log}"
    return 1
  fi
  rm -f "${dl_log}"
  cd caddy-forwardproxy-naive
}

build_caddy() {
  _yellow "调用 buildcaddy.sh 编译 Caddy"
  cd /tmp
  if ! run_with_context "执行 buildcaddy.sh" bash -c "bash <( curl -L https://raw.githubusercontent.com/viryaka/install_naive_l4/refs/heads/main/buildcaddy.sh )"; then
    _red "buildcaddy.sh 执行失败（自编译 Caddy 失败）"
    return 1
  fi
}

replace_caddy_bin() {
  local cp_log
  cp_log=$(mktemp)
  if ! run_with_context "停止 caddy 服务" service caddy stop >"${cp_log}" 2>&1; then
    _yellow "service caddy stop 出现警告（可忽略继续）："
    cat "${cp_log}" >&2
  fi
  if ! run_with_context "复制 caddy 二进制" cp /tmp/caddy /usr/bin/ >"${cp_log}" 2>&1; then
    _red "复制 /tmp/caddy 到 /usr/bin/ 失败，日志如下："
    cat "${cp_log}" >&2
    rm -f "${cp_log}"
    return 1
  fi
  rm -f "${cp_log}"
}

install_or_update_caddy() {
  local source="$1"

  # 中转强制自编译兜底
  if [[ $(cfg_get '.transit.enabled') == "true" && "${source}" == "prebuilt" ]]; then
    _yellow "中转启用时预编译 Caddy 不含 caddy-l4，自动改为自编译"
    source="build"
  fi
  if ! add_caddy_repo; then
    _red "配置 Caddy 源失败，更新中止"
    return 1
  fi
  if [[ "${source}" == "prebuilt" ]]; then
    if ! download_prebuilt; then
      _red "下载预编译 Caddy 失败，更新中止"
      return 1
    fi
  else
    if ! build_caddy; then
      _red "自编译 Caddy 失败，更新中止"
      return 1
    fi
  fi
  if ! replace_caddy_bin; then
    _red "替换 caddy 二进制失败，更新中止"
    return 1
  fi
}

# ===============================
# xkcd 页面
# ===============================
prepare_xkcd() {
  rm -rf /var/www/xkcdpw-html
  git clone https://github.com/crazypeace/xkcd-password-generator -b "master" /var/www/xkcdpw-html --depth=1
}

# ===============================
# Caddyfile 生成
# ===============================
generate_caddyfile() {
  local naive_domain naive_port mode reverse_upstream cf_key transit_enabled transit_ip transit_port
  naive_domain=$(cfg_get '.naive_domain')
  naive_port=$(cfg_get '.naive_port')
  mode=$(cfg_get '.mode')
  reverse_upstream=$(cfg_get '.reverse_upstream')
  cf_key=$(cfg_get '.cloudflare_key')
  transit_enabled=$(cfg_get '.transit.enabled')
  transit_ip=$(cfg_get '.transit.forward_ip')
  transit_port=$(cfg_get '.transit.forward_port')

  local tmp_block="" tmp_clean="" tmp_final=""
  local overwrite_all=false
  local backup_done=false
  tmp_block=$(mktemp) || { _red "mktemp 创建 tmp_block 失败"; return 1; }
  tmp_clean=$(mktemp) || { _red "mktemp 创建 tmp_clean 失败"; rm -f "${tmp_block:-}"; return 1; }
  tmp_final=$(mktemp) || { _red "mktemp 创建 tmp_final 失败"; rm -f "${tmp_block:-}" "${tmp_clean:-}"; return 1; }

  # 构建域名列表用于 SNI 本地匹配
  if [[ -f "${CADDYFILE}" ]]; then
    if ! grep -q "_naive_config_begin_" "${CADDYFILE}"; then
      echo "检测到现有 Caddyfile 未包含 Naive 标记块。"
      echo "请选择覆盖策略："
      echo "1) 直接覆盖现有 Caddyfile（不做备份，风险更高）"
      echo "2) 先备份现有 Caddyfile，再覆盖（推荐/默认）"
      while :; do
        if ! read -rt 20 -rp "请选择 [1-2]（20s 超时默认 2）: " choice; then
          choice="2"
          echo
        fi
        [[ -z "${choice}" ]] && choice="2"
        case "${choice}" in
          1)
            overwrite_all=true
            backup_done=true
            break
            ;;
          2)
            cp "${CADDYFILE}" "/etc/caddy/Caddyfile.bak_$(date +%Y%m%d%H%M%S)"
            overwrite_all=true
            backup_done=true
            break
            ;;
          *)
            error
            ;;
        esac
      done
    fi
  fi

  # 构建域名列表用于 SNI 本地匹配（列表语法）
  local sni_list=""
  if [[ -n "${naive_domain}" ]]; then
    sni_list="${naive_domain}"
  fi
  while IFS= read -r svc; do
    local d
    d=$(echo "$svc" | jq -r '.domain')
    if [[ -n "$d" && "$d" != "null" ]]; then
      if [[ -z "${sni_list}" ]]; then
        sni_list="${d}"
      else
        sni_list+=" ${d}"
      fi
    fi
  done < <(echo "$config" | jq -c '.services[]?')

  {
    echo "# _naive_config_begin_"
    echo "{"
    echo "  order forward_proxy first"

    if [[ "${transit_enabled}" == "true" && -n "${sni_list}" ]]; then
      echo "  layer4 {"
      echo "    :443 {"
      echo "      @local tls sni ${sni_list}"
      echo "      route @local {"
      echo "        proxy localhost:8443"
      echo "      }"
      echo "      route {"
      echo "        proxy ${transit_ip}:${transit_port}"
      echo "      }"
      echo "    }"
      echo "    :80 {"
      echo "      route {"
      echo "        proxy ${transit_ip}:80"
      echo "      }"
      echo "    }"
      echo "  }"
    fi

    echo "}"

    if [[ "${transit_enabled}" == "true" ]]; then
      echo ":8443, ${naive_domain}:8443 {"
      echo "  bind 127.0.0.1"
    else
      echo ":${naive_port}, ${naive_domain}:${naive_port} {"
    fi
    if [[ -n "${cf_key}" && "${cf_key}" != "null" ]]; then
      echo "  tls {"
      echo "    dns cloudflare ${cf_key}"
      echo "  }"
    fi
    echo "  forward_proxy {"
    echo "    hide_ip"
    echo "    hide_via"
    echo "    probe_resistance"
    while IFS= read -r user; do
      local u p
      u=$(echo "$user" | jq -r '.name' | tr -d '[:space:]')
      p=$(echo "$user" | jq -r '.password' | tr -d '[:space:]')
      [[ -n "$u" && -n "$p" ]] && echo "    basic_auth ${u} ${p}"
    done < <(echo "$config" | jq -c '.users[]?')
    echo "  }"
    if [[ "${mode}" == "reverse_proxy" ]]; then
      echo "  reverse_proxy ${reverse_upstream} {"
      echo "    header_up Host {upstream_hostport}"
      echo "  }"
    else
      echo "  file_server {"
      echo "    root /var/www/xkcdpw-html"
      echo "  }"
    fi
    echo "}"

    while IFS= read -r svc; do
      local name domain lport
      name=$(echo "$svc" | jq -r '.name')
      domain=$(echo "$svc" | jq -r '.domain')
      lport=$(echo "$svc" | jq -r '.local_port')
      [[ -z "$domain" || "$domain" == "null" ]] && continue
      echo "${domain}:8443 {"
      echo "  bind 127.0.0.1"
      if [[ -n "${cf_key}" && "${cf_key}" != "null" ]]; then
        echo "  tls {"
        echo "    dns cloudflare ${cf_key}"
        echo "  }"
      fi
      echo "  reverse_proxy 127.0.0.1:${lport}"
      echo "}"
    done < <(echo "$config" | jq -c '.services[]?')

    echo "# _naive_config_end_"
  } > "${tmp_block}"

  if [[ "${overwrite_all:-false}" == "true" ]]; then
    cat "${tmp_block}" > "${tmp_final}"
  else
    if [[ -f "${CADDYFILE}" ]]; then
      [[ -n "${tmp_clean:-}" ]] || { _red "tmp_clean 未就绪"; return 1; }
      sed '/_naive_config_begin_/,/_naive_config_end_/d' "${CADDYFILE}" > "${tmp_clean}"
    else
      [[ -n "${tmp_clean:-}" ]] || { _red "tmp_clean 未就绪"; return 1; }
      > "${tmp_clean}"
    fi
    cat "${tmp_block}" "${tmp_clean}" > "${tmp_final}"
  fi

  if command -v caddy >/dev/null 2>&1; then
    local validate_log
    validate_log=$(mktemp)
    if ! caddy validate --config "${tmp_final}" --adapter caddyfile >"${validate_log}" 2>&1; then
      local failed_copy="/etc/caddy/Caddyfile.failed_$(date +%Y%m%d_%H%M%S)"
      local cp_err=""
      if ! cp "${tmp_final}" "${failed_copy}" 2>"${validate_log}.cp"; then
        cp_err=$(cat "${validate_log}.cp" 2>/dev/null || true)
      fi
      _red "caddy validate 失败，原配置未改动"
      _yellow "validate 输出 (临时文件 ${validate_log}):"
      cat "${validate_log}" >&2
      _yellow "已改用 tls sni 列表语法，如仍提示 layer4 相关错误，请确认域名列表合法且当前 caddy 已含 caddy-l4 模块 (caddy list-modules | grep layer4)"
      if [[ -n "${cp_err}" ]]; then
        _red "保存失败文件到 ${failed_copy} 失败: ${cp_err}"
      else
        _green "失败文件已保存: ${failed_copy}"
      fi
      rm -f "${tmp_block}" "${tmp_clean}" "${tmp_final}" "${validate_log}" "${validate_log}.cp"
      return 1
    fi
    rm -f "${validate_log}" "${validate_log}.cp"
  fi

  if [[ -f "${CADDYFILE}" && "${backup_done:-false}" == "false" ]]; then
    cp "${CADDYFILE}" "/etc/caddy/Caddyfile.bak_$(date +%Y%m%d%H%M%S)"
  fi
  mv "${tmp_final}" "${CADDYFILE}"
  # 确保目录与文件权限/属主，避免 caddy 无法读取
  install -d -m 755 "/etc/caddy"
  chown root:caddy "${CADDYFILE}" || true
  chmod 640 "${CADDYFILE}" || true
  [[ -n "${tmp_block:-}" ]] && rm -f "${tmp_block}"
  [[ -n "${tmp_clean:-}" ]] && rm -f "${tmp_clean}"
  [[ -n "${tmp_final:-}" ]] && rm -f "${tmp_final}"
  return 0
}

# 确保 /etc/caddy 目录权限
install -d -m 755 "/etc/caddy"

restart_caddy() {
  service caddy restart || service caddy start
}

# ===============================
# 配置展示与 QR
# ===============================
show_summary() {
  echo "当前配置："
  echo "  域名: $(cfg_get '.naive_domain')"
  echo "  端口: $(cfg_get '.naive_port')"
  echo "  模式: $(cfg_get '.mode')"
  echo "  反代上游: $(cfg_get '.reverse_upstream')"
  local cf_key
  cf_key=$(cfg_get '.cloudflare_key')
  if [[ -n "${cf_key}" && "${cf_key}" != "null" ]]; then
    echo "  Cloudflare Key: 已配置(隐藏)"
  else
    echo "  Cloudflare Key: 未配置"
  fi
  echo "  Transit: $(cfg_get '.transit.enabled') $(cfg_get '.transit.forward_ip'):$(cfg_get '.transit.forward_port')"
  if [[ $(cfg_get '.transit.enabled') == "true" ]]; then
    echo "  Caddy Source: build（中转需自编译，包含 caddy-l4）"
  else
    echo "  Caddy Source: $(cfg_get '.caddy_source')"
  fi
  echo "  用户:"
  echo "$config" | jq -r '.users[]? | "    - " + .name'
  echo "  业务域名:"
  echo "$config" | jq -r '.services[]? | "    - " + .name + " " + .domain + " -> " + (.local_port|tostring)'
}

print_naive_urls() {
  local naive_domain naive_port
  naive_domain=$(cfg_get '.naive_domain')
  naive_port=$(cfg_get '.naive_port')
  local output_file=~/_naive_url_
  umask 077
  : > "${output_file}"
  chmod 600 "${output_file}"
  while IFS= read -r user; do
    local u p url
    u=$(echo "$user" | jq -r '.name')
    p=$(echo "$user" | jq -r '.password')
    [[ -z "$u" || -z "$p" ]] && continue
    url="https://$(echo -n "${u}:${p}@${naive_domain}:${naive_port}" | base64 -w 0)"
    echo
    _cyan "Naive 用户: ${u}"
    _yellow "URL:"
    echo "${url}" | tee -a "${output_file}"
    _yellow "二维码 (用户 ${u}):"
    qrencode -t UTF8 "${url}" | tee -a "${output_file}"
  done < <(echo "$config" | jq -c '.users[]?')
}

# ===============================
# 交互收集（初装）
# ===============================
collect_initial_config() {
  _yellow "开始采集初始配置"
  local domain port mode upstream cfkey ans userpass
  domain=$(prompt_domain)
  port=$(prompt_port 443)
  mode="file_server"
  ans=$(prompt_yes_no "是否切换为反向代理模式" "N")
  if [[ "$ans" == "Y" ]]; then
    mode="reverse_proxy"
    read -rp "请输入反代上游URL(默认https://example.org): " upstream
    [[ -z "$upstream" ]] && upstream="https://example.org"
  else
    upstream="https://example.org"
  fi
  read -rp "请输入 Cloudflare API Key(可留空): " cfkey

  # 初始用户
  echo "请添加至少1个用户"
  while :; do
    userpass=$(prompt_user_pwd)
    local uname="${userpass%%:*}" pwd="${userpass##*:}"
    config=$(echo "$config" | jq --arg u "$uname" --arg p "$pwd" '.users += [{"name":$u,"password":$p}]')
    ans=$(prompt_yes_no "是否继续添加用户" "N" 0 true)
    [[ "$ans" == "N" ]] && break
  done

  # transit
  ans=$(prompt_yes_no "是否开启中转(443/80 转发至落地机)" "N")
  if [[ "$ans" == "Y" ]]; then
    local ip tport
    ip=$(prompt_ip)
    tport=$(prompt_port 443)
    cfg_set ".transit.enabled=true | .transit.forward_ip=\"${ip}\" | .transit.forward_port=${tport}"
    cfg_set '.caddy_source="build"'
    _yellow "启用中转需自编译 Caddy（包含 caddy-l4），已自动选择自编译"
  fi

  # 业务域名
  ans=$(prompt_yes_no "是否添加本地多业务域名" "N")
  while [[ "$ans" == "Y" ]]; do
    local svc_name svc_domain svc_port
    read -rp "业务名称: " svc_name
    svc_domain=$(prompt_domain)
    svc_port=$(prompt_port 3000)
    config=$(echo "$config" | jq --arg n "$svc_name" --arg d "$svc_domain" --argjson p "$svc_port" '.services += [{"name":$n,"domain":$d,"local_port":$p}]')
    ans=$(prompt_yes_no "继续添加业务?" "N")
  done

  # caddy source
  if [[ $(cfg_get '.transit.enabled') == "true" ]]; then
    cfg_set '.caddy_source="build"'
    _yellow "已启用中转，自动使用自编译 Caddy（包含 caddy-l4）"
  else
    ans=$(prompt_yes_no "选择预编译Caddy?（原 naive 作者版本，不支持中转；否则重编译含 caddy-l4）" "Y")
    if [[ "$ans" == "Y" ]]; then
      cfg_set '.caddy_source="prebuilt"'
    else
      cfg_set '.caddy_source="build"'
    fi
  fi

  cfg_set ".naive_domain=\"${domain}\" | .naive_port=${port} | .mode=\"${mode}\" | .reverse_upstream=\"${upstream}\" | .cloudflare_key=\"${cfkey}\""
  save_config
}

# ===============================
# 菜单操作
# ===============================
post_config_change_prompt() {
  local ans
  ans=$(prompt_yes_no "本地配置已更新，是否同步生成 Caddyfile 并重启？" "Y")
  if [[ "$ans" == "Y" ]]; then
    menu_regen
  else
    _yellow "如需生效，请稍后执行菜单 8 重新生成并重启"
  fi
}

menu_transit() {
  local ans ip p
  ans=$(prompt_yes_no "是否启用中转" $( [[ $(cfg_get '.transit.enabled') == "true" ]] && echo "Y" || echo "N" ))
  if [[ "$ans" == "Y" ]]; then
    ip=$(prompt_ip)
    p=$(prompt_port $(cfg_get '.transit.forward_port'))
    cfg_set ".transit.enabled=true | .transit.forward_ip=\"${ip}\" | .transit.forward_port=${p} | .caddy_source=\"build\""
    _yellow "启用中转需自编译 Caddy（包含 caddy-l4），后续更新将自动使用自编译"
  else
    cfg_set '.transit.enabled=false'
  fi
  save_config
  post_config_change_prompt
}

menu_services() {
  while :; do
    echo "业务列表："
    echo "$config" | jq -r '.services[]? | "  - " + .name + " " + .domain + " -> " + (.local_port|tostring)'
    echo "1) 新增  2) 修改  3) 删除  4) 返回"
    read -rp "选择: " op
    case "$op" in
      1)
        local n d p
        read -rp "业务名称: " n
        d=$(prompt_domain)
        p=$(prompt_port 3000)
        config=$(echo "$config" | jq --arg n "$n" --arg d "$d" --argjson p "$p" '.services += [{"name":$n,"domain":$d,"local_port":$p}]')
        save_config
        post_config_change_prompt
        ;;
      2)
        read -rp "输入要修改的业务名称: " n
        if echo "$config" | jq -e --arg n "$n" '.services[]? | select(.name==$n)' >/dev/null; then
          d=$(prompt_domain)
          p=$(prompt_port 3000)
          config=$(echo "$config" | jq --arg n "$n" --arg d "$d" --argjson p "$p" '(.services[] | select(.name==$n) | .domain)=$d | (.services[] | select(.name==$n) | .local_port)=$p')
          save_config
          post_config_change_prompt
        else
          _red "未找到该业务"
        fi
        ;;
      3)
        read -rp "输入要删除的业务名称: " n
        config=$(echo "$config" | jq --arg n "$n" ' .services |= map(select(.name!=$n))')
        save_config
        post_config_change_prompt
        ;;
      4) break ;;
      *) error ;;
    esac
  done
}

menu_cfkey() {
  read -rp "请输入新的 Cloudflare API Key(可空): " cf
  cfg_set ".cloudflare_key=\"${cf}\""
  save_config
  post_config_change_prompt
}

menu_users() {
  while :; do
    echo "当前用户："
    echo "$config" | jq -r '.users[]? | "  - " + .name'
    echo "1) 新增  2) 修改密码  3) 删除  4) 返回"
    read -rp "选择: " op
    case "$op" in
      1)
        local up u p
        up=$(prompt_user_pwd); u=${up%%:*}; p=${up##*:}
        config=$(echo "$config" | jq --arg u "$u" --arg p "$p" '.users += [{"name":$u,"password":$p}]')
        save_config
        post_config_change_prompt
        ;;
      2)
        read -rp "要修改的用户名: " u
        if echo "$config" | jq -e --arg u "$u" '.users[]? | select(.name==$u)' >/dev/null; then
          read -rp "新密码: " p
          config=$(echo "$config" | jq --arg u "$u" --arg p "$p" '(.users[] | select(.name==$u) | .password)=$p')
          save_config
          post_config_change_prompt
        else
          _red "未找到用户"
        fi
        ;;
      3)
        read -rp "要删除的用户名: " u
        config=$(echo "$config" | jq --arg u "$u" '.users |= map(select(.name!=$u))')
        save_config
        post_config_change_prompt
        ;;
      4) break ;;
      *) error ;;
    esac
  done
}

menu_domain_port() {
  local d p
  d=$(prompt_domain)
  p=$(prompt_port $(cfg_get '.naive_port'))
  cfg_set ".naive_domain=\"${d}\" | .naive_port=${p}"
  save_config
  post_config_change_prompt
}

menu_mode() {
  echo "当前模式: $(cfg_get '.mode')"
  echo "1) file_server  2) reverse_proxy"
  read -rp "选择: " op
  case "$op" in
    1) cfg_set '.mode="file_server"' ;;
    2) cfg_set '.mode="reverse_proxy"'; read -rp "反代上游URL: " up; [[ -z "$up" ]] && up="https://example.org"; cfg_set ".reverse_upstream=\"${up}\"" ;;
    *) error ; return ;;
  esac
  save_config
  post_config_change_prompt
}

menu_regen() {
  if generate_caddyfile; then
    restart_caddy
    print_naive_urls
  else
    _red "生成失败，已回滚"
  fi
}

menu_print_naive_urls() {
  load_config
  local naive_domain naive_port users_count
  naive_domain=$(cfg_get '.naive_domain')
  naive_port=$(cfg_get '.naive_port')
  users_count=$(echo "$config" | jq '(.users // []) | length')

  if [[ -z "$naive_domain" || "$naive_domain" == "null" || -z "$naive_port" || "$naive_port" == "null" ]]; then
    _red "当前未完成初始化，请先配置域名与端口"
    return
  fi

  if [[ "$users_count" -eq 0 ]]; then
    _red "当前未配置 Naive 用户，请先添加用户"
    return
  fi

  print_naive_urls
}

menu_update_caddy() {
  # 展示本地/最新版本信息
  local local_info latest_tag
  local_info=$(get_local_caddy_info)
  latest_tag=$(fetch_latest_naive_tag)

  _cyan "本地 Caddy: ${local_info}"
  _cyan "线上最新：预编译 ${latest_tag}"

  ensure_transit_build_source || true
  local source=$(cfg_get '.caddy_source')
  if [[ $(cfg_get '.transit.enabled') == "true" ]]; then
    _yellow "已启用中转：只能自编译（需要 caddy-l4 + naive 模块）"
    if [[ "${LAST_CADDY_MODULE_STATUS:-未检测}" != "已包含naive和caddy-l4插件" ]]; then
      _yellow "预编译缺少所需模块caddy-l4，启用中转必须自编译"
    fi
    local confirm
    confirm=$(prompt_yes_no "是否继续自编译更新 Caddy" "Y")
    [[ "${confirm}" == "N" ]] && { _yellow "已取消更新"; return; }
    source="build"
  else
    if [[ "${LAST_CADDY_MODULE_STATUS:-未检测}" != "已包含naive和caddy-l4插件" ]]; then
      _yellow "预编译缺少所需模块caddy-l4，启用中转必须自编译"
    fi

    echo "请选择更新来源："
    echo "1) 预编译（原 naive 作者版本，不含 caddy-l4）"
    echo "2) 自编译（包含 forwardproxy@naive + caddy-l4，可支持中转）"
    read -rp "选择 [1-2]: " op
    case "$op" in
      1) source="prebuilt" ;;
      2) source="build" ;;
      *) error; return ;;
    esac
  fi

  _yellow "将覆盖现有 caddy 可执行文件 (source=${source})"

  cfg_set ".caddy_source=\"${source}\""
  if [[ "${source}" == "build" ]]; then
    cfg_set ".caddy_version=\"${DEFAULT_SELF_BUILT_VERSION}\""
  fi
  save_config

  if ! install_or_update_caddy "${source}"; then
    _red "更新 Caddy 失败（见上方日志）"
    _yellow "Caddy 更新未完成，将返回菜单"
    pause
    return 1
  fi

  # 自编译成功后，将线上最新 tag 写入配置作为本地版本号；预编译则写实际下载 tag
  if [[ "${source}" == "build" ]]; then
    cfg_set ".caddy_version=\"$(fetch_latest_naive_tag)\""
  else
    cfg_set ".caddy_version=\"$(fetch_latest_naive_tag)\""
  fi
  save_config

  restart_caddy
}

menu_reset_init() {
  echo "选择重置方式："
  echo "A) 更名备份后重置"
  echo "B) 直接删除旧配置后重置"
  echo "C) 取消返回"

  local choice="" ts="" caddy_has_marker="yes"
  while :; do
    read -rp "请选择 [A/B/C]: " choice
    case "${choice}" in
      [aA]) choice="A"; break ;;
      [bB]) choice="B"; break ;;
      [cC]) choice="C"; break ;;
      *) error ;;
    esac
  done

  if [[ "${choice}" == "C" ]]; then
    _yellow "已取消重置"
    return
  fi

  ts=$(date +%Y%m%d%H%M%S)

  backup_if_exists() {
    local file="$1" suffix="$2"
    if [[ -f "${file}" ]]; then
      mv "${file}" "${file}.${suffix}_${ts}"
      _yellow "已备份 ${file} -> ${file}.${suffix}_${ts}"
    fi
  }

  delete_if_exists() {
    local file="$1"
    if [[ -f "${file}" ]]; then
      rm -f "${file}"
      _yellow "已删除 ${file}"
    fi
  }

  if [[ -f "${CADDYFILE}" ]]; then
    if ! grep -q "_naive_config_begin_" "${CADDYFILE}"; then
      caddy_has_marker="no"
    fi
  fi

  case "${choice}" in
    A)
      backup_if_exists "${CONFIG_PATH}" "bak"
      backup_if_exists "${CADDYFILE}" "bak"
      ;;
    B)
      if [[ "${caddy_has_marker}" == "no" ]]; then
        local confirm_del
        confirm_del=$(prompt_yes_no "检测到现有 Caddyfile 无标记块，删除将丢失自定义，确认删除吗" "N")
        if [[ "${confirm_del}" != "Y" ]]; then
          _yellow "已取消删除"
          return
        fi
      fi
      delete_if_exists "${CONFIG_PATH}"
      delete_if_exists "${CADDYFILE}"
      ;;
  esac

  config="${DEFAULT_CONFIG}"

  _yellow "开始重新采集初始化配置"
  collect_initial_config
  prepare_xkcd
  if ensure_transit_build_source; then
    save_config
  fi
  if ! install_or_update_caddy "$(cfg_get '.caddy_source')"; then
    _red "安装/更新 Caddy 失败，重置中止"
    return 1
  fi
  if generate_caddyfile; then
    restart_caddy
    print_naive_urls
  else
    _red "生成 Caddyfile 失败，已保留失败文件 (见上方日志)"
    return 1
  fi
}

menu_reset_init() {
  echo "选择重置方式："
  echo "A) 更名备份后重置"
  echo "B) 直接删除旧配置后重置"
  echo "C) 取消返回"

  local choice="" ts="" caddy_has_marker="yes"
  while :; do
    read -rp "请选择 [A/B/C]: " choice
    case "${choice}" in
      [aA]) choice="A"; break ;;
      [bB]) choice="B"; break ;;
      [cC]) choice="C"; break ;;
      *) error ;;
    esac
  done

  if [[ "${choice}" == "C" ]]; then
    _yellow "已取消重置"
    return
  fi

  ts=$(date +%Y%m%d%H%M%S)

  backup_if_exists() {
    local file="$1" suffix="$2"
    if [[ -f "${file}" ]]; then
      mv "${file}" "${file}.${suffix}_${ts}"
      _yellow "已备份 ${file} -> ${file}.${suffix}_${ts}"
    fi
  }

  delete_if_exists() {
    local file="$1"
    if [[ -f "${file}" ]]; then
      rm -f "${file}"
      _yellow "已删除 ${file}"
    fi
  }

  if [[ -f "${CADDYFILE}" ]]; then
    if ! grep -q "_naive_config_begin_" "${CADDYFILE}"; then
      caddy_has_marker="no"
    fi
  fi

  case "${choice}" in
    A)
      backup_if_exists "${CONFIG_PATH}" "bak"
      backup_if_exists "${CADDYFILE}" "bak"
      ;;
    B)
      if [[ "${caddy_has_marker}" == "no" ]]; then
        local confirm_del
        confirm_del=$(prompt_yes_no "检测到现有 Caddyfile 无标记块，删除将丢失自定义，确认删除吗" "N")
        if [[ "${confirm_del}" != "Y" ]]; then
          _yellow "已取消删除"
          return
        fi
      fi
      delete_if_exists "${CONFIG_PATH}"
      delete_if_exists "${CADDYFILE}"
      ;;
  esac

  config="${DEFAULT_CONFIG}"

  _yellow "开始重新采集初始化配置"
  collect_initial_config
  prepare_xkcd
  if ensure_transit_build_source; then
    save_config
  fi
  if ! install_or_update_caddy "$(cfg_get '.caddy_source')"; then
    _red "安装/更新 Caddy 失败，重置中止"
    return 1
  fi
  if generate_caddyfile; then
    restart_caddy
    print_naive_urls
  else
    _red "生成 Caddyfile 失败，已保留失败文件 (见上方日志)"
    return 1
  fi
}

menu_loop() {
  while :; do
    echo "-----------------------------"
    echo "1) 查看配置"
    echo "2) 配置中转"
    echo "3) 管理业务域名"
    echo "4) 修改 Cloudflare Key"
    echo "5) 管理 Naive 用户"
    echo "6) 修改域名/端口"
    echo "7) 切换 file_server/反代"
    echo "8) 重新生成 Caddyfile 并重启"
    echo "9) 更新 Caddy (预编译/重编译)"
    echo "10) 重新开始初始化（备份/删除现有配置）"
    echo "11) 查看当前 Naive URL/二维码"
    echo "12) 退出"
    read -rp "选择: " op
    case "$op" in
      1) show_summary ;;
      2) menu_transit ;;
      3) menu_services ;;
      4) menu_cfkey ;;
      5) menu_users ;;
      6) menu_domain_port ;;
      7) menu_mode ;;
      8) menu_regen ;;
      9) menu_update_caddy ;;
      10) menu_reset_init ;;
      11) menu_print_naive_urls ;;
      12) break ;;
      *) error ;;
    esac
  done
}

# ===============================
# 主流程
# ===============================
main() {
  sleep 1
  echo -e "                     _ ___                   \n ___ ___ __ __ ___ _| |  _|___ __ __   _ ___ \n|-_ |_  |  |  |-_ | _ |   |- _|  |  |_| |_  |\n|___|___|  _  |___|___|_|_|___|  _  |___|___|\n        |_____|               |_____|        "
  echo -e "${yellow}此脚本兼容 Debian 10+，执行前请确保符合环境${none}"
  echo -e "脚本说明: https://github.com/crazypeace/naive"
  echo -e "有问题加群: https://t.me/+q5WPfGjtwukyZjhl"
  echo "----------------------------------------------------------------"

  ensure_deps
  load_config

  if [[ -z "$(cfg_get '.naive_domain')" || "$(cfg_get '.naive_domain')" == "null" ]]; then
    pause
    collect_initial_config
    prepare_xkcd
    if ensure_transit_build_source; then
      save_config
    fi
    install_or_update_caddy "$(cfg_get '.caddy_source')"
    if generate_caddyfile; then
      restart_caddy
      print_naive_urls
    else
      _red "生成 Caddyfile 失败，请检查配置"
      exit 1
    fi
  else
    _yellow "检测到已存在配置，将直接进入菜单"
  fi

  menu_loop
  _green "已退出"
}

main "$@"
