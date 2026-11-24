# VPS 开荒流程（定版）

## 流程总览
1. **DD 重装**：bin456789/reinstall，默认装 **Debian 13 最新版**，官方源实时拉取，不用自制镜像/第三方 DD 包
   ```bash
   bash reinstall.sh debian 13 --ssh-key "<默认公钥>" --ssh-port 49173
   ```
2. **开荒脚本**：`bash debian-post-dd.sh`（可用 `NICKNAME='机器昵称'` 预先传主机名）
3. **TCP 调优**：开荒后单独跑 tcpfit 一键调优（开荒脚本内不写 BBR/TCP 参数，避免冲突）
   ```bash
   bash <(curl -fsSL https://raw.githubusercontent.com/Kylin010/tcpfit/main/tcpfit.sh)
   ```
4. **验机测试**：最后跑 NodeQuality，硬件项选 `y`（标准模式），其余默认 `y`
   ```bash
   bash <(curl -sL https://run.NodeQuality.com)
   ```

## 定版规则
- 主机名 = 给这台机起的昵称，空格用 `-` 连接；没给昵称先问，不自创
- SSH 默认端口 **49173**；没特别给公钥时用默认公钥（Termius 生成，写在脚本里）
- 写好公钥后**直接关闭密码登录**，不等试登确认
- 不建普通用户；不开 BBR（交给 tcpfit）

## debian-post-dd.sh 的 8 步
1. 验机确认纯净（系统/IP/硬盘/监听端口/用户/密钥/定时任务/自启服务/登录记录，存日志）
2. 全量更新（full-upgrade + autoremove）
3. 时区 Asia/Shanghai + NTP；主机名按昵称设置（必填）
4. SSH 加固（默认公钥、端口 49173、关密码登录、root 仅密钥）+ Fail2ban
5. UFW 防火墙（先放行 SSH 端口再启用；80/443 可选）
6. Swap（已有跳过；小内存 2G / 其余 1G，swappiness=10）
7. 基础工具（curl wget git vim htop unzip tar ca-certificates gnupg lsb-release）
8. unattended-upgrades 自动安全更新 + journal 限额（200M/14 天）+ 收尾验证

## inspect.sh
只读巡检：系统版本、CPU/内存/磁盘、TOP 进程、监听端口、运行中/自启服务、Docker、定时任务、磁盘占用、最近登录。只看不改。
用法：在目标机上 `bash inspect.sh`，或远程 `ssh 主机 'bash -s' < inspect.sh`。
