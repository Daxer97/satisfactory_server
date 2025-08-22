# Proxmox Satisfactory Dedicated Server Helper Script

---

## Overview

A robust and detailed README is the gateway to any successful GitHub project, especially those designed for public utility and community collaboration. This document serves as the user’s first point of contact with the repository, providing them with crucial understanding, smooth onboarding, and clear operational guidance. In this context, we present an exhaustive, beginner-friendly, and professionally structured README for the **Proxmox Satisfactory Server Helper Script** repository.

This script is designed as an all-in-one automation solution for deploying a dedicated [Satisfactory](https://satisfactorygame.com/) game server on an **Ubuntu virtual machine (VM)** created within a Proxmox Virtual Environment (PVE). It also supports streamlined import of single-player save files, allowing users to continue factory-building adventures with friends on their private server. The README below details every aspect needed to use, customize, maintain, and troubleshoot your server deployment.

---

## Table of Contents

## Purpose

The **Proxmox Satisfactory Helper Script** lets you:

- **Quickly deploy Satisfactory servers** inside an isolated Ubuntu VM on your Proxmox host with minimal manual intervention.
- **Automate the entire lifecycle**, from VM creation, OS provisioning, dependency installation, SteamCMD setup, Satisfactory server installation, and service management to including firewall and port configuration.
- **Optionally import single-player save games** to your dedicated server, making migration from solo play effortless.
- **Ensure best practices** by isolating the game server in its own environment, increasing reliability, security, and scalability.

This solution is aimed at both newcomers to Proxmox/gameserver management and advanced administrators seeking automation and repeatability.

---

## Features

- 🔹 **One-command deployment**: Fully automated setup via a single shell command.
- 🔹 **Idempotent execution**: Safe, repeatable runs—rerunning will not corrupt or duplicate VMs/servers.
- 🔹 **Systemd integration**: Server runs as a resilient service, auto-restarts, and updates on reboot.
- 🔹 **Save import feature**: Seamlessly import single-player or prior multiplayer saves.
- 🔹 **Secure defaults**: Runs in a non-root VM user context, recommends network firewalling, and sets auto-updating.
- 🔹 **Beginner safe**: Designed to be used with minimal technical background.
- 🔹 **Comprehensive troubleshooting and support documentation**.

---

## Prerequisites

Before using this script, please review and ensure you meet the following requirements.

| **Requirement**                                  | **Details & Recommendations**                                                              |
|--------------------------------------------------|--------------------------------------------------------------------------------------------|
| **Proxmox VE**                                  | Version 7.x or newer, admin access to the web UI or SSH shell.                             |
| **Proxmox Node**                                | Sufficient free resources (see below).                                                     |
| **User Privileges**                             | Root or sudo access to Proxmox host (to run the helper script).                            |
| **Internet Connectivity**                       | Both Proxmox node and VM must have outbound network access for downloads and updates.      |
| **VM Storage**                                 | At least 20 GB free space per server VM (OS + game files + headroom for saves/logs).       |
| **CPU/RAM**                                    | Min 4 CPU cores and **8 GB RAM** for small games, 16 GB RAM advised for larger saves/players. |
| **ISO Images**                                 | Ubuntu Server ISO (tested on Ubuntu 22.04 LTS or newer).                                   |
| **Ports open/forwarded**                        | UDP 7777, 15777, 15000 by default; update firewall/NAT policy as needed. |
| **Client access**                              | Main OS for management: Windows, macOS, or Linux with SSH capability.                      |
| **(Optional) Save File**                       | Local Satisfactory save file (usually `.sav`) for single-player import.                    |

**Note:** SSD/NVMe storage is **highly** recommended for best server performance and autosave reliability.

The table above outlines minimum recommended requirements based on [Satisfactory's official wiki](https://satisfactory.wiki.gg/wiki/Dedicated_servers) and the common experience of server operators across platforms.

---

## Quickstart: One-liner Installation

If you’re in a hurry and want to try the automated install with the default parameters, run this on your Proxmox host:

```bash
bash <(curl -fsSL https://github.com/Daxer97/satisfactory_server/raw/main/setup.sh)
```

- The script will prompt for options where required.
- Advanced/automated use cases (custom VM IDs, import options, advanced networking) can be handled via additional options—see the full usage section below.

**Security Note:** Always review third-party scripts or run in a non-production environment if in doubt! This project aims for openness and safety, but you should always apply best security practices.

---

## How It Works

The helper script orchestrates the following workflow:

1. **Creates an Ubuntu VM** using `qm` CLI or Proxmox API, optionally downloading/uploading the required Ubuntu ISO.
2. **Bootstraps the VM**:
   - Configures CPU, RAM, disk size as recommended for Satisfactory servers.
   - Sets hostname and QEMU Guest Agent for system management.
   - Deploys SSH keys or temporary password for initial access.
3. **Bootstraps game environment**:
   - Installs required dependencies (SteamCMD, 32-bit libraries, SDL, etc.).
   - Sets up a dedicated Linux user (e.g., `steam` or `satisfactory`) inside the VM for security isolation.
   - Installs and initializes **SteamCMD** for direct, automatic download of the Satisfactory Dedicated Server app (AppID: 1690800).
   - Validates the installation and performs dry runs to confirm the server binary runs cleanly.
4. **Configures the server**:
   - Installs as a **systemd service** for robust autostart, crash recovery, and log management.
   - Prepares port forwarding and network interface settings (`-multihome` and firewall rules).
   - Tunes network performance for Satisfactory (bandwidth, player limits configurable).
5. **(Optional) Imports single-player saves**:
   - Accepts local save files, places them in the correct server-side directory to be selectable from in-game server manager.
6. **Displays join info and connection tips** for Satisfactory clients (Steam/Epic) with success message.

This end-to-end process is built on established best practices from community guides and official documentation.

---

## Detailed Usage Instructions

### 1. Clone and Review the Script (Optional)

While the one-liner (see above) is safe for quick trial, for maximum control or forking your own version:

```bash
git clone https://github.com/Daxer97/satisfactory_server/raw/main/setup.sh
cd proxmox-satisfactory-script
less setup.sh  # Review or edit as needed
bash setup.sh  # Launch interactive/main install script
```

### 2. Script Options & Flags

When running the install script, you can often specify or override parameters by providing environment variables, interactive prompts, or flags. Common options include:

| **Option/Flag**         | **Description**                                               | **Example**                                     |
|------------------------|--------------------------------------------------------------|-------------------------------------------------|
| `--vmid <id>`          | Specify the desired Proxmox VM ID (else choose next free)    | `--vmid 110`                                    |
| `--vmname <name>`      | Set custom VM name                                           | `--vmname satisfactory-server-1`                |
| `--storage <target>`   | Proxmox storage pool/disk to use for VM disk                 | `--storage local-lvm`                           |
| `--iso <path/url>`     | Path or URL to the Ubuntu ISO (local or remote)              | `--iso local:iso/ubuntu-22.04.iso`              |
| `--cpus <num>`         | Allocate number of CPU cores to the VM                       | `--cpus 6`                                      |
| `--ram <MB>`           | Allocate amount of RAM (MB) to the VM                        | `--ram 16384`                                   |
| `--disk <GB>`          | Disk size in GB                                              | `--disk 40`                                     |
| `--import-save <path>` | Local path to Satisfactory save file to upload and import     | `--import-save ./MyFactory.sav`                 |
| `--no-interactive`     | Run non-interactively (for automation/CI/CD)                 | `--no-interactive`                              |
| `--force`              | Proceed without confirmation prompts                         | `--force`                                       |

For a full list, please run:

```bash
bash setup.sh --help
```

Or consult script-internal documentation.

---

## Installation Steps (Explained)

### 1. Prepare Proxmox Host

- Ensure you are running **Proxmox VE 7.x or newer** with root/sudo privileges.
- SSH into your node, or use the Proxmox web UI's shell.
- Check that you have enough CPU, RAM, disk; verify that required ports are available/customizable; confirm outbound internet access.

### 2. Run the Script

- You can use the one-liner or run it from a checked-out directory. The script will:
  - Detect or prompt for available VM ID, storage, and select an Ubuntu ISO.
  - Download the ISO if not specified (stable LTS preferred).
  - Create the VM with reasonable defaults unless overridden.
  - Optionally, inject your SSH public key or generate a random password.
- If importing a save, upload or specify its path/file.

### 3. Wait for Completion

- The process may take 5–15 minutes: VM creation, Ubuntu install (cloud-init or autoinstall), dependency setup, and game server deployment.
- If needed, you can tail logs or watch output onscreen to observe progress.

### 4. Retrieve Join Information

- When done, the script will output:
  - The IP address of the new VM.
  - SSH access info for advanced login (if needed).
  - The **connection address** (IP:7777 by default) and instructions to claim the server in-game.
  - Save upload location and server management credentials.

### 5. Connect via Satisfactory's Native Server Manager

- Open Satisfactory client (Steam/Epic).
- Use the “Server Manager” UI to add your server by IP, set the admin password, and start or import a game.
- If you imported a save, it will be available for selection under the “Manage Saves” tab.

---

## Saving and Importing Single-Player Worlds

### How to Locate Your Save Files

- On **Windows**:  
  `%LOCALAPPDATA%\FactoryGame\Saved\SaveGames\<your_user_id>\`
- On **Linux** (client/host):  
  `~/.config/Epic/FactoryGame/Saved/SaveGames/<your_user_id>/`
- For servers:  
  Save files typically reside at `~/.config/Epic/FactoryGame/Saved/SaveGames/server/` on the *server* VM.

### How the Script Handles Save Import

- If you provide a `.sav` file path during setup, the script will:
  - Transfer it into the server’s `SaveGames/server/` folder in the correct location.
  - Ensure proper permissions and naming conventions.
  - You can then select/import it using the Satisfactory in-game server manager.
- You can also upload saves later using Satisfactory's built-in **Manage Saves** functionality, which is preferred for most users.

---

## Updating, Stopping, and Managing the Server

Your Satisfactory server is installed as a resilient Linux systemd service, ensuring uptime and automating restart after crashes or reboots.

### **Basic management commands (run over SSH from the VM):**

```bash
# Check status
sudo systemctl status satisfactory

# Start/Stop/Restart the server service
sudo systemctl start satisfactory
sudo systemctl stop satisfactory
sudo systemctl restart satisfactory

# Force update (will also update the Game Server)
sudo systemctl restart satisfactory
```

- Updating the Satisfactory Dedicated Server (for new patches): simply restart the service. The script configures it to always check and update before each start.
- Logs are available at:  
  `/home/steam/SatisfactoryDedicatedServer/FactoryGame/Saved/Logs/FactoryGame.log`

---

## Uninstallation & Cleanup

To remove a deployed server and reclaim resources:

1. **Delete the VM** using the Proxmox web UI or via CLI:

```bash
qm stop <vmid>
qm destroy <vmid>  # CAUTION: Destroys the VM and all data within
```

2. **Remove stale disk images** and ISOs if you don't need them.
3. Optionally delete old saves, logs, and cloud-init artifacts left on your Proxmox host or backup storage.

---

## FAQ & Troubleshooting

Here are answers to some of the most common questions and issues seen when deploying Satisfactory dedicated servers in Proxmox and Linux VMs.

### **Q1: My server doesn't show up in the game’s server browser. What do I do?**

- Satisfactory servers **must be claimed** within the game's in-game server manager panel.
- You need to use the server's **IP address and correct port (default 7777)**, not its hostname.
- Make sure your local firewall and/or router forwards all required **UDP ports** (7777/15000/15777) to your VM.
- Confirm the server is running and not blocked by any local firewall.

### **Q2: I get "SteamAPI_Init(): Loaded ... OK" but can't connect.**

- This is usually a SteamCMD/Linux library issue.
- Fix by running (inside the VM as `steam`):

```bash
ln -s /home/steam/SatisfactoryDedicatedServer/linux64/steamclient.so ~/.steam/sdk64/steamclient.so
```

### **Q3: I can't upload or load my save file.**

- First, make sure you are using the correct save file location for the server, **not your user's**.
- For uploading, use the in-game “Manage Saves” feature—this is both easier and supported for cross-platform migration.

### **Q4: The server crashes during large saves or with more players.**

- **Increase RAM** and CPU cores in the VM settings.
- Large factories (multi-hundred-hour saves) can exceed 10+ GB RAM use; **16 GB or more** is recommended.

### **Q5: My VM doesn't start, or fails to boot the game server.**

- Ensure you did not allocate more resource (RAM/CPU) than available on the Proxmox host.
- Double check the VM’s CPU type: set `host` as CPU type rather than `kvm64` to avoid binary incompatibility.

### **Q6: How do I claim and set the admin password?**

- The first client/user to join an unclaimed server becomes the administrator, sets the server name and admin password.

### **Q7: How do I update the Ubuntu OS or the game server itself?**

- SSH into the VM, and run standard Ubuntu updates:
```bash
sudo apt update && sudo apt upgrade
```
- To update the game server:  
`sudo systemctl restart satisfactory`  
The script ensures every start checks for app updates via SteamCMD.

### **Q8: The server won't start—systemd times out**

- This is typically hardware slowness or misconfigured startup/permissions. Increasing the systemd `TimeoutSec` value in the service file can help.

### **Q9: Advanced port or multi-server configuration**

- The script exposes `-Port` and `-multihome` as configurable; refer to advanced flags and adjust Proxmox NAT/bridging as necessary for parallel deployments.

---

## Customization & Advanced Features

The script is designed to be flexible and can be forked or edited for advanced use, including:

- **Automation**: Tie the script into CI/CD, postinstall hooks, or Ansible playbooks for automated, fleet-wide server provisioning.
- **Multi-server deployments**: Create multiple VMs, each with different ports or dedicated IP addresses for scaling up Satisfactory clusters.
- **Backups**: While not enabled by default, integrating with Proxmox Backup Server or nightly cronjobs can automate VM and savegame backups.
- **Mod support**: While not included by default (for Satisfactory 1.0), adding supported server-side mods may require further manual setup.

---

## Security Recommendations

- **Isolate your Satisfactory VM** on a Proxmox bridge with limited LAN access if you do not intend for it to be world-accessible.
- Use strong admin passwords and keep your Proxmox host patched.
- Regularly back up both game saves and the VM itself to avoid data loss.
- Limit systemd restarts or failed login attempts via tools like Fail2Ban.

---

## Contribution & Support

- **Issues/Feature Requests**: Please use GitHub issues to report bugs or propose enhancements.
- **Pull Requests**: Contributions welcome! Fork, create a feature branch, and open PR.
- **Community**: For general Satisfactory or Proxmox discussion/troubleshooting, the Satisfactory [Reddit community](https://www.reddit.com/r/SatisfactoryGame/) and [Proxmox forums](https://forum.proxmox.com/) are invaluable.
- **License**: See `LICENSE` file in the repo for details (open source encouraged).

---

## Credits

- Satisfactory Server setup approach adapted from the Satisfactory Wiki, PiMyLifeUp, Reddit community guides, and official game server documentation.
- Script design patterns based on best practices from well-known Proxmox helper script repositories.
- Markdown formatting informed by GitHub Flavored Markdown and open source community contributions.

---

## Changelog

- **v1.0.0 (2025-08-22)**: Initial public release. Supports Ubuntu 22.04/24.04 inside Proxmox, single-server deployments, save import, and systemd management.
- For details, see the `CHANGELOG.md` in the repository.

---

## License

MIT or Apache 2.0 recommended for maximum community adoption. Please see the repository `LICENSE` file.

---

## Final Notes

- For those new to Proxmox: This script helps automate and standardize what can be a complex manual operation, and is designed to be beginner-friendly.
- For server power users: The script is modular and idempotent (run it many times for testing or disaster recovery), and can serve as a blueprint for similar game server deployments.
- We welcome all feedback, bug reports, and contributions from the Proxmox and Satisfactory communities!

---

**Happy factory-building!** 🚀 If this project improves your Satisfactory experience—or your sysadmin sanity—please give it a star and consider contributing back!

---

*This README is up to date as of August 2025 and will be revised for future Satisfactory and Proxmox versions. Please check for the latest script and documentation at the GitHub repository.*

---

# Appendix: Example Proxmox VM networking and Advanced Usage

---

Below is an example systemd service file (installed automatically by the script):

```ini
[Unit]
Description=Satisfactory dedicated server
Wants=network-online.target
After=syslog.target network.target nss-lookup.target network-online.target

[Service]
Environment="LD_LIBRARY_PATH=./linux64"
ExecStartPre=/usr/games/steamcmd +login anonymous +force_install_dir "/home/steam/SatisfactoryDedicatedServer" +app_update 1690800 validate +quit
ExecStart=/home/steam/SatisfactoryDedicatedServer/FactoryServer.sh
User=steam
Group=steam
Restart=on-failure
KillSignal=SIGINT
WorkingDirectory=/home/steam/SatisfactoryDedicatedServer

[Install]
WantedBy=multi-user.target
```

---

# Appendix: Example Save File Import Steps

Suppose your single-player world is at `C:\Users\YourName\AppData\Local\FactoryGame\Saved\SaveGames\123456789/BigFactory.sav`:

1. Copy `BigFactory.sav` to your local machine.
2. During script setup, use the `--import-save <path>` option to upload this save.
3. Alternatively, after initial setup:
   - Join the running server via Satisfactory's "Server Manager".
   - Select "Manage Saves" → “Upload Save” and use the game’s native tools to finish import.

Your previously solo epic factory can now become a multi-player megaproject!

---

*This README is maintained with the same enthusiasm we hope you bring to your next Satisfactory adventure. Build bigger, automate smarter, and let Proxmox take care of the rest!*
