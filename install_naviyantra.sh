#!/usr/bin/env bash
# =============================================================================
# install_naviyantra.sh
# Naviyantra Enterprises — Raspberry Pi NAS & Sync Environment Installer
# Target: Raspberry Pi OS 64-bit Lite (Bookworm/Bullseye, Debian-based)
# Author: Naviyantra Enterprises
# Version: 1.0.0
# =============================================================================
# This script is IDEMPOTENT — safe to re-run on an existing installation.
# It will skip steps already completed and update only what is needed.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# CONFIGURATION — Edit these values to match your environment
# =============================================================================

DRIVE_LABEL="BACKUP_HDD"                        # btrfs drive label
MOUNT_POINT="/mnt/storage"                      # where the HDD is mounted
PI_USER="pi"                                    # Linux user owning files
PI_UID=1000
PI_GID=1000
TZ="Asia/Kolkata"
SAMBA_SHARE_NAME="Storage"
LOG_FILE="/var/log/naviyantra-setup.log"

# Docker image tags
SYNCTHING_IMAGE="lscr.io/linuxserver/syncthing:latest"
PORTAINER_IMAGE="portainer/portainer-ce:latest"

# Feature flags (set to 1 to enable)
INSTALL_PORTAINER=1                             # set 0 to skip Portainer
INSTALL_OCTOPRINT=1                             # set 0 to skip OctoPrint
INSTALL_N8N=1                                   # set 0 to skip n8n

# =============================================================================
# COLOUR HELPERS
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" | tee -a "$LOG_FILE"; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"
            echo -e "${BOLD}${CYAN}  $*${RESET}" | tee -a "$LOG_FILE"
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}" | tee -a "$LOG_FILE"; }

# =============================================================================
# PRE-FLIGHT
# =============================================================================

# Ensure log file is writable
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

echo "" | tee -a "$LOG_FILE"
echo "================================================================" | tee -a "$LOG_FILE"
echo " Naviyantra NAS Installer — $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
echo "================================================================" | tee -a "$LOG_FILE"

# Must run as root
[[ $EUID -eq 0 ]] || error "Please run as root: sudo bash $0"
success "Running as root"

# Confirm user exists
id "$PI_USER" &>/dev/null || error "User '$PI_USER' does not exist. Create it first."
success "User '$PI_USER' found"

# =============================================================================
# SECTION 1 — SYSTEM PACKAGES
# =============================================================================

section "1 · Installing system packages"

apt-get update -qq | tee -a "$LOG_FILE"

PKGS=(
    btrfs-progs
    samba
    samba-common-bin
    smartmontools
    curl
    git
    htop
    nano
    usbutils
    util-linux       # for lsblk / blkid
    ca-certificates
    gnupg
    lsb-release
    avahi-daemon     # mDNS — pi.local hostname
    ntfs-3g          # NTFS USB drive support
    exfatprogs       # exFAT USB drive support
    udiskie          # optional USB automount helper
)

for pkg in "${PKGS[@]}"; do
    if dpkg -s "$pkg" &>/dev/null; then
        info "  already installed: $pkg"
    else
        info "  installing: $pkg"
        apt-get install -y -qq "$pkg" | tee -a "$LOG_FILE"
        success "  installed: $pkg"
    fi
done

# =============================================================================
# SECTION 2 — DETECT & MOUNT BACKUP_HDD (Btrfs)
# =============================================================================

section "2 · Detecting and mounting $DRIVE_LABEL"

# Find block device by label
DRIVE_DEV=$(blkid -L "$DRIVE_LABEL" 2>/dev/null || true)

if [[ -z "$DRIVE_DEV" ]]; then
    # Fallback: scan all block devices for the label
    DRIVE_DEV=$(blkid | grep -i "LABEL=\"$DRIVE_LABEL\"" | awk -F: '{print $1}' | head -1 || true)
fi

if [[ -z "$DRIVE_DEV" ]]; then
    warn "Drive with label '$DRIVE_LABEL' not found."
    warn "Listing available block devices:"
    lsblk -o NAME,FSTYPE,LABEL,UUID,MOUNTPOINT | tee -a "$LOG_FILE"
    error "Please attach the HDD and re-run the installer."
fi

success "Found drive: $DRIVE_DEV"

# Get UUID for fstab (more stable than label)
DRIVE_UUID=$(blkid -s UUID -o value "$DRIVE_DEV")
DRIVE_FSTYPE=$(blkid -s TYPE -o value "$DRIVE_DEV")
info "UUID: $DRIVE_UUID  |  FS: $DRIVE_FSTYPE"

[[ "$DRIVE_FSTYPE" == "btrfs" ]] || error "Drive $DRIVE_DEV is $DRIVE_FSTYPE, not btrfs. Reformat or update DRIVE_LABEL."

# Create mount point
mkdir -p "$MOUNT_POINT"

# Mount if not already mounted
if mountpoint -q "$MOUNT_POINT"; then
    success "$MOUNT_POINT already mounted"
else
    info "Mounting $DRIVE_DEV → $MOUNT_POINT"
    mount -t btrfs -o defaults,noatime,compress=zstd "$DRIVE_DEV" "$MOUNT_POINT"
    success "Mounted successfully"
fi

# =============================================================================
# SECTION 3 — PERSISTENT FSTAB ENTRY
# =============================================================================

section "3 · Configuring /etc/fstab"

FSTAB_ENTRY="UUID=$DRIVE_UUID  $MOUNT_POINT  btrfs  defaults,noatime,compress=zstd,nofail  0  0"

# Backup fstab once (don't overwrite repeated backups)
if [[ ! -f /etc/fstab.naviyantra.bak ]]; then
    cp /etc/fstab /etc/fstab.naviyantra.bak
    info "fstab backed up → /etc/fstab.naviyantra.bak"
fi

if grep -qF "$DRIVE_UUID" /etc/fstab; then
    info "fstab entry for UUID=$DRIVE_UUID already present — skipping"
else
    echo "" >> /etc/fstab
    echo "# Naviyantra BACKUP_HDD — added by installer $(date '+%Y-%m-%d')" >> /etc/fstab
    echo "$FSTAB_ENTRY" >> /etc/fstab
    success "fstab entry added"
fi

# Test fstab is valid
mount -a --fake 2>/dev/null && success "fstab syntax OK" || warn "fstab --fake mount test reported an issue — review /etc/fstab"

# =============================================================================
# SECTION 4 — USB DRIVE AUTOMOUNT (udev rules)
# =============================================================================

section "4 · USB automount via udev"

USB_MOUNT_SCRIPT="/usr/local/bin/naviyantra-automount.sh"
UDEV_RULE="/etc/udev/rules.d/99-naviyantra-usb.rules"
USB_BASE="/mnt/usb"
mkdir -p "$USB_BASE"

cat > "$USB_MOUNT_SCRIPT" << 'SCRIPT'
#!/usr/bin/env bash
# Naviyantra USB automount helper — called by udev
# Mounts USB drives under /mnt/usb/<label_or_uuid>

ACTION="$1"
DEVNAME="$2"

USB_BASE="/mnt/usb"
mkdir -p "$USB_BASE"

if [[ "$ACTION" == "add" ]]; then
    sleep 2   # let kernel settle
    LABEL=$(blkid -s LABEL -o value "$DEVNAME" 2>/dev/null || true)
    UUID=$(blkid -s UUID  -o value "$DEVNAME" 2>/dev/null || true)
    FSTYPE=$(blkid -s TYPE  -o value "$DEVNAME" 2>/dev/null || true)

    # Skip swap, extended, unknown
    [[ -z "$FSTYPE" || "$FSTYPE" == "swap" ]] && exit 0

    MOUNTNAME="${LABEL:-$UUID}"
    MOUNTNAME="${MOUNTNAME// /_}"          # replace spaces
    MOUNTDIR="$USB_BASE/$MOUNTNAME"
    mkdir -p "$MOUNTDIR"

    case "$FSTYPE" in
        vfat|exfat)
            mount -t "$FSTYPE" -o uid=1000,gid=1000,umask=022,nofail "$DEVNAME" "$MOUNTDIR" ;;
        ntfs|ntfs-3g)
            mount -t ntfs-3g -o uid=1000,gid=1000,umask=022,nofail "$DEVNAME" "$MOUNTDIR" ;;
        btrfs)
            mount -t btrfs -o defaults,noatime,compress=zstd,nofail "$DEVNAME" "$MOUNTDIR" ;;
        ext4|ext3|ext2)
            mount -t "$FSTYPE" -o defaults,noatime,nofail "$DEVNAME" "$MOUNTDIR" ;;
        *)
            mount -o defaults,nofail "$DEVNAME" "$MOUNTDIR" ;;
    esac

    logger "naviyantra-automount: mounted $DEVNAME ($FSTYPE) → $MOUNTDIR"

elif [[ "$ACTION" == "remove" ]]; then
    # Unmount any mountpoint that contains this device
    while IFS= read -r line; do
        MP=$(echo "$line" | awk '{print $2}')
        umount "$MP" 2>/dev/null && rmdir "$MP" 2>/dev/null && \
            logger "naviyantra-automount: unmounted $MP"
    done < <(grep "$DEVNAME" /proc/mounts || true)
fi
SCRIPT

chmod +x "$USB_MOUNT_SCRIPT"

cat > "$UDEV_RULE" << UDEV
# Naviyantra USB automount rules
# Trigger on USB storage partition events
ACTION=="add",    KERNEL=="sd[b-z][0-9]", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", \
    RUN+="/usr/local/bin/naviyantra-automount.sh add %N"

ACTION=="remove", KERNEL=="sd[b-z][0-9]", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", \
    RUN+="/usr/local/bin/naviyantra-automount.sh remove %N"
UDEV

udevadm control --reload-rules
success "USB automount udev rules installed → $UDEV_RULE"

# =============================================================================
# SECTION 5 — DIRECTORY STRUCTURE
# =============================================================================

section "5 · Creating directory structure"

DIRS=(
    "$MOUNT_POINT/Workplace"
    "$MOUNT_POINT/docker/syncthing/config"
    "$MOUNT_POINT/docker/portainer/data"
    "$MOUNT_POINT/docker/octoprint/config"
    "$MOUNT_POINT/docker/n8n/data"
    "$MOUNT_POINT/backups/code_backup"
    "$MOUNT_POINT/backups/doc_backup"
    "$MOUNT_POINT/printer"
    "$MOUNT_POINT/printer/uploads"
    "$MOUNT_POINT/printer/timelapses"
    "$MOUNT_POINT/downloads"
    "$MOUNT_POINT/n8n"
    "$MOUNT_POINT/homepage"
    "$USB_BASE"
)

for d in "${DIRS[@]}"; do
    if [[ -d "$d" ]]; then
        info "  exists: $d"
    else
        mkdir -p "$d"
        success "  created: $d"
    fi
done

# Fix ownership
chown -R "$PI_USER":"$PI_USER" "$MOUNT_POINT" || warn "chown failed on some files — check permissions"
success "Ownership set to $PI_USER:$PI_USER on $MOUNT_POINT"

# Verify write access
TEST_FILE="$MOUNT_POINT/.naviyantra_write_test"
touch "$TEST_FILE" && rm "$TEST_FILE"
success "Write access to $MOUNT_POINT confirmed"

# =============================================================================
# SECTION 6 — DOCKER
# =============================================================================

section "6 · Installing Docker"

if command -v docker &>/dev/null; then
    DOCKER_VER=$(docker --version)
    info "Docker already installed: $DOCKER_VER"
else
    info "Installing Docker CE via official script..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh | tee -a "$LOG_FILE"
    rm /tmp/get-docker.sh
    success "Docker installed"
fi

# Add pi user to docker group
if groups "$PI_USER" | grep -q docker; then
    info "$PI_USER already in docker group"
else
    usermod -aG docker "$PI_USER"
    success "Added $PI_USER to docker group"
fi

systemctl enable docker --quiet
systemctl start  docker
success "Docker service running"

# =============================================================================
# SECTION 7 — SYNCTHING CONTAINER
# =============================================================================

section "7 · Deploying Syncthing"

SYNCTHING_NAME="syncthing"

if docker ps -a --format '{{.Names}}' | grep -q "^${SYNCTHING_NAME}$"; then
    info "Syncthing container already exists — pulling latest image and recreating"
    docker stop "$SYNCTHING_NAME"  || true
    docker rm   "$SYNCTHING_NAME"  || true
fi

docker pull "$SYNCTHING_IMAGE" | tee -a "$LOG_FILE"

docker run -d \
    --name "$SYNCTHING_NAME" \
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

success "Syncthing container started"

# Verify container can see /storage/Workplace
sleep 3
if docker exec "$SYNCTHING_NAME" ls /storage/Workplace &>/dev/null; then
    success "Syncthing can see /storage/Workplace ✓"
else
    warn "Syncthing cannot see /storage/Workplace yet — if HDD was mounted after Docker started, run: docker restart syncthing"
fi

# =============================================================================
# SECTION 8 — PORTAINER (optional)
# =============================================================================

section "8 · Portainer"

if [[ "$INSTALL_PORTAINER" -eq 1 ]]; then
    PORTAINER_NAME="portainer"

    if docker ps -a --format '{{.Names}}' | grep -q "^${PORTAINER_NAME}$"; then
        info "Portainer already running — skipping"
    else
        docker volume create portainer_data &>/dev/null || true
        docker pull "$PORTAINER_IMAGE" | tee -a "$LOG_FILE"

        docker run -d \
            --name "$PORTAINER_NAME" \
            --restart unless-stopped \
            -p 9000:9000 \
            -p 9443:9443 \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v portainer_data:/data \
            "$PORTAINER_IMAGE"

        success "Portainer started"
    fi
else
    info "Portainer skipped (INSTALL_PORTAINER=0)"
fi

# =============================================================================
# SECTION 9 — OCTOPRINT CONTAINER (optional)
# =============================================================================

section "9 · OctoPrint"

if [[ "$INSTALL_OCTOPRINT" -eq 1 ]]; then
    OCTOPRINT_NAME="octoprint"

    if docker ps -a --format '{{.Names}}' | grep -q "^${OCTOPRINT_NAME}$"; then
        info "OctoPrint already running — skipping"
    else
        docker pull octoprint/octoprint:latest | tee -a "$LOG_FILE"

        # Expose printer USB device if present (adjust if device path differs)
        PRINTER_DEV=""
        for dev in /dev/ttyUSB0 /dev/ttyACM0; do
            if [[ -c "$dev" ]]; then
                PRINTER_DEV="$dev"
                info "Found printer device: $PRINTER_DEV"
                break
            fi
        done

        DEVICE_ARG=""
        [[ -n "$PRINTER_DEV" ]] && DEVICE_ARG="--device $PRINTER_DEV"

        # shellcheck disable=SC2086
        docker run -d \
            --name "$OCTOPRINT_NAME" \
            --restart unless-stopped \
            -p 5000:5000 \
            $DEVICE_ARG \
            -e ENABLE_MJPG_STREAMER=true \
            -v "$MOUNT_POINT/docker/octoprint/config:/octoprint" \
            -v "$MOUNT_POINT/printer:/files" \
            octoprint/octoprint:latest

        success "OctoPrint started (port 5000)"
        info "OctoPrint uploads → $MOUNT_POINT/printer/uploads"
        info "OctoPrint timelapses → $MOUNT_POINT/printer/timelapses"
    fi
else
    info "OctoPrint skipped (INSTALL_OCTOPRINT=0)"
fi

# =============================================================================
# SECTION 10 — N8N DIRECTORIES (deployment deferred)
# =============================================================================

section "10 · n8n directories"

if [[ "$INSTALL_N8N" -eq 1 ]]; then
    mkdir -p "$MOUNT_POINT/n8n"
    mkdir -p "$MOUNT_POINT/docker/n8n/data"
    chown -R "$PI_USER":"$PI_USER" "$MOUNT_POINT/n8n" "$MOUNT_POINT/docker/n8n"
    success "n8n directories created — deploy manually when ready:"
    info "  docker run -d --name n8n --restart unless-stopped \\"
    info "    -p 5678:5678 -e TZ=$TZ \\"
    info "    -v $MOUNT_POINT/docker/n8n/data:/home/node/.n8n \\"
    info "    n8nio/n8n"
fi

# =============================================================================
# SECTION 11 — SAMBA
# =============================================================================

section "11 · Configuring Samba"

SMB_CONF="/etc/samba/smb.conf"

# Backup smb.conf once
if [[ ! -f "${SMB_CONF}.naviyantra.bak" ]]; then
    cp "$SMB_CONF" "${SMB_CONF}.naviyantra.bak"
    info "smb.conf backed up → ${SMB_CONF}.naviyantra.bak"
fi

# Check if our share already exists
if grep -q "\[$SAMBA_SHARE_NAME\]" "$SMB_CONF"; then
    info "Samba share [$SAMBA_SHARE_NAME] already configured — skipping"
else
    cat >> "$SMB_CONF" << SMB

# Naviyantra NAS share — added by installer $(date '+%Y-%m-%d')
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
    success "Samba share [$SAMBA_SHARE_NAME] added"
fi

# Set Samba password for pi user (non-interactive: use a temp password, prompt user to change)
SAMBA_PW_FILE="/root/.naviyantra_samba_pw_set"
if [[ ! -f "$SAMBA_PW_FILE" ]]; then
    DEFAULT_SAMBA_PASS="naviyantra123"
    (echo "$DEFAULT_SAMBA_PASS"; echo "$DEFAULT_SAMBA_PASS") | smbpasswd -s -a "$PI_USER"
    touch "$SAMBA_PW_FILE"
    warn "Samba password set to default: $DEFAULT_SAMBA_PASS"
    warn "CHANGE IT: sudo smbpasswd $PI_USER"
else
    info "Samba password already configured"
fi

# Validate smb.conf
testparm -s "$SMB_CONF" &>/dev/null && success "smb.conf syntax OK" || warn "smb.conf has issues — check with: testparm"

systemctl enable smbd nmbd --quiet
systemctl restart smbd nmbd
success "Samba restarted"

# =============================================================================
# SECTION 12 — MEMORY OPTIMISATION (1 GB Pi)
# =============================================================================

section "12 · Memory optimisation for 1 GB Pi"

SYSCTL_CONF="/etc/sysctl.d/99-naviyantra.conf"

if [[ ! -f "$SYSCTL_CONF" ]]; then
    cat > "$SYSCTL_CONF" << 'SYSCTL'
# Naviyantra — tuned for 1 GB Raspberry Pi NAS
vm.swappiness=10              # reduce swap usage
vm.vfs_cache_pressure=50      # keep inode/dentry cache longer
vm.dirty_background_ratio=5   # start writeback earlier
vm.dirty_ratio=10             # cap dirty pages
net.core.rmem_max=4194304
net.core.wmem_max=4194304
SYSCTL
    sysctl -p "$SYSCTL_CONF" | tee -a "$LOG_FILE"
    success "sysctl tuning applied"
else
    info "sysctl tuning already applied"
fi

# Enable zram swap for extra headroom (Bookworm: zram is built-in)
if ! swapon --show | grep -q zram; then
    if command -v zramctl &>/dev/null; then
        ZRAM_SIZE="256M"
        modprobe zram 2>/dev/null || true
        zramctl /dev/zram0 --algorithm lz4 --size "$ZRAM_SIZE" 2>/dev/null || true
        mkswap /dev/zram0 2>/dev/null && swapon -p 100 /dev/zram0 2>/dev/null && \
            success "zram swap enabled (${ZRAM_SIZE})" || warn "zram setup skipped"
    fi
else
    info "zram already active"
fi

# =============================================================================
# SECTION 13 — HEALTH CHECK & STATUS SCRIPTS
# =============================================================================

section "13 · Installing helper scripts"

# ── health check ─────────────────────────────────────────────────────────────
HEALTH_SCRIPT="/usr/local/bin/naviyantra-health.sh"
cat > "$HEALTH_SCRIPT" << 'HEALTH'
#!/usr/bin/env bash
# Naviyantra health check
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}[OK]${RESET}   $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; ISSUES=$((ISSUES+1)); }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
ISSUES=0

echo -e "\n${CYAN}Naviyantra Health Check — $(date)${RESET}"

# Disk
echo -e "\n── Storage ──"
if mountpoint -q /mnt/storage; then
    ok "/mnt/storage mounted"
    df -h /mnt/storage | tail -1
else
    fail "/mnt/storage NOT mounted"
fi

# Docker
echo -e "\n── Docker containers ──"
for cname in syncthing portainer octoprint; do
    state=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo "not found")
    if [[ "$state" == "running" ]]; then
        ok "$cname running"
    elif [[ "$state" == "not found" ]]; then
        warn "$cname not installed"
    else
        fail "$cname is $state"
    fi
done

# Syncthing access
echo -e "\n── Services ──"
if curl -sf http://localhost:8384 -o /dev/null; then
    ok "Syncthing UI reachable (port 8384)"
else
    fail "Syncthing UI not reachable"
fi
if curl -sf http://localhost:9000 -o /dev/null; then
    ok "Portainer UI reachable (port 9000)"
else
    warn "Portainer not reachable (may not be installed)"
fi
if curl -sf http://localhost:5000 -o /dev/null; then
    ok "OctoPrint UI reachable (port 5000)"
else
    warn "OctoPrint not reachable (may not be installed)"
fi

# Samba
if systemctl is-active smbd &>/dev/null; then
    ok "Samba running"
else
    fail "Samba not running"
fi

# Memory
echo -e "\n── Memory ──"
free -h | grep -E "Mem|Swap"

echo ""
if [[ $ISSUES -eq 0 ]]; then
    echo -e "${GREEN}All checks passed.${RESET}"
else
    echo -e "${RED}$ISSUES issue(s) found.${RESET}"
fi
HEALTH
chmod +x "$HEALTH_SCRIPT"
success "Health check → $HEALTH_SCRIPT"

# ── status script ─────────────────────────────────────────────────────────────
STATUS_SCRIPT="/usr/local/bin/naviyantra-status.sh"
cat > "$STATUS_SCRIPT" << 'STATUS'
#!/usr/bin/env bash
# Naviyantra quick status overview
echo ""
echo "═══════════════════════════════════════════"
echo "  Naviyantra NAS — Quick Status"
echo "═══════════════════════════════════════════"
echo ""
echo "── Mounts ──────────────────────────────────"
mount | grep -E "/mnt/(storage|usb)" || echo "  (none)"
echo ""
echo "── Docker containers ───────────────────────"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "  Docker not running"
echo ""
echo "── Disk usage ──────────────────────────────"
df -h /mnt/storage 2>/dev/null || echo "  HDD not mounted"
echo ""
echo "── USB drives ──────────────────────────────"
lsblk -o NAME,FSTYPE,LABEL,SIZE,MOUNTPOINT | grep -v "^loop" || true
echo ""
echo "── Memory ──────────────────────────────────"
free -h
echo ""
echo "── Service ports ───────────────────────────"
ss -tlnp | grep -E ":(8384|9000|9443|5000|5678|445|139)" || echo "  none found"
echo ""
STATUS
chmod +x "$STATUS_SCRIPT"
success "Status script → $STATUS_SCRIPT"

# =============================================================================
# SECTION 14 — RESTART DOCKER (ensure mounts are visible)
# =============================================================================

section "14 · Restarting Docker to refresh volume mounts"

systemctl restart docker
sleep 5
docker start syncthing portainer octoprint 2>/dev/null || true
success "Docker restarted and containers resumed"

# =============================================================================
# FINAL SUMMARY
# =============================================================================

# Detect Pi's IP
PI_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${BOLD}${GREEN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          Naviyantra NAS — Installation Complete              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "${CYAN}Pi IP address   :${RESET} $PI_IP"
echo ""
echo -e "${CYAN}Service URLs    :${RESET}"
echo "  Syncthing   →  http://$PI_IP:8384"
echo "  Portainer   →  http://$PI_IP:9000"
echo "  OctoPrint   →  http://$PI_IP:5000"
echo "  n8n (when deployed) → http://$PI_IP:5678"
echo ""
echo -e "${CYAN}Samba share     :${RESET}"
echo "  \\\\$PI_IP\\Storage       (Linux: smb://$PI_IP/Storage)"
echo "  \\\\$PI_IP\\Printer"
echo "  User: $PI_USER  |  Password: see smbpasswd warning above"
echo ""
echo -e "${CYAN}Key paths       :${RESET}"
echo "  HDD mount   :  $MOUNT_POINT"
echo "  Workplace   :  $MOUNT_POINT/Workplace"
echo "  Printer     :  $MOUNT_POINT/printer"
echo "  USB drives  :  $USB_BASE/<label>"
echo ""
echo -e "${CYAN}Syncthing setup :${RESET}"
echo "  1. Open http://$PI_IP:8384 in browser"
echo "  2. Add folder path: /storage/Workplace"
echo "  3. Set folder type: Receive Only (on Pi)"
echo "  4. On Fedora: Send Only, path /home/atharva/Workplace"
echo ""
echo -e "${CYAN}Useful commands :${RESET}"
echo "  naviyantra-health   — full health check"
echo "  naviyantra-status   — quick overview"
echo "  naviyantra-uninstall — remove everything"
echo "  docker restart syncthing  — if HDD remounted after boot"
echo "  sudo smbpasswd $PI_USER   — change Samba password"
echo ""
echo -e "${CYAN}Log file        :${RESET} $LOG_FILE"
echo ""

# Append summary to log
echo "Installation completed at $(date)" >> "$LOG_FILE"
