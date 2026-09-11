# Harvester Virtual Media (vmedia) ISO Remastering

Tooling to create automated, configuration-baked SUSE Virtualization (Harvester) v1.8 ISO images for unattended installation via Dell PowerEdge iDRAC Redfish Virtual Media or physical USB/CD-ROM.

---

## Architecture & How It Works

Harvester provides two primary unattended deployment mechanisms:
1. **PXE Network Boot**: Downloads `vmlinuz`, `initrd`, and fetches `rootfs.squashfs` over HTTP.
2. **Virtual Media Boot (vmedia)**: Mounts a bootable ISO over iDRAC. The 4GB `rootfs.squashfs` is already local on the virtual media (`root=live:CDLABEL=COS_LIVE`), eliminating high network transfer overhead.

### GRUB Evaluation Flow on the ISO
1. The ISO boots in UEFI mode using GRUB2 (`/boot/grub2/grub.cfg`).
2. `grub.cfg` sources `/boot/grub2/harvester.cfg`, which exposes the hook variable `${extra_iso_cmdline}`.
3. The remastering script (`remaster-iso.sh`) translates the site's Harvester configuration YAML (`config-create.yaml` or `config-join.yaml`) into dot-notated `harvester.*` kernel parameters via `yaml-to-cmdline.py`.
4. At boot time, Harvester's installer engine reads `/proc/cmdline` via `util.ReadCmdline("harvester")`. Seeing `harvester.install.automatic=true` without an external `config_url`, it immediately executes automated installation directly from the baked-in parameters.

---

## Native Tooling & Dependencies

The remastering toolchain runs natively on Linux without third-party containers or wrapper layers.

### Required Packages
- `xorriso` — ISO9660 / Rock Ridge / Joliet / El Torito filesystem manipulation
- `mcopy` (from `mtools`) — Copies EFI files into FAT32 boot images
- `mkfs.vfat` (from `dosfstools`) — Formats the 4MB UEFI system partition image
- `python3` — Standard library only (no external pip dependencies needed)

### Installation by Distribution

**openSUSE Leap / SLES / SLE Micro:**
```bash
sudo zypper in -y xorriso mtools dosfstools python3
```

**Ubuntu / Debian:**
```bash
sudo apt-get update && sudo apt-get install -y xorriso mtools dosfstools python3
```

**RHEL / Rocky Linux / AlmaLinux:**
```bash
sudo dnf install -y xorriso mtools dosfstools python3
```

---

## Quickstart via Taskfile

Ensure native dependencies are installed:
```bash
task vmedia:check-deps
```

### 1. Remaster CREATE ISO (Node 1)
Generates `harvester-v1.8.2-create.iso` using `provisioning/harvester-config/config-create.yaml`:
```bash
task vmedia:remaster-create SOURCE_ISO=/path/to/harvester-v1.8.2-amd64.iso
```

### 2. Remaster JOIN ISO (Node 2+)
Generates `harvester-v1.8.2-join.iso` using `provisioning/harvester-config/config-join.yaml`:
```bash
task vmedia:remaster-join SOURCE_ISO=/path/to/harvester-v1.8.2-amd64.iso
```

### 3. Remaster Both
```bash
task vmedia:remaster-all SOURCE_ISO=/path/to/harvester-v1.8.2-amd64.iso
```

### 4. Clean Artifacts
```bash
task vmedia:clean
```

---

## Direct CLI Usage (`remaster-iso.sh`)

```bash
./remaster-iso.sh \
  --source-iso /path/to/harvester-v1.8.2-amd64.iso \
  --config-file ../harvester-config/config-create.yaml \
  --mode create \
  --output-iso ./harvester-v1.8.2-create.iso \
  --timeout 3
```

### CLI Parameters
| Option | Required | Default | Description |
|---|---|---|---|
| `--source-iso` | Yes | - | Path to upstream Harvester v1.8 ISO |
| `--config-file` | Yes | - | Path to Harvester configuration YAML |
| `--mode` | Yes | - | Deployment mode: `create` (Node 1) or `join` (Node 2+) |
| `--output-iso` | Yes | - | Destination path for remastered ISO |
| `--timeout` | No | `3` | GRUB boot menu countdown in seconds |
| `--volume-id` | No | `COS_LIVE` | ISO volume label (must remain `COS_LIVE` for Harvester dracut) |

---

## iDRAC Redfish Virtual Media Deployment

Once the remastered ISO is generated, serve it via the local Hauler fileserver or HTTP server and attach it to target Dell PowerEdge servers via Redfish.

### Redfish InsertVirtualMedia Action
```http
POST https://<idrac-ip>/redfish/v1/Managers/iDRAC.Embedded.1/VirtualMedia/CD/Actions/VirtualMedia.InsertMedia
Content-Type: application/json

{
  "Image": "http://<LOCAL_FILESERVER_IP>:8080/harvester-v1.8.2-create.iso",
  "Inserted": true,
  "WriteProtected": true
}
```

### Redfish One-Time Boot Override (UEFI CD / Virtual Media)
```http
PATCH https://<idrac-ip>/redfish/v1/Systems/System.Embedded.1
Content-Type: application/json

{
  "Boot": {
    "BootSourceOverrideTarget": "Cd",
    "BootSourceOverrideMode": "UEFI",
    "BootSourceOverrideEnabled": "Once"
  }
}
```

### Reboot Server
```http
POST https://<idrac-ip>/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset
Content-Type: application/json

{
  "ResetType": "ForceRestart"
}
```

---

## Repository Guardrails & Constraints

- **C2 (Idempotency Guard)**: Harvester installation is destructive and non-idempotent. Always ensure target nodes are not already active members of a running cluster prior to attaching virtual media or power-cycling.
- **C5 (Immutable Host)**: Host customizations must be defined in the configuration YAML via `os.write_files`, `os.modules`, or `os.after_install_chroot_commands` rather than post-boot manual SSH intervention.
- **C6 (Air-Gap Integrity)**: Remastered ISOs and their SHA512 checksums are self-contained artifacts designed to operate in fully air-gapped environments.
