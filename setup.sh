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
set -euo pipefail

# ===== CONFIG =====
SAT_USER="${SAT_USER:-steam}"
SAT_SERVERDIR="${SAT_SERVERDIR:-/opt/satisfactory}"
SAT_HOME="/home/${SAT_USER}"
SAT_SAVEDIR="${SAT_SAVEDIR:-${SAT_HOME}/.config/Epic/FactoryGame/Saved/SaveGames/server}"

# ===== FUNCTIONS =====
log() { echo -e "\n[INFO] $*\n"; }
err() { echo -e "\n[ERROR] $*\n" >&2; }

install_with_retry() {
    # Guard against missing argument
    if [[ $# -lt 1 || -z "$1" ]]; then
        err "install_with_retry() called without a package name"
        return 1
    fi

    local pkg="$1"
    local retries=3
    local count=0

    until apt-get install -y "$pkg"; do
        count=$((count+1))
        if (( count >= retries )); then
            err "Failed to install $pkg after $retries attempts."
            return 1
        fi
        err "Installation of $pkg failed. Attempt $count/$retries. Fixing and retrying..."
        apt-get install -f -y || true
        dpkg --configure -a || true
        sleep 5
    done
}

# ===== MAIN =====

# Ensure cloud-init finished
sleep 10

# 1. Create dedicated 'steam' user if not exists
if ! id "${SAT_USER}" &>/dev/null; then
    log "Creating user ${SAT_USER}"
    useradd -m -s /bin/bash "${SAT_USER}"
fi

# 2. Install required dependencies
export DEBIAN_FRONTEND=noninteractive
log "Updating package lists"
apt-get update -y

log "Installing base dependencies"
apt-get install -y wget curl software-properties-common ca-certificates gnupg2 tmux lsof ufw sudo

# 3. Enable 32-bit architecture and install SteamCMD, libraries
log "Enabling 32-bit architecture"
dpkg --add-architecture i386
apt-get update -y

log "Installing 32-bit libraries"
install_with_retry "lib32gcc-s1"
install_with_retry "lib32stdc++6"

log "Installing SteamCMD"
install_with_retry "steamcmd"

# 4. Allow 'steam' to run SteamCMD and adjust ownership
log "Configuring user permissions"
usermod -aG sudo "${SAT_USER}"
mkdir -p "${SAT_SERVERDIR}"
chown -R "${SAT_USER}:${SAT_USER}" "${SAT_SERVERDIR}"

# 5. Install Satisfactory Dedicated Server with SteamCMD
log "Installing Satisfactory Dedicated Server"
sudo -u "${SAT_USER}" /usr/games/steamcmd \
  +@sSteamCmdForcePlatformType linux \
  +force_install_dir "${SAT_SERVERDIR}" \
  +login anonymous \
  +app_update 1690800 validate \
  +quit

# 6. Create systemd service for Satisfactory
log "Creating systemd service"
cat > /etc/systemd/system/satisfactory.service <<EOL
[Unit]
Description=Satisfactory Dedicated Server
Wants=network-online.target
After=network-online.target

[Service]
User=${SAT_USER}
Group=${SAT_USER}
Type=simple
Restart=on-failure
RestartSec=10
WorkingDirectory=${SAT_SERVERDIR}
ExecStartPre=/usr/games/steamcmd +@sSteamCmdForcePlatformType linux +force_install_dir ${SAT_SERVERDIR} +login anonymous +app_update 1690800 validate +quit
ExecStart=${SAT_SERVERDIR}/FactoryServer.sh -unattended -log -BeaconPort=15000 -ServerQueryPort=15777 -Port=7777 -multihome=0.0.0.0

[Install]
WantedBy=multi-user.target
EOL

systemctl daemon-reload
systemctl enable satisfactory
systemctl start satisfactory

# 7. Configure UFW for Satisfactory ports
log "Configuring firewall"
ufw allow 7777
ufw allow 15000
ufw allow 15777
ufw --force enable

# 8. Create save directory, fix permissions
log "Setting up save directory"
mkdir -p "${SAT_SAVEDIR}"
chown -R "${SAT_USER}:${SAT_USER}" "${SAT_HOME}/.config"

# 9. Add "Buy me a Coffee" header
log "Adding MOTD message"
{
    echo ""
    echo "💖 Support this project: https://www.paypal.me/daxernet"
    echo ""
} >> /etc/motd

log "Setup complete!"

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
