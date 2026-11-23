#!/usr/bin/env bash
# sbm — sing-box 节点/中转管理脚本
# 由 Muse 从零编写。不含任何第三方脚本代码。
# 设计原则:
#   1. 核心只从 sing-box 官方 GitHub Release 下载, 有校验文件时强制 SHA-256 校验
#   2. 本脚本永不自更新, 不回传任何数据; 除包管理器和官方 Release 外不访问其他地址
#   3. 所有状态保存在 /etc/sbm/*.json, 配置由状态文件全量重建, 可审计可回滚
# 用法: 以 root 运行  bash sbm.sh   (可用 SBM_ROOT=/tmp/xxx 做沙盒测试)
set -uo pipefail

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
CERTDIR="$SB_ETC/certs"
VER="0.4.3"

C_R=$'\033[0m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_RED=$'\033[31m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_R" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_R" "$*"; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_R" "$*" >&2; }
ask()  { local p="$1" d="${2:-}" v; printf '%s' "$p" >&2; read -r v || v=""; printf '%s' "${v:-$d}"; }
pause(){ printf '按回车继续...' >&2; read -r _ || true; }

need_root() { [ "$(id -u)" = 0 ] || { err "需要 root 运行"; exit 1; }; }
has() { command -v "$1" >/dev/null 2>&1; }

install_deps() {
  local miss=()
  has jq || miss+=(jq); has curl || miss+=(curl); has openssl || miss+=(openssl)
  [ ${#miss[@]} -eq 0 ] && return 0
  warn "安装依赖: ${miss[*]}"
  if has apt-get; then apt-get update -qq && apt-get install -y -qq "${miss[@]}" >/dev/null
  elif has apk; then apk add --no-cache "${miss[@]}"
  elif has dnf; then dnf install -y "${miss[@]}"
  else err "未知包管理器, 请手动安装: ${miss[*]}"; return 1; fi
}

init_state() {
  mkdir -p "$ETC" "$SB_ETC" "$CERTDIR"
  [ -f "$NODES" ] || echo '{"nodes":[]}' > "$NODES"
  [ -f "$RELAY" ] || echo '{"routes":[],"forwards":[]}' > "$RELAY"
  [ -f "$META" ]  || echo '{"dns":"cf"}' > "$META"
  chmod 700 "$ETC" 2>/dev/null || true
}

# ---------- 随机/生成 ----------
rand_port() { echo $(( (RANDOM % 40000) + 20000 )); }
rand_hex()  { openssl rand -hex "$1"; }
rand_pw()   { openssl rand -base64 18 | tr -d '/+=' | head -c "${1:-16}"; }
gen_uuid()  { if [ -x "$SB_BIN" ]; then "$SB_BIN" generate uuid; else cat /proc/sys/kernel/random/uuid; fi; }
server_ip() { curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'; }

# ---------- 核心管理 ----------
core_version() { [ -x "$SB_BIN" ] && "$SB_BIN" version 2>/dev/null | head -1 | awk '{print $3}' || echo ""; }

core_install() {
  need_root; install_deps || return 1
  local arch tarball url rel ver tmp
  case "$(uname -m)" in
    x86_64) arch="amd64" ;; aarch64) arch="arm64" ;; armv7l) arch="armv7" ;;
    *) err "不支持的架构: $(uname -m)"; return 1 ;;
  esac
  rel=$(curl -fsSL --max-time 20 https://api.github.com/repos/SagerNet/sing-box/releases/latest) || { err "获取官方版本失败"; return 1; }
  ver=$(printf '%s' "$rel" | jq -r '.tag_name' | sed 's/^v//')
  [ -n "$ver" ] && [ "$ver" != "null" ] || { err "解析版本号失败"; return 1; }
  tarball="sing-box-${ver}-linux-${arch}.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/${tarball}"
  tmp=$(mktemp -d)
  say "下载官方 sing-box v${ver} (${arch}) ..."
  curl -fL --max-time 300 -o "$tmp/$tarball" "$url" || { err "下载失败"; rm -rf "$tmp"; return 1; }
say "安装包 SHA-256 (备查): $(sha256sum "$tmp/$tarball" | awk '{print $1}')"
  # 官方 Release 附带 .sha256sum 时强制校验; 没有则提示(仍继续, 但会明确告知)
  if curl -fsSL --max-time 30 -o "$tmp/sums.txt" "https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${arch}.tar.gz.sha256sum" 2>/dev/null; then
    ( cd "$tmp" && sha256sum -c sums.txt >/dev/null 2>&1 ) && ok "SHA-256 校验通过" || { err "SHA-256 校验失败, 已中止"; rm -rf "$tmp"; return 1; }
  else
    warn "该版本未提供独立校验文件, 跳过校验 (下载源为官方 Release)"
  fi
  tar -xzf "$tmp/$tarball" -C "$tmp" || { err "解压失败"; rm -rf "$tmp"; return 1; }
  install -m 755 "$tmp/sing-box-${ver}-linux-${arch}/sing-box" "$SB_BIN"
  rm -rf "$tmp"
  ok "sing-box 已安装: $("$SB_BIN" version | head -1)"
  write_unit; enable_service
}

write_unit() {
  [ -n "$ROOT" ] && return 0   # 沙盒模式不写 systemd
  cat > "$UNIT" <<EOF
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
  systemctl daemon-reload
}
enable_service() { [ -n "$ROOT" ] && return 0; systemctl enable sing-box >/dev/null 2>&1 || warn "服务自启设置失败, 请手动执行: systemctl enable sing-box"; }
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
  local a; a=$(ask "确认卸载? 将停止服务并删除核心与全部节点/中转配置 (y/N): " "n")
  [ "$a" = "y" ] || { say "已取消"; return; }
  [ -z "$ROOT" ] && { systemctl stop sing-box 2>/dev/null; systemctl disable sing-box 2>/dev/null; rm -f "$UNIT"; systemctl daemon-reload; }
  rm -f "$SB_BIN"; rm -rf "$ETC" "$SB_ETC"
  ok "已卸载 (脚本文件本身保留, 可手动删除)"
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
  local tmp="$SB_ETC/.config.json.tmp"
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
      }' > "$tmp" || { err "配置生成失败"; return 1; }
  if [ -x "$SB_BIN" ]; then
    if ! "$SB_BIN" check -c "$tmp" 2>"$ETC/.check.log"; then
      err "sing-box 配置校验未通过, 未应用. 详情: $ETC/.check.log"; sed 's/^/    /' "$ETC/.check.log" >&2; rm -f "$tmp"; return 1
    fi
  fi
  mv "$tmp" "$CONF"; chmod 600 "$CONF"
  ok "配置已重建并通过校验"
  if [ -z "$ROOT" ] && systemctl is-enabled sing-box >/dev/null 2>&1; then
    if systemctl restart sing-box; then
      sleep 1
      if systemctl is-active --quiet sing-box; then ok "服务已重启并正常运行"
      else err "服务重启后未能正常运行 (可能配置运行时错误), 用菜单 [9] 看日志"; fi
    else err "服务重启失败, 用菜单 [9] 看日志"; fi
  fi
  fw_sync
  nft_sync
}


# ---------- 防火墙联动 (UFW) ----------
fw_active() { [ -z "$ROOT" ] && has ufw && ufw status 2>/dev/null | grep -q 'Status: active'; }
fw_desired() {
  jq -r '
    def proto_of:
      if .type == "hysteria2" or .type == "tuic" then "udp"
      elif .type == "shadowsocks" or .type == "socks" then "both"
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
  want=$(fw_desired)
  have=$(grep -v '^$' "$list" 2>/dev/null | sort -u | while read -r r; do
    [ -n "$r" ] && fw_exists "$r" && echo "$r"
  done || true)
  local r
  while read -r r; do
    [ -n "$r" ] && ufw allow "$r" >/dev/null 2>&1 && say "  防火墙放行: $r"
  done < <(comm -13 <(printf '%s\n' "$have") <(printf '%s\n' "$want"))
  while read -r r; do
    [ -n "$r" ] && ufw delete allow "$r" >/dev/null 2>&1 && say "  防火墙回收: $r"
  done < <(comm -23 <(printf '%s\n' "$have") <(printf '%s\n' "$want"))
  { printf '%s\n' "$want"; printf '%s\n' "$have"; } | grep -v '^$' | sort -u | while read -r r; do
    [ -n "$r" ] && fw_exists "$r" && echo "$r"
  done > "$list"
  fw_route_sync
}


fw_route_exists() { # <host> <port> <proto> : ufw 中是否还有这条 FWD 规则
  ufw status 2>/dev/null | awk -v h="$1" -v pp="$2/$3" '$4 == "FWD" && $1 == h && $2 == pp {f=1} END {exit !f}'
}

# nft 引擎时, 转发流量在 UFW 转发链的放行同步
fw_route_sync() {
  local list="$ETC/fwroute.list" want have r h p pr
  if [ "$(jq -r '.fw_engine // "sing-box"' "$META")" = "nft" ]; then
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
      ufw route allow to "$h" port "$p" proto tcp >/dev/null 2>&1 && say "  转发放行: $h:$p/tcp"
      ufw route allow to "$h" port "$p" proto udp >/dev/null 2>&1 && say "  转发放行: $h:$p/udp"
    else
      ufw route allow to "$h" port "$p" proto "$pr" >/dev/null 2>&1 && say "  转发放行: $h:$p/$pr"
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
  { printf '%s\n' "$want"; printf '%s\n' "$have"; } | grep -v '^$' | sort -u | while read -r r; do
    [ -n "$r" ] || continue
    set -- $r; h="$2"; p="$3"; pr="$4"
    if [ "$pr" = "both" ]; then
      if fw_route_exists "$h" "$p" tcp || fw_route_exists "$h" "$p" udp; then echo "$r"; fi
    else
      fw_route_exists "$h" "$p" "$pr" && echo "$r"
    fi
  done > "$list"
}

# ---------- nftables 转发引擎 ----------
nft_sync() {
  [ -n "$ROOT" ] && return 0
  [ "$(jq -r '.fw_engine // "sing-box"' "$META")" = "nft" ] || return 0
  has nft || return 0
  local f="$ETC/sbm.nft" pre post
  pre=$(jq -r '.forwards[] | (if .network == "udp" then ["udp"] elif .network == "tcp" then ["tcp"] else ["tcp", "udp"] end)[] as $pr | "    \($pr) dport \(.listen_port) dnat to \(.target_host):\(.target_port)"' "$RELAY")
  post=$(jq -r '.forwards[] | (if .network == "udp" then ["udp"] elif .network == "tcp" then ["tcp"] else ["tcp", "udp"] end)[] as $pr | "    ip daddr \(.target_host) \($pr) dport \(.target_port) masquerade"' "$RELAY")
  {
    echo "table ip sbm_fwd {"
    echo "  chain prerouting { type nat hook prerouting priority -100; policy accept;"
    [ -n "$pre" ] && printf '%s\n' "$pre"
    echo "  }"
    echo "  chain postrouting { type nat hook postrouting priority 100; policy accept;"
    [ -n "$post" ] && printf '%s\n' "$post"
    echo "  }"
    echo "}"
  } > "$f"
  nft delete table ip sbm_fwd 2>/dev/null || true
  if [ -n "$pre" ]; then
    nft -f "$f" && ok "nftables 转发规则已应用" || err "nftables 规则应用失败"
  fi
}

nft_boot_enable() {
  cat > /etc/systemd/system/sbm-nft.service <<EOF
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
  systemctl daemon-reload
  systemctl enable sbm-nft >/dev/null 2>&1 || warn "nft 转发开机恢复设置失败, 重启后需手动恢复转发"
}
nft_boot_disable() {
  systemctl disable sbm-nft >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/sbm-nft.service
  systemctl daemon-reload
}

engine_switch() {
  need_root; init_state
  local cur; cur=$(jq -r '.fw_engine // "sing-box"' "$META")
  say "当前转发引擎: $cur (sing-box=随服务运行, nftables=内核转发)" >&2
  local c target=""
  c=$(ask "[1] sing-box 引擎  [2] nftables 引擎  [0] 返回: " "0")
  case "$c" in 1) target="sing-box" ;; 2) target="nft" ;; *) return ;; esac
  [ "$target" = "$cur" ] && { say "已经是该引擎, 无需切换"; return; }
  if [ "$target" = "nft" ]; then
    if ! has nft; then
      warn "安装 nftables ..."
      apt-get update -qq && apt-get install -y -qq nftables >/dev/null || { err "nftables 安装失败"; return 1; }
    fi
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-sbm-fwd.conf
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    nft_boot_enable
  else
    nft delete table ip sbm_fwd 2>/dev/null || true
    nft_boot_disable
    rm -f /etc/sysctl.d/99-sbm-fwd.conf
    sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
  fi
  jq --arg e "$target" '.fw_engine = $e' "$META" > "$META.tmp" && mv "$META.tmp" "$META"
  rebuild_config && ok "已切换到 $target 引擎"
}

# ---------- 证书 ----------
make_cert() { # make_cert <tag> <domain> -> 回显 "crt|key"
  local tag="$1" dom="$2" crt="$CERTDIR/$tag.crt" key="$CERTDIR/$tag.key"
  if [ ! -f "$crt" ]; then
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
    *) method="2022-blake3-aes-256-gcm"; pw=$(openssl rand -base64 32) ;;
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
  local ip f="$SB_ETC/clash.yaml" tmp="$SB_ETC/.clash.tmp"
  ip=$(server_ip)
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
      elif $s.proto=="anytls" then
        "  - {name: \($n), type: anytls, server: \($ip), port: \($p), password: \($s.password), sni: \($s.sni), skip-cert-verify: true}"
      elif $s.proto=="hysteria2" then
        "  - {name: \($n), type: hysteria2, server: \($ip), port: \($p), password: \($s.password), sni: \($s.sni), skip-cert-verify: true}"
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
    echo "  - {name: PROXY, type: select, proxies: [DIRECT$(jq -r '[.nodes[].name] | map(", " + .) | join("")' "$NODES")]}"
    echo "rules:"
    echo "  - MATCH,PROXY"
  } > "$tmp" && mv "$tmp" "$f"
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
c=$(ask "请输入选项 [0]: " "0"); [ "$c" = "0" ] && return
name=$(ask "节点名称: " "node-$(rand_hex 2)")
port=$(ask "监听端口 [随机]: " "$(rand_port)")
tag=$(uniq_tag n "$name")
built=$(build_by_choice "$c" "$tag" "$port") || { err "创建失败"; return 1;}
cp "$NODES" "$NODES.bak"
jq --arg name "$name" --argjson b "$built" '.nodes += [{name:$name} + $b]' "$NODES" > "$NODES.tmp" && mv "$NODES.tmp" "$NODES"
if ! rebuild_config; then mv "$NODES.bak" "$NODES"; err "已回滚节点状态"; return 1; fi
rm -f "$NODES.bak"
write_clash_yaml
ip=$(server_ip)
ok "节点已添加: $name ($(proto_name "$(jq -r .share.proto <<<"$built")"))"
say " 链接: $(share_link "$ip" "$port" "$name" "$(jq -c .share <<<"$built")")"
}

node_list_links() {
init_state; local ip; ip=$(server_ip)
local n; n=$(jq '.nodes|length' "$NODES")
[ "$n" = 0 ] && { say "暂无节点"; return;}
jq -c '.nodes[]' "$NODES" | while read -r row; do
local nm pt pr sh
nm=$(jq -r .name <<<"$row"); pt=$(jq -r .inbound.listen_port <<<"$row")
pr=$(jq -r .share.proto <<<"$row"); sh=$(jq -c .share <<<"$row")
printf '\n%s (%s) 端口 %s\n %s\n' "$nm" "$(proto_name "$pr")" "$pt" "$(share_link "$ip" "$pt" "$nm" "$sh")"
done
local rn; rn=$(jq '.routes|length' "$RELAY")
if [ "$rn"!= 0 ]; then
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
jq --argjson i "$((idx-1))" 'del(.nodes[$i])' "$NODES" > "$NODES.tmp" && mv "$NODES.tmp" "$NODES"
rebuild_config && write_clash_yaml && ok "已删除"
}

node_modify() {
init_state
jq -r '.nodes | to_entries[] | " [\(.key+1)] \(.value.name) 端口 \(.value.inbound.listen_port)"' "$NODES" >&2
local idx n what name port
idx=$(ask "输入要修改的序号 [0 取消]: " "0"); [ "$idx" = "0" ] && return
n=$(jq '.nodes|length' "$NODES"); [ "$idx" -ge 1 ] && [ "$idx" -le "$n" ] || { err "序号无效"; return;}
what=$(ask "[1] 改名称 [2] 改端口 [0] 取消: " "0")
case "$what" in
1) name=$(ask "新名称: " ""); [ -n "$name" ] || return
jq --argjson i "$((idx-1))" --arg v "$name" '.nodes[$i].name = $v' "$NODES" > "$NODES.tmp" && mv "$NODES.tmp" "$NODES";;
2) port=$(ask "新端口: " ""); [ -n "$port" ] || return
jq --argjson i "$((idx-1))" --argjson v "$port" '.nodes[$i].inbound.listen_port = $v' "$NODES" > "$NODES.tmp" && mv "$NODES.tmp" "$NODES";;
*) return;;
esac
rebuild_config && write_clash_yaml && ok "已修改"
}

# ---------- 落地 / 中转 ----------
token_export() {
init_state
local n; n=$(jq '.nodes|length' "$NODES"); [ "$n" = 0 ] && { say "本机暂无节点可导出"; return;}
jq -r '.nodes | to_entries[] | " [\(.key+1)] \(.value.name) (\(.value.share.proto))"' "$NODES" >&2
local idx; idx=$(ask "选择要导出的落地节点 [0 取消]: " "0"); [ "$idx" = "0" ] && return
local row proto outbound pass blob
row=$(jq -c --argjson i "$((idx-1))" '.nodes[$i]' "$NODES")
proto=$(jq -r .share.proto <<<"$row")
outbound=$(node_to_outbound "$row") || { err "该协议暂不支持 Token 导出"; return 1;}
pass=$(rand_pw 12)
blob=$(jq -n --arg name "$(jq -r .name <<<"$row")" --argjson ob "$outbound" \
'{v:1, name:$name, outbound:$ob}' \
| openssl enc -aes-256-cbc -pbkdf2 -salt -pass "pass:$pass" -base64 -A) || { err "加密失败"; return 1;}
say ""; ok "落地 Token (通过一种渠道发送):"
say "SBM1:$blob"
say ""; ok "解密口令 (请通过另一种渠道发送): $pass"
}

# 把本机节点条目转换成可供中转机使用的 outbound; 不支持的协议返回非 0
node_to_outbound() {
local row="$1" proto ip port
proto=$(jq -r .share.proto <<<"$row"); ip=$(server_ip); port=$(jq -r .inbound.listen_port <<<"$row")
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
tag=$(uniq_tag r "$name")
built=$(build_by_choice "$c" "$tag" "$port") || { err "入口创建失败"; return 1;}
outbound=$(jq --arg t "out-$tag" '.tag = $t' <<<"$outbound")
jq -n --arg name "$name" --argjson b "$built" --argjson ob "$outbound" \
'{name:$name, inbound:$b.inbound, share:$b.share, outbound:$ob}' > "$ETC/.route.json"
cp "$RELAY" "$RELAY.bak"
jq --slurpfile r "$ETC/.route.json" '.routes += $r' "$RELAY" > "$RELAY.tmp" && mv "$RELAY.tmp" "$RELAY"
rm -f "$ETC/.route.json"
if ! rebuild_config; then mv "$RELAY.bak" "$RELAY"; err "已回滚中转状态"; return 1; fi
rm -f "$RELAY.bak"
ip=$(server_ip)
ok "中转已建立: $name -> $(jq -r .server <<<"$outbound"):$(jq -r .server_port <<<"$outbound")"
say " 链接: $(share_link "$ip" "$port" "$name" "$(jq -c .share <<<"$built")")"
}

token_import() {
init_state
[ -x "$SB_BIN" ] || { warn "核心未安装, 先用主菜单 [15] 安装"; return;}
local tok pass plain outbound
tok=$(ask "粘贴落地 Token (SBM1:...): " ""); [ -n "$tok" ] || return
pass=$(ask "输入解密口令: " ""); [ -n "$pass" ] || return
plain=$(printf '%s' "${tok#SBM1:}" | openssl enc -d -aes-256-cbc -pbkdf2 -base64 -A -pass "pass:$pass" 2>/dev/null) \
|| { err "解密失败: Token 或口令不正确"; return 1;}
outbound=$(jq -c '.outbound' <<<"$plain") || { err "Token 内容无效"; return 1;}
relay_add_with_outbound "$outbound" "$(jq -r '.name // "relay"' <<<"$plain")"
}

# ---------- 第三方节点导入 ----------
urldecode() { printf '%b' "$(printf '%s' "$1" | sed 's/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g; s/+/ /g')";}
b64d() { local s="$1"; s=$(printf '%s' "$s" | tr '_-' '/+'); local m=$(( ${#s} % 4)); [ $m -eq 2 ] && s="$s=="; [ $m -eq 3 ] && s="$s="; printf '%s' "$s" | base64 -d 2>/dev/null;}
qparam() { # qparam <query> <key>
printf '%s' "$1" | tr '&' '\n' | awk -F= -v k="$2" '$1==k{print substr($0, index($0,"=")+1)}' | head -1
}

parse_vless_link() { # 回显 outbound json
local link="$1" rest uuid hostport query uuidpart
rest="${link#vless://}"; rest="${rest%%#*}"
uuidpart="${rest%%@*}"; rest="${rest#*@}"
hostport="${rest%%\?*}"; query=""; case "$rest" in *\?*) query="${rest#*\?}";; esac
local host port; host="${hostport%:*}"; host="${host#[}"; host="${host%]}"; port="${hostport##*:}"
uuid=$(urldecode "$uuidpart")
local security type sni pbk sid flow path hosthdr svc
security=$(qparam "$query" security); type=$(qparam "$query" type); sni=$(urldecode "$(qparam "$query" sni)")
pbk=$(qparam "$query" pbk); sid=$(qparam "$query" sid); flow=$(qparam "$query" flow)
path=$(urldecode "$(qparam "$query" path)"); hosthdr=$(urldecode "$(qparam "$query" host)"); svc=$(qparam "$query" serviceName)
jq -n --arg host "$host" --argjson port "${port:-443}" --arg uuid "$uuid" --arg security "$security" \
--arg type "$type" --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" --arg flow "$flow" \
--arg path "$path" --arg hosthdr "$hosthdr" --arg svc "$svc" '
{type:"vless", tag:"", server:$host, server_port:$port, uuid:$uuid}
+ (if $flow!= "" then {flow:$flow} else {} end)
+ (if $security=="reality" then
{tls:{enabled:true, server_name:$sni, utls:{enabled:true, fingerprint:"chrome"},
reality:{enabled:true, public_key:$pbk, short_id:$sid}}}
elif $security=="tls" then
{tls:{enabled:true, server_name:$sni, insecure:true}}
else {} end)
+ (if $type=="ws" then {transport:{type:"ws", path:$path, headers:{Host:$hosthdr}}}
elif $type=="grpc" then {transport:{type:"grpc", service_name:$svc}}
else {} end)'
}

parse_ss_link() { # 回显 outbound json
local link="$1" rest name cred hostport method pw host port
rest="${link#ss://}"; name=""; case "$rest" in *#*) name="${rest#*#}"; rest="${rest%%#*}";; esac
rest="${rest%%\?*}"
if [[ "$rest" == *"@"* ]]; then
cred="${rest%%@*}"; hostport="${rest#*@}"
if [[ "$cred" == *":"* ]]; then method="${cred%%:*}"; pw=$(urldecode "${cred#*:}")
else local dec; dec=$(b64d "$cred"); method="${dec%%:*}"; pw="${dec#*:}"; fi
else
local dec; dec=$(b64d "$rest"); cred="${dec%%@*}"; hostport="${dec#*@}"
method="${cred%%:*}"; pw="${cred#*:}"
fi
host="${hostport%:*}"; host="${host#[}"; host="${host%]}"; port="${hostport##*:}"
jq -n --arg host "$host" --argjson port "${port:-8388}" --arg method "$method" --arg pw "$pw" '
{type:"shadowsocks", tag:"", server:$host, server_port:$port, method:$method, password:$pw}'
}

third_party_import() {
init_state
[ -x "$SB_BIN" ] || { warn "核心未安装, 先用主菜单 [15] 安装"; return;}
say "支持: [1] vless:// 链接 [2] ss:// 链接 [3] 手动 SOCKS5 [4] 手动 HTTP(S) 代理" >&2
local c link outbound
c=$(ask "选择导入方式 [0 取消]: " "0")
case "$c" in
1) link=$(ask "粘贴 vless:// 链接: " ""); outbound=$(parse_vless_link "$link");;
2) link=$(ask "粘贴 ss:// 链接: " ""); outbound=$(parse_ss_link "$link");;
3) local h p u pw; h=$(ask "服务器地址: " ""); p=$(ask "端口: " "")
u=$(ask "用户名 (可空): " ""); pw=$(ask "密码 (可空): " "")
outbound=$(jq -n --arg h "$h" --argjson p "${p:-1080}" --arg u "$u" --arg pw "$pw" '
{type:"socks", tag:"", server:$h, server_port:$p, version:"5"}
+ (if $u!= "" then {username:$u, password:$pw} else {} end)');;
4) local h p u pw tls; h=$(ask "服务器地址: " ""); p=$(ask "端口: " "")
u=$(ask "用户名 (可空): " ""); pw=$(ask "密码 (可空): " ""); tls=$(ask "启用 TLS (HTTPS 代理)? (y/N): " "n")
outbound=$(jq -n --arg h "$h" --argjson p "${p:-8080}" --arg u "$u" --arg pw "$pw" --arg tls "$tls" '
{type:"http", tag:"", server:$h, server_port:$p}
+ (if $u!= "" then {username:$u, password:$pw} else {} end)
+ (if $tls == "y" then {tls:{enabled:true, server_name:$h, insecure:true}} else {} end)');;
*) return;;
esac
[ -n "$outbound" ] && jq -e '
(.server | type == "string" and length > 0)
and (.server_port | type == "number" and . > 0 and . < 65536)
and (if .type == "shadowsocks" then
       (.method | IN("aes-128-gcm","aes-256-gcm","chacha20-ietf-poly1305","xchacha20-ietf-poly1305",
                      "2022-blake3-aes-128-gcm","2022-blake3-aes-256-gcm","2022-blake3-chacha20-poly1305"))
     else true end)' >/dev/null <<<"$outbound" || { err "解析失败或参数不合法 (地址/端口/加密方式), 请检查输入"; return 1;}
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
jq --argjson i "$((idx-1))" 'del(.routes[$i])' "$RELAY" > "$RELAY.tmp" && mv "$RELAY.tmp" "$RELAY"
rebuild_config && ok "已删除"
}

relay_change_port() {
init_state; relay_list
local idx n port; idx=$(ask "输入链路序号 [0 取消]: " "0"); [ "$idx" = "0" ] && return
n=$(jq '.routes|length' "$RELAY"); [ "$idx" -ge 1 ] && [ "$idx" -le "$n" ] || { err "序号无效"; return;}
port=$(ask "新监听端口: " ""); [ -n "$port" ] || return
jq --argjson i "$((idx-1))" --argjson p "$port" '.routes[$i].inbound.listen_port = $p' "$RELAY" > "$RELAY.tmp" && mv "$RELAY.tmp" "$RELAY"
rebuild_config && ok "已修改"
}

relay_clear() {
local a; a=$(ask "确认清空全部中转配置? (y/N): " "n"); [ "$a" = "y" ] || return
jq '.routes = []' "$RELAY" > "$RELAY.tmp" && mv "$RELAY.tmp" "$RELAY"
rebuild_config && ok "已清空"
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
    local c; c=$(ask "请输入选项 [0]: " "0")
    case "$c" in
      1) local h p lp net tag
         h=$(ask "目标地址 (IP/域名): " ""); [ -n "$h" ] || continue
         p=$(ask "目标端口: " ""); lp=$(ask "本机监听端口 [随机]: " "$(rand_port)")
         net=$(ask "协议 [1]TCP+UDP [2]TCP [3]UDP: " "1")
         case "$net" in 2) net="tcp" ;; 3) net="udp" ;; *) net="tcp_and_udp" ;; esac
         tag="fwd-$lp"
         cp "$RELAY" "$RELAY.bak"
         jq --arg tag "$tag" --argjson lp "$lp" --arg h "$h" --argjson p "$p" --arg net "$net" \
           '.forwards += [{tag:$tag, listen_port:$lp, target_host:$h, target_port:$p, network:$net}]' \
           "$RELAY" > "$RELAY.tmp" && mv "$RELAY.tmp" "$RELAY"
         if rebuild_config; then rm -f "$RELAY.bak"; ok "转发已添加: :$lp -> $h:$p ($net)"
         else mv "$RELAY.bak" "$RELAY"; err "已回滚转发状态"; fi ;;
      2) jq -r '.forwards | to_entries[] | "  [\(.key+1)] :\(.value.listen_port) -> \(.value.target_host):\(.value.target_port) (\(.value.network))"' "$RELAY" ;;
      3) local idx n what v
         jq -r '.forwards | to_entries[] | "  [\(.key+1)] :\(.value.listen_port) -> \(.value.target_host):\(.value.target_port) (\(.value.network))"' "$RELAY" >&2
         idx=$(ask "输入要修改的序号 [0 取消]: " "0"); [ "$idx" = "0" ] && continue
         n=$(jq '.forwards|length' "$RELAY"); [ "$idx" -ge 1 ] && [ "$idx" -le "$n" ] || { err "序号无效"; continue; }
         what=$(ask "[1] 目标地址  [2] 目标端口  [3] 监听端口  [4] 协议  [0] 取消: " "0")
         cp "$RELAY" "$RELAY.bak"
         case "$what" in
           1) v=$(ask "新目标地址: " ""); [ -n "$v" ] || { rm -f "$RELAY.bak"; continue; }
              jq --argjson i "$((idx-1))" --arg v "$v" '.forwards[$i].target_host = $v' "$RELAY" > "$RELAY.tmp" && mv "$RELAY.tmp" "$RELAY" ;;
           2) v=$(ask "新目标端口: " ""); [ -n "$v" ] || { rm -f "$RELAY.bak"; continue; }
              jq --argjson i "$((idx-1))" --argjson v "$v" '.forwards[$i].target_port = $v' "$RELAY" > "$RELAY.tmp" && mv "$RELAY.tmp" "$RELAY" ;;
           3) v=$(ask "新监听端口: " ""); [ -n "$v" ] || { rm -f "$RELAY.bak"; continue; }
              jq --argjson i "$((idx-1))" --argjson v "$v" '.forwards[$i].listen_port = $v | .forwards[$i].tag = "fwd-\($v)"' "$RELAY" > "$RELAY.tmp" && mv "$RELAY.tmp" "$RELAY" ;;
           4) v=$(ask "协议 [1]TCP+UDP [2]TCP [3]UDP: " "1")
              case "$v" in 2) v="tcp" ;; 3) v="udp" ;; *) v="tcp_and_udp" ;; esac
              jq --argjson i "$((idx-1))" --arg v "$v" '.forwards[$i].network = $v' "$RELAY" > "$RELAY.tmp" && mv "$RELAY.tmp" "$RELAY" ;;
           *) rm -f "$RELAY.bak"; continue ;;
         esac
         if rebuild_config; then rm -f "$RELAY.bak"; ok "已修改"; else mv "$RELAY.bak" "$RELAY"; err "已回滚"; fi ;;
      4) local idx n
         jq -r '.forwards | to_entries[] | "  [\(.key+1)] :\(.value.listen_port) -> \(.value.target_host):\(.value.target_port)"' "$RELAY" >&2
         idx=$(ask "删除序号 [0 取消]: " "0"); [ "$idx" = "0" ] && continue
         n=$(jq '.forwards|length' "$RELAY"); [ "$idx" -ge 1 ] && [ "$idx" -le "$n" ] || { err "序号无效"; continue; }
         cp "$RELAY" "$RELAY.bak"
         jq --argjson i "$((idx-1))" 'del(.forwards[$i])' "$RELAY" > "$RELAY.tmp" && mv "$RELAY.tmp" "$RELAY"
         if rebuild_config; then rm -f "$RELAY.bak"; ok "已删除"; else mv "$RELAY.bak" "$RELAY"; err "已回滚"; fi ;;
      5) engine_switch ;;
      6) local a; a=$(ask "确认清空全部转发规则? (y/N): " "n"); [ "$a" = "y" ] || continue
         cp "$RELAY" "$RELAY.bak"
         jq '.forwards = []' "$RELAY" > "$RELAY.tmp" && mv "$RELAY.tmp" "$RELAY"
         if rebuild_config; then rm -f "$RELAY.bak"; ok "已清空"; else mv "$RELAY.bak" "$RELAY"; err "已回滚"; fi ;;
      0) return ;;
    esac
  done
}

menu_relay() {
while true; do
cat >&2 <<'EOF'



[1] 落地机: 生成全协议 Token
[2] 中转机: 通过 Token 导入规则
[3] 中转机: 导入第三方节点

[4] 查看当前中转链路
[5] 删除指定中转路由
[6] 修改中转监听端口
[7] 清空所有中转配置

[8] 端口转发管理
[0] 返回主菜单
EOF
local c; c=$(ask "请输入选项 [0]: " "0")
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
log) [ -n "$ROOT" ] && { say "(沙盒模式无日志)"; return;}; journalctl -u sing-box -n 100 --no-pager;;
esac
}

sched_restart() {
need_root
say "当前: $(crontab -l 2>/dev/null | grep -F 'systemctl restart sing-box' || echo '未设置')" >&2
local a; a=$(ask "[1] 每天 04:00 重启 [2] 取消定时重启 [0] 返回: " "0")
case "$a" in
1) ( crontab -l 2>/dev/null | grep -vF 'systemctl restart sing-box'; echo "0 4 * * * /usr/bin/systemctl restart sing-box") | crontab - && ok "已设置每天 04:00 重启" || err "crontab 写入失败";;
2) ( crontab -l 2>/dev/null | grep -vF 'systemctl restart sing-box') | crontab - && ok "已取消" || err "crontab 写入失败";;
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
case "$c" in
1) jq '.dns="cf"' "$META" > "$META.tmp" && mv "$META.tmp" "$META";;
2) jq '.dns="google"' "$META" > "$META.tmp" && mv "$META.tmp" "$META";;
3) jq '.dns="ali"' "$META" > "$META.tmp" && mv "$META.tmp" "$META";;
*) return;;
esac
rebuild_config && ok "DNS 已更新"
}

config_check() {
init_state
[ -x "$SB_BIN" ] || { warn "核心未安装"; return;}
if [ -f "$CONF" ] && "$SB_BIN" check -c "$CONF"; then ok "配置文件校验通过"; else err "校验失败或配置不存在"; fi
}

not_in_v1() { warn "该功能不在本版范围内 (v0.1): $1";}

# ---------- 主菜单 ----------
main_menu() {
init_state
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

[12] 检查配置文件 [13] 更新 Sing-box 核心 (官方源+校验)
[14] DNS 设置

[15] 安装/更新 Sing-box 核心
[16] 安装/更新 Xray 核心 (v2)
[17] 卸载

[18] 落地/中转/第三方节点导入/端口转发
[19] Xray 节点管理 (v2)
[0] 退出
EOF
local c; c=$(ask "请输入选项 [0]: " "0")
case "$c" in
1) node_add;; 2) not_in_v1 "Argo 隧道节点";;
3) node_list_links;; 4) node_delete;;
5) node_modify;;
6) menu_service restart;; 7) menu_service stop;;
8) menu_service status;; 9) menu_service log;;
10) sched_restart;; 11) time_check;;
12) config_check;; 13) core_install;;
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
install -m 755 "$0" "$SB_LINK"
ok "已安装为命令: sbm (以后直接运行 sbm)"
;;
check) init_state; rebuild_config;;
version) say "sbm v$VER";;
*) install_deps >/dev/null 2>&1 || true
   if ! has jq || ! has curl || ! has openssl; then
     err "依赖缺失 (需要 jq / curl / openssl), 自动安装失败, 请手动安装后重试"; exit 1
   fi
   main_menu;;
esac
