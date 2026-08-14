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
  - `blueprints/04-powerstore-csi/resources/multipathd-powerstore.yaml` - Harvester CloudInit CRD manifest for PowerStore multipath.

## TODO / Roadmap

- [ ] **Download and setup `dap-bpa` CLI** (from [Dell Automation Studio Catalog](https://automation.dell.com/catalog/offers/blueprint_assist_macos)).
- [ ] **Blueprint 02 (`harvester-install`)**: Complete multi-file TOSCA `dell_1_1` definition (`blueprint.yaml`, `inputs.yaml`, `capabilities.yaml`).
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
