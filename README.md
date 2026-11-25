# sbm — sing-box 节点/中转管理脚本

由 Muse 从零编写（不含任何第三方脚本代码）。
版本 v0.5.0，单文件 bash；依赖 jq、curl、openssl、flock（util-linux）与 ss（iproute2），缺项时脚本会尝试通过系统包管理器安装。

## 设计原则
1. 核心只从 sing-box 官方 GitHub Release 下载；必须取得 Release API 提供的 SHA-256 摘要并匹配，否则中止安装
2. **脚本永不自更新、无回传配置数据**；除发行版包管理器与官方 Release 外，仅在生成分享链接/Clash 配置时查询一次公网 IP（api.ipify.org，不发送任何配置，本进程内缓存）
3. UFW 联动: 配置重建后自动同步防火墙 (放行新节点端口/回收已删端口, sbm 管理的规则记在 /etc/sbm/fw.list)
4. 状态保存在权限收紧的 `/etc/sbm/` 文件中；修改由状态锁串行化，配置以唯一临时文件原子替换。
   每次重建必须通过 `sing-box check`；实机路径还核验 systemd、监听端口与本机防火墙/转发规则。
   这些检查不代表云厂商防火墙、运营商路径或公网客户端连通性已验证。

## 本地安全加固补丁
- 新导出使用 `SBM2` Token（AES-256-CBC/PBKDF2 加密并附 HMAC-SHA256 完整性标签）；旧 `SBM1` 仍可导入，但会提示其未认证。
- VLESS、Shadowsocks 链接及 Token outbound 会验证地址、端口、凭据和传输参数；错误的交互输入会要求重输。
- 敏感状态及 Clash 输出使用严格权限；卸载只删除所有权清单记录的 SBM 文件，并保留其他文件。
- 沙盒测试只证明配置/逻辑路径，不会启动真实服务，也不验证公网可达性。
- CLI 菜单按用途分组、未实现的 v2 项目单独标注；空列表会给出明确提示，删除节点/路由/转发前会二次确认，非终端输出支持纯文本。
- 节点/中转成功提示只报告本机配置、服务及监听检查；外部可达性、云防火墙和运营商/IP 封锁需从公网客户端另行验证。

## v0.5.0 修复（2026-11-24，对照 singbox-lite 功能描述复审）
- 中转列表判断 `[ "$rn"!= 0 ]` 缺空格已修复
- 回滚补全：删除/改名/改端口节点、删除/改端口/清空中转、切换 DNS 失败时均回滚状态；配置通过校验但服务重启失败时自动恢复上一份配置并回滚
- Clash/Mihomo 配置补全：新增 VLESS+gRPC、VLESS+TCP、Snell 条目；Hysteria2 带 Salamander 混淆时写入 obfs 字段；proxy-group 只引用实际生成的节点，不再产生坏配置
- 新增端口冲突检查：新建/修改节点、中转、转发时校验端口合法性与占用（状态内查重 + 系统监听提醒）
- 第三方导入收紧：带 plugin 的 ss:// 链接明确拒绝（不再静默剥离）；vless:// 校验 UUID 格式、Reality 公钥/SNI、WS 路径；地址不带端口时按协议默认端口解析
- 卸载清理补全：回收 UFW 放行/转发规则、定时重启 crontab、nft 服务与规则表、sbm 命令本体
- nft 转发引擎：域名目标在每次同步时解析为 IPv4 并明确提示；IPv6 目标明确跳过并告警（请改用 sing-box 引擎）；切回 sing-box 引擎不再强制关闭 ip_forward（避免误伤 Docker 等）
- 防火墙：Snell 入站补放行 UDP；SS 加密方式菜单输错不再静默套用默认项
- 主菜单 [13] 改为“检查新版本（仅检查不安装）”，与 [15] 安装/更新不再重复；[9] 日志改为实时跟随
- 落地 Token 菜单标注 SS+ShadowTLS 不支持导出（原“全协议”说法不准确）

## 与上游 singbox-lite 仍存在的差距（诚实标注）
- Argo 隧道、Xray 双核心、批量创建：仍在 v2 计划，未实现
- 修改节点目前只有改名/改端口；上游可改认证、SNI/证书、Reality 密钥、WS/gRPC 路径、Hysteria2 混淆与带宽
- Hysteria2 无端口跳跃；节点分享地址使用生成时的当前公网 IP，IP 变更后需重新查看链接
- nft 引擎域名目标在同步时解析，无上游的每分钟自动刷新

## 开荒脚本（kaihuang/）
本仓库同时收录 VPS 开荒流程脚本，详见 `kaihuang/README.md`：
- `kaihuang/debian-post-dd.sh` — DD（默认 bin456789/reinstall 装 Debian 13 最新版）后的开荒脚本：验机→更新→时区/主机名→SSH 加固（默认端口 49173、默认公钥、直接关密码登录）+Fail2ban→UFW→Swap→基础工具→自动更新/日志瘦身
- `kaihuang/inspect.sh` — 只读巡检脚本：打印系统/资源/监听端口/服务/Docker/定时任务/登录记录，不做任何修改

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
11 种协议全部在真实机器上逐个添加并从外部客户端连通验证，出口 IP 正确（Snell v5 无 sing-box 客户端，仅验证入站监听）；UFW 自动放行/回收双向验证通过；Token 跨沙盒导入导出闭环通过；
第三方链接导入、垃圾链接拒绝、端口转发、校验失败回滚均验证通过。
v0.4.0 追加实测：ShadowTLS 组合节点客户端连通（出口 IP 正确）；nft 引擎转发经
DNS-over-TCP 端到端验证；引擎双向切换迁移规则、UFW route 放行/回收均通过。

## 稳健性审计（v0.4.1–v0.4.3）
起因：nft 引擎的 UFW route 规则删除语法写错且被静默吞掉，造成追踪状态与实际漂移。
已全面排查同类"静默失败"点并修复：两套防火墙同步（端口规则/route 规则）改为
每次同步先按 `ufw status` 真实状态过滤追踪表、同步后双向核验写回，漂移一轮自愈
（已在实机人为删规则/塞幽灵条目验证）；防火墙同步不再受服务启用状态门控；
依赖安装失败在启动时明确报错退出；服务自启、nft 开机恢复、crontab 写入失败均改为可见告警。
