# DAP for SUSE Virtualization (Harvester)

Dell Automation Platform (DAP) blueprints and supporting plugins to orchestrate SUSE Virtualization (Harvester) v1.8 on Dell PowerEdge hardware backed by Dell PowerStore storage in air-gapped environments.

## Blueprint Architecture Overview

| ID | Blueprint | Description |
|---|---|---|
| `01` | `baremetal-prep` | Onboard PowerEdge assets, set BIOS/RAID/NIC profiles via iDRAC |
| `02` | `harvester-install` | Install Harvester v1.8 across N nodes (PXE / virtual media) |
| `03` | `harvester-network` | Post-install network (ClusterNetwork, VlanConfig, VM networks, storage-network) |
| `04` | `powerstore-csi` | Host multipath/iSCSI prerequisites + Dell CSI PowerStore driver + `csi-driver-config` |
| `00` | `harvester-stack` | Umbrella blueprint composing phases 01–04 |

## Current Status

- **Repository Stage:** Early foundation / scaffolding.
- **Available Assets:**
  - `AGENTS.md` - Master specification and non-negotiable constraints.
  - `airgap/` - Hauler manifest (`hauler-manifest.yaml`) and staging `Taskfile.yml`.
  - `provisioning/pxe/` - iPXE scripts (`ipxe-create`, `ipxe-join`) and DHCP configurations (`dnsmasq`, `kea-dhcp4`).
  - `provisioning/harvester-config/` - Harvester v1.8 unattended install configs (`create` and `join`).
  - `blueprints/02-harvester-install/` - Harvester v1.8.2 installation TOSCA `dell_1_1` blueprint.
  - `blueprints/04-powerstore-csi/resources/` - Helm values, StorageClass, and CloudInit CRD manifests for PowerStore.

## Development & Operational Tasks

This repository uses [Task](https://taskfile.dev) for blueprint validation, air-gap staging, and archiving workflows:

```bash
# --- Blueprint Validation (dap-bpa CLI) ---
task lint                  # Lint all TOSCA blueprints against DAP standards
task validate              # Schema-validate all node template properties
task visualize             # Generate interactive offline HTML topology diagrams

# --- Air-Gap Staging & Hauler ---
task airgap:sync           # Download Harvester boot files, PowerStore chart & images
task airgap:save           # Package Hauler store into portable airgap.tar.zst
task airgap:load           # Unpack airgap.tar.zst archive into local Hauler store
task airgap:serve-registry # Start local Hauler OCI registry (port 5000)
task airgap:serve-fileserver # Start local Hauler HTTP fileserver (port 8080)
task airgap:info           # Display local Hauler store contents

# --- Repository Release ---
task archive               # Export clean dap-harvester.tar.gz via git archive
```

## TODO / Roadmap

- [ ] **Download and setup `dap-bpa` CLI** (from [Dell Automation Studio Catalog](https://automation.dell.com/catalog/offers/blueprint_assist_macos)).
- [x] **Blueprint 02 (`harvester-install`)**: Complete multi-file TOSCA `dell_1_1` definition (`blueprint.yaml`, `inputs.yaml`, `capabilities.yaml`).
- [ ] **Blueprint 01 (`baremetal-prep`)**: Complete multi-file TOSCA `dell_1_1` definition for PowerEdge iDRAC asset onboarding and BIOS/RAID/NIC profiling.
- [ ] **Blueprint 03 (`harvester-network`)**: Complete TOSCA definitions for `ClusterNetwork`, `VlanConfig`, VM Networks, and `storage-network` setting.
- [ ] **Blueprint 04 (`powerstore-csi`)**: Complete TOSCA definition for CloudInit multipath, Dell CSI PowerStore Helm chart release, and `csi-driver-config`.
- [ ] **Blueprint 00 (`harvester-stack`)**: Author umbrella TOSCA blueprint composing phases 01 through 04.
- [ ] **Validation**: Run `task lint` / `dap-bpa blueprint lint` against all blueprint modules.

## References & Primary Sources

- [Dell Automation Platform Blueprint Developer's Guide](https://dl.dell.com/content/manual39624970-dell-automation-platform-blueprint-developer-s-guide.pdf?language=en-us)
- [Dell DAP Blueprint Assist Training Repository](https://github.com/tme-tech-ops/blueprint-assist-training)
- [Harvester v1.8 PXE Boot Installation Documentation](https://docs.harvesterhci.io/v1.8/install/pxe-boot-install)
- [Harvester iPXE Examples Repository](https://github.com/harvester/ipxe-examples)
- [Harvester v1.8 Configuration Reference](https://docs.harvesterhci.io/v1.8/install/harvester-configuration)
- [Dell Container Storage Modules (CSM) / CSI Helm Charts](https://dell.github.io/helm-charts)
