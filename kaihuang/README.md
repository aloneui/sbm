# VPS 开荒流程（定版）

> 定版日期：2026-11-25。核心原则：**全程手动、逐步验证，不用任何一键开荒脚本**（旧的一键脚本 `debian-post-dd.sh` 已废弃并删除，不要再使用、不要再分发）。
> 每一步做完必须实查验证再进下一步，不能只看退出码。汇报要带数字和链接。

## 全局参数

- 目标系统：Debian 13 最新版
- SSH 端口：**49173**
- 登录方式：仅公钥，DD 时直接关闭密码登录，不等试登确认
- 公钥：**双公钥**——机主 Termius 公钥 + 执行者自己的公钥，DD 时一起写入
- 主机名：用机主给的昵称，空格用 `-` 连接；**没给昵称先问，不许自编**
- 时区：Asia/Shanghai
- 不建普通用户；不开 BBR（交给 tcpfit）

## 第 0 步：DD 重装（bin456789/reinstall）

只用官方源现拉，不用自制镜像/第三方 DD 包。

```bash
curl -O https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh
bash reinstall.sh debian 13 --username root \
  --ssh-key "<机主公钥>" --ssh-key "<执行者公钥>" \
  --ssh-port 49173
# 核对准备输出（Debian 13 / root / 端口 49173 / 双公钥）无误后手动触发：
reboot
```

- 装机约 10–12 分钟，期间 SSH 连不上是正常过程（先进入安装环境，再切新系统）。
- 精简镜像可能没有 curl：先 `apt update && apt install -y curl` 再下载。
- 从 Windows DD：用官方 `reinstall.bat`（管理员 cmd，certutil 下载官方文件），参数同上，准备完成后 `shutdown /r /t 0` 触发。
- **DD 后每台机的 SSH 主机密钥都会变**：首次连接前先清掉本地 `known_hosts` 里该 IP:端口的旧指纹，否则会被 SSH 严格校验拒连、误判为没装好。
- 商家分配的 IPv6 可能在**第二块网卡**上：配网络前先数网卡数量、逐块检查，不要默认只有一块。

## 第 1 步：手动开荒 8 步（逐步执行、逐步验证）

### 1) 验机 + 后门排查（第一位，硬指标异常立刻停下人工确认）

逐项检查并存日志：

- 系统版本、IP、硬盘、监听端口、登录记录
- **UID 0 账户**（除 root 外多一个即实锤）、**空密码账户**
- **全部用户**的 `authorized_keys`（不只 root；机主后来授权加的钥匙要认，不要误报）
- `/etc/ld.so.preload` 劫持、`LD_PRELOAD` 环境注入（profile.d、bashrc）
- sshd 配置异常（AuthorizedKeysFile 被改路径、ForceCommand 等）
- `dpkg --verify` 系统文件完整性（过滤配置文件的正常改动）
- 不属于任何软件包的自启服务、systemd 定时器
- 当前对外连接、`/tmp` 与 `/dev/shm` 里的可执行文件

### 2) 全量升级

```bash
apt update && apt full-upgrade -y && apt autoremove -y
```

### 3) 时区 / 主机名

```bash
timedatectl set-timezone Asia/Shanghai   # 并确认 NTP 同步开启
hostnamectl set-hostname <昵称>
```

### 4) SSH 加固 + Fail2ban

- authorized_keys 只留授权公钥；端口 49173
- `PasswordAuthentication no`、`PubkeyAuthentication yes`、root 仅密钥登录
- 安装并启用 fail2ban

### 5) UFW 防火墙

先放行 49173 再启用 UFW（顺序反了会把自己锁在外面）。默认只放行 SSH 端口，80/443 等建站时再开。

### 6) Swap

无 swap 时建 2G，`swappiness=10` 并持久化。

### 7) 基础工具

```bash
apt install -y tmux iperf3 curl wget git vim htop unzip tar ca-certificates gnupg jq
```

（tmux 和 iperf3 是下一步 tcpfit 的前置，必须在这步装好。）

### 8) 自动更新 + 日志上限

- 启用 unattended-upgrades（只装安全更新，不自动重启）
- journal 限额：总量 200M、保留 14 天

## 第 2 步：root 密码锁定确认

```bash
passwd -S root   # 应为 L（locked）；不是 L 就执行 passwd -l root 锁死
```

（bin456789 DD 写公钥时通常默认已锁，此步为确认项。）

## 第 3 步：sshd 四项细项加固

写入 `/etc/ssh/sshd_config.d/99-hardening.conf`：

```
MaxAuthTries 3
LoginGraceTime 30
MaxStartups 10:30:60
AuthenticationMethods publickey
```

流程：先 `sshd -t` 校验语法 → 再重载 sshd → `sshd -T` 确认生效 → **逐台新开一条连接验证能登录**（防把自己锁外面）。

机主未批准的项不要擅自加：X11Forwarding no、PermitAgentForwarding no、AllowUsers root、ClientAlive 空闲断开、LogLevel VERBOSE。

## 第 4 步：tcpfit 一键调优（必须在 tmux 里跑）

```bash
tmux new -s tcpfit
bash <(curl -fsSL https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh)
```

选项定版：

- 主菜单：**[1] 一键全自动调优**
- 带宽：**留空**（现场实测，不要手填猜测值）
- 测速对端：**留空**（自动选最近的公共节点）
- 机器用途：**[1] 代理/加速**
- 最终确认：**y**
- iperf3 是否装守护进程：**No**

注意：

- 一台约 10 分钟，它是真跑流量逐档扫限速拐点，天生慢。
- 自动化驱动 tmux 时**用窗格 ID 定位，不要用会话名**（部分机器会话名定位不生效，会脱节空转）。
- 高带宽机器（如多 Gbps 端口）完整扫描可能烧几十 GB 流量：向导给出大流量估算时先问机主再决定跑不跑，不要默认继续。
- 跑完验证：`sysctl net.ipv4.tcp_congestion_control` 应为 `bbr`；记录每台的测速对端、RTT、实测带宽、是否检出限速器/是否加整形、耗流量。

## 第 5 步：NodeQuality 测试（必须在 tmux 里跑，硬件选 y）

```bash
tmux new -s nq
bash <(curl -sL https://run.NodeQuality.com)
```

- 第一个问题（HardwareQuality）：选 **y**
- 其余问题（IP / 网络 / 回程）：默认全选 y；机主指定只测某项时按指令选（如只测 IP 其余选 n）
- 一台约 10–20 分钟，跑完保存报告链接（nodequality.com/r/…），汇报时附链接

## 开荒之后（不属于开荒流程，需机主单独下令才做）

- 建节点：用 sbm 建 VLESS + Reality + Vision，监听 **8443**（443 留给建站），节点名末尾带“空格+国家缩写”（如 `leadinnoISP3 US`）
- SNI/伪装域名：必须从**每台 VPS 本机**实测 TLS 握手速度后逐台选，不用统一默认值；避开 Cloudflare 等共享 CDN 的站点域名（机主确认 apple.com、www.bing.com、www.amd.com 可用）
- UK 中转转发等拓扑变更同样需机主下令

## 踩过的坑（务必避开）

1. DD 后主机密钥变更 → 先清 known_hosts 旧指纹再连。
2. 批量 SSH 遇链路抖动会系统性漏检/误判超时 → 每台多次重试，必要时用一台稳定的机器作跳板，不要凭一次失败下结论。
3. tmux 驱动用窗格 ID，不用会话名。
4. 向导中途退回主菜单时不会改任何参数（机器保持原状），可安全重跑；完成与否以实查结果（如 sysctl 为 bbr）为准。
5. 配 IPv6 前先数网卡，第二块网卡可能才是商家给的 v6 口。
6. 精简镜像可能缺 curl，DD 第一步就会断 — 先补 curl。
7. 每一步都验证：脚本说“完成”不算完成，实查生效才算。

## inspect.sh

只读巡检：系统版本、CPU/内存/磁盘、TOP 进程、监听端口、运行中/自启服务、Docker、定时任务、磁盘占用、最近登录，附安全速查（UID 0 / 空密码账户、全部 authorized_keys 指纹、ld.so.preload 与 LD_PRELOAD 注入、对外连接、/tmp 与 /dev/shm 可执行文件）。只看不改。
用法：在目标机上 `bash inspect.sh`，或远程 `ssh 主机 'bash -s' < inspect.sh`。
