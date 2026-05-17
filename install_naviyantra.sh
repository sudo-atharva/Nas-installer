#!/usr/bin/env bash
# =============================================================================
# install_naviyantra.sh — Naviyantra Enterprises Pi NAS Installer
# Version: 2.0.0
# Target:  Raspberry Pi OS 64-bit Lite (Bookworm)
# =============================================================================
# WHAT THIS SCRIPT DOES (in order):
#   1.  Installs all required system packages
#   2.  Automatically detects & reformats BACKUP_HDD if corrupted
#   3.  Mounts HDD at /mnt/storage with rw verified (hard fail if ro)
#   4.  Writes fstab entry (UUID-based, nofail)
#   5.  Creates systemd mount unit — HDD mounts BEFORE Docker on every boot
#   6.  Makes Docker depend on that mount unit — no more lost volumes on reboot
#   7.  Sets up USB automount via udev
#   8.  Creates full directory structure with correct rw permissions
#   9.  Installs Docker CE
#   10. Deploys: Syncthing, Portainer, OctoPrint, n8n, Netdata
#   11. Writes Syncthing .stignore (blocks .venv, node_modules, __pycache__)
#   12. Configures Samba shares
#   13. Tunes memory for 1 GB Pi + enables zram swap
#   14. Installs naviyantra-health and naviyantra-status commands
#   15. Copies installer to HDD for easy re-run
#   16. Prints final summary with all URLs
#
# SAFE TO RE-RUN — idempotent throughout.
# Set FORCE_REFORMAT=1 at top to force wipe even if drive looks healthy.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# CONFIGURATION — edit here
# =============================================================================

DRIVE_LABEL="BACKUP_HDD"
MOUNT_POINT="/mnt/storage"
PI_USER="pi"
PI_UID=1000
PI_GID=1000
TZ="Asia/Kolkata"
SAMBA_SHARE_NAME="Storage"
LOG_FILE="/var/log/naviyantra-setup.log"

SYNCTHING_IMAGE="lscr.io/linuxserver/syncthing:latest"
PORTAINER_IMAGE="portainer/portainer-ce:latest"

INSTALL_PORTAINER=1
INSTALL_OCTOPRINT=1
INSTALL_N8N=1
INSTALL_NETDATA=1

# Set to 1 to force wipe+reformat even if drive is healthy
FORCE_REFORMAT=0

# =============================================================================
# COLOURS & LOGGING
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

info()    { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" | tee -a "$LOG_FILE"; exit 1; }
section() {
    echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${CYAN}  $*${RESET}" | tee -a "$LOG_FILE"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
}

echo "" | tee -a "$LOG_FILE"
echo "================================================================" | tee -a "$LOG_FILE"
echo " Naviyantra NAS Installer v2.0 — $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
echo "================================================================" | tee -a "$LOG_FILE"

[[ $EUID -eq 0 ]] || error "Run as root: sudo bash $0"
id "$PI_USER" &>/dev/null || error "User '$PI_USER' not found."
success "Pre-flight OK"

# =============================================================================
# SECTION 1 — SYSTEM PACKAGES
# =============================================================================

section "1 · Installing system packages"

apt-get update -qq 2>&1 | tee -a "$LOG_FILE"

PKGS=(
    btrfs-progs samba samba-common-bin smartmontools
    curl git htop nano usbutils util-linux
    ca-certificates gnupg lsb-release
    avahi-daemon ntfs-3g exfatprogs
)

for pkg in "${PKGS[@]}"; do
    if dpkg -s "$pkg" &>/dev/null 2>&1; then
        info "  already installed: $pkg"
    else
        info "  installing: $pkg"
        apt-get install -y -qq "$pkg" 2>&1 | tee -a "$LOG_FILE"
        success "  installed: $pkg"
    fi
done

# =============================================================================
# SECTION 2 — FIND THE HDD
# =============================================================================

section "2 · Locating $DRIVE_LABEL"

DRIVE_DEV=$(blkid -L "$DRIVE_LABEL" 2>/dev/null || true)
if [[ -z "$DRIVE_DEV" ]]; then
    DRIVE_DEV=$(blkid | grep -i "LABEL=\"$DRIVE_LABEL\"" | awk -F: '{print $1}' | head -1 || true)
fi
if [[ -z "$DRIVE_DEV" ]]; then
    warn "Drive '$DRIVE_LABEL' not found. Available devices:"
    lsblk -o NAME,FSTYPE,LABEL,SIZE,MOUNTPOINT | tee -a "$LOG_FILE"
    error "Attach the HDD and re-run."
fi
success "Found: $DRIVE_DEV"

# =============================================================================
# SECTION 3 — STOP CONTAINERS & UNMOUNT CLEANLY
# =============================================================================

section "3 · Stopping containers and unmounting HDD"

if command -v docker &>/dev/null && systemctl is-active docker &>/dev/null 2>&1; then
    RUNNING=$(docker ps -q 2>/dev/null || true)
    if [[ -n "$RUNNING" ]]; then
        info "Stopping running containers..."
        docker stop $RUNNING 2>/dev/null || true
        sleep 3
    fi
fi

if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    info "Unmounting $MOUNT_POINT..."
    umount -l "$MOUNT_POINT" 2>/dev/null || true
    sleep 2
fi

success "Clean slate ready"

# =============================================================================
# SECTION 4 — REFORMAT HDD IF NEEDED
# =============================================================================

section "4 · Filesystem check / reformat"

DRIVE_FSTYPE=$(blkid -s TYPE -o value "$DRIVE_DEV" 2>/dev/null || true)
NEEDS_FORMAT=0

if [[ "$FORCE_REFORMAT" -eq 1 ]]; then
    warn "FORCE_REFORMAT=1 — reformatting unconditionally"
    NEEDS_FORMAT=1
elif [[ "$DRIVE_FSTYPE" != "btrfs" ]]; then
    warn "Drive is '$DRIVE_FSTYPE' not btrfs — reformatting"
    NEEDS_FORMAT=1
else
    info "Running btrfs integrity check..."
    if ! btrfs check --readonly "$DRIVE_DEV" &>/dev/null 2>&1; then
        warn "btrfs check FAILED — filesystem corrupted — reformatting"
        NEEDS_FORMAT=1
    else
        success "btrfs filesystem healthy — skipping reformat"
    fi
fi

if [[ "$NEEDS_FORMAT" -eq 1 ]]; then
    info "Formatting $DRIVE_DEV as btrfs (label: $DRIVE_LABEL)..."
    mkfs.btrfs -f -L "$DRIVE_LABEL" "$DRIVE_DEV" 2>&1 | tee -a "$LOG_FILE"
    sleep 2
    blkid -c /dev/null "$DRIVE_DEV" &>/dev/null || true
    success "Drive formatted"
fi

# =============================================================================
# SECTION 5 — MOUNT & VERIFY RW
# =============================================================================

section "5 · Mounting HDD (rw required)"

mkdir -p "$MOUNT_POINT"

mount -t btrfs -o defaults,noatime,compress=zstd,rw "$DRIVE_DEV" "$MOUNT_POINT" \
    2>&1 | tee -a "$LOG_FILE" || error "Mount failed — check cable/power and re-run"

# Hard verify rw
MOUNT_OPTS=$(mount | grep " $MOUNT_POINT " | grep -o '([^)]*)' || true)
if echo "$MOUNT_OPTS" | grep -qw 'ro'; then
    error "HDD mounted read-only after reformat. Unplug, replug and re-run."
fi
success "HDD mounted rw $MOUNT_OPTS"

touch "$MOUNT_POINT/.naviyantra_write_test" && rm "$MOUNT_POINT/.naviyantra_write_test" \
    || error "Write test failed — aborting"
success "Write test passed"

# =============================================================================
# SECTION 6 — FSTAB
# =============================================================================

section "6 · /etc/fstab"

DRIVE_UUID=$(blkid -s UUID -o value "$DRIVE_DEV")
info "UUID: $DRIVE_UUID"

[[ ! -f /etc/fstab.naviyantra.bak ]] && cp /etc/fstab /etc/fstab.naviyantra.bak

# Remove any previous naviyantra entries (handles UUID change after reformat)
grep -v -E "(Naviyantra BACKUP|$MOUNT_POINT.*btrfs)" /etc/fstab > /tmp/fstab.clean || true
cp /tmp/fstab.clean /etc/fstab

echo "" >> /etc/fstab
echo "# Naviyantra BACKUP_HDD — $(date '+%Y-%m-%d')" >> /etc/fstab
echo "UUID=$DRIVE_UUID  $MOUNT_POINT  btrfs  defaults,noatime,compress=zstd,nofail,x-systemd.device-timeout=30  0  0" >> /etc/fstab
success "fstab updated (UUID=$DRIVE_UUID)"

# =============================================================================
# SECTION 7 — SYSTEMD MOUNT UNIT (boot order fix)
# =============================================================================

section "7 · Systemd mount unit — HDD before Docker on every boot"

cat > /etc/systemd/system/mnt-storage.mount << UNIT
[Unit]
Description=Naviyantra BACKUP_HDD
After=local-fs.target
Before=docker.service

[Mount]
What=/dev/disk/by-uuid/$DRIVE_UUID
Where=$MOUNT_POINT
Type=btrfs
Options=defaults,noatime,compress=zstd,nofail,x-systemd.device-timeout=30

[Install]
WantedBy=multi-user.target
UNIT

mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/naviyantra-wait-for-hdd.conf << OVERRIDE
[Unit]
After=mnt-storage.mount
Wants=mnt-storage.mount
OVERRIDE

systemctl daemon-reload
systemctl enable mnt-storage.mount --quiet
success "Boot order fixed: HDD mounts before Docker on every reboot"

# =============================================================================
# SECTION 8 — USB AUTOMOUNT
# =============================================================================

section "8 · USB automount via udev"

USB_BASE="/mnt/usb"
mkdir -p "$USB_BASE"

cat > /usr/local/bin/naviyantra-automount.sh << 'SCRIPT'
#!/usr/bin/env bash
ACTION="$1"; DEVNAME="$2"
USB_BASE="/mnt/usb"
mkdir -p "$USB_BASE"
if [[ "$ACTION" == "add" ]]; then
    sleep 2
    LABEL=$(blkid -s LABEL -o value "$DEVNAME" 2>/dev/null || true)
    UUID=$(blkid  -s UUID  -o value "$DEVNAME" 2>/dev/null || true)
    FSTYPE=$(blkid -s TYPE -o value "$DEVNAME" 2>/dev/null || true)
    [[ -z "$FSTYPE" || "$FSTYPE" == "swap" ]] && exit 0
    MNAME="${LABEL:-$UUID}"; MNAME="${MNAME// /_}"
    MDIR="$USB_BASE/$MNAME"; mkdir -p "$MDIR"
    case "$FSTYPE" in
        vfat|exfat)   mount -t "$FSTYPE"  -o uid=1000,gid=1000,umask=022,nofail "$DEVNAME" "$MDIR" ;;
        ntfs|ntfs-3g) mount -t ntfs-3g    -o uid=1000,gid=1000,umask=022,nofail "$DEVNAME" "$MDIR" ;;
        btrfs)        mount -t btrfs      -o defaults,noatime,compress=zstd,nofail "$DEVNAME" "$MDIR" ;;
        ext*)         mount -t "$FSTYPE"  -o defaults,noatime,nofail "$DEVNAME" "$MDIR" ;;
        *)            mount -o defaults,nofail "$DEVNAME" "$MDIR" ;;
    esac
    logger "naviyantra-automount: $DEVNAME ($FSTYPE) → $MDIR"
elif [[ "$ACTION" == "remove" ]]; then
    while IFS= read -r line; do
        MP=$(echo "$line" | awk '{print $2}')
        umount "$MP" 2>/dev/null && rmdir "$MP" 2>/dev/null || true
    done < <(grep "$DEVNAME" /proc/mounts || true)
fi
SCRIPT

chmod +x /usr/local/bin/naviyantra-automount.sh

cat > /etc/udev/rules.d/99-naviyantra-usb.rules << 'UDEV'
ACTION=="add",    KERNEL=="sd[b-z][0-9]", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", RUN+="/usr/local/bin/naviyantra-automount.sh add %N"
ACTION=="remove", KERNEL=="sd[b-z][0-9]", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", RUN+="/usr/local/bin/naviyantra-automount.sh remove %N"
UDEV

udevadm control --reload-rules
success "USB automount ready"

# =============================================================================
# SECTION 9 — DIRECTORY STRUCTURE & PERMISSIONS
# =============================================================================

section "9 · Directories & permissions"

DIRS=(
    "$MOUNT_POINT/Workplace"
    "$MOUNT_POINT/docker/syncthing/config"
    "$MOUNT_POINT/docker/portainer/data"
    "$MOUNT_POINT/docker/octoprint/config"
    "$MOUNT_POINT/docker/n8n/data"
    "$MOUNT_POINT/docker/netdata/config"
    "$MOUNT_POINT/backups/code_backup"
    "$MOUNT_POINT/backups/doc_backup"
    "$MOUNT_POINT/printer/uploads"
    "$MOUNT_POINT/printer/timelapses"
    "$MOUNT_POINT/downloads"
    "$MOUNT_POINT/n8n"
    "$MOUNT_POINT/homepage"
    "$USB_BASE"
)

for d in "${DIRS[@]}"; do
    mkdir -p "$d" && info "  ready: $d"
done

chown -R "$PI_USER":"$PI_USER" "$MOUNT_POINT"
find "$MOUNT_POINT" -type d -exec chmod 775 {} \;
find "$MOUNT_POINT" -type d -exec chmod g+s {} \;
find "$MOUNT_POINT" -type f -exec chmod 664 {} \;
chmod 775 "$USB_BASE"
chown "$PI_USER":"$PI_USER" "$USB_BASE"

# Save installer to HDD — survives reinstalls
cp "$0" "$MOUNT_POINT/install_naviyantra.sh" 2>/dev/null || true
chmod 775 "$MOUNT_POINT/install_naviyantra.sh" 2>/dev/null || true

success "Permissions OK (dirs=775+sgid, files=664, owner=$PI_USER)"

# =============================================================================
# SECTION 10 — DOCKER
# =============================================================================

section "10 · Docker"

if command -v docker &>/dev/null; then
    info "Docker already installed: $(docker --version)"
else
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh 2>&1 | tee -a "$LOG_FILE"
    rm /tmp/get-docker.sh
    success "Docker installed"
fi

groups "$PI_USER" | grep -q docker || usermod -aG docker "$PI_USER"
systemctl enable docker --quiet
systemctl start docker
success "Docker running"

# Helper — deploy only if container doesn't already exist
deploy() {
    local NAME="$1"; shift
    if docker ps -a --format '{{.Names}}' | grep -q "^${NAME}$"; then
        info "$NAME already exists — skipping"
    else
        info "Deploying $NAME..."
        docker run -d "$@"
        success "$NAME started"
    fi
}

# =============================================================================
# SECTION 11 — SYNCTHING
# =============================================================================

section "11 · Syncthing"

# Always recreate Syncthing — fresh filesystem needs fresh config
docker stop syncthing 2>/dev/null || true
docker rm   syncthing 2>/dev/null || true

docker pull "$SYNCTHING_IMAGE" 2>&1 | tee -a "$LOG_FILE"

docker run -d \
    --name syncthing \
    --restart unless-stopped \
    -e PUID="$PI_UID" \
    -e PGID="$PI_GID" \
    -e TZ="$TZ" \
    -p 8384:8384 \
    -p 22000:22000/tcp \
    -p 22000:22000/udp \
    -p 21027:21027/udp \
    -v "$MOUNT_POINT/docker/syncthing/config:/config" \
    -v "$MOUNT_POINT:/storage" \
    "$SYNCTHING_IMAGE"

success "Syncthing started"

# Write .stignore to block problematic files from ever being synced
info "Writing Syncthing ignore patterns..."
sleep 5   # let container init

STIGNORE="$MOUNT_POINT/Workplace/.stignore"
cat > "$STIGNORE" << 'IGNORE'
// Naviyantra — Syncthing ignore patterns
// These paths are NEVER synced to/from this device

// Python virtual environments (huge, platform-specific, always regenerate)
.venv
venv
env
.env
__pycache__
*.pyc
*.pyo
*.egg-info
dist
build
.pytest_cache
.mypy_cache
*.so

// Node.js
node_modules
.next
.nuxt
.cache
dist
build

// Version control (do not double-sync git internals)
.git

// OS noise
.DS_Store
Thumbs.db
desktop.ini

// Logs and temp files
*.log
*.tmp
*.swp
*.bak
~$*

// Large files unlikely to need sync
*.iso
*.img
*.vmdk
*.ova
IGNORE

chown "$PI_USER":"$PI_USER" "$STIGNORE"
chmod 664 "$STIGNORE"
success "Syncthing .stignore written"

sleep 3
docker exec syncthing ls /storage/Workplace &>/dev/null \
    && success "Syncthing sees /storage/Workplace ✓" \
    || warn "Volume check pending — run: docker restart syncthing if UI shows error"

# =============================================================================
# SECTION 12 — PORTAINER
# =============================================================================

section "12 · Portainer"

if [[ "$INSTALL_PORTAINER" -eq 1 ]]; then
    deploy portainer \
        --name portainer \
        --restart unless-stopped \
        -p 9000:9000 \
        -p 9443:9443 \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$MOUNT_POINT/docker/portainer/data:/data" \
        "$PORTAINER_IMAGE"
fi

# =============================================================================
# SECTION 13 — OCTOPRINT
# =============================================================================

section "13 · OctoPrint"

if [[ "$INSTALL_OCTOPRINT" -eq 1 ]]; then
    # No --device flag — starts fine without printer, connect later via UI
    deploy octoprint \
        --name octoprint \
        --restart unless-stopped \
        -p 5000:5000 \
        -e ENABLE_MJPG_STREAMER=true \
        -v "$MOUNT_POINT/docker/octoprint/config:/octoprint" \
        -v "$MOUNT_POINT/printer:/files" \
        octoprint/octoprint:latest
fi

# =============================================================================
# SECTION 14 — N8N
# =============================================================================

section "14 · n8n"

if [[ "$INSTALL_N8N" -eq 1 ]]; then
    deploy n8n \
        --name n8n \
        --restart unless-stopped \
        -p 5678:5678 \
        -e TZ="$TZ" \
        -e GENERIC_TIMEZONE="$TZ" \
        -e N8N_SECURE_COOKIE=false \
        -e N8N_BASIC_AUTH_ACTIVE=true \
        -e N8N_BASIC_AUTH_USER=admin \
        -e N8N_BASIC_AUTH_PASSWORD=naviyantra123 \
        -v "$MOUNT_POINT/docker/n8n/data:/home/node/.n8n" \
        -v "$MOUNT_POINT/n8n:/files" \
        n8nio/n8n:latest

    warn "n8n default login: admin / naviyantra123 — change after first login"
fi

# =============================================================================
# SECTION 15 — NETDATA
# =============================================================================

section "15 · Netdata"

if [[ "$INSTALL_NETDATA" -eq 1 ]]; then
    deploy netdata \
        --name netdata \
        --restart unless-stopped \
        -p 19999:19999 \
        --cap-add SYS_PTRACE \
        --security-opt apparmor=unconfined \
        -v /proc:/host/proc:ro \
        -v /sys:/host/sys:ro \
        -v /etc/os-release:/host/etc/os-release:ro \
        -v /var/run/docker.sock:/var/run/docker.sock:ro \
        netdata/netdata:latest
fi

# =============================================================================
# SECTION 16 — SAMBA
# =============================================================================

section "16 · Samba"

SMB_CONF="/etc/samba/smb.conf"
[[ ! -f "${SMB_CONF}.naviyantra.bak" ]] && cp "$SMB_CONF" "${SMB_CONF}.naviyantra.bak"

if grep -q "\[$SAMBA_SHARE_NAME\]" "$SMB_CONF"; then
    info "Samba shares already configured"
else
    cat >> "$SMB_CONF" << SMB

# Naviyantra — $(date '+%Y-%m-%d')
[$SAMBA_SHARE_NAME]
   comment = Naviyantra NAS Storage
   path = $MOUNT_POINT
   browseable = yes
   writable = yes
   guest ok = no
   valid users = $PI_USER
   create mask = 0775
   directory mask = 0775
   force user = $PI_USER
   force group = $PI_USER

[Printer]
   comment = OctoPrint Files
   path = $MOUNT_POINT/printer
   browseable = yes
   writable = yes
   guest ok = no
   valid users = $PI_USER
   create mask = 0775
   directory mask = 0775
SMB
    success "Samba shares added"
fi

if [[ ! -f /root/.naviyantra_samba_pw_set ]]; then
    (echo "naviyantra123"; echo "naviyantra123") | smbpasswd -s -a "$PI_USER"
    touch /root/.naviyantra_samba_pw_set
    warn "Samba password: naviyantra123 — change with: sudo smbpasswd $PI_USER"
fi

testparm -s "$SMB_CONF" &>/dev/null && success "smb.conf OK" || warn "smb.conf issue — run: testparm"
systemctl enable smbd nmbd --quiet
systemctl restart smbd nmbd
success "Samba running"

# =============================================================================
# SECTION 17 — MEMORY TUNING
# =============================================================================

section "17 · Memory tuning"

SYSCTL_CONF="/etc/sysctl.d/99-naviyantra.conf"
if [[ ! -f "$SYSCTL_CONF" ]]; then
    cat > "$SYSCTL_CONF" << 'SYSCTL'
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_background_ratio=5
vm.dirty_ratio=10
net.core.rmem_max=4194304
net.core.wmem_max=4194304
SYSCTL
    sysctl -p "$SYSCTL_CONF" 2>&1 | tee -a "$LOG_FILE"
    success "sysctl tuning applied"
else
    info "sysctl already tuned"
fi

if ! swapon --show | grep -q zram; then
    modprobe zram 2>/dev/null || true
    if zramctl /dev/zram0 --algorithm lz4 --size 256M 2>/dev/null; then
        mkswap /dev/zram0 &>/dev/null && swapon -p 100 /dev/zram0 &>/dev/null \
            && success "zram swap enabled (256M)" || warn "zram swapon failed"
    else
        warn "zram unavailable on this kernel"
    fi
else
    info "zram already active"
fi

# =============================================================================
# SECTION 18 — HELPER COMMANDS
# =============================================================================

section "18 · Helper commands"

cat > /usr/local/bin/naviyantra-health.sh << 'HEALTH'
#!/usr/bin/env bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}[OK]${RESET}   $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; ISSUES=$((ISSUES+1)); }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
ISSUES=0

echo -e "\n${CYAN}Naviyantra Health — $(date)${RESET}"

echo -e "\n── Storage ──"
if mountpoint -q /mnt/storage; then
    ok "/mnt/storage mounted"
    df -h /mnt/storage | tail -1
    BTRFS_ERRS=$(dmesg 2>/dev/null | grep -c "BTRFS error" || echo 0)
    [[ "$BTRFS_ERRS" -gt 0 ]] \
        && fail "btrfs $BTRFS_ERRS error(s) in dmesg — HDD needs reformat, run installer" \
        || ok "No btrfs errors"
else
    fail "/mnt/storage NOT mounted — run: sudo systemctl start mnt-storage.mount"
fi

echo -e "\n── Containers ──"
for cname in syncthing portainer octoprint n8n netdata; do
    state=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo "not found")
    case "$state" in
        running)    ok   "$cname" ;;
        not\ found) warn "$cname not installed" ;;
        *)          fail "$cname is $state — run: docker start $cname" ;;
    esac
done

echo -e "\n── Services ──"
curl -sf --max-time 3 http://localhost:8384  -o /dev/null && ok  "Syncthing  :8384"  || fail "Syncthing  :8384"
curl -sf --max-time 3 http://localhost:9000  -o /dev/null && ok  "Portainer  :9000"  || warn "Portainer  :9000"
curl -sf --max-time 3 http://localhost:5000  -o /dev/null && ok  "OctoPrint  :5000"  || warn "OctoPrint  :5000"
curl -sf --max-time 3 http://localhost:5678  -o /dev/null && ok  "n8n        :5678"  || warn "n8n        :5678"
curl -sf --max-time 3 http://localhost:19999 -o /dev/null && ok  "Netdata    :19999" || warn "Netdata    :19999"
systemctl is-active smbd &>/dev/null && ok "Samba" || fail "Samba not running"

echo -e "\n── Syncthing volume ──"
docker exec syncthing ls /storage/Workplace &>/dev/null \
    && ok "Syncthing sees /storage/Workplace" \
    || fail "Syncthing cannot see volume — run: docker restart syncthing"

echo -e "\n── Memory ──"
free -h | grep -E "Mem|Swap"

echo ""
[[ $ISSUES -eq 0 ]] && echo -e "${GREEN}All checks passed.${RESET}" \
                     || echo -e "${RED}$ISSUES issue(s) found.${RESET}"
HEALTH

cat > /usr/local/bin/naviyantra-status.sh << 'STATUS'
#!/usr/bin/env bash
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
PI_IP=$(hostname -I | awk '{print $1}')
echo -e "\n${BOLD}${CYAN}Naviyantra NAS — $(date '+%H:%M:%S')${RESET}"
echo -e "\n── Mounts ──"
mount | grep -E "/mnt/(storage|usb)" || echo "  (none)"
echo -e "\n── Containers ──"
docker ps --format "  {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | column -t -s $'\t' || echo "  Docker not running"
echo -e "\n── Disk ──"
df -h /mnt/storage 2>/dev/null || echo "  HDD not mounted"
echo -e "\n── Memory ──"
free -h | grep -E "Mem|Swap"
echo -e "\n── URLs ──"
echo "  Syncthing  → http://$PI_IP:8384"
echo "  Portainer  → http://$PI_IP:9000"
echo "  OctoPrint  → http://$PI_IP:5000"
echo "  n8n        → http://$PI_IP:5678"
echo "  Netdata    → http://$PI_IP:19999"
echo ""
STATUS

chmod +x /usr/local/bin/naviyantra-health.sh /usr/local/bin/naviyantra-status.sh
ln -sf /usr/local/bin/naviyantra-health.sh /usr/local/bin/naviyantra-health
ln -sf /usr/local/bin/naviyantra-status.sh /usr/local/bin/naviyantra-status
success "naviyantra-health and naviyantra-status installed"

# =============================================================================
# SECTION 19 — FINAL RESTART
# =============================================================================

section "19 · Final restart"

systemctl daemon-reload
systemctl restart docker
sleep 8

for cname in syncthing portainer octoprint n8n netdata; do
    docker start "$cname" 2>/dev/null && info "  started: $cname" || warn "  skipped: $cname"
done

sleep 5

# =============================================================================
# SUMMARY
# =============================================================================

PI_IP=$(hostname -I | awk '{print $1}')

echo "" | tee -a "$LOG_FILE"
echo -e "${BOLD}${GREEN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║       Naviyantra NAS v2.0 — Installation Complete           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "${CYAN}Pi IP        :${RESET} $PI_IP"
echo ""
echo -e "${CYAN}Services     :${RESET}"
echo "  Syncthing  →  http://$PI_IP:8384"
echo "  Portainer  →  http://$PI_IP:9000"
echo "  OctoPrint  →  http://$PI_IP:5000"
echo "  n8n        →  http://$PI_IP:5678   (admin / naviyantra123)"
echo "  Netdata    →  http://$PI_IP:19999"
echo ""
echo -e "${CYAN}Samba        :${RESET}"
echo "  smb://$PI_IP/Storage   (user: $PI_USER / naviyantra123)"
echo "  smb://$PI_IP/Printer"
echo ""
echo -e "${CYAN}Boot order   :${RESET} HDD → Docker → Containers (systemd guaranteed)"
echo -e "${CYAN}Installer    :${RESET} $MOUNT_POINT/install_naviyantra.sh"
echo ""
echo -e "${CYAN}Syncthing    :${RESET}"
echo "  Pi path    : /storage/Workplace  → set as Receive Only"
echo "  Fedora path: /home/atharva/Workplace  → set as Send Only"
echo "  Ignore file: pre-written (.venv, node_modules, __pycache__ blocked)"
echo ""
echo -e "${CYAN}Commands     :${RESET}"
echo "  naviyantra-health          — full health check with btrfs error detection"
echo "  naviyantra-status          — quick overview + URLs"
echo "  sudo smbpasswd $PI_USER    — change Samba password"
echo "  docker restart syncthing   — if volumes lost after unexpected remount"
echo "  sudo bash $MOUNT_POINT/install_naviyantra.sh — re-run from HDD"
echo ""
echo -e "${CYAN}Log          :${RESET} $LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Installation completed at $(date)" >> "$LOG_FILE"
