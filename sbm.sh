#!/usr/bin/env bash
# sbm — sing-box 节点/中转管理脚本
# 由 Muse 从零编写。不含任何第三方脚本代码。
# 设计原则:
#   1. 核心只从 sing-box 官方 GitHub Release 下载, 有校验文件时强制 SHA-256 校验
#   2. 本脚本永不自更新, 不回传配置数据; 除包管理器和官方 Release 外, 仅在生成分享链接时查询公网 IP (api.ipify.org, 不发送任何配置)
#   3. 所有状态保存在 /etc/sbm/*.json, 配置由状态文件全量重建, 可审计可回滚
# 用法: 以 root 运行  bash sbm.sh   (可用 SBM_ROOT=/tmp/xxx 做沙盒测试)
set -uo pipefail
umask 077

ROOT="${SBM_ROOT:-}"
ETC="$ROOT/etc/sbm"
SB_ETC="$ROOT/etc/sing-box"
SB_BIN="$ROOT/usr/local/bin/sing-box"
SB_LINK="$ROOT/usr/local/bin/sbm"
UNIT="$ROOT/etc/systemd/system/sing-box.service"
CONF="$SB_ETC/config.json"
NODES="$ETC/nodes.json"
RELAY="$ETC/relay.json"
META="$ETC/meta.json"
OWNED="$ETC/.owned-files"
CERTDIR="$SB_ETC/certs"
VER="0.5.0"

C_R=$'\033[0m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_RED=$'\033[31m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_R" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_R" "$*"; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_R" "$*" >&2; }
valid_port() {
  local v="${1:-}"
  [[ "$v" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$v >= 1 && 10#$v <= 65535 ))
}
valid_ipv4() {
  local v="${1:-}" octet
  [[ "$v" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local IFS=.; read -r -a _octets <<<"$v"
  for octet in "${_octets[@]}"; do (( 10#$octet <= 255 )) || return 1; done
}
valid_public_ipv4() {
  valid_ipv4 "${1:-}" || return 1
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  a=$((10#$a)); b=$((10#$b)); c=$((10#$c))
  (( a > 0 && a < 224 && a != 10 && a != 127 )) || return 1
  (( a == 169 && b == 254 )) && return 1
  (( a == 172 && b >= 16 && b <= 31 )) && return 1
  (( a == 192 && b == 168 )) && return 1
  (( a == 100 && b >= 64 && b <= 127 )) && return 1
  (( a == 192 && b == 0 && c == 0 )) && return 1
  (( a == 192 && b == 0 && c == 2 )) && return 1
  (( a == 192 && b == 88 && c == 99 )) && return 1
  (( a == 198 && (b == 18 || b == 19) )) && return 1
  (( a == 198 && b == 51 && c == 100 )) && return 1
  (( a == 203 && b == 0 && c == 113 )) && return 1
  return 0
}
valid_domain() {
  local v="${1:-}" label
  [[ ${#v} -le 253 && "$v" =~ ^[A-Za-z0-9.-]+$ && "$v" != .* && "$v" != *. ]] || return 1
  [[ "$v" == *.* ]] || return 1
  local IFS=.; read -r -a _labels <<<"$v"
  for label in "${_labels[@]}"; do
    [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}
valid_ipv6() {
  local v="${1:-}" left right part count=0
  local -a left_parts=() right_parts=() parts=()
  [[ "$v" == *:* && "$v" != *:::* ]] || return 1
  if [[ "$v" == *::* ]]; then
    left="${v%%::*}"; right="${v#*::}"
    [[ "$right" != *::* ]] || return 1
    IFS=: read -r -a left_parts <<<"$left"
    IFS=: read -r -a right_parts <<<"$right"
    for part in "${left_parts[@]}" "${right_parts[@]}"; do
      [ -n "$part" ] || continue
      [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
      ((count+=1))
    done
    (( count < 8 ))
  else
    [[ "$v" != :* && "$v" != *: ]] || return 1
    IFS=: read -r -a parts <<<"$v"
    for part in "${parts[@]}"; do
      [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
      ((count+=1))
    done
    (( count == 8 ))
  fi
}
valid_host() {
  local v="${1:-}"
  [[ ${#v} -le 253 && "$v" != *[[:space:][:cntrl:]]* ]] || return 1
  if [[ "$v" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then valid_ipv4 "$v"; return; fi
  valid_domain "$v" || valid_ipv6 "$v"
}
valid_name() {
  local v="${1:-}"
  [[ ${#v} -ge 1 && ${#v} -le 64 && "$v" =~ ^[A-Za-z0-9_.\ -]+$ && "$v" != " "* && "$v" != *" " ]]
}
valid_path() { [[ "${1:-}" =~ ^/[A-Za-z0-9._~/%-]*$ && "$1" != *..* ]]; }
valid_service() { [[ "${1:-}" =~ ^[A-Za-z0-9_.-]{1,128}$ ]]; }
valid_user() { [[ "${1:-}" =~ ^[A-Za-z0-9_.-]{1,64}$ ]]; }
valid_choice() { local v="${1:-}" allowed="$2"; [[ " $allowed " == *" $v "* ]]; }

validate_prompt() {
  local p="$1" v="$2" n
  [[ ${#v} -le 65536 && "$v" != *[[:cntrl:]]* ]] || return 1
  case "$p" in
    *"确认卸载?"*|*"确认清空"*|*"启用 Salamander"*|*"启用 TLS"*|*"尝试校时"*)
      [[ "$v" == y || "$v" == Y || "$v" == n || "$v" == N ]] ;;
    *"Reality 伪装域名"*|*"TLS 域名"*|*"ShadowTLS 伪装域名"*) valid_domain "$v" ;;
    *"WebSocket 路径"*) valid_path "$v" ;;
    *"gRPC 服务名"*) valid_service "$v" ;;
    *"节点名称"*|*"新名称"*) valid_name "$v" ;;
    *"服务器地址"*|*"目标地址 (IP/域名)"*|*"新目标地址"*) valid_host "$v" ;;
    *"端口"*) valid_port "$v" ;;
    *"用户名 [user]"*) valid_user "$v" ;;
    *"用户名 (可空)"*) [[ -z "$v" ]] || valid_user "$v" ;;
    *"主菜单选项"*) valid_choice "$v" "0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19" ;;
    *"中转菜单选项"*) valid_choice "$v" "0 1 2 3 4 5 6 7 8" ;;
    *"转发菜单选项"*) valid_choice "$v" "0 1 2 3 4 5 6" ;;
    *"请输入协议选项"*|*"选择中转入口协议"*) valid_choice "$v" "0 1 2 3 4 5 6 7 8 9 10 11" ;;
    *"请选择加密方式"*) valid_choice "$v" "1 2 3 4 5 6 7 8" ;;
    *"协议 [1]TCP+UDP"*) valid_choice "$v" "1 2 3" ;;
    *"[1] sing-box 引擎"*) valid_choice "$v" "0 1 2" ;;
    *"[1] 每天 04:00"*) valid_choice "$v" "0 1 2" ;;
    *"[1] Cloudflare"*) valid_choice "$v" "0 1 2 3" ;;
    *"[1] vless:// 链接"*) valid_choice "$v" "0 1 2 3 4" ;;
    *"选择导入方式"*) valid_choice "$v" "0 1 2 3 4" ;;
    *"[1] 改名称"*) valid_choice "$v" "0 1 2" ;;
    *"[1] 目标地址"*) valid_choice "$v" "0 1 2 3 4" ;;
    *"输入要删除的序号"*|*"输入要删除的链路序号"*|*"输入要修改的序号"*|*"输入要修改的转发序号"*|*"选择要导出的落地节点"*|*"输入链路序号"*|*"删除序号"*)
      [[ "$v" == 0 ]] && return 0
      [[ "$v" =~ ^[0-9]{1,6}$ ]] || return 1
      case "$p" in
        *"落地节点"*) n=$(jq '.nodes|length' "$NODES" 2>/dev/null || echo 0) ;;
        *"链路序号"*) n=$(jq '.routes|length' "$RELAY" 2>/dev/null || echo 0) ;;
        *"删除序号"*) n=$(jq '.forwards|length' "$RELAY" 2>/dev/null || echo 0) ;;
        *"转发序号"*) n=$(jq '.forwards|length' "$RELAY" 2>/dev/null || echo 0) ;;
        *"链路"*) n=$(jq '.routes|length' "$RELAY" 2>/dev/null || echo 0) ;;
        *) n=$(jq '.nodes|length' "$NODES" 2>/dev/null || echo 0); [[ "$p" == *"链路"* ]] && n=$(jq '.routes|length' "$RELAY" 2>/dev/null || echo 0) ;;
      esac
      (( 10#$v >= 1 && 10#$v <= n )) ;;
    *"粘贴 vless:// 链接"*) parse_vless_link "$v" >/dev/null 2>&1 ;;
    *"粘贴 ss:// 链接"*) parse_ss_link "$v" >/dev/null 2>&1 ;;
    *"落地 Token"*) [[ "$v" == SBM1:* || "$v" == SBM2:* ]] ;;
    *"解密口令"*) [[ ${#v} -ge 8 && ${#v} -le 256 ]] ;;
    *"Snell 版本"*) valid_choice "$v" "5 6" ;;
    *) return 0 ;;
  esac
}
ask() {
  local p="$1" d="${2:-}" v
  while true; do
    printf '%s' "$p" >&2
    if ! IFS= read -r v; then
      v="$d"
      validate_prompt "$p" "$v" || { err "输入结束且默认值无效，已中止此操作"; return 1; }
      printf '%s' "$v"; return 0
    fi
    v="${v:-$d}"
    case "$p" in *"(y/N"*|*"(y/n"*|*" (y/N"*) v="${v,,}" ;; esac
    if validate_prompt "$p" "$v"; then
      case "$p" in
        *"端口"*) [[ "$v" =~ ^[0-9]+$ ]] && v=$((10#$v)) ;;
        *"序号"*|*"落地节点"*|*"删除序号"*) [[ "$v" =~ ^[0-9]+$ ]] && v=$((10#$v)) ;;
      esac
      printf '%s' "$v"; return 0
    fi
    warn "输入无效，请按提示重新输入" >&2
  done
}
pause(){ printf '按回车继续...' >&2; read -r _ || true; }

atomic_write() {
  local dest="$1" dir base tmp
  dir="${dest%/*}"; base="${dest##*/}"
  [ ! -L "$dest" ] && { [ ! -e "$dest" ] || [ -f "$dest" ]; } || { err "原子写入目标不是普通文件，拒绝替换: $dest"; return 1; }
  tmp=$(mktemp "$dir/.${base}.XXXXXX") || return 1
  if cat > "$tmp" && chmod 600 "$tmp" && mv -f -- "$tmp" "$dest"; then return 0; fi
  rm -f -- "$tmp"; return 1
}
acquire_state_lock() {
  has flock || { err "缺少 flock，无法安全锁定状态；请安装 util-linux 后重试"; return 1; }
  [ ! -L "$ETC" ] || { err "状态目录是符号链接，拒绝访问: $ETC"; return 1; }
  [ -d "$ETC" ] || mark_owned_if_new 'etc/sbm/' "$ETC" || return 1
  mkdir -p "$ETC" || return 1; chmod 700 "$ETC" || return 1
  [ ! -L "$ETC/.lock" ] || { err "状态锁文件是符号链接，拒绝访问"; return 1; }
  exec {SBM_LOCK_FD}>"$ETC/.lock" || return 1
  chmod 600 "$ETC/.lock" || { err "无法保护状态锁文件权限"; return 1; }
  flock -n "$SBM_LOCK_FD" || { err "另一个 sbm 实例正在修改状态，请稍后重试"; return 1; }
}
mark_owned_if_new() {
  local rel="$1" path="$2"
  [ ! -L "$path" ] || { err "目标是符号链接，拒绝替换: $path"; return 1; }
  [ -e "$path" ] && return 0
  record_owned "$rel"
}
owned_has() { [ -f "$OWNED" ] && grep -Fxq -- "$1" "$OWNED"; }
record_owned() {
  local rel="$1"
  [[ "$rel" =~ ^[A-Za-z0-9._/-]+$ && "$rel" != /* && "$rel" != *..* ]] || { err "拒绝记录不安全的所有权路径"; return 1; }
  [ ! -L "$ETC" ] || { err "状态目录是符号链接，拒绝写入所有权清单"; return 1; }
  mkdir -p "$ETC" && chmod 700 "$ETC" || { err "无法保护所有权清单目录"; return 1; }
  [ ! -L "$OWNED" ] && { [ ! -e "$OWNED" ] || [ -f "$OWNED" ]; } || { err "所有权清单不是普通文件，拒绝访问"; return 1; }
  touch "$OWNED" && chmod 600 "$OWNED" || { err "无法保护所有权清单权限"; return 1; }
  grep -Fxq -- "$rel" "$OWNED" 2>/dev/null || printf '%s\n' "$rel" >> "$OWNED"
}
unrecord_owned() {
  local rel="$1"
  owned_has "$rel" || return 0
  (grep -Fxv -- "$rel" "$OWNED" || true) | atomic_write "$OWNED"
}
restore_state() {
  local backup="$1" dest="$2"
  mv -f -- "$backup" "$dest" && chmod 600 "$dest" || { err "严重：状态回滚失败，需人工检查 $backup 与 $dest"; return 1; }
}
backup_state() {
  local src="$1" dest="${1}.bak" rel
  if [ -e "$dest" ] || [ -L "$dest" ]; then err "发现未处理的状态备份，拒绝覆盖: $dest"; return 1; fi
  rel="etc/sbm/${src##*/}.bak"
  record_owned "$rel" || return 1
  cp -- "$src" "$dest" && chmod 600 "$dest"
}

need_root() { [ "$(id -u)" = 0 ] || { err "需要 root 运行"; exit 1; }; }
has() { command -v "$1" >/dev/null 2>&1; }

install_deps() {
  local miss=()
  has jq || miss+=(jq); has curl || miss+=(curl); has openssl || miss+=(openssl)
  has flock || miss+=(util-linux); has ss || miss+=(iproute2)
  [ ${#miss[@]} -eq 0 ] && return 0
  warn "安装依赖: ${miss[*]}"
  if has apt-get; then apt-get update -qq && apt-get install -y -qq "${miss[@]}" >/dev/null
  elif has apk; then apk add --no-cache "${miss[@]}"
  elif has dnf; then dnf install -y "${miss[@]}"
  else err "未知包管理器, 请手动安装: ${miss[*]}"; return 1; fi
}

init_state() {
  local path
  for path in "$ETC" "$SB_ETC" "$CERTDIR"; do
    [ ! -L "$path" ] || { err "状态目录是符号链接，拒绝访问: $path"; return 1; }
  done
  [ ! -L "$OWNED" ] && { [ ! -e "$OWNED" ] || [ -f "$OWNED" ]; } || { err "所有权清单不是普通文件，拒绝访问"; return 1; }
  [ -d "$ETC" ] || mark_owned_if_new 'etc/sbm/' "$ETC" || return 1
  [ -d "$SB_ETC" ] || mark_owned_if_new 'etc/sing-box/' "$SB_ETC" || return 1
  [ -d "$CERTDIR" ] || mark_owned_if_new 'etc/sing-box/certs/' "$CERTDIR" || return 1
  install -d -m 700 "$ETC" "$SB_ETC" "$CERTDIR" || return 1
  if [ ! -f "$NODES" ]; then mark_owned_if_new 'etc/sbm/nodes.json' "$NODES" || return 1; printf '%s\n' '{"nodes":[]}' | atomic_write "$NODES" || return 1; fi
  if [ ! -f "$RELAY" ]; then mark_owned_if_new 'etc/sbm/relay.json' "$RELAY" || return 1; printf '%s\n' '{"routes":[],"forwards":[]}' | atomic_write "$RELAY" || return 1; fi
  if [ ! -f "$META" ]; then mark_owned_if_new 'etc/sbm/meta.json' "$META" || return 1; printf '%s\n' '{"dns":"cf"}' | atomic_write "$META" || return 1; fi
  for path in "$NODES" "$RELAY" "$META"; do
    [ ! -L "$path" ] && [ -f "$path" ] || { err "状态文件不是普通文件，拒绝访问: $path"; return 1; }
  done
  chmod 700 "$ETC" "$SB_ETC" "$CERTDIR" || { err "无法保护状态目录权限"; return 1; }
  chmod 600 "$NODES" "$RELAY" "$META" || { err "无法保护敏感状态文件权限"; return 1; }
}

# ---------- 随机/生成 ----------
rand_port() { echo $(( (RANDOM % 40000) + 20000 )); }
rand_hex()  { openssl rand -hex "$1"; }
rand_pw()   { openssl rand -base64 18 | tr -d '/+=' | head -c "${1:-16}"; }
gen_uuid()  { if [ -x "$SB_BIN" ]; then "$SB_BIN" generate uuid; else cat /proc/sys/kernel/random/uuid; fi; }
_SBM_IP_CACHE=""; _SBM_IP_LOOKED=0
server_ip() { # 本进程内缓存, 避免一次操作多次查询公网 IP
  if [ "$_SBM_IP_LOOKED" = 0 ]; then
    _SBM_IP_LOOKED=1
    local candidate
    candidate=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    candidate="${candidate//$'\n'/}"
    valid_public_ipv4 "$candidate" && _SBM_IP_CACHE="$candidate"
  fi
  printf '%s' "$_SBM_IP_CACHE"
}

# ---------- 核心管理 ----------
core_version() { [ -x "$SB_BIN" ] && "$SB_BIN" version 2>/dev/null | head -1 | awk '{print $3}' || echo ""; }

core_install() {
  need_root; install_deps || return 1
  [ ! -L "$SB_BIN" ] || { err "sing-box 核心路径是符号链接，拒绝更新"; return 1; }
  [ ! -e "$SB_BIN" ] || [ -f "$SB_BIN" ] || { err "sing-box 核心目标不是普通文件，拒绝更新"; return 1; }
  if [ -e "$SB_BIN" ] && ! owned_has 'usr/local/bin/sing-box'; then
    if [ -f "$UNIT" ] && [ ! -L "$UNIT" ] && grep -Fq 'Description=sing-box service (managed by sbm)' "$UNIT"; then
      record_owned 'usr/local/bin/sing-box' || return 1
    else err "发现未登记的 sing-box 核心，拒绝覆盖以免影响现有安装: $SB_BIN"; return 1; fi
  fi
  local arch tarball url rel ver tmp digest actual
  case "$(uname -m)" in
    x86_64) arch="amd64" ;; aarch64) arch="arm64" ;; armv7l) arch="armv7" ;;
    *) err "不支持的架构: $(uname -m)"; return 1 ;;
  esac
  rel=$(curl -fsSL --max-time 20 https://api.github.com/repos/SagerNet/sing-box/releases/latest) || { err "获取官方版本失败"; return 1; }
  ver=$(printf '%s' "$rel" | jq -r '.tag_name' | sed 's/^v//')
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || { err "Release 版本号格式无效，拒绝拼接下载路径"; return 1; }
  tarball="sing-box-${ver}-linux-${arch}.tar.gz"
  digest=$(printf '%s' "$rel" | jq -r --arg n "$tarball" '.assets[]? | select(.name == $n) | .digest // empty' | head -1)
  [[ "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || { err "GitHub Release API 未提供该安装包的 SHA-256 摘要，按安全策略中止安装"; return 1; }
  url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/${tarball}"
  tmp=$(mktemp -d) || { err "无法创建下载临时目录，已中止安装"; return 1; }
  say "下载官方 sing-box v${ver} (${arch}) ..."
  curl --proto '=https' -fL --max-time 300 -o "$tmp/$tarball" "$url" || { err "下载失败"; rm -rf "$tmp"; return 1; }
  actual="sha256:$(sha256sum "$tmp/$tarball" | awk '{print $1}')"
  [ "${actual,,}" = "${digest,,}" ] || { err "安装包 SHA-256 与 GitHub Release API 摘要不符，已中止"; rm -rf "$tmp"; return 1; }
  ok "GitHub Release API SHA-256 校验通过: ${actual#sha256:}"
  tar -xzf "$tmp/$tarball" -C "$tmp" || { err "解压失败"; rm -rf "$tmp"; return 1; }
  [ ! -L "$SB_BIN" ] || { err "sing-box 路径是符号链接，拒绝覆盖"; rm -rf "$tmp"; return 1; }
  local insttmp
  insttmp=$(mktemp "${SB_BIN}.XXXXXX") || { err "无法创建核心安装临时文件"; rm -rf "$tmp"; return 1; }
  install -m 755 "$tmp/sing-box-${ver}-linux-${arch}/sing-box" "$insttmp" || { rm -f "$insttmp"; rm -rf "$tmp"; err "核心文件安装失败"; return 1; }
  record_owned 'usr/local/bin/sing-box' || { rm -f "$insttmp"; rm -rf "$tmp"; return 1; }
  mv -f "$insttmp" "$SB_BIN" || { rm -f "$insttmp"; rm -rf "$tmp"; err "无法原子替换 sing-box 核心"; return 1; }
  rm -rf "$tmp"
  ok "sing-box 已安装: $("$SB_BIN" version | head -1)"
  write_unit || { err "核心已安装，但 systemd 服务单元配置失败"; return 1; }
  enable_service || { err "核心已安装，但 systemd 自启设置失败"; return 1; }
}

write_unit() {
  [ -n "$ROOT" ] && return 0   # 沙盒模式不写 systemd
  [ ! -L "$UNIT" ] || { err "sing-box.service 是符号链接，拒绝覆盖"; return 1; }
  if [ -e "$UNIT" ] && ! grep -Fq 'Description=sing-box service (managed by sbm)' "$UNIT"; then
    err "发现非 sbm 管理的 sing-box.service，拒绝覆盖"; return 1
  fi
  if [ -e "$UNIT" ]; then record_owned 'etc/systemd/system/sing-box.service' || return 1
  else mark_owned_if_new 'etc/systemd/system/sing-box.service' "$UNIT" || return 1; fi
  local unit_tmp
  unit_tmp=$(mktemp "/etc/systemd/system/.sing-box.service.XXXXXX") || return 1
  cat > "$unit_tmp" <<EOF
[Unit]
Description=sing-box service (managed by sbm)
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=$SB_BIN run -c $CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  chmod 600 "$unit_tmp" && mv -f "$unit_tmp" "$UNIT" || { rm -f "$unit_tmp"; err "sing-box.service 原子写入失败"; return 1; }
  systemctl daemon-reload
}
enable_service() { [ -n "$ROOT" ] && return 0; systemctl enable sing-box >/dev/null 2>&1 || { err "服务自启设置失败, 请手动执行: systemctl enable sing-box"; return 1; }; }
svc() { # svc <action>
  if [ -n "$ROOT" ]; then say "(沙盒模式, 跳过 systemctl $1)"; return 0; fi
  systemctl "$1" sing-box
}
svc_state() {
  if [ -n "$ROOT" ]; then echo "沙盒"; return; fi
  systemctl is-active sing-box 2>/dev/null || echo "inactive"
}

core_uninstall() {
  need_root
  [ ! -L "$ETC" ] && [ ! -L "$OWNED" ] || { err "卸载安全检查失败：状态目录或所有权清单是符号链接"; return 1; }
  local a; a=$(ask "确认卸载? 将停止服务并删除核心与全部节点/中转配置 (y/N): " "n")
  [ "$a" = "y" ] || { say "已取消"; return; }
  if [ -z "$ROOT" ]; then
    if owned_has 'etc/systemd/system/sing-box.service'; then
      if [ -f "$UNIT" ] && [ ! -L "$UNIT" ] && grep -Fq 'Description=sing-box service (managed by sbm)' "$UNIT"; then
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
      else warn "sing-box.service 已不再匹配 SBM 标记；保留该服务且不停止它"; fi
    fi
    # 只移除 SBM 明确标记创建的精确 crontab 条目
    if owned_has 'etc/sbm/.cron-restart' && has crontab; then
      ( crontab -l 2>/dev/null | grep -Fxv '0 4 * * * /usr/bin/systemctl restart sing-box' || true ) | crontab - 2>/dev/null || warn "无法自动清理 SBM 定时重启条目；其他 crontab 行未触碰"
    fi
    # 仅清理所有权清单记录的 nft 表/服务
    if owned_has 'etc/sbm/sbm.nft'; then nft delete table ip sbm_fwd 2>/dev/null || true; fi
    if owned_has 'etc/systemd/system/sbm-nft.service'; then
      if [ -f /etc/systemd/system/sbm-nft.service ] && [ ! -L /etc/systemd/system/sbm-nft.service ] && grep -Fq 'Description=sbm nftables port forwarding' /etc/systemd/system/sbm-nft.service; then
        systemctl disable sbm-nft >/dev/null 2>&1 || true
      else warn "sbm-nft.service 已不再匹配 SBM 标记；保留该服务且不禁用它"; fi
    fi
    # UFW: 回收 sbm 管理的放行与转发规则 (在删状态目录之前读追踪表)
    if has ufw && [ -f "$ETC/fw.list" ]; then
      while read -r r; do [ -n "$r" ] && ufw delete allow "$r" >/dev/null 2>&1 || true; done < "$ETC/fw.list"
    fi
    if has ufw && [ -f "$ETC/fwroute.list" ]; then
      while read -r _ h p pr; do
        [ -n "${h:-}" ] || continue
        if [ "$pr" = "both" ]; then
          ufw route delete allow to "$h" port "$p" proto tcp >/dev/null 2>&1 || true
          ufw route delete allow to "$h" port "$p" proto udp >/dev/null 2>&1 || true
        else
          ufw route delete allow to "$h" port "$p" proto "$pr" >/dev/null 2>&1 || true
        fi
      done < "$ETC/fwroute.list"
    fi
    systemctl daemon-reload
  fi
  if [ -f "$OWNED" ]; then
    while IFS= read -r rel; do
      case "$rel" in
        etc/sbm/nodes.json) rm -f "$NODES" ;;
        etc/sbm/relay.json) rm -f "$RELAY" ;;
        etc/sbm/meta.json) rm -f "$META" ;;
        etc/sbm/.check.log|etc/sbm/.config.prev.json|etc/sbm/.cron-restart|etc/sbm/fw.list|etc/sbm/fwroute.list|etc/sbm/sbm.nft) rm -f -- "$ROOT/$rel" ;;
        etc/sbm/.route.json|etc/sbm/nodes.json.bak|etc/sbm/relay.json.bak|etc/sbm/meta.json.bak) rm -f -- "$ROOT/$rel" ;;
        etc/sbm/) rmdir "$ETC" 2>/dev/null || true ;;
        etc/sing-box/) rmdir "$CERTDIR" "$SB_ETC" 2>/dev/null || true ;;
        etc/sing-box/config.json) rm -f "$CONF" ;;
        etc/sing-box/clash.yaml) rm -f "$SB_ETC/clash.yaml" ;;
        etc/sing-box/certs/*)
          [[ "$rel" =~ ^etc/sing-box/certs/[A-Za-z0-9_.-]+\.(crt|key)$ ]] && rm -f -- "$ROOT/$rel" ;;
        usr/local/bin/sing-box) rm -f "$SB_BIN" ;;
        usr/local/bin/sbm) rm -f "$SB_LINK" ;;
        etc/systemd/system/sing-box.service)
          if [ -f "$UNIT" ] && [ ! -L "$UNIT" ] && grep -Fq 'Description=sing-box service (managed by sbm)' "$UNIT"; then rm -f "$UNIT"
          else warn "保留未匹配 SBM 标记的 sing-box.service"; fi ;;
        etc/systemd/system/sbm-nft.service)
          if [ -z "$ROOT" ] && [ -f /etc/systemd/system/sbm-nft.service ] && [ ! -L /etc/systemd/system/sbm-nft.service ] && grep -Fq 'Description=sbm nftables port forwarding' /etc/systemd/system/sbm-nft.service; then rm -f /etc/systemd/system/sbm-nft.service
          else warn "保留未匹配 SBM 标记的 sbm-nft.service"; fi ;;
        etc/sysctl.d/99-sbm-fwd.conf)
          if [ -z "$ROOT" ] && [ -f /etc/sysctl.d/99-sbm-fwd.conf ] && [ ! -L /etc/sysctl.d/99-sbm-fwd.conf ] && grep -Fq '# Managed by sbm; do not edit while nft forwarding is enabled.' /etc/sysctl.d/99-sbm-fwd.conf; then rm -f /etc/sysctl.d/99-sbm-fwd.conf
          else warn "保留未匹配 SBM 标记的 sysctl 文件"; fi ;;
      esac
    done < "$OWNED"
  fi
  [ -n "$ROOT" ] || systemctl daemon-reload >/dev/null 2>&1 || warn "卸载后 systemd daemon-reload 失败"
  rm -f "$OWNED"
  rmdir "$CERTDIR" "$SB_ETC" "$ETC" 2>/dev/null || warn "保留了目录中非 sbm 创建的其他文件"
  ok "已卸载；仅移除了所有权清单记录的 sbm 文件，其他文件/目录均保留"
}

# ---------- 配置重建 ----------
dns_block() {
  case "$(jq -r '.dns' "$META")" in
    google) echo '{"servers":[{"type":"udp","tag":"dns","server":"8.8.8.8"}],"final":"dns"}' ;;
    ali)    echo '{"servers":[{"type":"udp","tag":"dns","server":"223.5.5.5"}],"final":"dns"}' ;;
    *)      echo '{"servers":[{"type":"udp","tag":"dns","server":"1.1.1.1"}],"final":"dns"}' ;;
  esac
}

rebuild_config() {
  init_state
  local tmp
  [ ! -L "$CONF" ] || { err "sing-box 配置是符号链接，拒绝替换"; return 1; }
  [ ! -e "$CONF" ] || [ -f "$CONF" ] || { err "sing-box 配置目标不是普通文件，拒绝替换"; return 1; }
  [ ! -L "$ETC/.check.log" ] || { err "sing-box 检查日志是符号链接，拒绝写入"; return 1; }
  [ ! -L "$ETC/.config.prev.json" ] || { err "sing-box 配置备份是符号链接，拒绝写入"; return 1; }
  tmp=$(mktemp "$SB_ETC/.config.json.XXXXXX") || { err "无法创建配置临时文件"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  jq -n \
    --slurpfile nodes "$NODES" --slurpfile relay "$RELAY" \
    --arg engine "$(jq -r '.fw_engine // "sing-box"' "$META")" \
    --argjson dns "$(dns_block)" '
    ($nodes[0].nodes) as $n
    | ($relay[0].routes) as $r
    | ($relay[0].forwards) as $f
    | {
        log: {level: "info", timestamp: true},
        dns: $dns,
        inbounds: (
          [ $n[] | (.inbound, (.inbound_extra // [])[]) ]
          + [ $r[] | .inbound ]
          + (if $engine == "nft" then [] else [ $f[] | ({type: "direct", tag: .tag, listen: "::", listen_port: .listen_port,
                      override_address: .target_host, override_port: .target_port}
                     + (if .network == "tcp" or .network == "udp" then {network: .network} else {} end)) ] end)
        ),
        outbounds: (
          [ {type: "direct", tag: "direct"}, {type: "block", tag: "block"} ]
          + [ $r[] | .outbound ]
        ),
        route: {
          rules: [ $r[] | {inbound: [.inbound.tag], action: "route", outbound: .outbound.tag} ],
          final: "direct"
        }
      }' > "$tmp" || { err "配置生成失败"; rm -f "$tmp"; return 1; }
  [ -x "$SB_BIN" ] || { err "sing-box 核心不可执行，拒绝应用未经核心校验的配置"; rm -f "$tmp"; return 1; }
  if [ -e "$ETC/.check.log" ] && ! owned_has 'etc/sbm/.check.log'; then
    err "发现未登记的 sing-box 检查日志，拒绝覆盖: $ETC/.check.log"; rm -f "$tmp"; return 1
  fi
  record_owned 'etc/sbm/.check.log' || { rm -f "$tmp"; return 1; }
  : > "$ETC/.check.log" && chmod 600 "$ETC/.check.log" || { rm -f "$tmp"; err "无法保护 sing-box 检查日志"; return 1; }
  if ! "$SB_BIN" check -c "$tmp" 2>"$ETC/.check.log"; then
    err "sing-box 配置校验未通过, 未应用. 详情: $ETC/.check.log"; sed 's/^/    /' "$ETC/.check.log" >&2; rm -f "$tmp"; return 1
  fi
  if [ -f "$CONF" ]; then
    if ! owned_has 'etc/sing-box/config.json'; then
      if [ -f "$UNIT" ] && grep -Fq 'Description=sing-box service (managed by sbm)' "$UNIT"; then
        record_owned 'etc/sing-box/config.json' || { rm -f "$tmp"; return 1; }
      else
        rm -f "$tmp"; err "发现未登记的 sing-box 配置，拒绝覆盖: $CONF"; return 1
      fi
    fi
    if [ -e "$ETC/.config.prev.json" ] && [ ! -f "$ETC/.config.prev.json" ]; then
      rm -f "$tmp"; err "旧配置备份不是普通文件，拒绝覆盖"; return 1
    fi
    if [ -e "$ETC/.config.prev.json" ] && ! owned_has 'etc/sbm/.config.prev.json'; then
      rm -f "$tmp"; err "发现未登记的旧配置备份，拒绝覆盖: $ETC/.config.prev.json"; return 1
    fi
    record_owned 'etc/sbm/.config.prev.json' || { rm -f "$tmp"; return 1; }
    cp -p "$CONF" "$ETC/.config.prev.json" && chmod 600 "$ETC/.config.prev.json" || { rm -f "$tmp"; err "无法备份旧配置，未应用新配置"; return 1; }
  fi
  mark_owned_if_new 'etc/sing-box/config.json' "$CONF" || { rm -f "$tmp"; return 1; }
  if ! mv "$tmp" "$CONF" || ! chmod 600 "$CONF"; then
    if [ -f "$ETC/.config.prev.json" ]; then cp "$ETC/.config.prev.json" "$CONF" && chmod 600 "$CONF" || err "严重：配置文件替换失败且旧配置恢复失败"
    else rm -f "$CONF"; fi
    rm -f "$tmp"; err "配置文件原子替换失败，未报告应用成功"; return 1
  fi
  ok "配置文件已通过 sing-box 检查；继续验证服务状态和端口监听"
  if [ -z "$ROOT" ]; then
    if ! systemctl restart sing-box || { sleep 1; ! systemctl is-active --quiet sing-box; }; then
      err "服务重启后未能正常运行, 正在恢复上一份配置"
      if [ -f "$ETC/.config.prev.json" ]; then
        cp "$ETC/.config.prev.json" "$CONF"
        systemctl restart sing-box >/dev/null 2>&1 || true
      else
        rm -f "$CONF"; systemctl stop sing-box >/dev/null 2>&1 || true
      fi
      return 1
    fi
    ok "服务已重启并正常运行"
    if ! verify_listeners; then
      err "服务未监听配置中要求的全部端口；正在恢复上一份配置"
      if [ -f "$ETC/.config.prev.json" ]; then cp "$ETC/.config.prev.json" "$CONF"; systemctl restart sing-box >/dev/null 2>&1 || true
      else rm -f "$CONF"; systemctl stop sing-box >/dev/null 2>&1 || true; fi
      return 1
    fi
  else
    warn "沙盒模式：配置通过核心校验，但未启动服务或验证实际监听端口"
  fi
  if ! fw_sync || ! nft_sync; then
    err "防火墙/转发规则未能确认应用；本次配置不报告成功，正在恢复旧配置"
    if [ -f "$ETC/.config.prev.json" ]; then
      cp "$ETC/.config.prev.json" "$CONF"; chmod 600 "$CONF"
      [ -z "$ROOT" ] && systemctl restart sing-box >/dev/null 2>&1 || true
      fw_sync || true; nft_sync || true
    else
      rm -f "$CONF"
      [ -z "$ROOT" ] && systemctl stop sing-box >/dev/null 2>&1 || true
    fi
    return 1
  fi
}

verify_listeners() {
  [ -z "$ROOT" ] || return 0
  has ss || { err "缺少 ss，无法确认端口监听状态"; return 1; }
  local spec port proto ss_args
  while IFS=/ read -r port proto; do
    [ -n "$port" ] || continue
    case "$proto" in tcp) ss_args=(-H -lnt);; udp) ss_args=(-H -lnu);; *) err "内部端口协议无效: $proto"; return 1;; esac
    if ! ss "${ss_args[@]}" 2>/dev/null | awk -v suffix=":$port" 'substr($5, length($5)-length(suffix)+1) == suffix {found=1} END {exit !found}'; then
      err "$proto 端口 $port 未出现在系统监听列表中"; return 1
    fi
  done < <(jq -r '
    .inbounds[]? | .listen_port as $p |
    if .type == "hysteria2" or .type == "tuic" then "\($p)/udp"
    elif .type == "shadowsocks" or .type == "socks" or .type == "snell" then "\($p)/tcp", "\($p)/udp"
    elif .type == "direct" then (if .network == "tcp" then "\($p)/tcp" elif .network == "udp" then "\($p)/udp" else "\($p)/tcp", "\($p)/udp" end)
    else "\($p)/tcp" end' "$CONF" | sort -u)
}


# ---------- 防火墙联动 (UFW) ----------
fw_active() { [ -z "$ROOT" ] && has ufw && ufw status 2>/dev/null | grep -q 'Status: active'; }
fw_desired() {
  jq -r '
    def proto_of:
      if .type == "hysteria2" or .type == "tuic" then "udp"
      elif .type == "shadowsocks" or .type == "socks" or .type == "snell" then "both"
      elif .type == "direct" then (if .network == "tcp" then "tcp" elif .network == "udp" then "udp" else "both" end)
      else "tcp" end;
    .inbounds[] | select(.listen != "127.0.0.1") | .listen_port as $p | proto_of as $pr
    | if $pr == "both" then "\($p)/tcp", "\($p)/udp" else "\($p)/\($pr)" end
  ' "$CONF" 2>/dev/null | grep -v '^$' | sort -u
}
fw_exists() { # <port/proto> : ufw 中是否确有这条放行 (v4/v6 任一即可)
  ufw status 2>/dev/null | grep -q "^$1 "
}

fw_sync() {
  fw_active || return 0
  [ -f "$CONF" ] || return 0
  local list="$ETC/fw.list" want have
  if [ -e "$list" ] && ! owned_has 'etc/sbm/fw.list'; then err "发现未登记的 UFW 规则追踪文件，拒绝覆盖: $list"; return 1; fi
  want=$(fw_desired)
  have=$(grep -v '^$' "$list" 2>/dev/null | sort -u | while read -r r; do
    [ -n "$r" ] && fw_exists "$r" && echo "$r"
  done || true)
  local r failed=0
  while read -r r; do
    [ -n "$r" ] || continue
    if ufw allow "$r" >/dev/null 2>&1; then say "  防火墙放行: $r"; else err "UFW 未能放行 $r"; failed=1; fi
  done < <(comm -13 <(printf '%s\n' "$have") <(printf '%s\n' "$want"))
  while read -r r; do
    [ -n "$r" ] && ufw delete allow "$r" >/dev/null 2>&1 && say "  防火墙回收: $r"
  done < <(comm -23 <(printf '%s\n' "$have") <(printf '%s\n' "$want"))
  mark_owned_if_new 'etc/sbm/fw.list' "$list" || return 1
  { printf '%s\n' "$want"; printf '%s\n' "$have"; } | grep -v '^$' | sort -u | while read -r r; do
    [ -n "$r" ] && fw_exists "$r" && echo "$r"
  done | atomic_write "$list" || return 1
  [ "$failed" = 0 ] || return 1
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    fw_exists "$r" || { err "UFW 放行核验失败: $r"; return 1; }
  done <<<"$want"
  fw_route_sync || return 1
}


fw_route_exists() { # <host> <port> <proto> : ufw 中是否还有这条 FWD 规则
  ufw status 2>/dev/null | awk -v h="$1" -v pp="$2/$3" '$4 == "FWD" && $1 == h && $2 == pp {f=1} END {exit !f}'
}

# nft 引擎时, 转发流量在 UFW 转发链的放行同步
fw_route_sync() {
  local list="$ETC/fwroute.list" want have r h p pr engine failed=0
  if [ -e "$list" ] && ! owned_has 'etc/sbm/fwroute.list'; then err "发现未登记的 UFW 转发追踪文件，拒绝覆盖: $list"; return 1; fi
  engine=$(jq -r '.fw_engine // "sing-box"' "$META")
  if [ "$engine" = "nft" ]; then
    want=$(jq -r '.forwards[] | "route \(.target_host) \(.target_port) \(if .network == "udp" then "udp" elif .network == "tcp" then "tcp" else "both" end)"' "$RELAY" 2>/dev/null | grep -v '^$' | sort -u)
  else want=""; fi
  have=$(grep -v '^$' "$list" 2>/dev/null | sort -u | while read -r r; do
    [ -n "$r" ] || continue
    set -- $r; h="$2"; p="$3"; pr="$4"
    if [ "$pr" = "both" ]; then
      if fw_route_exists "$h" "$p" tcp || fw_route_exists "$h" "$p" udp; then echo "$r"; fi
    else
      fw_route_exists "$h" "$p" "$pr" && echo "$r"
    fi
  done || true)
  while read -r r; do
    [ -n "$r" ] || continue
    set -- $r; h="$2"; p="$3"; pr="$4"
    if [ "$pr" = "both" ]; then
      ufw route allow to "$h" port "$p" proto tcp >/dev/null 2>&1 && say "  转发放行: $h:$p/tcp" || { err "UFW route 未能放行 $h:$p/tcp"; failed=1; }
      ufw route allow to "$h" port "$p" proto udp >/dev/null 2>&1 && say "  转发放行: $h:$p/udp" || { err "UFW route 未能放行 $h:$p/udp"; failed=1; }
    else
      ufw route allow to "$h" port "$p" proto "$pr" >/dev/null 2>&1 && say "  转发放行: $h:$p/$pr" || { err "UFW route 未能放行 $h:$p/$pr"; failed=1; }
    fi
  done < <(comm -13 <(printf '%s\n' "$have") <(printf '%s\n' "$want"))
  while read -r r; do
    [ -n "$r" ] || continue
    set -- $r; h="$2"; p="$3"; pr="$4"
    if [ "$pr" = "both" ]; then
      ufw route delete allow to "$h" port "$p" proto tcp >/dev/null 2>&1 || true
      ufw route delete allow to "$h" port "$p" proto udp >/dev/null 2>&1 || true
    else
      ufw route delete allow to "$h" port "$p" proto "$pr" >/dev/null 2>&1 || true
    fi
    say "  转发回收: $h:$p/$pr"
  done < <(comm -23 <(printf '%s\n' "$have") <(printf '%s\n' "$want"))
  mark_owned_if_new 'etc/sbm/fwroute.list' "$list" || return 1
  { printf '%s\n' "$want"; printf '%s\n' "$have"; } | grep -v '^$' | sort -u | while read -r r; do
    [ -n "$r" ] || continue
    set -- $r; h="$2"; p="$3"; pr="$4"
    if [ "$pr" = "both" ]; then
      if fw_route_exists "$h" "$p" tcp || fw_route_exists "$h" "$p" udp; then echo "$r"; fi
    else
      fw_route_exists "$h" "$p" "$pr" && echo "$r"
    fi
  done | atomic_write "$list" || return 1
  [ "$failed" = 0 ] || return 1
  if [ "$engine" = "nft" ]; then
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      set -- $r; h="$2"; p="$3"; pr="$4"
      if [ "$pr" = "both" ]; then
        fw_route_exists "$h" "$p" tcp && fw_route_exists "$h" "$p" udp || { err "UFW route 放行核验失败: $h:$p/tcp+udp"; return 1; }
      else fw_route_exists "$h" "$p" "$pr" || { err "UFW route 放行核验失败: $h:$p/$pr"; return 1; }; fi
    done <<<"$want"
  fi
}

# ---------- nftables 转发引擎 ----------
nft_sync() {
  [ -n "$ROOT" ] && return 0
  [ "$(jq -r '.fw_engine // "sing-box"' "$META")" = "nft" ] || return 0
  has nft || { err "已选择 nft 引擎但未安装 nft，无法应用转发规则"; return 1; }
  local f="$ETC/sbm.nft" pre="" post="" row h ip oldfile="" had_table=0 had_file=0
  while read -r row; do
    [ -n "$row" ] || continue
    h=$(jq -r .target_host <<<"$row")
    if [[ "$h" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ip="$h"
    elif [[ "$h" == *":"* ]]; then err "nft 引擎暂不支持 IPv6 转发目标: $h；规则未应用"; return 1
    else
      ip=$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}')
      [ -n "$ip" ] || { err "转发目标域名解析失败，规则未应用: $h"; return 1; }
    fi
    pre+=$(jq -r --arg ip "$ip" '(if .network == "udp" then ["udp"] elif .network == "tcp" then ["tcp"] else ["tcp", "udp"] end)[] as $pr | "    \($pr) dport \(.listen_port) dnat to \($ip):\(.target_port)"' <<<"$row")$'
'
    post+=$(jq -r --arg ip "$ip" '(if .network == "udp" then ["udp"] elif .network == "tcp" then ["tcp"] else ["tcp", "udp"] end)[] as $pr | "    ip daddr \($ip) \($pr) dport \(.target_port) masquerade"' <<<"$row")$'
'
  done < <(jq -c '.forwards[]' "$RELAY")
  if [ -f "$f" ]; then
    owned_has 'etc/sbm/sbm.nft' || { err "发现未登记的 nft 规则文件，拒绝覆盖: $f"; return 1; }
    had_file=1
    oldfile=$(mktemp "$ETC/.sbm.nft.prev.XXXXXX") || return 1
    cp "$f" "$oldfile" || { rm -f "$oldfile"; return 1; }
  fi
  if nft list table ip sbm_fwd >/dev/null 2>&1; then
    had_table=1
    [ "$had_file" = 1 ] || { err "存在 nft 表 ip sbm_fwd，但缺少 SBM 规则备份；拒绝覆盖未知规则"; return 1; }
  fi
  mark_owned_if_new 'etc/sbm/sbm.nft' "$f" || { rm -f "$oldfile"; return 1; }
  {
    echo "table ip sbm_fwd {"
    echo "  chain prerouting { type nat hook prerouting priority -100; policy accept;"
    [ -n "$pre" ] && printf '%s' "$pre"
    echo "  }"
    echo "  chain postrouting { type nat hook postrouting priority 100; policy accept;"
    [ -n "$post" ] && printf '%s' "$post"
    echo "  }"
    echo "}"
  } | atomic_write "$f" || { rm -f "$oldfile"; err "无法安全写入 nft 规则文件"; return 1; }
  if [ "$had_table" = 1 ]; then
    if ! nft delete table ip sbm_fwd; then
      if [ "$had_file" = 1 ]; then atomic_write "$f" < "$oldfile" || err "旧 nft 文件恢复失败"; else rm -f "$f"; fi
      rm -f "$oldfile"; err "无法安全替换现有 nft 表"; return 1
    fi
  fi
  if [ -n "$pre" ]; then
    if ! nft -f "$f"; then
      err "nftables 规则应用失败，正在恢复上一份规则"
      if [ "$had_table" = 1 ] && [ -s "$oldfile" ]; then
        nft -f "$oldfile" || err "严重：旧 nft 规则恢复失败，请立即检查本机 nftables"
      fi
      if [ "$had_file" = 1 ]; then atomic_write "$f" < "$oldfile" || err "旧 nft 规则文件恢复失败"; else rm -f "$f"; fi
      rm -f "$oldfile"
      return 1
    fi
    ok "nftables 转发规则已应用 (域名目标在每次同步时解析, 解析变更后需重新同步)"
  fi
  rm -f "$oldfile"
}

nft_boot_enable() {
  local unit=/etc/systemd/system/sbm-nft.service
  [ ! -L "$unit" ] || { err "sbm-nft.service 是符号链接，拒绝覆盖"; return 1; }
  if [ -e "$unit" ] && ! grep -Fq 'Description=sbm nftables port forwarding' "$unit"; then
    err "发现非 sbm 管理的 sbm-nft.service，拒绝覆盖"; return 1
  fi
  if [ -e "$unit" ]; then record_owned 'etc/systemd/system/sbm-nft.service' || return 1
  else mark_owned_if_new 'etc/systemd/system/sbm-nft.service' "$unit" || return 1; fi
  cat <<EOF | atomic_write "$unit" || { err "无法安全写入 sbm-nft.service"; return 1; }
[Unit]
Description=sbm nftables port forwarding
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f $ETC/sbm.nft
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || { err "systemd daemon-reload 失败"; return 1; }
  systemctl enable sbm-nft >/dev/null 2>&1 || { err "nft 转发开机恢复设置失败"; return 1; }
}
nft_boot_disable() {
  if owned_has 'etc/systemd/system/sbm-nft.service'; then
    local unit=/etc/systemd/system/sbm-nft.service
    [ -f "$unit" ] && [ ! -L "$unit" ] && grep -Fq 'Description=sbm nftables port forwarding' "$unit" || { err "sbm-nft.service 不匹配 SBM 标记，拒绝禁用或删除"; return 1; }
    systemctl disable sbm-nft >/dev/null 2>&1 || { err "无法禁用 SBM nft 服务"; return 1; }
    rm -f "$unit" || return 1
    systemctl daemon-reload || { err "systemd daemon-reload 失败"; return 1; }
  fi
}

restore_engine_switch() {
  local sysfile="$1" sysbak="$2" syshad="$3" oldip="$4" unit="$5" unitbak="$6" unithad="$7" oldenabled="$8"
  local failed=0
  if [ "$syshad" = 1 ]; then cp "$sysbak" "$sysfile" && chmod 600 "$sysfile" || { err "严重：无法恢复旧 sysctl 文件"; failed=1; }
  elif owned_has 'etc/sysctl.d/99-sbm-fwd.conf'; then rm -f "$sysfile" || { err "严重：无法移除本次创建的 sysctl 文件"; failed=1; }; fi
  if [ "$unithad" = 1 ]; then cp "$unitbak" "$unit" && chmod 600 "$unit" || { err "严重：无法恢复旧 nft 服务单元"; failed=1; }
  elif owned_has 'etc/systemd/system/sbm-nft.service'; then rm -f "$unit" || { err "严重：无法移除本次创建的 nft 服务单元"; failed=1; }; fi
  systemctl daemon-reload >/dev/null 2>&1 || { err "严重：systemd daemon-reload 恢复失败"; failed=1; }
  if [ "$oldenabled" = enabled ]; then systemctl enable sbm-nft >/dev/null 2>&1 || { err "严重：无法恢复 nft 服务自启状态"; failed=1; }
  else systemctl disable sbm-nft >/dev/null 2>&1 || { err "严重：无法恢复 nft 服务禁用状态"; failed=1; }; fi
  sysctl -w "net.ipv4.ip_forward=$oldip" >/dev/null 2>&1 || { err "严重：无法恢复原 ip_forward=$oldip"; failed=1; }
  return "$failed"
}

engine_switch() {
  need_root; init_state
  local cur; cur=$(jq -r '.fw_engine // "sing-box"' "$META")
  [[ "$cur" == sing-box || "$cur" == nft ]] || { err "状态中的转发引擎值无效，拒绝切换"; return 1; }
  say "当前转发引擎: $cur (sing-box=随服务运行, nftables=内核转发)" >&2
  local c target=""
  c=$(ask "[1] sing-box 引擎  [2] nftables 引擎  [0] 返回: " "0")
  case "$c" in 1) target="sing-box" ;; 2) target="nft" ;; *) return ;; esac
  [ "$target" = "$cur" ] && { say "已经是该引擎, 无需切换"; return; }

  local sysfile=/etc/sysctl.d/99-sbm-fwd.conf unit=/etc/systemd/system/sbm-nft.service
  local sysbak unitbak syshad=0 unithad=0 oldip oldenabled restore_failed=0
  local metab="$META.bak"
  [ ! -L "$sysfile" ] && [ ! -L "$unit" ] || { err "引擎配置目标是符号链接，拒绝修改"; return 1; }
  if [ "$cur" = nft ] && [ -e "$sysfile" ]; then
    owned_has 'etc/sysctl.d/99-sbm-fwd.conf' && grep -Fq '# Managed by sbm; do not edit while nft forwarding is enabled.' "$sysfile" || { err "sysctl 转发文件不匹配 SBM 标记，拒绝删除或修改"; return 1; }
  fi
  if [ "$cur" = nft ] && [ -e "$unit" ]; then
    owned_has 'etc/systemd/system/sbm-nft.service' && grep -Fq 'Description=sbm nftables port forwarding' "$unit" || { err "sbm-nft.service 不匹配 SBM 标记，拒绝禁用或删除"; return 1; }
  fi
  backup_state "$META" || { err "无法备份引擎状态"; return 1; }
  sysbak=$(mktemp "$ETC/.sysctl.engine.XXXXXX") || { rm -f "$metab"; return 1; }
  unitbak=$(mktemp "$ETC/.unit.engine.XXXXXX") || { rm -f "$metab" "$sysbak"; return 1; }
  if [ -e "$sysfile" ]; then syshad=1; cp "$sysfile" "$sysbak" || { rm -f "$metab" "$sysbak" "$unitbak"; return 1; }; fi
  if [ -e "$unit" ]; then unithad=1; cp "$unit" "$unitbak" || { rm -f "$metab" "$sysbak" "$unitbak"; return 1; }; fi
  oldip=$(sysctl -n net.ipv4.ip_forward 2>/dev/null) || { rm -f "$metab" "$sysbak" "$unitbak"; err "无法读取 ip_forward，拒绝切换"; return 1; }
  oldenabled=$(systemctl is-enabled sbm-nft 2>/dev/null || echo disabled)

  if [ "$target" = nft ]; then
    if ! has nft; then
      warn "安装 nftables ..."
      apt-get update -qq && apt-get install -y -qq nftables >/dev/null || { rm -f "$metab" "$sysbak" "$unitbak"; err "nftables 安装失败"; return 1; }
    fi
    if [ -e "$sysfile" ] && ! owned_has 'etc/sysctl.d/99-sbm-fwd.conf'; then
      rm -f "$metab" "$sysbak" "$unitbak"; err "发现非 SBM 管理的 $sysfile，拒绝覆盖"; return 1
    fi
    if [ -e "$unit" ] && ! owned_has 'etc/systemd/system/sbm-nft.service'; then
      rm -f "$metab" "$sysbak" "$unitbak"; err "发现未登记的 sbm-nft.service，拒绝覆盖"; return 1
    fi
    mark_owned_if_new 'etc/sysctl.d/99-sbm-fwd.conf' "$sysfile" || { rm -f "$metab" "$sysbak" "$unitbak"; return 1; }
    printf '# Managed by sbm; do not edit while nft forwarding is enabled.\nnet.ipv4.ip_forward=1\n' | atomic_write "$sysfile" || {
      restore_engine_switch "$sysfile" "$sysbak" "$syshad" "$oldip" "$unit" "$unitbak" "$unithad" "$oldenabled" || err "严重：引擎状态未能完整恢复"; rm -f "$metab" "$sysbak" "$unitbak"; err "sysctl 文件写入失败，已尝试恢复旧状态；请留意严重错误提示"; return 1; }
    sysctl -w net.ipv4.ip_forward=1 >/dev/null || {
      restore_engine_switch "$sysfile" "$sysbak" "$syshad" "$oldip" "$unit" "$unitbak" "$unithad" "$oldenabled" || err "严重：引擎状态未能完整恢复"; rm -f "$metab" "$sysbak" "$unitbak"; err "启用 ip_forward 失败，已尝试恢复旧状态；请留意严重错误提示"; return 1; }
    nft_boot_enable || {
      restore_engine_switch "$sysfile" "$sysbak" "$syshad" "$oldip" "$unit" "$unitbak" "$unithad" "$oldenabled" || err "严重：引擎状态未能完整恢复"; rm -f "$metab" "$sysbak" "$unitbak"; return 1; }
  else
    if [ -e "$unit" ] && ! owned_has 'etc/systemd/system/sbm-nft.service'; then
      rm -f "$metab" "$sysbak" "$unitbak"; err "发现非 SBM 管理的 sbm-nft.service，拒绝禁用或删除"; return 1
    fi
    if nft list table ip sbm_fwd >/dev/null 2>&1; then
      owned_has 'etc/sbm/sbm.nft' || { rm -f "$metab" "$sysbak" "$unitbak"; err "发现未知 nft 表 ip sbm_fwd，拒绝删除"; return 1; }
      nft delete table ip sbm_fwd || { rm -f "$metab" "$sysbak" "$unitbak"; err "无法删除 SBM nft 转发表"; return 1; }
    fi
    nft_boot_disable || { restore_engine_switch "$sysfile" "$sysbak" "$syshad" "$oldip" "$unit" "$unitbak" "$unithad" "$oldenabled" || err "严重：系统文件/服务回滚失败"; nft_sync || err "严重：旧 nft 规则恢复失败"; rm -f "$metab" "$sysbak" "$unitbak"; return 1; }
    if owned_has 'etc/sysctl.d/99-sbm-fwd.conf'; then
      rm -f "$sysfile" || { restore_engine_switch "$sysfile" "$sysbak" "$syshad" "$oldip" "$unit" "$unitbak" "$unithad" "$oldenabled" || err "严重：系统文件/服务回滚失败"; nft_sync || err "严重：旧 nft 规则恢复失败"; rm -f "$metab" "$sysbak" "$unitbak"; err "无法删除 SBM sysctl 文件"; return 1; }
    fi
    # 不把 ip_forward 强制改回 0；其他服务 (如 Docker) 可能依赖它。
  fi

  if ! jq --arg e "$target" '.fw_engine = $e' "$META" | atomic_write "$META"; then
    restore_engine_switch "$sysfile" "$sysbak" "$syshad" "$oldip" "$unit" "$unitbak" "$unithad" "$oldenabled" || restore_failed=1
    restore_state "$metab" "$META" || restore_failed=1
    if [ "$cur" = nft ]; then nft_sync || restore_failed=1; fw_route_sync || restore_failed=1; fi
    rm -f "$sysbak" "$unitbak"
    [ "$restore_failed" = 0 ] && err "引擎状态写入失败；旧系统状态恢复命令均通过" || err "严重：引擎状态写入失败且回滚不完整，需立即人工检查"
    return 1
  fi
  if rebuild_config; then
    rm -f "$metab" "$sysbak" "$unitbak"
    ok "已切换到 $target 引擎"
    return 0
  fi
  restore_state "$metab" "$META" || { err "严重：引擎状态回滚失败"; rm -f "$sysbak" "$unitbak"; return 1; }
  if restore_engine_switch "$sysfile" "$sysbak" "$syshad" "$oldip" "$unit" "$unitbak" "$unithad" "$oldenabled"; then
    restore_failed=0
    if [ "$cur" = nft ]; then nft_sync || restore_failed=1; fw_route_sync || restore_failed=1; fi
    if [ "$restore_failed" = 0 ]; then err "引擎切换未通过配置/服务验证；旧系统状态及适用的转发规则均已核验恢复"
    else err "严重：引擎切换失败且转发规则回滚不完整，需立即人工检查"; fi
  else
    err "严重：引擎切换未通过验证且系统状态回滚不完整，需立即人工检查"
  fi
  rm -f "$sysbak" "$unitbak"
  return 1
}

# ---------- 端口冲突检查 ----------
port_conflict() { # port_conflict <port> [exclude-tag] : 已被本脚本其他入站/转发占用返回 0
  local p="$1" ex="${2:-}"
  jq -e --argjson p "$p" --arg ex "$ex" '
    ([.nodes[]? | (.inbound, (.inbound_extra // [])[]) | select(.tag != $ex) | .listen_port] | index($p)) != null' "$NODES" >/dev/null 2>&1 && return 0
  jq -e --argjson p "$p" --arg ex "$ex" '
    (([.routes[]?.inbound | select(.tag != $ex) | .listen_port] + [.forwards[]? | select(.tag != $ex) | .listen_port]) | index($p)) != null' "$RELAY" >/dev/null 2>&1 && return 0
  return 1
}
check_port_free() { # check_port_free <port> [exclude-tag]
  valid_port "${1:-}" || { err "端口必须是 1-65535 的整数: ${1:-}"; return 1; }
  if port_conflict "$1" "${2:-}"; then err "端口 $1 已被其他节点/中转/转发占用"; return 1; fi
  if [ -z "$ROOT" ] && has ss && ss -tuln 2>/dev/null | awk '{print $5}' | grep -q ":$1\$"; then
    if [ -n "${2:-}" ] && jq -s -e --arg ex "$2" --argjson p "$1" '
      (any(.[0].nodes[]? | (.inbound, (.inbound_extra // [])[]) | .tag == $ex and .listen_port == $p))
      or (any(.[1].routes[]?.inbound | .tag == $ex and .listen_port == $p))
      or (any(.[1].forwards[]? | .tag == $ex and .listen_port == $p))' "$NODES" "$RELAY" >/dev/null 2>&1; then :
    else err "端口 $1 已被系统进程占用，拒绝继续以免服务启动失败"; return 1; fi
  fi
  return 0
}

# ---------- 证书 ----------
make_cert() { # make_cert <tag> <domain> -> 回显 "crt|key"
  local tag="$1" dom="$2" crt key
  crt="$CERTDIR/$tag.crt"; key="$CERTDIR/$tag.key"
  [[ "$tag" =~ ^[A-Za-z0-9_.-]{1,80}$ && "$tag" != *..* ]] || { err "节点标识不安全，拒绝写入证书路径"; return 1; }
  if [ -e "$crt" ] || [ -e "$key" ]; then
    [ -f "$crt" ] && [ -f "$key" ] || { err "证书文件不完整，拒绝覆盖现有文件"; return 1; }
  else
    mark_owned_if_new "etc/sing-box/certs/$tag.crt" "$crt" || return 1
    mark_owned_if_new "etc/sing-box/certs/$tag.key" "$key" || return 1
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -keyout "$key" -out "$crt" -days 3650 -subj "/CN=$dom" \
      -addext "subjectAltName=DNS:$dom" >/dev/null 2>&1 || return 1
    chmod 600 "$key"
  fi
  printf '%s|%s' "$crt" "$key"
}

# ---------- 入站构建 ----------
# 每个 build_* 回显一个 JSON: {inbound:{...}, share:{...}}
# inbound.tag 规则: n-<name> (普通节点) / r-<name> (中转入口)
uniq_tag() { # uniq_tag <prefix> <name>
  local t="$1-$2"
  if jq -e --arg t "$t" '[.nodes[]|select(.inbound.tag==$t)]|length>0' "$NODES" >/dev/null 2>&1 \
     || jq -e --arg t "$t" '[.routes[]|select(.inbound.tag==$t)]|length>0' "$RELAY" >/dev/null 2>&1; then
    t="$t-$(rand_hex 2)"
  fi
  printf '%s' "$t"
}

build_vless_reality() { # <tag> <port>
  local tag="$1" port="$2" uuid sni kp priv pub sid
  uuid=$(gen_uuid); sni=$(ask "Reality 伪装域名 SNI [www.microsoft.com]: " "www.microsoft.com")
  kp=$("$SB_BIN" generate reality-keypair) || return 1
  priv=$(printf '%s' "$kp" | awk '/PrivateKey/{print $2}'); pub=$(printf '%s' "$kp" | awk '/PublicKey/{print $2}')
  sid=$(rand_hex 4)
  jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg sni "$sni" \
        --arg priv "$priv" --arg pub "$pub" --arg sid "$sid" '
    {inbound: {type:"vless", tag:$tag, listen:"::", listen_port:$port,
               users:[{uuid:$uuid, flow:"xtls-rprx-vision"}],
               tls:{enabled:true, server_name:$sni,
                    reality:{enabled:true, handshake:{server:$sni, server_port:443},
                             private_key:$priv, short_id:[$sid]}}},
     share: {proto:"vless-reality", uuid:$uuid, sni:$sni, pbk:$pub, sid:$sid}}'
}

build_vless_ws_tls() { # <tag> <port>
  local tag="$1" port="$2" uuid dom path ck crt key
  uuid=$(gen_uuid); dom=$(ask "TLS 域名 (自签证书 CN) [www.bing.com]: " "www.bing.com")
  path=$(ask "WebSocket 路径 [/ws]: " "/ws")
  ck=$(make_cert "$tag" "$dom") || return 1; crt="${ck%%|*}"; key="${ck##*|}"
  jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg dom "$dom" \
        --arg path "$path" --arg crt "$crt" --arg key "$key" '
    {inbound: {type:"vless", tag:$tag, listen:"::", listen_port:$port,
               users:[{uuid:$uuid}],
               transport:{type:"ws", path:$path},
               tls:{enabled:true, server_name:$dom, certificate_path:$crt, key_path:$key}},
     share: {proto:"vless-ws", uuid:$uuid, sni:$dom, path:$path}}'
}

build_trojan_ws_tls() { # <tag> <port>
  local tag="$1" port="$2" pw dom path ck crt key
  pw=$(rand_pw 16); dom=$(ask "TLS 域名 (自签证书 CN) [www.bing.com]: " "www.bing.com")
  path=$(ask "WebSocket 路径 [/ws]: " "/ws")
  ck=$(make_cert "$tag" "$dom") || return 1; crt="${ck%%|*}"; key="${ck##*|}"
  jq -n --arg tag "$tag" --argjson port "$port" --arg pw "$pw" --arg dom "$dom" \
        --arg path "$path" --arg crt "$crt" --arg key "$key" '
    {inbound: {type:"trojan", tag:$tag, listen:"::", listen_port:$port,
               users:[{password:$pw}],
               transport:{type:"ws", path:$path},
               tls:{enabled:true, server_name:$dom, certificate_path:$crt, key_path:$key}},
     share: {proto:"trojan-ws", password:$pw, sni:$dom, path:$path}}'
}

build_vless_grpc_tls() { # <tag> <port>
  local tag="$1" port="$2" uuid dom svc ck crt key
  uuid=$(gen_uuid); dom=$(ask "TLS 域名 (自签证书 CN) [www.bing.com]: " "www.bing.com")
  svc=$(ask "gRPC 服务名 [grpc]: " "grpc")
  ck=$(make_cert "$tag" "$dom") || return 1; crt="${ck%%|*}"; key="${ck##*|}"
  jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg dom "$dom" \
        --arg svc "$svc" --arg crt "$crt" --arg key "$key" '
    {inbound: {type:"vless", tag:$tag, listen:"::", listen_port:$port,
               users:[{uuid:$uuid}],
               transport:{type:"grpc", service_name:$svc},
               tls:{enabled:true, server_name:$dom, certificate_path:$crt, key_path:$key}},
     share: {proto:"vless-grpc", uuid:$uuid, sni:$dom, service:$svc}}'
}

build_anytls() { # <tag> <port>
  local tag="$1" port="$2" pw dom ck crt key
  pw=$(rand_pw 16); dom=$(ask "TLS 域名 (自签证书 CN) [www.bing.com]: " "www.bing.com")
  ck=$(make_cert "$tag" "$dom") || return 1; crt="${ck%%|*}"; key="${ck##*|}"
  jq -n --arg tag "$tag" --argjson port "$port" --arg pw "$pw" --arg dom "$dom" \
        --arg crt "$crt" --arg key "$key" '
    {inbound: {type:"anytls", tag:$tag, listen:"::", listen_port:$port,
               users:[{password:$pw}],
               tls:{enabled:true, server_name:$dom, certificate_path:$crt, key_path:$key}},
     share: {proto:"anytls", password:$pw, sni:$dom}}'
}

build_hysteria2() { # <tag> <port>
  local tag="$1" port="$2" pw obfs dom ck crt key use_obfs
  pw=$(rand_pw 16); dom=$(ask "TLS 域名 (自签证书 CN) [www.bing.com]: " "www.bing.com")
  use_obfs=$(ask "启用 Salamander 混淆? (y/N): " "n")
  ck=$(make_cert "$tag" "$dom") || return 1; crt="${ck%%|*}"; key="${ck##*|}"
  obfs=""; [ "$use_obfs" = "y" ] && obfs=$(rand_pw 12)
  jq -n --arg tag "$tag" --argjson port "$port" --arg pw "$pw" --arg dom "$dom" \
        --arg obfs "$obfs" --arg crt "$crt" --arg key "$key" '
    {inbound: ({type:"hysteria2", tag:$tag, listen:"::", listen_port:$port,
               users:[{password:$pw}],
               tls:{enabled:true, server_name:$dom, certificate_path:$crt, key_path:$key}}
              + (if $obfs != "" then {obfs:{type:"salamander", password:$obfs}} else {} end)),
     share: {proto:"hysteria2", password:$pw, sni:$dom, obfs:$obfs}}'
}

build_tuic() { # <tag> <port>
  local tag="$1" port="$2" uuid pw dom ck crt key
  uuid=$(gen_uuid); pw=$(rand_pw 16); dom=$(ask "TLS 域名 (自签证书 CN) [www.bing.com]: " "www.bing.com")
  ck=$(make_cert "$tag" "$dom") || return 1; crt="${ck%%|*}"; key="${ck##*|}"
  jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg pw "$pw" --arg dom "$dom" \
        --arg crt "$crt" --arg key "$key" '
    {inbound: {type:"tuic", tag:$tag, listen:"::", listen_port:$port,
               users:[{uuid:$uuid, password:$pw}], congestion_control:"bbr",
               tls:{enabled:true, server_name:$dom, certificate_path:$crt, key_path:$key, alpn:["h3"]}},
     share: {proto:"tuic", uuid:$uuid, password:$pw, sni:$dom}}'
}

build_shadowsocks() { # <tag> <port>
  local tag="$1" port="$2" method pw m
  cat >&2 <<'EOF'
  [经典 SS]
    1) aes-128-gcm
    2) aes-256-gcm
    3) chacha20-ietf-poly1305
    4) xchacha20-ietf-poly1305
  [SS-2022]
    5) 2022-blake3-aes-128-gcm
    6) 2022-blake3-aes-256-gcm
    7) 2022-blake3-chacha20-poly1305
  [组合]
    8) 2022-blake3-aes-256-gcm + ShadowTLS v3
EOF
  m=$(ask "请选择加密方式 [6]: " "6")
  case "$m" in
    1) method="aes-128-gcm"; pw=$(rand_pw 16) ;;
    2) method="aes-256-gcm"; pw=$(rand_pw 16) ;;
    3) method="chacha20-ietf-poly1305"; pw=$(rand_pw 16) ;;
    4) method="xchacha20-ietf-poly1305"; pw=$(rand_pw 16) ;;
    5) method="2022-blake3-aes-128-gcm"; pw=$(openssl rand -base64 16) ;;
    7) method="2022-blake3-chacha20-poly1305"; pw=$(openssl rand -base64 32) ;;
    8) build_ss_shadowtls "$tag" "$port"; return ;;
    6) method="2022-blake3-aes-256-gcm"; pw=$(openssl rand -base64 32) ;;
    *) err "无效的加密方式选择: $m"; return 1 ;;
  esac
  jq -n --arg tag "$tag" --argjson port "$port" --arg method "$method" --arg pw "$pw" '
    {inbound: {type:"shadowsocks", tag:$tag, listen:"::", listen_port:$port,
               method:$method, password:$pw},
     share: {proto:"ss", method:$method, password:$pw}}'
}

build_ss_shadowtls() { # <tag> <port> : 公开 ShadowTLS 入站 + 回环 SS 入站 (detour)
  local tag="$1" port="$2" host ss_psk stls_pw iport
  host=$(ask "ShadowTLS 伪装域名 [www.microsoft.com]: " "www.microsoft.com")
  ss_psk=$(openssl rand -base64 32); stls_pw=$(rand_pw 16)
  iport=$(( (RANDOM % 20000) + 20000 ))
  jq -n --arg tag "$tag" --argjson port "$port" --arg host "$host" \
        --arg sspsk "$ss_psk" --arg stlspw "$stls_pw" --argjson iport "$iport" '
    {inbound: {type:"shadowtls", tag:$tag, listen:"::", listen_port:$port, version:3,
               users:[{name:"user", password:$stlspw}],
               handshake:{server:$host, server_port:443}, detour:($tag + "-ss")},
     inbound_extra: [{type:"shadowsocks", tag:($tag + "-ss"), listen:"127.0.0.1", listen_port:$iport,
               method:"2022-blake3-aes-256-gcm", password:$sspsk}],
     share: {proto:"ss-shadowtls", method:"2022-blake3-aes-256-gcm", password:$sspsk,
             stls_password:$stlspw, stls_host:$host, version:3}}'
}

build_vless_tcp() { # <tag> <port>
  local tag="$1" port="$2" uuid
  uuid=$(gen_uuid)
  jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" '
    {inbound: {type:"vless", tag:$tag, listen:"::", listen_port:$port, users:[{uuid:$uuid}]},
     share: {proto:"vless-tcp", uuid:$uuid}}'
}

build_socks5() { # <tag> <port>
  local tag="$1" port="$2" user pw
  user=$(ask "用户名 [user]: " "user"); pw=$(rand_pw 16)
  jq -n --arg tag "$tag" --argjson port "$port" --arg user "$user" --arg pw "$pw" '
    {inbound: {type:"socks", tag:$tag, listen:"::", listen_port:$port,
               users:[{username:$user, password:$pw}]},
     share: {proto:"socks5", username:$user, password:$pw}}'
}

build_snell() { # <tag> <port>  (sing-box 实现: 无 obfs 字段; 入站 v5/v6, 出站仅 v6)
  local tag="$1" port="$2" v psk
  v=$(ask "Snell 版本 [6] (5 亦可, 但 v5 不能被中转机作落地): " "6")
  case "$v" in 5|6) ;; *) v=6 ;; esac
  psk=$(rand_pw 16)
  jq -n --arg tag "$tag" --argjson port "$port" --argjson ver "$v" --arg psk "$psk" '
    {inbound: {type:"snell", tag:$tag, listen:"::", listen_port:$port, version:$ver, psk:$psk},
     share: {proto:"snell", psk:$psk, version:$ver}}'
}

# 协议编号 -> 构建函数
build_by_choice() { # <choice> <tag> <port>
  case "$1" in
    1) build_vless_reality "$2" "$3" ;;  2) build_vless_ws_tls "$2" "$3" ;;
    3) build_trojan_ws_tls "$2" "$3" ;;  4) build_vless_grpc_tls "$2" "$3" ;;
    5) build_anytls "$2" "$3" ;;         6) build_hysteria2 "$2" "$3" ;;
    7) build_tuic "$2" "$3" ;;           8) build_shadowsocks "$2" "$3" ;;
    9) build_vless_tcp "$2" "$3" ;;      10) build_socks5 "$2" "$3" ;;
    11) build_snell "$2" "$3" ;;
    *) return 1 ;;
  esac
}
proto_name() {
  case "$1" in
    vless-reality) echo "VLESS+Reality+Vision" ;; vless-ws) echo "VLESS+WS+TLS" ;;
    trojan-ws) echo "Trojan+WS+TLS" ;; vless-grpc) echo "VLESS+gRPC+TLS" ;;
    anytls) echo "AnyTLS" ;; hysteria2) echo "Hysteria2" ;; tuic) echo "TUIC v5" ;;
    ss) echo "Shadowsocks" ;; vless-tcp) echo "VLESS+TCP" ;; socks5) echo "SOCKS5" ;;
    snell) echo "Snell" ;; ss-shadowtls) echo "SS2022+ShadowTLS" ;;
    *) echo "$1" ;;
  esac
}

# ---------- 分享链接 ----------
share_link() { # share_link <ip> <port> <name> <share-json>
  local ip="$1" port="$2" name="$3" s="$4" proto enc
  valid_public_ipv4 "$ip" || { err "分享链接需要有效公网 IPv4"; return 1; }
  proto=$(printf '%s' "$s" | jq -r '.proto')
  case "$proto" in
    vless-reality)
      printf 'vless://%s@%s:%s?security=reality&encryption=none&pbk=%s&sid=%s&sni=%s&fp=chrome&flow=xtls-rprx-vision&type=tcp#%s' \
        "$(jq -r .uuid <<<"$s")" "$ip" "$port" "$(jq -r .pbk <<<"$s")" "$(jq -r .sid <<<"$s")" "$(jq -r .sni <<<"$s")" "$name" ;;
    vless-ws)
      printf 'vless://%s@%s:%s?security=tls&encryption=none&sni=%s&type=ws&host=%s&path=%s#%s' \
        "$(jq -r .uuid <<<"$s")" "$ip" "$port" "$(jq -r .sni <<<"$s")" "$(jq -r .sni <<<"$s")" "$(jq -r .path <<<"$s")" "$name" ;;
    trojan-ws)
      printf 'trojan://%s@%s:%s?security=tls&sni=%s&type=ws&host=%s&path=%s#%s' \
        "$(jq -r .password <<<"$s")" "$ip" "$port" "$(jq -r .sni <<<"$s")" "$(jq -r .sni <<<"$s")" "$(jq -r .path <<<"$s")" "$name" ;;
    vless-grpc)
      printf 'vless://%s@%s:%s?security=tls&encryption=none&sni=%s&type=grpc&serviceName=%s#%s' \
        "$(jq -r .uuid <<<"$s")" "$ip" "$port" "$(jq -r .sni <<<"$s")" "$(jq -r .service <<<"$s")" "$name" ;;
    anytls)
      printf 'anytls://%s@%s:%s?sni=%s&insecure=1#%s' \
        "$(jq -r .password <<<"$s")" "$ip" "$port" "$(jq -r .sni <<<"$s")" "$name" ;;
    hysteria2)
      if [ -n "$(jq -r '.obfs // empty' <<<"$s")" ]; then
        printf 'hysteria2://%s@%s:%s?sni=%s&insecure=1&obfs=salamander&obfs-password=%s#%s' \
          "$(jq -r .password <<<"$s")" "$ip" "$port" "$(jq -r .sni <<<"$s")" "$(jq -r .obfs <<<"$s")" "$name"
      else
        printf 'hysteria2://%s@%s:%s?sni=%s&insecure=1#%s' \
          "$(jq -r .password <<<"$s")" "$ip" "$port" "$(jq -r .sni <<<"$s")" "$name"
      fi ;;
    tuic)
      printf 'tuic://%s:%s@%s:%s?sni=%s&congestion_control=bbr&alpn=h3&allow_insecure=1#%s' \
        "$(jq -r .uuid <<<"$s")" "$(jq -r .password <<<"$s")" "$ip" "$port" "$(jq -r .sni <<<"$s")" "$name" ;;
    ss)
      enc=$(printf '%s:%s' "$(jq -r .method <<<"$s")" "$(jq -r .password <<<"$s")" | base64 -w0 | tr '+/' '-_' | tr -d '=')
      printf 'ss://%s@%s:%s#%s' "$enc" "$ip" "$port" "$name" ;;
    vless-tcp)
      printf 'vless://%s@%s:%s?encryption=none&type=tcp#%s' \
        "$(jq -r .uuid <<<"$s")" "$ip" "$port" "$name" ;;
    socks5)
      printf 'socks://%s:%s@%s:%s#%s' \
        "$(jq -r .username <<<"$s")" "$(jq -r .password <<<"$s")" "$ip" "$port" "$name" ;;
    ss-shadowtls)
      enc=$(printf '%s:%s' "$(jq -r .method <<<"$s")" "$(jq -r .password <<<"$s")" | base64 -w0 | tr '+/' '-_' | tr -d '=')
      printf 'ss://%s@%s:%s?plugin=shadow-tls%%3Bhost%%3D%s%%3Bpassword%%3D%s%%3Bversion%%3D3#%s' \
        "$enc" "$ip" "$port" "$(jq -r .stls_host <<<"$s")" "$(jq -r .stls_password <<<"$s")" "$name" ;;
    snell)
      printf 'Surge 配置行: %s = snell, %s, %s, psk = %s, version = %s' \
        "$name" "$ip" "$port" "$(jq -r .psk <<<"$s")" "$(jq -r .version <<<"$s")" ;;
    *) echo "(无分享链接)" ;;
  esac
}

write_clash_yaml() {
  local ip f="$SB_ETC/clash.yaml" tmp
  tmp=$(mktemp "$SB_ETC/.clash.yaml.XXXXXX") || { err "无法创建 Clash 临时文件"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  ip=$(server_ip)
  [ -n "$ip" ] || { rm -f "$tmp"; err "无法确认公网 IPv4，拒绝生成包含空/私网地址的 Clash 配置"; return 1; }
  [ ! -e "$f" ] || [ -f "$f" ] || { rm -f "$tmp"; err "Clash 输出目标不是普通文件，拒绝替换"; return 1; }
  if [ -e "$f" ] && ! owned_has 'etc/sing-box/clash.yaml'; then
    rm -f "$tmp"; err "发现未登记的 Clash 配置，拒绝覆盖: $f"; return 1
  fi
  {
    echo "proxies:"
    jq -r --arg ip "$ip" '
      .nodes[] | .share as $s | .inbound.listen_port as $p | .name as $n |
      if $s.proto=="vless-reality" then
        "  - {name: \($n), type: vless, server: \($ip), port: \($p), uuid: \($s.uuid), network: tcp, flow: xtls-rprx-vision, tls: true, servername: \($s.sni), reality-opts: {public-key: \($s.pbk), short-id: \($s.sid)}, client-fingerprint: chrome}"
      elif $s.proto=="vless-ws" then
        "  - {name: \($n), type: vless, server: \($ip), port: \($p), uuid: \($s.uuid), network: ws, tls: true, servername: \($s.sni), ws-opts: {path: \($s.path), headers: {Host: \($s.sni)}}, skip-cert-verify: true}"
      elif $s.proto=="trojan-ws" then
        "  - {name: \($n), type: trojan, server: \($ip), port: \($p), password: \($s.password), network: ws, sni: \($s.sni), ws-opts: {path: \($s.path), headers: {Host: \($s.sni)}}, skip-cert-verify: true}"
      elif $s.proto=="vless-grpc" then
        "  - {name: \($n), type: vless, server: \($ip), port: \($p), uuid: \($s.uuid), network: grpc, tls: true, servername: \($s.sni), grpc-opts: {grpc-service-name: \($s.service)}, skip-cert-verify: true}"
      elif $s.proto=="vless-tcp" then
        "  - {name: \($n), type: vless, server: \($ip), port: \($p), uuid: \($s.uuid), network: tcp, tls: false}"
      elif $s.proto=="snell" then
        "  - {name: \($n), type: snell, server: \($ip), port: \($p), psk: \($s.psk), version: \($s.version), udp: true}"
      elif $s.proto=="anytls" then
        "  - {name: \($n), type: anytls, server: \($ip), port: \($p), password: \($s.password), sni: \($s.sni), skip-cert-verify: true}"
      elif $s.proto=="hysteria2" then
        "  - {name: \($n), type: hysteria2, server: \($ip), port: \($p), password: \($s.password), sni: \($s.sni), skip-cert-verify: true\(if ($s.obfs // "") != "" then ", obfs: salamander, obfs-password: \($s.obfs)" else "" end)}"
      elif $s.proto=="tuic" then
        "  - {name: \($n), type: tuic, server: \($ip), port: \($p), uuid: \($s.uuid), password: \($s.password), sni: \($s.sni), alpn: [h3], congestion-controller: bbr, skip-cert-verify: true}"
      elif $s.proto=="ss-shadowtls" then
        "  - {name: \($n), type: ss, server: \($ip), port: \($p), cipher: \($s.method), password: \($s.password), plugin: shadow-tls, plugin-opts: {host: \($s.stls_host), password: \($s.stls_password), version: 3}}"
      elif $s.proto=="ss" then
        "  - {name: \($n), type: ss, server: \($ip), port: \($p), cipher: \($s.method), password: \($s.password)}"
      elif $s.proto=="socks5" then
        "  - {name: \($n), type: socks5, server: \($ip), port: \($p), username: \($s.username), password: \($s.password)}"
      else empty end' "$NODES"
    echo "proxy-groups:"
    echo "  - {name: PROXY, type: select, proxies: [DIRECT$(jq -r '[.nodes[] | select(.share.proto | IN("vless-reality","vless-ws","trojan-ws","vless-grpc","vless-tcp","anytls","hysteria2","tuic","ss","ss-shadowtls","socks5","snell")) | .name] | map(", " + .) | join("")' "$NODES")]}"
    echo "rules:"
    echo "  - MATCH,PROXY"
  } > "$tmp" && mark_owned_if_new 'etc/sing-box/clash.yaml' "$f" && mv "$tmp" "$f" && chmod 600 "$f" || { rm -f "$tmp"; err "Clash 配置写入失败"; return 1; }
  ok "Clash/Mihomo 配置已更新: $f"
}

# ---------- 节点管理 ----------
menu_protocols() {
cat >&2 <<'EOF'


[1] VLESS + TCP + Reality + Vision
[2] VLESS (WebSocket+TLS)
[3] Trojan (WebSocket+TLS)
[4] VLESS (gRPC+TLS)
[5] AnyTLS
[6] Hysteria2
[7] TUICv5
[8] Shadowsocks
[9] VLESS (TCP)
[10] SOCKS5
    [11] Snell (v5/v6, Surge 系)
[0] 返回
EOF
}

node_add() {
need_root; init_state
[ -x "$SB_BIN" ] || { warn "核心未安装, 先用主菜单 [15] 安装"; return;}
menu_protocols
local c name port tag built ip
c=$(ask "请输入协议选项 [0]: " "0"); [ "$c" = "0" ] && return
name=$(ask "节点名称: " "node-$(rand_hex 2)")
port=$(ask "监听端口 [随机]: " "$(rand_port)")
check_port_free "$port" || return 1
tag=$(uniq_tag n "$name")
built=$(build_by_choice "$c" "$tag" "$port") || { err "创建失败"; return 1;}
backup_state "$NODES" || return 1
if ! jq --arg name "$name" --argjson b "$built" '.nodes += [{name:$name} + $b]' "$NODES" | atomic_write "$NODES"; then
  restore_state "$NODES.bak" "$NODES"; err "节点状态写入失败，未应用配置"; return 1
fi
if ! rebuild_config; then restore_state "$NODES.bak" "$NODES"; err "已回滚节点状态"; return 1; fi
rm -f "$NODES.bak"
write_clash_yaml || warn "节点本机服务已验证，但 Clash 文件未生成；请检查上方错误"
ip=$(server_ip)
if [ -n "$ROOT" ]; then
  ok "节点配置已保存并通过 sing-box 检查: $name ($(proto_name "$(jq -r .share.proto <<<"$built")"))"
  warn "沙盒模式未启动服务、未验证系统监听，也未验证公网可达性；这不代表 VPS 节点已部署成功"
else
  ok "节点本机部署已验证: $name ($(proto_name "$(jq -r .share.proto <<<"$built")"))；sing-box 检查通过、systemd 为 active、配置端口均已监听"
fi
if [ -n "$ip" ]; then say " 链接: $(share_link "$ip" "$port" "$name" "$(jq -c .share <<<"$built")")"
else warn "未能获取公网 IPv4，未生成分享链接；本机监听成功不等于公网可达，需另行检查云防火墙/运营商网络"; fi
}

node_list_links() {
init_state; local ip; ip=$(server_ip)
local n; n=$(jq '.nodes|length' "$NODES")
[ "$n" = 0 ] && { say "暂无节点"; return;}
if [ -z "$ip" ]; then warn "无法确认公网 IPv4，暂不输出可能错误的分享链接；请检查公网地址服务后重试"; return 1; fi
jq -c '.nodes[]' "$NODES" | while read -r row; do
local nm pt pr sh
nm=$(jq -r .name <<<"$row"); pt=$(jq -r .inbound.listen_port <<<"$row")
pr=$(jq -r .share.proto <<<"$row"); sh=$(jq -c .share <<<"$row")
printf '\n%s (%s) 端口 %s\n %s\n' "$nm" "$(proto_name "$pr")" "$pt" "$(share_link "$ip" "$pt" "$nm" "$sh")"
done
local rn; rn=$(jq '.routes|length' "$RELAY")
if [ "$rn" != "0" ]; then
say ""; say "中转入口:"
jq -c '.routes[]' "$RELAY" | while read -r row; do
local nm pt pr sh
nm=$(jq -r .name <<<"$row"); pt=$(jq -r .inbound.listen_port <<<"$row")
pr=$(jq -r .share.proto <<<"$row"); sh=$(jq -c .share <<<"$row")
printf '\n%s (%s -> 落地 %s) 端口 %s\n %s\n' "$nm" "$(proto_name "$pr")" "$(jq -r .outbound.tag <<<"$row")" "$pt" "$(share_link "$ip" "$pt" "$nm" "$sh")"
done
fi
}

node_delete() {
init_state
jq -r '.nodes | to_entries[] | " [\(.key+1)] \(.value.name) (\(.value.share.proto) 端口 \(.value.inbound.listen_port))"' "$NODES" >&2
local idx n; idx=$(ask "输入要删除的序号 [0 取消]: " "0"); [ "$idx" = "0" ] && return
n=$(jq '.nodes|length' "$NODES"); [ "$idx" -ge 1 ] && [ "$idx" -le "$n" ] || { err "序号无效"; return;}
backup_state "$NODES" || return 1
if ! jq --argjson i "$((idx-1))" 'del(.nodes[$i])' "$NODES" | atomic_write "$NODES"; then restore_state "$NODES.bak" "$NODES"; err "状态写入失败，已回滚"; return 1; fi
if rebuild_config; then rm -f "$NODES.bak"; write_clash_yaml && ok "已删除"
else restore_state "$NODES.bak" "$NODES"; err "删除失败, 已回滚"; fi
}

node_modify() {
init_state
jq -r '.nodes | to_entries[] | " [\(.key+1)] \(.value.name) 端口 \(.value.inbound.listen_port)"' "$NODES" >&2
local idx n what name port
idx=$(ask "输入要修改的序号 [0 取消]: " "0"); [ "$idx" = "0" ] && return
n=$(jq '.nodes|length' "$NODES"); [ "$idx" -ge 1 ] && [ "$idx" -le "$n" ] || { err "序号无效"; return;}
what=$(ask "[1] 改名称 [2] 改端口 [0] 取消: " "0")
backup_state "$NODES" || return 1
case "$what" in
1) name=$(ask "新名称: " ""); [ -n "$name" ] || { rm -f "$NODES.bak"; return; }
jq --argjson i "$((idx-1))" --arg v "$name" '.nodes[$i].name = $v' "$NODES" | atomic_write "$NODES" || { restore_state "$NODES.bak" "$NODES"; err "状态写入失败，已回滚"; return 1; };;
2) port=$(ask "新端口: " ""); [ -n "$port" ] || { rm -f "$NODES.bak"; return; }
check_port_free "$port" "$(jq -r --argjson i "$((idx-1))" '.nodes[$i].inbound.tag' "$NODES")" || { rm -f "$NODES.bak"; return; }
jq --argjson i "$((idx-1))" --argjson v "$port" '.nodes[$i].inbound.listen_port = $v' "$NODES" | atomic_write "$NODES" || { restore_state "$NODES.bak" "$NODES"; err "状态写入失败，已回滚"; return 1; };;
*) rm -f "$NODES.bak"; return;;
esac
if rebuild_config; then rm -f "$NODES.bak"; write_clash_yaml && ok "已修改"
else restore_state "$NODES.bak" "$NODES"; err "修改失败, 已回滚"; fi
}

# ---------- 落地 / 中转 ----------
token_export() {
  init_state
  local n; n=$(jq '.nodes|length' "$NODES"); [ "$n" = 0 ] && { say "本机暂无节点可导出"; return;}
  jq -r '.nodes | to_entries[] | " [\(.key+1)] \(.value.name) (\(.value.share.proto))"' "$NODES" >&2
  local idx; idx=$(ask "选择要导出的落地节点 [0 取消]: " "0"); [ "$idx" = "0" ] && return
  local row proto outbound pass blob mac
  row=$(jq -c --argjson i "$((idx-1))" '.nodes[$i]' "$NODES")
  proto=$(jq -r .share.proto <<<"$row")
  outbound=$(node_to_outbound "$row") || { err "该协议暂不支持 Token 导出"; return 1;}
  pass=$(rand_pw 12)
  blob=$(jq -n --arg name "$(jq -r .name <<<"$row")" --argjson ob "$outbound" \
  '{v:1, name:$name, outbound:$ob}' \
  | openssl enc -aes-256-cbc -pbkdf2 -salt -pass fd:3 -base64 -A 3< <(printf '%s\n' "$pass")) || { err "加密失败"; return 1;}
  mac=$(token_mac "$pass" "SBM2:$blob") || { err "Token 完整性标签生成失败"; return 1; }
  say ""; ok "落地 Token (通过一种渠道发送):"
  say "SBM2:$blob:$mac"
  say ""; ok "解密口令 (请通过另一种渠道发送): $pass"
}

token_mac() {
  local pass="$1" data="$2"
  printf '%s' "$data" | openssl dgst -sha256 -hmac "$pass" | awk '{print $NF}'
}

validate_outbound() {
  local outbound="$1" type host port value
  jq -e '
    def only($allowed): (keys - $allowed) == [];
    type == "object"
    and only(["type","tag","server","server_port","uuid","flow","tls","transport","method","password","username","version","psk","congestion_control"])
    and (.type | IN("vless","shadowsocks","socks","http","trojan","hysteria2","tuic","anytls","snell"))
    and (.server | type == "string" and length > 0)
    and (.server_port | type == "number" and floor == . and . >= 1 and . <= 65535)
    and (if has("tag") then (.tag | type == "string" and (length == 0 or test("^[A-Za-z0-9_.-]{1,80}$"))) else true end)
    and (if has("tls") then
      (.tls | type == "object" and only(["enabled","server_name","insecure","utls","reality","alpn"])
        and (if has("enabled") then (.enabled | type == "boolean") else true end)
        and (if has("insecure") then (.insecure | type == "boolean") else true end)
        and (if has("server_name") then (.server_name | type == "string" and length > 0) else true end)
        and (if has("alpn") then (.alpn | type == "array" and all(.[]; type == "string" and length > 0)) else true end)
        and (if has("utls") then (.utls | type == "object" and only(["enabled","fingerprint"]) and .enabled == true and (.fingerprint | type == "string" and length > 0)) else true end)
        and (if has("reality") then (.reality | type == "object" and only(["enabled","public_key","short_id"]) and .enabled == true) else true end))
      else true end)
    and (if has("transport") then
      (.transport | type == "object" and only(["type","path","service_name","headers"])
        and (.type | IN("ws","grpc"))
        and (if has("headers") then (.headers | type == "object" and only(["Host"]) and (.Host | type == "string" and length > 0)) else true end))
      else true end)' >/dev/null 2>&1 <<<"$outbound" || return 1
  host=$(jq -r '.server' <<<"$outbound"); port=$(jq -r '.server_port' <<<"$outbound")
  valid_host "$host" && valid_port "$port" || return 1
  type=$(jq -r '.type' <<<"$outbound")
  case "$type" in
    vless)
      jq -e 'keys - ["type","tag","server","server_port","uuid","flow","tls","transport"] == []' >/dev/null 2>&1 <<<"$outbound" || return 1
      jq -e '.uuid | type == "string" and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")' >/dev/null 2>&1 <<<"$outbound" || return 1
      value=$(jq -r '.flow // empty' <<<"$outbound"); [ -z "$value" ] || { [ "$value" = "xtls-rprx-vision" ] && jq -e '.tls.reality.enabled == true' >/dev/null 2>&1 <<<"$outbound"; } || return 1
      value=$(jq -r '.tls.server_name // empty' <<<"$outbound"); [ -z "$value" ] || valid_domain "$value" || return 1
      if jq -e '.tls.reality.enabled == true' >/dev/null 2>&1 <<<"$outbound"; then
        [ "$(jq -r '.tls.enabled' <<<"$outbound")" = true ] || return 1
        value=$(jq -r '.tls.reality.public_key // empty' <<<"$outbound"); [[ "$value" =~ ^[A-Za-z0-9_-]{43}$ ]] || return 1
        value=$(jq -r '.tls.reality.short_id // empty' <<<"$outbound"); [[ "$value" =~ ^[A-Fa-f0-9]{0,16}$ ]] || return 1
        [ -n "$(jq -r '.tls.server_name // empty' <<<"$outbound")" ] || return 1
        [ "$(jq -r '.transport.type // "tcp"' <<<"$outbound")" = tcp ] || return 1
      fi
      case "$(jq -r '.transport.type // "tcp"' <<<"$outbound")" in
        tcp) ;;
        ws) value=$(jq -r '.transport.path // empty' <<<"$outbound"); valid_path "$value" || return 1
            value=$(jq -r '.transport.headers.Host // empty' <<<"$outbound"); [ -z "$value" ] || valid_domain "$value" || return 1 ;;
        grpc) value=$(jq -r '.transport.service_name // empty' <<<"$outbound"); valid_service "$value" || return 1 ;;
        *) return 1 ;;
      esac ;;
    shadowsocks)
      jq -e 'keys - ["type","tag","server","server_port","method","password"] == []' >/dev/null 2>&1 <<<"$outbound" || return 1
      jq -e '(.method | IN("aes-128-gcm","aes-256-gcm","chacha20-ietf-poly1305","xchacha20-ietf-poly1305","2022-blake3-aes-128-gcm","2022-blake3-aes-256-gcm","2022-blake3-chacha20-poly1305")) and (.password | type == "string" and length > 0)' >/dev/null 2>&1 <<<"$outbound" || return 1 ;;
    socks|http)
      jq -e 'keys - (if .type == "socks" then ["type","tag","server","server_port","version","username","password"] else ["type","tag","server","server_port","username","password","tls"] end) == []
        and (if has("username") or has("password") then (.username | type == "string" and length > 0) and (.password | type == "string" and length > 0) else true end)
        and (if .type == "socks" then .version == "5" else true end)' >/dev/null 2>&1 <<<"$outbound" || return 1
      if [ "$type" = http ]; then value=$(jq -r '.tls.server_name // empty' <<<"$outbound"); [ -z "$value" ] || valid_host "$value" || return 1; fi ;;
    snell)
      jq -e 'keys - ["type","tag","server","server_port","version","psk"] == [] and .version == 6 and (.psk | type == "string" and length > 0)' >/dev/null 2>&1 <<<"$outbound" || return 1 ;;
    tuic)
      jq -e 'keys - ["type","tag","server","server_port","uuid","password","congestion_control","tls"] == [] and (.uuid | type == "string" and test("^[0-9a-fA-F-]{36}$")) and (.password | type == "string" and length > 0) and .congestion_control == "bbr"' >/dev/null 2>&1 <<<"$outbound" || return 1
      value=$(jq -r '.tls.server_name // empty' <<<"$outbound"); valid_domain "$value" || return 1 ;;
    trojan|hysteria2|anytls)
      jq -e 'keys - (if .type == "trojan" then ["type","tag","server","server_port","password","transport","tls"] else ["type","tag","server","server_port","password","tls"] end) == [] and (.password | type == "string" and length > 0)' >/dev/null 2>&1 <<<"$outbound" || return 1
      jq -e '.tls.enabled == true and (if .type == "trojan" then .transport.type == "ws" else (has("transport") | not) end)' >/dev/null 2>&1 <<<"$outbound" || return 1
      value=$(jq -r '.tls.server_name // empty' <<<"$outbound"); valid_domain "$value" || return 1 ;;
  esac
}

# 把本机节点条目转换成可供中转机使用的 outbound; 不支持的协议返回非 0
node_to_outbound() {
local row="$1" proto ip port
proto=$(jq -r .share.proto <<<"$row"); ip=$(server_ip); port=$(jq -r .inbound.listen_port <<<"$row")
[ -n "$ip" ] || { err "无法确认公网 IPv4，拒绝导出地址为空的 Token"; return 1; }
jq -n --arg ip "$ip" --argjson port "$port" --argjson s "$(jq -c .share <<<"$row")" '
if $s.proto=="vless-reality" then
{type:"vless", tag:"", server:$ip, server_port:$port, uuid:$s.uuid, flow:"xtls-rprx-vision",
tls:{enabled:true, server_name:$s.sni, utls:{enabled:true, fingerprint:"chrome"},
reality:{enabled:true, public_key:$s.pbk, short_id:$s.sid}}}
elif $s.proto=="vless-ws" then
{type:"vless", tag:"", server:$ip, server_port:$port, uuid:$s.uuid,
transport:{type:"ws", path:$s.path, headers:{Host:$s.sni}},
tls:{enabled:true, server_name:$s.sni, insecure:true}}
elif $s.proto=="trojan-ws" then
{type:"trojan", tag:"", server:$ip, server_port:$port, password:$s.password,
transport:{type:"ws", path:$s.path, headers:{Host:$s.sni}},
tls:{enabled:true, server_name:$s.sni, insecure:true}}
elif $s.proto=="anytls" then
{type:"anytls", tag:"", server:$ip, server_port:$port, password:$s.password,
tls:{enabled:true, server_name:$s.sni, insecure:true}}
elif $s.proto=="hysteria2" then
{type:"hysteria2", tag:"", server:$ip, server_port:$port, password:$s.password,
tls:{enabled:true, server_name:$s.sni, insecure:true}}
elif $s.proto=="tuic" then
{type:"tuic", tag:"", server:$ip, server_port:$port, uuid:$s.uuid, password:$s.password,
congestion_control:"bbr", tls:{enabled:true, server_name:$s.sni, insecure:true, alpn:["h3"]}}
elif $s.proto=="ss" then
{type:"shadowsocks", tag:"", server:$ip, server_port:$port, method:$s.method, password:$s.password}
elif $s.proto=="vless-tcp" then
{type:"vless", tag:"", server:$ip, server_port:$port, uuid:$s.uuid}
elif $s.proto=="socks5" then
{type:"socks", tag:"", server:$ip, server_port:$port, version:"5", username:$s.username, password:$s.password}
elif $s.proto=="snell" and ($s.version|tonumber)==6 then
      {type:"snell", tag:"", server:$ip, server_port:$port, version:6, psk:$s.psk}
    else error("unsupported") end' 2>/dev/null
}

relay_add_with_outbound() { # <outbound-json> <建议名>
local outbound="$1" defname="${2:-relay}" name port c tag built ip
name=$(ask "中转节点名称 [$defname]: " "$defname")
menu_protocols
c=$(ask "选择中转入口协议 [0 取消]: " "0"); [ "$c" = "0" ] && return
port=$(ask "中转监听端口 [随机]: " "$(rand_port)")
check_port_free "$port" || return 1
tag=$(uniq_tag r "$name")
built=$(build_by_choice "$c" "$tag" "$port") || { err "入口创建失败"; return 1;}
outbound=$(jq --arg t "out-$tag" '.tag = $t' <<<"$outbound")
jq -n --arg name "$name" --argjson b "$built" --argjson ob "$outbound" \
'{name:$name, inbound:$b.inbound, share:$b.share, outbound:$ob}' | atomic_write "$ETC/.route.json" || { err "中转临时状态写入失败"; return 1; }
backup_state "$RELAY" || { rm -f "$ETC/.route.json"; return 1; }
if ! jq --slurpfile r "$ETC/.route.json" '.routes += $r' "$RELAY" | atomic_write "$RELAY"; then
  restore_state "$RELAY.bak" "$RELAY"; rm -f "$ETC/.route.json"; err "中转状态写入失败，已回滚"; return 1
fi
rm -f "$ETC/.route.json"
if ! rebuild_config; then restore_state "$RELAY.bak" "$RELAY"; err "已回滚中转状态"; return 1; fi
rm -f "$RELAY.bak"
ip=$(server_ip)
if [ -n "$ROOT" ]; then
  ok "中转配置已保存并通过 sing-box 检查: $name -> $(jq -r .server <<<"$outbound"):$(jq -r .server_port <<<"$outbound")"
  warn "沙盒模式未启动服务、未验证监听或公网可达性"
else
  ok "中转本机部署已验证: $name；sing-box 检查通过、systemd 为 active、配置端口均已监听"
fi
if [ -n "$ip" ]; then say " 链接: $(share_link "$ip" "$port" "$name" "$(jq -c .share <<<"$built")")"
else warn "未能获取公网 IPv4，未生成入口分享链接；公网可达性尚未验证"; fi
}

token_import() {
  init_state
  [ -x "$SB_BIN" ] || { warn "核心未安装, 先用主菜单 [15] 安装"; return;}
  local tok pass plain outbound payload blob mac expected name
  while true; do
    tok=$(ask "粘贴落地 Token (SBM2:...): " ""); [ -n "$tok" ] || return
    pass=$(ask "输入解密口令: " ""); [ -n "$pass" ] || return
    case "$tok" in
      SBM2:*)
        payload="${tok#SBM2:}"; blob="${payload%%:*}"; mac="${payload#*:}"
        if [[ "$payload" != *:* || "$blob" == *:* || ! "$mac" =~ ^[A-Fa-f0-9]{64}$ ]]; then
          err "SBM2 Token 格式错误，请重新输入"; continue
        fi
        expected=$(token_mac "$pass" "SBM2:$blob")
        if [ "${expected,,}" != "${mac,,}" ]; then err "Token 完整性校验失败（内容被改动或口令错误），请重新输入"; continue; fi
        plain=$(printf '%s' "$blob" | openssl enc -d -aes-256-cbc -pbkdf2 -base64 -A -pass fd:3 3< <(printf '%s\n' "$pass") 2>/dev/null) || { err "Token 解密失败，请重新输入"; continue; } ;;
      SBM1:*)
        warn "这是旧版 SBM1 Token，无法验证其完整性；继续导入前请确认来源可信"
        plain=$(printf '%s' "${tok#SBM1:}" | openssl enc -d -aes-256-cbc -pbkdf2 -base64 -A -pass fd:3 3< <(printf '%s\n' "$pass") 2>/dev/null) || { err "旧版 Token 解密失败，请重新输入"; continue; } ;;
      *) err "Token 版本不受支持，请重新输入"; continue ;;
    esac
    if ! jq -e 'type == "object" and .v == 1 and (.name | type == "string" and length > 0 and length <= 64) and (.outbound | type == "object")' >/dev/null 2>&1 <<<"$plain"; then
      err "Token 内容结构/版本无效，请重新输入"; continue
    fi
    outbound=$(jq -c '.outbound' <<<"$plain")
    if ! validate_outbound "$outbound"; then err "Token 中 outbound 字段不完整或参数非法，请重新输入"; continue; fi
    break
  done
  name=$(jq -r '.name' <<<"$plain")
  relay_add_with_outbound "$outbound" "$name"
}

# ---------- 第三方节点导入 ----------
urldecode() { printf '%b' "$(printf '%s' "$1" | sed 's/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g; s/+/ /g')";}
b64d() { local s="$1"; s=$(printf '%s' "$s" | tr '_-' '/+'); local m=$(( ${#s} % 4)); [ $m -eq 2 ] && s="$s=="; [ $m -eq 3 ] && s="$s="; printf '%s' "$s" | base64 -d 2>/dev/null;}
qparam() { # qparam <query> <key>
printf '%s' "$1" | tr '&' '\n' | awk -F= -v k="$2" '$1==k{print substr($0, index($0,"=")+1)}' | head -1
}

parse_vless_link() { # 回显 outbound json；所有字段先做白名单校验
  local link="$1" rest uuid hostport query uuidpart host port suffix
  [[ "$link" == vless://* ]] || return 1
  rest="${link#vless://}"; rest="${rest%%#*}"
  [[ "$rest" == *@* && "${rest#*@}" != *@* ]] || return 1
  uuidpart="${rest%%@*}"; rest="${rest#*@}"
  hostport="${rest%%\?*}"; query=""; case "$rest" in *\?*) query="${rest#*\?}";; esac
  [[ -n "$uuidpart" && -n "$hostport" ]] || return 1
  if [[ "$hostport" == "["* ]]; then
    [[ "$hostport" == *"]"* ]] || return 1
    host="${hostport#\[}"; host="${host%%\]*}"; suffix="${hostport#*\]}"
    valid_ipv6 "$host" || return 1
    case "$suffix" in "") port="" ;; :*) port="${suffix#:}"; [[ -n "$port" ]] || return 1 ;; *) return 1 ;; esac
  elif [[ "$hostport" == *":"* ]]; then
    host="${hostport%:*}"; port="${hostport##*:}"
    [[ "$host" != *:* && -n "$port" ]] || return 1
  else host="$hostport"; port=""; fi
  valid_host "$host" || return 1
  port="${port:-443}"; valid_port "$port" || return 1
  uuid=$(urldecode "$uuidpart")
  [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || return 1
  local security type sni pbk sid flow path hosthdr svc key count fp encryption pair qkey
  local -a query_pairs=()
  IFS='&' read -r -a query_pairs <<<"$query"
  for pair in "${query_pairs[@]}"; do
    [ -n "$pair" ] || continue
    [[ "$pair" == *=* ]] || return 1
    qkey="${pair%%=*}"
    case "$qkey" in security|type|sni|pbk|sid|flow|path|host|serviceName|encryption|fp) ;; *) return 1 ;; esac
  done
  for key in security type sni pbk sid flow path host serviceName encryption fp; do
    count=$(printf '%s' "$query" | tr '&' '\n' | awk -F= -v k="$key" '$1==k{n++} END{print n+0}')
    (( count <= 1 )) || return 1
  done
  security=$(qparam "$query" security); security="${security:-none}"
  type=$(qparam "$query" type); type="${type:-tcp}"
  sni=$(urldecode "$(qparam "$query" sni)"); pbk=$(urldecode "$(qparam "$query" pbk)")
  sid=$(urldecode "$(qparam "$query" sid)"); flow=$(urldecode "$(qparam "$query" flow)")
  path=$(urldecode "$(qparam "$query" path)"); hosthdr=$(urldecode "$(qparam "$query" host)")
  svc=$(urldecode "$(qparam "$query" serviceName)")
  encryption=$(qparam "$query" encryption); encryption="${encryption:-none}"
  fp=$(urldecode "$(qparam "$query" fp)")
  [ "$encryption" = none ] || return 1
  [ -z "$fp" ] || [[ "$fp" =~ ^(chrome|firefox|safari|edge)$ ]] || return 1
  case "$security" in none|tls|reality) ;; *) return 1 ;; esac
  case "$type" in tcp|ws|grpc) ;; *) return 1 ;; esac
  if [ "$security" = reality ]; then
    [ "$type" = tcp ] || return 1
    valid_domain "$sni" && [[ "$pbk" =~ ^[A-Za-z0-9_-]{43}$ && "$sid" =~ ^[A-Fa-f0-9]{0,16}$ ]] || return 1
    [[ -z "$flow" || "$flow" == xtls-rprx-vision ]] || return 1
  elif [ "$flow" != "" ]; then return 1
  fi
  if [ "$security" = tls ]; then
    sni="${sni:-$host}"
    valid_host "$sni" || return 1
  elif [ -n "$fp" ] && [ "$security" != reality ]; then return 1
  fi
  if [ "$type" = ws ]; then
    path="${path:-/}"; valid_path "$path" || return 1
    hosthdr="${hosthdr:-${sni:-$host}}"; valid_host "$hosthdr" || return 1
  elif [ "$type" = grpc ]; then
    valid_service "$svc" || return 1
  fi
  jq -n --arg host "$host" --argjson port "$port" --arg uuid "$uuid" --arg security "$security" \
    --arg type "$type" --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" --arg flow "$flow" --arg fp "$fp" \
    --arg path "$path" --arg hosthdr "$hosthdr" --arg svc "$svc" '
    {type:"vless", tag:"", server:$host, server_port:$port, uuid:$uuid}
    + (if $flow != "" then {flow:$flow} else {} end)
    + (if $security=="reality" then
      {tls:{enabled:true, server_name:$sni, utls:{enabled:true, fingerprint:(if $fp == "" then "chrome" else $fp end)}, reality:{enabled:true, public_key:$pbk, short_id:$sid}}}
      elif $security=="tls" then {tls: ({enabled:true, server_name:$sni, insecure:true} + (if $fp != "" then {utls:{enabled:true, fingerprint:$fp}} else {} end))} else {} end)
    + (if $type=="ws" then {transport:{type:"ws", path:$path, headers:{Host:$hosthdr}}}
      elif $type=="grpc" then {transport:{type:"grpc", service_name:$svc}} else {} end)'
}

parse_ss_link() { # 回显 outbound json
  local link="$1" rest cred hostport method pw host port dec suffix
  [[ "$link" == ss://* ]] || return 1
  rest="${link#ss://}"; rest="${rest%%#*}"
  [[ "$rest" != *plugin=* ]] || return 1
  rest="${rest%%\?*}"
  if [[ "$rest" == *@* ]]; then
    cred="${rest%%@*}"; hostport="${rest#*@}"
    if [[ "$cred" == *":"* ]]; then method="${cred%%:*}"; pw=$(urldecode "${cred#*:}")
    else dec=$(b64d "$cred") || return 1; [[ "$dec" == *:* ]] || return 1; method="${dec%%:*}"; pw="${dec#*:}"; fi
  else
    dec=$(b64d "$rest") || return 1; [[ "$dec" == *@* ]] || return 1
    cred="${dec%%@*}"; hostport="${dec#*@}"
    [[ "$cred" == *:* ]] || return 1; method="${cred%%:*}"; pw="${cred#*:}"
  fi
  if [[ "$hostport" == "["* ]]; then
    [[ "$hostport" == *"]"* ]] || return 1
    host="${hostport#\[}"; host="${host%%\]*}"; suffix="${hostport#*\]}"
    valid_ipv6 "$host" || return 1
    case "$suffix" in "") port="" ;; :*) port="${suffix#:}"; [[ -n "$port" ]] || return 1 ;; *) return 1 ;; esac
  elif [[ "$hostport" == *":"* ]]; then
    host="${hostport%:*}"; port="${hostport##*:}"
    [[ "$host" != *:* && -n "$port" ]] || return 1
  else host="$hostport"; port=""; fi
  port="${port:-8388}"; valid_host "$host" && valid_port "$port" || return 1
  [[ -n "$pw" ]] || return 1
  case "$method" in aes-128-gcm|aes-256-gcm|chacha20-ietf-poly1305|xchacha20-ietf-poly1305|2022-blake3-aes-128-gcm|2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) ;; *) return 1 ;; esac
  jq -n --arg host "$host" --argjson port "$port" --arg method "$method" --arg pw "$pw" \
    '{type:"shadowsocks", tag:"", server:$host, server_port:$port, method:$method, password:$pw}'
}

third_party_import() {
init_state
[ -x "$SB_BIN" ] || { warn "核心未安装, 先用主菜单 [15] 安装"; return;}
say "支持: [1] vless:// 链接 [2] ss:// 链接 [3] 手动 SOCKS5 [4] 手动 HTTP(S) 代理" >&2
local c link outbound
c=$(ask "选择导入方式 [0 取消]: " "0")
case "$c" in
1) link=$(ask "粘贴 vless:// 链接: " ""); outbound=$(parse_vless_link "$link");;
2) link=$(ask "粘贴 ss:// 链接: " "")
   if printf '%s' "$link" | grep -q '[?&]plugin='; then err "带 plugin 的 SS 链接不受支持 (ShadowTLS/混淆插件请改用本机节点创建)"; return 1; fi
   outbound=$(parse_ss_link "$link");;
3) local h p u pw; h=$(ask "服务器地址: " ""); p=$(ask "端口 [1080]: " "1080")
u=$(ask "用户名 (可空): " ""); pw=$(ask "密码 (可空): " "")
outbound=$(jq -n --arg h "$h" --argjson p "$p" --arg u "$u" --arg pw "$pw" '
{type:"socks", tag:"", server:$h, server_port:$p, version:"5"}
+ (if $u!= "" then {username:$u, password:$pw} else {} end)');;
4) local h p u pw tls; h=$(ask "服务器地址: " ""); p=$(ask "端口 [8080]: " "8080")
u=$(ask "用户名 (可空): " ""); pw=$(ask "密码 (可空): " ""); tls=$(ask "启用 TLS (HTTPS 代理)? (y/N): " "n")
outbound=$(jq -n --arg h "$h" --argjson p "$p" --arg u "$u" --arg pw "$pw" --arg tls "$tls" '
{type:"http", tag:"", server:$h, server_port:$p}
+ (if $u!= "" then {username:$u, password:$pw} else {} end)
+ (if $tls == "y" then {tls:{enabled:true, server_name:$h, insecure:true}} else {} end)');;
*) return;;
esac
validate_outbound "$outbound" || { err "解析失败或参数不合法 (地址/端口/认证/传输字段)，未保存；请重新输入"; return 1; }
say "已解析落地: $(jq -c '{type, server, server_port}' <<<"$outbound")" >&2
relay_add_with_outbound "$outbound"
}

relay_list() {
init_state
local rn; rn=$(jq '.routes|length' "$RELAY")
[ "$rn" = 0 ] && { say "暂无中转链路"; return;}
jq -r '.routes | to_entries[] |
" [\(.key+1)] \(.value.name): 入口 \(.value.inbound.listen_port) (\(.value.share.proto)) -> \(.value.outbound.type) \(.value.outbound.server):\(.value.outbound.server_port)"' "$RELAY"
}

relay_delete() {
init_state; relay_list
local idx n; idx=$(ask "输入要删除的链路序号 [0 取消]: " "0"); [ "$idx" = "0" ] && return
n=$(jq '.routes|length' "$RELAY"); [ "$idx" -ge 1 ] && [ "$idx" -le "$n" ] || { err "序号无效"; return;}
backup_state "$RELAY" || { err "无法创建状态备份"; return 1; }
if ! jq --argjson i "$((idx-1))" 'del(.routes[$i])' "$RELAY" | atomic_write "$RELAY"; then restore_state "$RELAY.bak" "$RELAY"; err "状态写入失败，已回滚"; return 1; fi
if rebuild_config; then rm -f "$RELAY.bak"; ok "已删除"
else restore_state "$RELAY.bak" "$RELAY"; err "删除失败, 已回滚"; fi
}

relay_change_port() {
init_state; relay_list
local idx n port; idx=$(ask "输入链路序号 [0 取消]: " "0"); [ "$idx" = "0" ] && return
n=$(jq '.routes|length' "$RELAY"); [ "$idx" -ge 1 ] && [ "$idx" -le "$n" ] || { err "序号无效"; return;}
port=$(ask "新监听端口: " ""); [ -n "$port" ] || return
check_port_free "$port" "$(jq -r --argjson i "$((idx-1))" '.routes[$i].inbound.tag' "$RELAY")" || return
backup_state "$RELAY" || { err "无法创建状态备份"; return 1; }
if ! jq --argjson i "$((idx-1))" --argjson p "$port" '.routes[$i].inbound.listen_port = $p' "$RELAY" | atomic_write "$RELAY"; then restore_state "$RELAY.bak" "$RELAY"; err "状态写入失败，已回滚"; return 1; fi
if rebuild_config; then rm -f "$RELAY.bak"; ok "已修改"
else restore_state "$RELAY.bak" "$RELAY"; err "修改失败, 已回滚"; fi
}

relay_clear() {
local a; a=$(ask "确认清空全部中转配置? (y/N): " "n"); [ "$a" = "y" ] || return
backup_state "$RELAY" || { err "无法创建状态备份"; return 1; }
if ! jq '.routes = []' "$RELAY" | atomic_write "$RELAY"; then restore_state "$RELAY.bak" "$RELAY"; err "状态写入失败，已回滚"; return 1; fi
if rebuild_config; then rm -f "$RELAY.bak"; ok "已清空"
else restore_state "$RELAY.bak" "$RELAY"; err "清空失败, 已回滚"; fi
}

# ---------- 端口转发 (sing-box direct 入站, TCP/UDP) ----------
forward_menu() {
  init_state
  while true; do
    local cnt eng
    cnt=$(jq '.forwards|length' "$RELAY")
    eng=$(jq -r '.fw_engine // "sing-box"' "$META")
    cat >&2 <<EOF

  【端口转发管理】 (当前规则: $cnt 条, 引擎: $eng)
    [1] 添加转发规则
    [2] 查看当前转发规则
    [3] 修改转发规则
    [4] 删除转发规则
    [5] 切换转发引擎
    [6] 清空所有转发规则
    [0] 返回上级菜单
EOF
    local c; c=$(ask "转发菜单选项 [0]: " "0")
    case "$c" in
      1) local h p lp net tag
         h=$(ask "目标地址 (IP/域名): " ""); [ -n "$h" ] || continue
         p=$(ask "目标端口: " ""); lp=$(ask "本机监听端口 [随机]: " "$(rand_port)")
         net=$(ask "协议 [1]TCP+UDP [2]TCP [3]UDP: " "1")
         case "$net" in 2) net="tcp" ;; 3) net="udp" ;; *) net="tcp_and_udp" ;; esac
         check_port_free "$lp" || continue
         tag="fwd-$lp"
         backup_state "$RELAY" || continue
         jq --arg tag "$tag" --argjson lp "$lp" --arg h "$h" --argjson p "$p" --arg net "$net" \
           '.forwards += [{tag:$tag, listen_port:$lp, target_host:$h, target_port:$p, network:$net}]' \
           "$RELAY" | atomic_write "$RELAY" || { restore_state "$RELAY.bak" "$RELAY"; err "状态写入失败，已回滚"; continue; }
         if rebuild_config; then rm -f "$RELAY.bak"; ok "转发已添加: :$lp -> $h:$p ($net)"
         else restore_state "$RELAY.bak" "$RELAY"; err "已回滚转发状态"; fi ;;
      2) jq -r '.forwards | to_entries[] | "  [\(.key+1)] :\(.value.listen_port) -> \(.value.target_host):\(.value.target_port) (\(.value.network))"' "$RELAY" ;;
      3) local idx n what v
         jq -r '.forwards | to_entries[] | "  [\(.key+1)] :\(.value.listen_port) -> \(.value.target_host):\(.value.target_port) (\(.value.network))"' "$RELAY" >&2
         idx=$(ask "输入要修改的转发序号 [0 取消]: " "0"); [ "$idx" = "0" ] && continue
         n=$(jq '.forwards|length' "$RELAY"); [ "$idx" -ge 1 ] && [ "$idx" -le "$n" ] || { err "序号无效"; continue; }
         what=$(ask "[1] 目标地址  [2] 目标端口  [3] 监听端口  [4] 协议  [0] 取消: " "0")
         backup_state "$RELAY" || continue
         case "$what" in
           1) v=$(ask "新目标地址: " ""); [ -n "$v" ] || { rm -f "$RELAY.bak"; continue; }
              jq --argjson i "$((idx-1))" --arg v "$v" '.forwards[$i].target_host = $v' "$RELAY" | atomic_write "$RELAY" || { restore_state "$RELAY.bak" "$RELAY"; err "状态写入失败，已回滚"; continue; } ;;
           2) v=$(ask "新目标端口: " ""); [ -n "$v" ] || { rm -f "$RELAY.bak"; continue; }
              jq --argjson i "$((idx-1))" --argjson v "$v" '.forwards[$i].target_port = $v' "$RELAY" | atomic_write "$RELAY" || { restore_state "$RELAY.bak" "$RELAY"; err "状态写入失败，已回滚"; continue; } ;;
           3) v=$(ask "新监听端口: " ""); [ -n "$v" ] || { rm -f "$RELAY.bak"; continue; }
              check_port_free "$v" "$(jq -r --argjson i "$((idx-1))" '.forwards[$i].tag' "$RELAY")" || { rm -f "$RELAY.bak"; continue; }
              jq --argjson i "$((idx-1))" --argjson v "$v" '.forwards[$i].listen_port = $v | .forwards[$i].tag = "fwd-\($v)"' "$RELAY" | atomic_write "$RELAY" || { restore_state "$RELAY.bak" "$RELAY"; err "状态写入失败，已回滚"; continue; } ;;
           4) v=$(ask "协议 [1]TCP+UDP [2]TCP [3]UDP: " "1")
              case "$v" in 2) v="tcp" ;; 3) v="udp" ;; *) v="tcp_and_udp" ;; esac
              jq --argjson i "$((idx-1))" --arg v "$v" '.forwards[$i].network = $v' "$RELAY" | atomic_write "$RELAY" || { restore_state "$RELAY.bak" "$RELAY"; err "状态写入失败，已回滚"; continue; } ;;
           *) rm -f "$RELAY.bak"; continue ;;
         esac
         if rebuild_config; then rm -f "$RELAY.bak"; ok "已修改"; else restore_state "$RELAY.bak" "$RELAY"; err "已回滚"; fi ;;
      4) local idx n
         jq -r '.forwards | to_entries[] | "  [\(.key+1)] :\(.value.listen_port) -> \(.value.target_host):\(.value.target_port)"' "$RELAY" >&2
         idx=$(ask "删除序号 [0 取消]: " "0"); [ "$idx" = "0" ] && continue
         n=$(jq '.forwards|length' "$RELAY"); [ "$idx" -ge 1 ] && [ "$idx" -le "$n" ] || { err "序号无效"; continue; }
         backup_state "$RELAY" || continue
         jq --argjson i "$((idx-1))" 'del(.forwards[$i])' "$RELAY" | atomic_write "$RELAY" || { restore_state "$RELAY.bak" "$RELAY"; err "状态写入失败，已回滚"; continue; }
         if rebuild_config; then rm -f "$RELAY.bak"; ok "已删除"; else restore_state "$RELAY.bak" "$RELAY"; err "已回滚"; fi ;;
      5) engine_switch ;;
      6) local a; a=$(ask "确认清空全部转发规则? (y/N): " "n"); [ "$a" = "y" ] || continue
         backup_state "$RELAY" || continue
         jq '.forwards = []' "$RELAY" | atomic_write "$RELAY" || { restore_state "$RELAY.bak" "$RELAY"; err "状态写入失败，已回滚"; continue; }
         if rebuild_config; then rm -f "$RELAY.bak"; ok "已清空"; else restore_state "$RELAY.bak" "$RELAY"; err "已回滚"; fi ;;
      0) return ;;
    esac
  done
}

menu_relay() {
while true; do
cat >&2 <<'EOF'



[1] 落地机: 生成落地 Token (SS+ShadowTLS 不支持导出)
[2] 中转机: 通过 Token 导入规则
[3] 中转机: 导入第三方节点

[4] 查看当前中转链路
[5] 删除指定中转路由
[6] 修改中转监听端口
[7] 清空所有中转配置

[8] 端口转发管理
[0] 返回主菜单
EOF
local c; c=$(ask "中转菜单选项 [0]: " "0")
case "$c" in
1) token_export;; 2) token_import;; 3) third_party_import;;
4) relay_list;; 5) relay_delete;; 6) relay_change_port;;
7) relay_clear;; 8) forward_menu;; 0) return;;
*) warn "无效选项";;
esac
done
}

# ---------- 服务控制 ----------
menu_service() { # <action>
case "$1" in
restart) svc restart; ok "已重启";;
stop) svc stop; ok "已停止";;
status)
say "sing-box: $(svc_state) 版本: $(core_version)"
say "节点数: $(jq '.nodes|length' "$NODES" 2>/dev/null || echo 0) 中转链路: $(jq '.routes|length' "$RELAY" 2>/dev/null || echo 0) 端口转发: $(jq '.forwards|length' "$RELAY" 2>/dev/null || echo 0)"
[ -z "$ROOT" ] && ss -tulnp 2>/dev/null | grep -E 'sing-box' || true;;
log) [ -n "$ROOT" ] && { say "(沙盒模式无日志)"; return;}; journalctl -u sing-box -n 100 -f;;
esac
}

sched_restart() {
need_root
say "当前: $(crontab -l 2>/dev/null | grep -F 'systemctl restart sing-box' || echo '未设置')" >&2
local a; a=$(ask "[1] 每天 04:00 重启 [2] 取消定时重启 [0] 返回: " "0")
case "$a" in
1)
  local line='0 4 * * * /usr/bin/systemctl restart sing-box'
  if crontab -l 2>/dev/null | grep -Fxq "$line"; then warn "已有完全相同的定时任务，未登记为 SBM 创建"; return; fi
  if [ -e "$ETC/.cron-restart" ] && ! owned_has 'etc/sbm/.cron-restart'; then err "发现未登记的定时重启标记，拒绝覆盖"; return 1; fi
  record_owned 'etc/sbm/.cron-restart' || return 1
  printf 'created-by-sbm\n' | atomic_write "$ETC/.cron-restart" || return 1
  ( crontab -l 2>/dev/null; echo "$line" ) | crontab - && ok "已设置每天 04:00 重启" || { rm -f "$ETC/.cron-restart"; unrecord_owned 'etc/sbm/.cron-restart' || err "所有权标记清理失败"; err "crontab 写入失败"; return 1; } ;;
2) ( crontab -l 2>/dev/null | grep -Fxv '0 4 * * * /usr/bin/systemctl restart sing-box' || true ) | crontab - && { rm -f "$ETC/.cron-restart"; unrecord_owned 'etc/sbm/.cron-restart' || err "所有权标记清理失败"; ok "已取消"; } || err "crontab 写入失败";;
esac
}

time_check() {
say "系统时间: $(date '+%F %T %Z') UTC: $(date -u '+%F %T')"
if [ -z "$ROOT" ] && has timedatectl; then timedatectl 2>/dev/null | grep -E 'synchronized|NTP service' || true; fi
local a; a=$(ask "尝试校时 (重启 timesyncd)? (y/N): " "n")
if [ "$a" = "y" ] && [ -z "$ROOT" ];  then
systemctl restart systemd-timesyncd 2>/dev/null && ok "已触发校时" || warn "校时失败, 可考虑安装 chrony"
fi
}

dns_menu() {
init_state
say "当前 DNS: $(jq -r .dns "$META") (cf=Cloudflare, google=Google, ali=阿里)" >&2
local c; c=$(ask "[1] Cloudflare [2] Google [3] 阿里 [0] 返回: " "0")
backup_state "$META" || return 1
case "$c" in
1) jq '.dns="cf"' "$META" | atomic_write "$META" || { restore_state "$META.bak" "$META"; err "DNS 状态写入失败，已回滚"; return 1; };;
2) jq '.dns="google"' "$META" | atomic_write "$META" || { restore_state "$META.bak" "$META"; err "DNS 状态写入失败，已回滚"; return 1; };;
3) jq '.dns="ali"' "$META" | atomic_write "$META" || { restore_state "$META.bak" "$META"; err "DNS 状态写入失败，已回滚"; return 1; };;
*) return;;
esac
if rebuild_config; then rm -f "$META.bak"; ok "DNS 已更新"
else restore_state "$META.bak" "$META"; err "DNS 更新失败, 已回滚"; fi
}

config_check() {
init_state
[ -x "$SB_BIN" ] || { warn "核心未安装"; return;}
if [ -f "$CONF" ] && "$SB_BIN" check -c "$CONF"; then ok "配置文件校验通过"; else err "校验失败或配置不存在"; fi
}

not_in_v1() { warn "该功能不在本版范围内 (v0.1): $1";}

core_check_update() { # 仅查询官方最新版本, 不下载不安装
  install_deps || return 1
  local rel latest cur
  rel=$(curl -fsSL --max-time 20 https://api.github.com/repos/SagerNet/sing-box/releases/latest) || { err "获取官方版本失败"; return 1; }
  latest=$(printf '%s' "$rel" | jq -r '.tag_name' | sed 's/^v//')
  cur=$(core_version)
  say "当前版本: ${cur:-未安装}  官方最新: ${latest:-未知}"
  if [ -n "$cur" ] && [ "$cur" = "$latest" ]; then ok "已是最新版"
  elif [ -n "$cur" ]; then warn "有新版本可用, 用主菜单 [15] 安装/更新"; fi
}

# ---------- 主菜单 ----------
main_menu() {
acquire_state_lock || return 1
init_state || return 1
while true; do
local st="未运行" xv="未安装"
[ "$(svc_state)" = "active" ] && st="${C_G}运行中${C_R}"
cat >&2 <<EOF

sbm v$VER — sing-box 管理 (Muse 编写, 无自更新/无回传)
系统版本: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")
sing-box: $(core_version || echo 未安装) 服务: $st
Xray 服务: 未包含在本版


[1] 添加节点 [2] Argo 隧道节点 (v2)
[3] 查看节点链接 [4] 删除节点
[5] 修改节点

[6] 重启服务 [7] 停止服务
[8] 查看运行状态 [9] 查看实时日志
[10] 定时重启设置 [11] 时间诊断/校时

[12] 检查配置文件 [13] 检查 Sing-box 新版本 (仅检查)
[14] DNS 设置

[15] 安装/更新 Sing-box 核心
[16] 安装/更新 Xray 核心 (v2)
[17] 卸载

[18] 落地/中转/第三方节点导入/端口转发
[19] Xray 节点管理 (v2)
[0] 退出
EOF
local c; c=$(ask "主菜单选项 [0]: " "0")
case "$c" in
1) node_add;; 2) not_in_v1 "Argo 隧道节点";;
3) node_list_links;; 4) node_delete;;
5) node_modify;;
6) menu_service restart;; 7) menu_service stop;;
8) menu_service status;; 9) menu_service log;;
10) sched_restart;; 11) time_check;;
12) config_check;; 13) core_check_update;;
14) dns_menu;;
15) core_install;; 16) not_in_v1 "Xray 核心";;
17) core_uninstall;;
18) menu_relay;; 19) not_in_v1 "Xray 节点管理";;
0) say "再见"; return 0;;
*) warn "无效选项";;
esac
done
}

# ---------- 入口 ----------
case "${1:-}" in
--install-self)
need_root
acquire_state_lock || exit 1
if { [ -e "$SB_LINK" ] || [ -L "$SB_LINK" ]; } && ! owned_has 'usr/local/bin/sbm'; then
  err "发现未登记的 sbm 命令文件，拒绝覆盖: $SB_LINK"; exit 1
fi
mark_owned_if_new 'usr/local/bin/sbm' "$SB_LINK" || exit 1
mkdir -p "${SB_LINK%/*}" || { err "无法创建命令安装目录"; exit 1; }
local_tmp=$(mktemp "${SB_LINK}.XXXXXX") || { err "无法创建 sbm 命令临时文件"; exit 1; }
install -m 755 "$0" "$local_tmp" && mv -f "$local_tmp" "$SB_LINK" || { rm -f "$local_tmp"; err "命令安装失败"; exit 1; }
ok "已安装为命令: sbm (以后直接运行 sbm)"
;;
check) acquire_state_lock && init_state && rebuild_config;;
version) say "sbm v$VER";;
*) install_deps >/dev/null 2>&1 || true
   if ! has jq || ! has curl || ! has openssl; then
     err "依赖缺失 (需要 jq / curl / openssl), 自动安装失败, 请手动安装后重试"; exit 1
   fi
   main_menu;;
esac
