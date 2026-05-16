#!/usr/bin/env bash
# =============================================================================
# status_naviyantra.sh
# Naviyantra Enterprises — Full system status report
# =============================================================================

set -uo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RESET='\033[0m'

PI_IP=$(hostname -I | awk '{print $1}')

bar() { echo -e "${BOLD}${CYAN}── $* ──────────────────────────────────────${RESET}"; }

clear
echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Naviyantra NAS — System Status                      ║"
echo "║  $(date '+%a %d %b %Y  %H:%M:%S')                                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

# ── Storage ──────────────────────────────────────────────────────────────────
bar "Storage"
if mountpoint -q /mnt/storage 2>/dev/null; then
    echo -e "  ${GREEN}/mnt/storage${RESET} mounted"
    df -h /mnt/storage | awk 'NR==2 {printf "  Used: %s / %s  (%s)\n", $3, $2, $5}'
else
    echo -e "  ${RED}/mnt/storage NOT mounted${RESET}"
fi
echo ""
echo "  USB drives:"
lsblk -o NAME,FSTYPE,LABEL,SIZE,MOUNTPOINT 2>/dev/null | grep -v "^loop" | sed 's/^/  /' || echo "  (none)"

# ── Docker containers ─────────────────────────────────────────────────────────
echo ""
bar "Docker containers"
if command -v docker &>/dev/null && systemctl is-active docker &>/dev/null; then
    docker ps --format "  {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | \
        column -t -s $'\t' || echo "  (none running)"
    echo ""
    echo "  Stopped containers:"
    docker ps -a --filter "status=exited" --format "  {{.Names}}\t{{.Status}}" 2>/dev/null | \
        column -t -s $'\t' || echo "  (none)"
else
    echo -e "  ${RED}Docker not running${RESET}"
fi

# ── Service URLs ──────────────────────────────────────────────────────────────
echo ""
bar "Service URLs"
services=(
    "Syncthing|http://$PI_IP:8384"
    "Portainer|http://$PI_IP:9000"
    "OctoPrint|http://$PI_IP:5000"
    "n8n      |http://$PI_IP:5678"
)
for svc in "${services[@]}"; do
    name="${svc%%|*}"
    url="${svc##*|}"
    if curl -sf --max-time 2 "$url" -o /dev/null 2>/dev/null; then
        echo -e "  ${GREEN}●${RESET} $name  →  $url"
    else
        echo -e "  ${YELLOW}○${RESET} $name  →  $url  (not reachable)"
    fi
done

# ── Samba ─────────────────────────────────────────────────────────────────────
echo ""
bar "Samba"
if systemctl is-active smbd &>/dev/null; then
    echo -e "  ${GREEN}smbd running${RESET}"
    echo "  Share path: smb://$PI_IP/Storage"
    echo "  Printer   : smb://$PI_IP/Printer"
else
    echo -e "  ${RED}smbd not running${RESET}"
fi

# ── Memory & CPU ──────────────────────────────────────────────────────────────
echo ""
bar "Memory & CPU"
free -h | grep -E "Mem|Swap" | sed 's/^/  /'
echo ""
CPU_TEMP=$(vcgencmd measure_temp 2>/dev/null | cut -d= -f2 || cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.1f°C", $1/1000}' || echo "N/A")
echo "  CPU temp  : $CPU_TEMP"
echo "  Load avg  : $(cut -d' ' -f1-3 /proc/loadavg)"
echo "  Uptime    : $(uptime -p)"

# ── Syncthing volume check ─────────────────────────────────────────────────────
echo ""
bar "Syncthing /storage check"
if docker inspect syncthing &>/dev/null; then
    if docker exec syncthing ls /storage/Workplace &>/dev/null; then
        echo -e "  ${GREEN}Syncthing can see /storage/Workplace ✓${RESET}"
    else
        echo -e "  ${RED}Syncthing cannot see /storage/Workplace${RESET}"
        echo "  Fix: docker restart syncthing"
    fi
else
    echo "  Syncthing container not found"
fi

echo ""
echo -e "${CYAN}Log: /var/log/naviyantra-setup.log${RESET}"
echo ""
