#!/usr/bin/env bash
echo "=== BASIC ==="
hostname; hostnamectl 2>/dev/null | head -20
cat /etc/os-release 2>/dev/null | grep -E 'PRETTY|VERSION='
uname -a
uptime
echo "=== CPU/MEM/DISK ==="
nproc; grep -m1 'model name' /proc/cpuinfo
free -h; df -hT -x tmpfs -x devtmpfs; lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null
echo "=== TOP PROC ==="
ps aux --sort=-%mem | head -25
echo "=== LISTEN ==="
ss -tulpn 2>/dev/null || netstat -tulpn 2>/dev/null
echo "=== RUNNING SERVICES ==="
systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | head -60
echo "=== ENABLED SERVICES ==="
systemctl list-unit-files --state=enabled --no-pager --no-legend 2>/dev/null | head -60
echo "=== DOCKER ==="
if command -v docker >/dev/null; then docker ps -a --format '{{.Names}} | {{.Image}} | {{.Status}} | {{.Ports}}'; echo "--- compose/images ---"; docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' | head -30; else echo "no docker"; fi
if command -v podman >/dev/null; then podman ps -a; fi
echo "=== PANELS / COMMON APPS ==="
ls -la /root /opt /www 2>/dev/null; ls /usr/local/bin 2>/dev/null | head -40
for d in nginx apache2 mysql mariadb postgresql redis-server x-ui 3x-ui sing-box xray v2ray hysteria trojan caddy fail2ban docker containerd; do systemctl is-active $d 2>/dev/null | grep -q active && echo "active: $d"; done
command -v nginx caddy apache2 mysql psql redis-cli xray sing-box 2>/dev/null
echo "=== CRON ==="
crontab -l 2>/dev/null; ls /etc/cron.d 2>/dev/null; systemctl list-timers --no-pager 2>/dev/null | head -20
echo "=== DISK TOP ==="
du -sh /root /home /var /opt /www /usr 2>/dev/null | sort -h
echo "=== LAST LOGIN ==="
last -n 10 2>/dev/null
echo "=== END ==="
