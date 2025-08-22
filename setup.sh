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
  --memory ${MEMORY} \
  --cores ${CORES} \
  --net0 virtio,bridge=${BRIDGE} \
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
  
qm resize ${VMID} scsi0 ${DISK_SIZE}

# --- 3. Start VM and Wait for Provisioning (Cloud-Init) ---

echo "==> [3/8] Starting VM for cloud-init provisioning..."
qm start ${VMID}

echo "==> Waiting 180 seconds for cloud-init to apply basic config (SSH, net)..."

# Wait for QEMU Guest Agent to respond
for i in {1..30}; do
    if qm guest exec ${VMID} -- ls / >/dev/null 2>&1; then
        echo "Guest agent is up"
        break
    fi
    echo "Waiting for guest agent..."
    sleep 5
done


# Try to find the VM IP using qemu-guest-agent
VM_IP=""
for i in {1..10}; do
  VM_IP=$(qm guest cmd ${VMID} network-get-interfaces | grep -Eo '\"ip-address\":\s*\"[0-9.]+\"' | grep -v '127.0.0.1' | grep -Eo '[0-9.]+')
  if [ -n "$VM_IP" ]; then
    break
  fi
  sleep 6
done

if [ -z "$VM_IP" ]; then
  echo "Could not automatically determine VM IP. You must manually SSH to continue."
  echo "Consider running: 'qm guest cmd ${VMID} network-get-interfaces' to find IP."
  exit 1
fi

echo "==> Detected VM IP: ${VM_IP}"

# --- 4. SSH and Provision SteamCMD/Satisfactory Server ---

# Generate an SSH provisioning script to copy in and execute
PROVISION_SCRIPT=$(mktemp)

cat > "${PROVISION_SCRIPT}" <<EOF
#!/bin/bash
set -euo pipefail

# Ensure cloud-init finished
sleep 10

# 1. Create dedicated 'steam' user if not exists
if ! id "${SAT_USER}" &>/dev/null; then
  useradd -m -s /bin/bash ${SAT_USER}
fi

# 2. Install required dependencies
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y wget curl software-properties-common ca-certificates gnupg2 tmux lsof ufw sudo

# 3. Enable 32-bit architecture and install SteamCMD, libraries
dpkg --add-architecture i386
apt-get update
apt-get install -y lib32gcc-s1 lib32stdc++6 steamcmd

# 4. Allow 'steam' to run SteamCMD and adjust ownership
usermod -aG sudo ${SAT_USER}
mkdir -p ${SAT_SERVERDIR}

# 5. Install Satisfactory Dedicated Server with SteamCMD
sudo -u ${SAT_USER} /usr/games/steamcmd \
  +@sSteamCmdForcePlatformType linux \
  +force_install_dir ${SAT_SERVERDIR} \
  +login anonymous \
  +app_update 1690800 validate \
  +quit

# 6. Create systemd service for Satisfactory
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

# 7. Configure UFW for Satisfactory ports (optional, open)
ufw allow 7777
ufw allow 15000
ufw allow 15777
ufw --force enable

# 8. Create save directory, fix permissions
mkdir -p "${SAT_SAVEDIR}"
chown -R ${SAT_USER}:${SAT_USER} "${SAT_HOME}/.config"

# 9. Add "Buy me a Coffe header"
sudo sh -c 'echo "" >> /etc/motd'
sudo sh -c 'echo "💖 Support this project: https://www.paypal.me/daxernet" >> /etc/motd'
sudo sh -c 'echo "" >> /etc/motd'
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
echo "==> Game files location (on server):"
echo "   ${SAT_SERVERDIR}"
echo "==> Save file directory:"
echo "   ${SAT_SAVEDIR}"

echo
echo "==> [8/8] Setup complete!"
echo "   Claim the server via in-game Server Manager first!"
echo "   Set server/admin passwords and session via the Satisfactory client."
echo
echo "==> --- Script finished ---"
exit 0
