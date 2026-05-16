#!/usr/bin/env bash
# =============================================================================
# uninstall_naviyantra.sh
# Naviyantra Enterprises — NAS Environment Uninstaller
# WARNING: This will remove containers, configs, and system changes.
#          Your DATA on /mnt/storage is preserved.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }

echo -e "${RED}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║       Naviyantra NAS — UNINSTALLER                          ║"
echo "║  DATA on /mnt/storage will NOT be deleted.                  ║"
echo "║  Docker containers, configs, and system files will be       ║"
echo "║  removed.                                                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
read -r -p "Type 'yes' to confirm uninstall: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }

# Stop and remove containers
info "Stopping Docker containers..."
for cname in syncthing portainer octoprint n8n; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${cname}$"; then
        docker stop "$cname" 2>/dev/null || true
        docker rm   "$cname" 2>/dev/null || true
        success "Removed container: $cname"
    fi
done

# Remove helper scripts
info "Removing helper scripts..."
for f in /usr/local/bin/naviyantra-automount.sh \
         /usr/local/bin/naviyantra-health.sh \
         /usr/local/bin/naviyantra-status.sh; do
    rm -f "$f" && success "Removed: $f"
done

# Remove udev rules
rm -f /etc/udev/rules.d/99-naviyantra-usb.rules
udevadm control --reload-rules
success "Removed udev USB rules"

# Remove sysctl tuning
rm -f /etc/sysctl.d/99-naviyantra.conf
sysctl --system &>/dev/null || true
success "Removed sysctl tuning"

# Restore fstab backup
if [[ -f /etc/fstab.naviyantra.bak ]]; then
    warn "Restoring original fstab from backup..."
    cp /etc/fstab.naviyantra.bak /etc/fstab
    success "fstab restored"
else
    warn "No fstab backup found — remove BACKUP_HDD entry manually from /etc/fstab"
fi

# Restore smb.conf backup
if [[ -f /etc/samba/smb.conf.naviyantra.bak ]]; then
    cp /etc/samba/smb.conf.naviyantra.bak /etc/samba/smb.conf
    systemctl restart smbd nmbd 2>/dev/null || true
    success "smb.conf restored"
else
    warn "No smb.conf backup found — Naviyantra share entries remain in /etc/samba/smb.conf"
fi

# Unmount HDD
if mountpoint -q /mnt/storage; then
    umount /mnt/storage && success "Unmounted /mnt/storage"
fi

# Remove Samba password marker
rm -f /root/.naviyantra_samba_pw_set

echo ""
echo -e "${GREEN}Uninstall complete.${RESET}"
echo "Docker and other system packages were NOT removed."
echo "Your data at /mnt/storage is untouched."
echo "To remove Docker: sudo apt-get purge docker-ce docker-ce-cli containerd.io"
