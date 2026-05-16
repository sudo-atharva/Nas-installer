# Naviyantra NAS — Setup Guide

**Raspberry Pi · Btrfs HDD · Syncthing · Samba · Docker**

---

## Architecture Overview

```
Internet
    │
    ▼
Home Router (192.168.31.1)
    ├── Fedora Workstation   /home/atharva/Workplace  ←──┐
    │                                                     │ Syncthing
    └── Raspberry Pi (static IP)                          │
            ├── /mnt/storage         (BACKUP_HDD, btrfs) │
            │       ├── Workplace  ◄─────────────────────┘
            │       ├── printer/   ← OctoPrint files
            │       ├── downloads/
            │       └── n8n/
            ├── Docker
            │       ├── syncthing   :8384
            │       ├── portainer   :9000
            │       ├── octoprint   :5000
            │       └── n8n         :5678 (deploy manually)
            └── Samba share → \\<pi-ip>\Storage
```

---

## Directory Map

| Path | Purpose |
|------|---------|
| `/mnt/storage` | HDD root mount point |
| `/mnt/storage/Workplace` | Syncthing sync folder |
| `/mnt/storage/printer` | OctoPrint uploads & timelapses |
| `/mnt/storage/printer/uploads` | Gcode files from OctoPrint |
| `/mnt/storage/printer/timelapses` | Timelapse videos |
| `/mnt/storage/downloads` | General downloads |
| `/mnt/storage/n8n` | n8n workflow data |
| `/mnt/storage/backups/code_backup` | Code backups |
| `/mnt/storage/backups/doc_backup` | Document backups |
| `/mnt/storage/docker/syncthing/config` | Syncthing config |
| `/mnt/storage/docker/portainer/data` | Portainer data |
| `/mnt/storage/docker/octoprint/config` | OctoPrint config |
| `/mnt/usb/<label>` | Auto-mounted USB drives |

---

## Installation

### Prerequisites

- Raspberry Pi OS 64-bit Lite (Bookworm recommended)
- External HDD formatted as **btrfs** with label **BACKUP_HDD**
- Pi connected to router via Ethernet
- Internet access from Pi

### Run installer

```bash
# Copy to Pi
scp install_naviyantra.sh pi@<pi-ip>:~/

# SSH in and run
ssh pi@<pi-ip>
chmod +x install_naviyantra.sh
sudo bash install_naviyantra.sh
```

The installer is **idempotent** — safe to re-run. It skips steps already completed.

---

## Giving Pi a Static IP

After the Pi gets a DHCP address from your router, lock it in:

```bash
# On the Pi
sudo nmcli con mod "netplan-eth0" \
    ipv4.addresses 192.168.31.125/24 \
    ipv4.gateway 192.168.31.1 \
    ipv4.dns 192.168.31.1 \
    ipv4.method manual
sudo nmcli con up "netplan-eth0" &
```

Or reserve the Pi's MAC address in your router's DHCP settings (preferred — no SSH drop risk).  
Pi MAC: `d8:3a:dd:a2:e4:d0`

---

## Syncthing Setup

### On the Pi (Receive Only)

1. Open `http://<pi-ip>:8384` in browser
2. Skip the "Set admin password" prompt or set one
3. Click **Add Folder**
   - Folder Label: `Workplace`
   - Folder Path: `/storage/Workplace`
   - Folder Type: **Receive Only**
4. Note the Device ID from **Actions → Show ID**

### On Fedora (Send Only)

```bash
# Install Syncthing
sudo dnf install syncthing

# Start and enable
systemctl --user enable --now syncthing

# Open UI
xdg-open http://localhost:8384
```

1. Open `http://localhost:8384`
2. Add folder:
   - Path: `/home/atharva/Workplace`
   - Folder Type: **Send Only**
3. Add device using Pi's Device ID
4. Share the folder with the Pi device

---

## Samba Access

### From Fedora (Files / Nautilus)

Press `Ctrl+L` and enter:
```
smb://<pi-ip>/Storage
```

### Mount permanently on Fedora

```bash
sudo mkdir -p /mnt/nas
echo "//<pi-ip>/Storage  /mnt/nas  cifs  credentials=/etc/samba/naviyantra-creds,uid=1000,gid=1000,iocharset=utf8  0  0" | sudo tee -a /etc/fstab
```

Create credentials file:
```bash
sudo nano /etc/samba/naviyantra-creds
```
```
username=pi
password=naviyantra123
```
```bash
sudo chmod 600 /etc/samba/naviyantra-creds
sudo mount -a
```

### Change Samba password

```bash
sudo smbpasswd pi
```

---

## OctoPrint — Files on HDD

OctoPrint is configured with `/mnt/storage/printer` mounted as `/files` inside the container.

To make OctoPrint save uploads to the HDD, in OctoPrint Settings:
- **Features → Upload folder** → set to `/files/uploads`
- **Plugins → Octolapse** (if installed) → timelapse folder → `/files/timelapses`

Files are then visible via Samba at `\\<pi-ip>\Printer`.

---

## USB Drive Automount

USB drives are automatically mounted to `/mnt/usb/<label>` when plugged in, using the udev rule installed by the script. Supports NTFS, exFAT, FAT32, ext4, and btrfs.

To check what is mounted:
```bash
lsblk -o NAME,FSTYPE,LABEL,SIZE,MOUNTPOINT
ls /mnt/usb/
```

---

## n8n Deployment (when ready)

```bash
docker run -d \
  --name n8n \
  --restart unless-stopped \
  -p 5678:5678 \
  -e TZ=Asia/Kolkata \
  -v /mnt/storage/docker/n8n/data:/home/node/.n8n \
  n8nio/n8n
```

Access at `http://<pi-ip>:5678`

---

## Common Troubleshooting

### Syncthing can't see /storage/Workplace

HDD was mounted after Docker started. Fix:
```bash
docker restart syncthing
docker exec syncthing ls /storage/Workplace
```

### Pi gets wrong IP (10.42.0.x instead of 192.168.31.x)

Your Fedora machine is sharing its connection. On Fedora:
```bash
sudo nmcli con mod "Wired connection 1" ipv4.method auto
sudo nmcli con up "Wired connection 1"
```
Then reboot the Pi.

### Samba share not accessible

```bash
sudo systemctl restart smbd nmbd
testparm                      # check config
sudo smbpasswd pi             # reset password
```

### Docker container not starting after reboot

If HDD isn't mounted before Docker starts:
```bash
sudo systemctl restart docker
docker start syncthing portainer octoprint
```

To fix boot order, ensure fstab has the `nofail` option and add a systemd override:
```bash
sudo systemctl edit docker
```
Add:
```ini
[Unit]
After=mnt-storage.mount
Wants=mnt-storage.mount
```

### Check installer log
```bash
cat /var/log/naviyantra-setup.log
```

---

## Useful Commands

```bash
# Status overview
naviyantra-status

# Full health check
naviyantra-health

# Container logs
docker logs syncthing --tail 50
docker logs octoprint --tail 50

# Restart all containers
docker restart syncthing portainer octoprint

# Disk usage breakdown
btrfs filesystem usage /mnt/storage

# SMART health of HDD
sudo smartctl -H /dev/sda

# Samba connected users
smbstatus

# Check open ports
ss -tlnp

# Memory usage by process
ps aux --sort=-%mem | head -15
```

---

## Uninstall

```bash
sudo bash uninstall_naviyantra.sh
```

Your data on `/mnt/storage` is **never deleted** by the uninstaller.
