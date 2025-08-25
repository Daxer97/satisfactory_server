#!/usr/bin/env bash
#=================================================
# Filename:        proxmox-ubuntu-satisfactory-server.sh
# Description:     Automated Ubuntu VM creation on Proxmox, installation of SteamCMD,
#                  Satisfactory dedicated server setup, systemd service configuration,
#                  and migration of single-player save files.
# Author:          Daxer97
# Version:         1.0.0
# License:         None
# Proxmox-Helper-Script: true
#=================================================

set -euo pipefail

#
# --- USER CONFIGURATION SECTION ---
#

VMID=9025                              # Change as needed; must be unique for your Proxmox host
VM_NAME="satisfactory-server"          # Friendly VM name
MEMORY=8192                            # RAM in MB (min 8GB recommended)
CORES=4                                # CPU cores (adjust based on host)
DISK_SIZE=50G                          # Disk size for VM
BRIDGE="vmbr0"                         # Network bridge for the VM
STORAGE="local-lvm"                    # Proxmox storage for VM disk/cloud-init
ISO_STORAGE="local"                    # Storage location for ISOs/template images

UBUNTU_CLOUD_IMG="jammy-server-cloudimg-amd64.img"
UBUNTU_CLOUD_URL="https://cloud-images.ubuntu.com/jammy/current/${UBUNTU_CLOUD_IMG}"

SSH_PUBLIC_KEY="${HOME}/.ssh/id_rsa.pub" # Change if using a different SSH key

SAT_USER="steam"
SAT_HOME="/home/${SAT_USER}"
SAT_SERVERDIR="${SAT_HOME}/SatisfactoryDedicatedServer"
SAT_SAVEDIR="${SAT_HOME}/.config/Epic/FactoryGame/Saved/SaveGames/server"

# Enter the path to your single-player save files (optional, may prompt user later)
SAVED_GAME_SRC="" # e.g., "/home/myuser/SatisfactorySaves/"

# ===== CREATE CLOUD-INIT USER-DATA =====
# This will install qemu-guest-agent on first boot
SSH_PUBLIC_KEY_1=$(<"$SSH_PUBLIC_KEY")
CLOUDINIT_SNIPPET="/var/lib/vz/snippets/${VM_NAME}-cloudinit.yaml"

cat > "$CLOUDINIT_SNIPPET" <<EOF
#cloud-config
package_update: false
packages:
  - qemu-guest-agent
ssh_authorized_keys:
  - ${SSH_PUBLIC_KEY_1}
runcmd:
  - systemctl enable --now qemu-guest-agent
EOF

#
# --- END USER CONFIGURATION SECTION ---
#

# --- 1. Check and Download Ubuntu Cloud Image if Absent ---

echo "==> [1/8] Checking for Ubuntu cloud image..."

if [ ! -s "/var/lib/vz/template/iso/${UBUNTU_CLOUD_IMG}" ]; then
  echo "Ubuntu image not found or empty, downloading..."
  wget -O "/var/lib/vz/template/iso/${UBUNTU_CLOUD_IMG}" "${UBUNTU_CLOUD_URL}"
else
  echo "Ubuntu image found and valid."
fi

# --- 2. Create the Proxmox VM ---

echo "==> [2/8] Creating Proxmox VM ${VMID}..."

if qm list | awk '{print $1}' | grep -q "^${VMID}$"; then
  echo "VM ID ${VMID} already exists. Refusing to overwrite."
  exit 1
fi

qm create ${VMID} \
  --name "${VM_NAME}" \
  --memory "${MEMORY}" \
  --cores "${CORES}" \
  --net0 virtio,bridge="${BRIDGE}" \
  --agent enabled=1 \
  --bios ovmf --machine q35 \
  --serial0 socket --vga serial0 \
  --ostype l26

# --- Import the Ubuntu cloud image as VM disk ---
echo "==> [2.1/8] Importing Ubuntu disk image..."

qm importdisk ${VMID} "/var/lib/vz/template/iso/${UBUNTU_CLOUD_IMG}" "${STORAGE}"

qm set ${VMID} \
  --scsihw virtio-scsi-pci \
  --scsi0 "${STORAGE}:vm-${VMID}-disk-0" \
  --boot order=scsi0 \
  --ide2 "${STORAGE}:cloudinit" \
  --ipconfig0 ip=dhcp \
  --sshkeys "${SSH_PUBLIC_KEY}" \
  --cicustom "user=local:snippets/${VM_NAME}-cloudinit.yaml"
  
qm resize ${VMID} scsi0 ${DISK_SIZE}

# --- 3. Start VM and Wait for Provisioning (Cloud-Init) ---

echo "==> [3/8] Starting VM for cloud-init provisioning..."
qm start ${VMID}

echo "Waiting 60 second for machine to boot"
sleep 60

# Perform a ping to get the IP address from DHCP
qm guest exec ${VMID} ping 192.168.1.199

VM_IP=$(qm guest cmd ${VMID} network-get-interfaces \
  | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
  | grep -Ev '^127\.' \
  | grep -Ev '\.199$')
    
if [ -n "$VM_IP" ]; then
    echo "Detected VM IP: $VM_IP"
else
    echo "Could not detect VM IP"
fi

# --- 4. SSH and Provision SteamCMD/Satisfactory Server ---

# Generate an SSH provisioning script to copy in and execute
PROVISION_SCRIPT=$(mktemp)

cat > "${PROVISION_SCRIPT}" <<EOF
#!/bin/bash
# Satisfactory Dedicated Server Automated Installer
# Designed for Ubuntu (recommended 20.04+), Debian 11+, or compatible derivatives.

set -euo pipefail

# ---- Configurable Variables ----
STEAM_USER="steam"
SERVER_DIR="/home/$STEAM_USER/SatisfactoryDedicatedServer"
MOTD_MESSAGE="Welcome to your Satisfactory Dedicated Server! Happy Building!"
LOG_FILE="/var/log/satisfactory_server_setup.log"
# Satisfactory Server default ports
UDP_PORTS=(7777 15000 15777)

# ---- Logging Utility ----
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') : $*" | tee -a "$LOG_FILE"
}

# ---- Step 1: Ensure script is run as root ----
if [ "$(id -u)" -ne 0 ]; then
  echo "Please run this script as root (sudo)."
  exit 1
fi

log "Started Satisfactory server setup."

# ---- Step 2: Update system and install basic tools ----
log "Updating system packages and installing essentials."
apt-get update -y
apt-get upgrade -y
apt-get install -y software-properties-common apt-transport-https curl ufw sudo

# ---- Step 3: Enable 32-bit (i386) architecture if not already present ----
if ! dpkg --print-foreign-architectures | grep -qw i386; then
  log "Enabling i386 (32-bit) architecture support."
  dpkg --add-architecture i386
  apt-get update -y
else
  log "i386 architecture already enabled."
fi

# ---- Step 4: Add multiverse/non-free repositories (idempotent) ----
# Ubuntu: multiverse; Debian: non-free
os_release=$(grep -oE '^ID=[a-z]+' /etc/os-release | cut -d'=' -f2)
if [ "$os_release" = "ubuntu" ]; then
  log "Adding multiverse repo (Ubuntu)."
  add-apt-repository -y multiverse || true
elif [ "$os_release" = "debian" ]; then
  log "Ensuring 'non-free' is in sources.list (Debian)."
  if ! grep -qE "non-free" /etc/apt/sources.list; then
    sed -i 's/ main$/ main contrib non-free/' /etc/apt/sources.list
    apt-get update -y
  fi
fi

apt-get update -y

# ---- Step 5: Install all dependencies (idempotent and modernized) ----
log "Installing required 32-bit libraries and dependencies for SteamCMD."
# Replace old lib32gcc1 with lib32gcc-s1, add lib32z1 for compression support, and libc6-i386 for compatibility.
apt-get install -y lib32gcc-s1 lib32stdc++6 lib32z1 libc6-i386

# ---- Step 6: Install SteamCMD via apt (avoid manual .deb to prevent dpkg errors) ----
log "Installing SteamCMD from the official repositories."
apt-get install -y steamcmd

# ---- Step 7: User and Directory Setup (idempotent) ----
if ! id "$STEAM_USER" &>/dev/null; then
  log "Creating user $STEAM_USER."
  useradd -m -s /bin/bash "$STEAM_USER"
fi

# Tighten home dir permissions for security best practices
chmod 700 "/home/$STEAM_USER"

# Create or verify Satisfactory server directory
install -d -m 755 "$SERVER_DIR" -o "$STEAM_USER" -g "$STEAM_USER"
log "Ensured Satisfactory server directory: $SERVER_DIR"

# ---- Step 8: Install/Update the Dedicated Server via SteamCMD ----
log "Installing or updating Satisfactory Dedicated Server (AppID 1690800) using SteamCMD..."
sudo -u "$STEAM_USER" /usr/games/steamcmd +login anonymous +force_install_dir "$SERVER_DIR" +app_update 1690800 validate +quit

# ---- Step 9: Systemd Service Setup ----
SYSTEMD_UNIT="/etc/systemd/system/satisfactory.service"
log "Configuring systemd service at $SYSTEMD_UNIT"

cat > "$SYSTEMD_UNIT" <<EOL
[Unit]
Description=Satisfactory Dedicated Server
Wants=network-online.target
After=syslog.target network.target nss-lookup.target network-online.target

[Service]
Type=simple
User=$STEAM_USER
Group=$STEAM_USER
Environment="LD_LIBRARY_PATH=$SERVER_DIR/linux64"
ExecStartPre=/usr/games/steamcmd +login anonymous +force_install_dir "$SERVER_DIR" +app_update 1690800 validate +quit
ExecStart=$SERVER_DIR/FactoryServer.sh -ServerQueryPort=15777 -BeaconPort=15000 -Port=7777 -log -unattended -multihome=0.0.0.0
WorkingDirectory=$SERVER_DIR
Restart=on-failure
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOL

# Idempotently reload systemd and enable the service
systemctl daemon-reload
systemctl enable satisfactory
systemctl restart satisfactory
log "Satisfactory systemd service enabled and started."

# ---- Step 10: UFW Firewall Configuration ----
log "Configuring UFW firewall rules."
ufw allow 22/tcp comment 'SSH'
for port in "${UDP_PORTS[@]}"; do
  ufw allow "$port/udp" comment "Satisfactory Server UDP port $port"
done
ufw --force enable

log "UFW rules for Satisfactory and SSH applied."

# ---- Step 11: /etc/motd Automation ----
MOTD_SCRIPT="/etc/update-motd.d/99-satisfactory"
if [ ! -f "$MOTD_SCRIPT" ]; then
  log "Adding custom Satisfactory message to MOTD."
  echo -e "#!/bin/sh\necho \"$MOTD_MESSAGE\"" > "$MOTD_SCRIPT"
  chmod +x "$MOTD_SCRIPT"
fi

# ---- Script Completion ----
log "All steps completed! Your Satisfactory Dedicated Server should now be running and accessible."
echo "Check with: systemctl status satisfactory"
echo "Default ports: Query=15777 UDP, Beacon=15000 UDP, Game=7777 UDP"
echo "Review /var/log/satisfactory_server_setup.log for a full installation record."
EOF

chmod +x "${PROVISION_SCRIPT}"

echo "==> [4/8] Transferring and executing in-VM provisioning script to install SteamCMD and Satisfactory..."

# Use sshpass if passwordless SSH is not set up, but prefer SSH key
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${PROVISION_SCRIPT}" ubuntu@"${VM_IP}":/tmp/provsat.sh
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"${VM_IP}" "sudo bash /tmp/provsat.sh"

# Cleanup
rm -f "${PROVISION_SCRIPT}"

echo "==> [5/8] Server installation complete!"

# --- 5. Optional: Transfer Saved Game Files ---

if [ -n "${SAVED_GAME_SRC}" ]; then
  echo "==> [6/8] Transferring save files from '${SAVED_GAME_SRC}'..."
  # SCP all .sav files to the server's save directory
  scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${SAVED_GAME_SRC}"/*.sav ubuntu@"${VM_IP}":/tmp/
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"${VM_IP}" "sudo mv /tmp/*.sav ${SAT_SAVEDIR} && sudo chown ${SAT_USER}:${SAT_USER} ${SAT_SAVEDIR}/*.sav"
  echo "==> Save files uploaded."
else
  echo "==> To copy your Satisfactory single-player save files later:"
  echo "   scp /path/to/your/save.sav ubuntu@${VM_IP}:/tmp/"
  echo "   ssh ubuntu@${VM_IP} \"sudo mv /tmp/save.sav ${SAT_SAVEDIR}/ && sudo chown ${SAT_USER}:${SAT_USER} ${SAT_SAVEDIR}/save.sav\""
fi

echo "==> [7/8] Finalizing..."

# --- 6. Display Service and Access Instructions ---

echo "==> Your Satisfactory Server is deployed and running as a systemd service."
echo "   To check status:"
echo "     ssh ubuntu@${VM_IP} 'systemctl status satisfactory'"
echo "   To restart:"
echo "     ssh ubuntu@${VM_IP} 'sudo systemctl restart satisfactory'"
echo
echo "Game files"
echo "   ${SAT_SERVERDIR}"
echo "==> Save file directory:"
echo "   ${SAT_SAVEDIR}"

echo
echo "==> [8/8] Setup complete!"
echo "   Claim the server via in-game Server Manager first!"
echo "   Set server/admin passwords and session via the Satisfactory client."
echo
exit 0
