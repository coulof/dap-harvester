# Uncertainty Ledger & Architecture Assumptions

> Maintained per **AGENTS.md §9**. Tracks assumptions, verifications, and empirical findings for DAP on SUSE Virtualization (Harvester).

---

## 1. Empirically Verified Invariants (Harvester v1.8.2)

The following items have been verified directly on live Harvester v1.8.2 clusters (both hosting cluster `op-prg2` and nested deployed nodes):

| Item | Expected / Assumed | Verified Reality | Verification Method | Status |
|------|--------------------|------------------|---------------------|--------|
| **Installer Parameter Schema** | Speculative camelCase duplicates | Harvester installer expects canonical snake_case (`harvester.install.management_interface.*`, `harvester.install.iso_url`). Guesswork camelCase aliases were eliminated to stay within the 2048-byte `COMMAND_LINE_SIZE` limit. | Table-driven `yaml-to-cmdline.py` with 2000-byte length guard and unit test suite. | **VERIFIED** |
| **`iso_url` Requirement** | Can be omitted or set to `"local"` | In unattended installer mode (`harvester.install.automatic=true`), `harvester-installer` performs a `check_url` validation requiring `http://` or `https://`. `"local"` fails validation. | Configured with valid URL (e.g., local air-gap Hauler endpoint or release URL). | **VERIFIED** |
| **Dracut Static IP Syntax** | DNS embedded in `ip=` string | Appending nameservers into the `ip=` field contaminates the MTU/MAC slot. Dracut requires separate `nameserver=<ip>` arguments, and `ip=<client-ip>::<gw>:<netmask>:<hostname>:<iface>:none`. | Verified via unit test suite and Dracut live boot parser. | **VERIFIED** |
| **Secrets on Kernel Cmdline** | Storing passwords and tokens on cmdline | `/proc/cmdline` is world-readable and captured in systemd/dmesg logs. For defense/enterprise compliance, secrets should be kept in `config_url` or embedded ISO configs; `yaml-to-cmdline.py` supports `--exclude-secrets` and warns on plaintext secrets. | Added `--exclude-secrets` mode and security warning. | **VERIFIED** |
| **Serial vs VGA TUI Console** | `install.tty` set to `ttyS0` | Setting `install.tty` to `ttyS0` directs the Harvester TUI dashboard exclusively to the serial console, leaving VGA/VNC (`tty1`) as a plain Linux login prompt. Omitting `install.tty` (or setting `tty1`) ensures the TUI appears on the graphical VNC console. | Verified on running KubeVirt nested VM and `getty@tty1.service`. | **VERIFIED** |
| **UEFI Boot Order** | CD-ROM must be booted first, then hard disk | With UEFI firmware (EDK2/OVMF), setting hard disk to `bootOrder: 1` and CD-ROM to `bootOrder: 2` allows initial boot to skip unpartitioned disk and boot CD-ROM; subsequent reboots automatically boot installed Harvester on disk. | Confirmed on KubeVirt VM `test-harvester-sample-01`. Initial boot skipped disk, second boot booted Harvester OS. | **VERIFIED** |
| **`nvme-cli` Package in v1.8.2** | Unknown if `nvme-cli` is present | `nvme-cli-2.11` is installed out of the box in `/usr/sbin/nvme`. `nvme_tcp` and `nvme_fabrics` kernel modules are pre-loaded. | Inspected live node filesystem and `lsmod`. | **VERIFIED** |
| **Multipath & iSCSI in v1.8.2** | Unknown if multipath tools are present | `multipath-tools-0.12.3` (`/usr/sbin/multipath`, `/usr/sbin/multipathd`) and `open-iscsi-2.1.11` (`/usr/sbin/iscsiadm`) are installed out of the box. Services are disabled by default. | Inspected live node filesystem and `systemctl`. | **VERIFIED** |
| **PowerStore CSI Host Prerequisites** | Requires custom OS image or package installation | Packages are present. Prerequisites can be met entirely via CloudInit `/oem/99-*.yaml` enabling `multipathd` and `iscsid` (`systemctl enable --now multipathd iscsid`). No custom image build required. | Confirmed packages and module availability. | **VERIFIED** |
| **`csi-driver-config` Schema (v1.8.2)** | Map of CSI drivers to snapshot classes | Setting `harvesterhci.io/v1beta1 Setting csi-driver-config` uses a JSON map: `{"<driver-name>": {"volumeSnapshotClassName": "<vsc>", "backupVolumeSnapshotClassName": "<vsc-backup>"}}`. | Inspected `kubectl get settings csi-driver-config -o yaml` on live v1.8.2 cluster. | **VERIFIED** |

---

## 2. Active Assumptions & Open Questions (DAP Control Plane)

These items require validation once connected to the target DAP orchestrator instance:

| # | Assumption | Basis | Confirmation / Refutation Test | Blast Radius |
|---|------------|-------|--------------------------------|--------------|
| **A1** | Orchestrator DSL imports URL format is `http://<orchestrator-fileserver>/cloudify/types/types.yaml` or versioned equivalent. | Inferred from Cloudify DSL 1.3 / DTIAS lineage. | Inspect target DAP orchestrator catalogue / plugins directory. | Blueprint upload fails static parse. |
| **A2** | DAP Kubernetes plugin can accept an external cluster `kubeconfig` supplied via blueprint secret. | Standard Cloudify/DAP Kubernetes plugin behavior (`kubeconfig_content` in client config). | Deploy blueprint 03 against a staged secret kubeconfig on DAP orchestrator. | Phase 02 to 03/04 seam cannot use standard Kubernetes plugin; would require custom script execution. |
| **A3** | Redfish virtual-media mounting via iDRAC supports direct HTTP/HTTPS streaming of remastered ISO from local Hauler fileserver. | Standard Dell iDRAC 9 Redfish `InsertVirtualMedia` specification. | Issue `InsertVirtualMedia` call to lab PowerEdge iDRAC pointing at Hauler fileserver URL. | Provisioning method fallback required (PXE or staging on local NFS/CIFS share). |
| **A4** | DAP asset onboarding for Harvester nodes does not conflict with non-FDO discovery. | Dell documentation specifies manual/API onboarding via iDRAC credentials for non-NativeEdge OS nodes. | Register lab PowerEdge server in DAP portal using iDRAC credentials. | Node inventory structure format in blueprint 01 may require adjustment. |
