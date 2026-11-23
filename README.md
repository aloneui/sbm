# sbm — sing-box 节点/中转管理脚本

由 Muse 为 Jessica 从零编写（不含任何第三方脚本代码），功能清单按她给的菜单规格实现。
版本 v0.4.3，单文件 bash，依赖：jq、curl、openssl（脚本会自动用 apt 安装）。

## 设计原则
1. 核心只从 sing-box 官方 GitHub Release 下载；官方未提供校验文件时明确提示，并打印安装包 SHA-256 备查
2. **脚本永不自更新、无回传**；除发行版包管理器与官方 Release 外不访问其他地址
3. UFW 联动: 配置重建后自动同步防火墙 (放行新节点端口/回收已删端口, sbm 管理的规则记在 /etc/sbm/fw.list)
4. 状态保存在 `/etc/sbm/nodes.json`、`relay.json`、`meta.json`；sing-box 配置由状态全量重建，
   每次重建先过 `sing-box check`，校验失败自动回滚状态、保留旧配置

## 使用
```bash
bash sbm.sh              # 交互菜单
bash sbm.sh --install-self   # 安装为系统命令 sbm
bash sbm.sh check        # 由状态重建配置并校验
```

## 已实现（均通过 sing-box 1.14.4 实机实测）
- 核心：安装/更新（官方源）、卸载、systemd 服务托管
- 节点：添加/链接查看/删除/改名改端口；10 种协议
  VLESS+Reality+Vision、VLESS+WS+TLS、Trojan+WS+TLS、VLESS+gRPC+TLS、AnyTLS、
  Hysteria2（含 Salamander 混淆）、TUIC v5、Shadowsocks（含 2022）、VLESS+TCP、SOCKS5、
  Snell v5/v6（sing-box 实现无 obfs；出站仅 v6，故 v5 节点不支持 Token 导出；分享为 Surge 配置行）
- Shadowsocks 全量菜单：经典 4 种（aes-128-gcm / aes-256-gcm / chacha20-ietf-poly1305 /
  xchacha20-ietf-poly1305）+ SS-2022 三种（blake3-aes-128-gcm / blake3-aes-256-gcm /
  blake3-chacha20-poly1305）+ SS-2022+ShadowTLS v3 组合（公开 ShadowTLS 入站 detour
  回环 SS 入站，防火墙只放行公开端口；分享为 SIP002 plugin 链接）。
  注：“2022 带 Padding”在 sing-box 中无此字段，不提供
- 分享：各协议链接 + Clash/Mihomo YAML（/etc/sing-box/clash.yaml）
- 中转：落地 Token（AES-256-CBC + PBKDF2 加密，口令单独发送）导出/导入；
  第三方 vless://、ss:// 链接导入（带地址/端口/加密方式白名单校验）；手动 SOCKS5/HTTP 落地；
  链路查看/删除/改端口/清空
- 端口转发双引擎：sing-box 引擎（direct 入站）/ nftables 引擎（内核 DNAT+masquerade，
  自动 ip_forward、UFW route 放行、开机自启恢复）；子菜单：添加/查看/修改/删除/切换引擎/清空，
  切换引擎自动迁移现有规则
- 服务：重启/停止/状态/日志、定时重启（cron）、时间诊断/校时、配置检查、DNS 切换（CF/Google/阿里）

## v2 计划（菜单中已标注）
Argo 隧道节点、Xray 核心与节点管理、批量创建节点

## 测试记录（2026-11-23，沙盒 SBM_ROOT + 官方 sing-box 1.14.4）
11 种协议全部在真实机器 (cloudleadinno4) 逐个添加并从外部客户端连通验证, 出口 IP 正确 (Snell v5 无 sing-box 客户端, 仅验证入站监听); UFW 自动放行/回收双向验证通过；Token 跨沙盒导入导出闭环通过；
第三方链接导入、垃圾链接拒绝、端口转发、校验失败回滚均验证通过。
v0.4.0 追加实测：ShadowTLS 组合节点客户端连通（出口 IP 正确）；nft 引擎转发经
DNS-over-TCP 端到端验证；引擎双向切换迁移规则、UFW route 放行/回收均通过。

## 稳健性审计（v0.4.1–v0.4.3）
起因：nft 引擎的 UFW route 规则删除语法写错且被静默吞掉，造成追踪状态与实际漂移。
已全面排查同类"静默失败"点并修复：两套防火墙同步（端口规则/route 规则）改为
每次同步先按 `ufw status` 真实状态过滤追踪表、同步后双向核验写回，漂移一轮自愈
（已在实机人为删规则/塞幽灵条目验证）；防火墙同步不再受服务启用状态门控；
依赖安装失败在启动时明确报错退出；服务自启、nft 开机恢复、crontab 写入失败均改为可见告警。
