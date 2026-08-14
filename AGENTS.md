# AGENTS.md — DAP for SUSE Virtualization (Harvester)

> Loaded by `opencode` at session start. Read this fully before touching any file.
> If anything here conflicts with what you infer from the code, **this file wins** — raise the conflict instead of silently resolving it.

---

## 1. What we are building

A set of **Dell Automation Platform (DAP) blueprints and supporting plugins** that let DAP act as the control plane for a SUSE Virtualization (Harvester) v1.8 cluster on Dell PowerEdge hardware, backed by Dell PowerStore.

Four outcomes, delivered as four composable blueprints plus one umbrella:

| # | Blueprint | Outcome |
|---|-----------|---------|
| 01 | `baremetal-prep` | Onboard PowerEdge assets, apply BIOS/RAID/NIC profile via iDRAC, stage boot artefacts |
| 02 | `harvester-install` | Install Harvester v1.8 across N nodes (PXE default, virtual-media alternative), form the cluster |
| 03 | `harvester-network` | Post-install network: ClusterNetwork, VlanConfig, VM Networks, storage-network |
| 04 | `powerstore-csi` | Node prerequisites + Dell CSI driver for PowerStore + Harvester `csi-driver-config` |
| 00 | `harvester-stack` | Umbrella: composes 01→04 with the phase contracts in §5 |

**Environment is air-gapped.** Every artefact — kernel/initrd/squashfs, container images, Helm charts, plugin wagons — is served locally. Hauler is the staging tool. Nothing may reference an internet endpoint at runtime.

---

## 2. Hard constraints — do not design around these, design *within* them

**C1 — Harvester nodes are not DAP endpoints.**
DAP's zero-touch FDO onboarding assumes NativeEdge OS on the device. A Harvester node runs SUSE Rancher Prime: OS Manager (Elemental). After installation the box remains a *hardware asset* reachable over iDRAC/Redfish; the cluster itself is a *deployment resource*. All Harvester day-2 flows go through the Kubernetes API, never through DAP endpoint management. Do not write blueprints that assume an agent runs on the Harvester host.

**C2 — Harvester installation is destructive and non-idempotent.**
This fights TOSCA `create/configure/start` lifecycle semantics. Every node-install operation MUST be guarded (see §6.2). A `heal`, `update`, or re-run of an install workflow must never reimage a node that is already a member of a healthy cluster. This is the single highest-consequence bug class in this repo.

**C3 — Custom blueprints are unsupported by Dell.**
Dell's documentation states it cannot guarantee support for user-created blueprints; Automation Studio is the sanctioned authoring surface. Every generated README, SoW fragment, or customer-facing artefact must carry this caveat. Never imply Dell support for anything in this repo.

**C4 — PowerStore CSI on Harvester is an unvalidated combination.**
Harvester engineering validates only internally developed storage and select open-source projects; third-party appliances go through the Partner Certification catalogue. Dell's CSM support matrix is Kubernetes/OpenShift-shaped and does not list SUSE Virtualization. Treat blueprint 04 as **PoC/lab scope**. Do not generate text claiming validated or supported status.

**C5 — Harvester is an immutable OS.**
No `zypper install`, no persistent `systemctl enable` by hand. Host-level changes go through `/oem` CloudInit files or the CloudInit CRD so they survive reboot and upgrade. Any instruction telling an operator to SSH in and change state permanently is wrong.

**C6 — Air-gap is absolute.**
No blueprint, chart value, iPXE script, or plugin may resolve an external URL at runtime. All references point at the local Hauler registry/fileserver or the DAP on-prem catalogue.

---

## 3. Repository layout

```
.
├── AGENTS.md
├── README.md
├── blueprints/
│   ├── 00-harvester-stack/          # umbrella
│   ├── 01-baremetal-prep/
│   ├── 02-harvester-install/
│   ├── 03-harvester-network/
│   └── 04-powerstore-csi/
│       ├── blueprint.yaml           # TOSCA entrypoint
│       ├── inputs/                  # example + per-site input files
│       ├── types/                   # local type definitions if any
│       └── resources/               # scripts, templates, manifests
├── plugins/                         # custom DAP plugins (only if unavoidable — see §4.4)
├── provisioning/
│   ├── pxe/                         # iPXE templates, DHCP snippets
│   ├── vmedia/                      # Redfish virtual-media path
│   └── harvester-config/            # config-create / config-join templates
├── airgap/
│   ├── hauler-manifest.yaml
│   └── Makefile                     # sync / save / load / serve targets
├── docs/
│   ├── architecture.md
│   ├── assumptions.md               # THE UNCERTAINTY LEDGER — see §9
│   └── runbook.md
└── tests/
    ├── lint/
    └── lab/
```

---

## 4. Blueprint conventions

### 4.1 DSL
DAP blueprints are TOSCA-based YAML in the Cloudify DSL lineage (`tosca_definitions_version: cloudify_dsl_1_3`). Standard shape:

```yaml
tosca_definitions_version: cloudify_dsl_1_3
description: >
  <one line>
imports:
  - <types URL from the DAP orchestrator fileserver>
  - plugin:<plugin-name>
inputs: {}
node_templates: {}
outputs: {}
```

**The `imports` block is the #1 fabrication risk.** The types URL and plugin names are environment-specific and version-specific. Never invent them. Leave a `# TODO(verify): <what>` marker and record it in `docs/assumptions.md`.

### 4.2 Inputs
- Every input carries `type`, `description`, and a `default` **only** where a wrong default is harmless. Never default a VIP, token, credential, or array endpoint.
- Site-specific values live in `inputs/<site>.yaml`, never inline in `blueprint.yaml`.
- Node counts, MACs, and iDRAC addresses come from an inventory input, not hardcoded lists.

### 4.3 Secrets
Cluster token, node password, SSH keys, iDRAC credentials, and PowerStore array credentials **must** come from the DAP secret store (`get_secret`), never from inputs, never from files in the repo, never from environment interpolation into a rendered template that lands on disk.

If you find a credential in plaintext anywhere in this repo, stop and flag it before doing anything else.

### 4.4 Plugins — prefer not to write one
Order of preference for any new capability:
1. Existing Dell/DAP plugin from the orchestrator catalogue
2. Ansible via the Ansible plugin
3. Kubernetes manifests / Helm via the respective plugins
4. Terraform provider via the Terraform plugin
5. **Last resort:** a custom Python plugin under `plugins/`

A custom plugin means packaging a wagon, uploading it, and owning its lifecycle in an air-gapped estate. Justify it in `docs/architecture.md` before writing one.

### 4.5 Day-2
Each blueprint exposes named workflows beyond install/uninstall. At minimum: `validate` (read-only health assertion) and `report` (emit current state). Destructive workflows must be named unambiguously (`reinstall_node`, not `refresh`) and require an explicit node-id parameter — never operate on "all nodes" by default.

---

## 5. Phase contracts (the composition seam)

These are invariants. Breaking one breaks the umbrella.

**01 → 02**
Outputs: `node_inventory` — list of `{node_id, service_tag, idrac_address, mgmt_mac, role}`. Roles are `management` (exactly 3 in a production layout) or `worker`. BIOS/boot mode is UEFI and confirmed, not assumed.

**02 → 03, 04**
Outputs: `kubeconfig` (as a secret reference, not a literal), `vip`, `harvester_version`, `node_inventory` (enriched with assigned IPs).

`kubeconfig` is the hinge of this whole repo. 03 and 04 consume it as a capability. Do not let 03 or 04 rediscover the cluster by other means, and do not write the kubeconfig to disk in a blueprint resource directory.

**03 → 04**
Outputs: `storage_network_cidr`, `storage_vlan_id`, `mgmt_bond_config`. Blueprint 04 must not create or assume network state; if the storage network is absent it fails loudly rather than falling back to the management network.

**Failure isolation:** 04 failing must leave 01–03 intact and the cluster usable. The umbrella treats 04 as a soft dependency.

---

## 6. Component guidance

### 6.1 `01-baremetal-prep`
- Asset onboarding into the DAP portal happens by iDRAC credentials (the non-FDO path), then assets are assigned to the orchestrator. FDO/voucher onboarding is **not** applicable here — see C1.
- BIOS profile must set: UEFI boot mode, PXE enabled on the designated mgmt NIC, and — if PXE over tagged VLAN is required — VLAN ID and boot protocol set in NIC firmware. Some of this is only settable at the NIC firmware level on certain models; treat per-model quirks as a lookup table in `provisioning/pxe/nic-profiles/`, not as generic logic.
- RAID: Harvester expects a clean install target. Define the install disk explicitly; do not let disk enumeration order decide.

### 6.2 `02-harvester-install`

**Provisioning primitive is pluggable.** Input `provisioning_method: pxe | vmedia`. PXE is the default; the Redfish virtual-media path (InsertVirtualMedia + one-time boot override with a config-baked ISO) exists because customer sites frequently do not let us own DHCP. Both paths must produce identical post-install state.

**PXE specifics that are non-negotiable:**
- iPXE kernel line requires `initrd=harvester-<version>-initrd` **as a kernel parameter**, in addition to the separate `initrd` line. Omitting it is a silent, confusing failure.
- `harvester.install.automatic=true` and `harvester.install.config_url=<local http>` drive the unattended install.
- DHCP **must** supply `option routers`. Without a default route the node fails to start. This is the most common field failure — assert it in `validate`.
- ISC DHCP is EOL; prefer dnsmasq or Kea in generated examples.

**Two config flavours, and the DAG must serialise them:**
- `config-create.yaml` — first management node. Defines the cluster VIP and the token.
- `config-join.yaml` — all others. `server_url` points at the VIP; `token` matches.
- Ordering: create node → **wait for cluster API ready** → join remaining nodes. Do not parallelise joins with the create. Staggering joins is safer than a thundering herd.

**Idempotency guard (C2).** Before any install operation on a node, the blueprint must check whether that node is already a healthy member of the target cluster (query the Kubernetes API via the phase-02 kubeconfig if one exists, plus a Redfish power/boot-source check). If yes: no-op and report. Only an explicit `reinstall_node` workflow with a named node may proceed past the guard. Write this guard once, in `resources/`, and call it from every path.

Management interface bonding and MTU are set **at install time** in the harvester config, not afterwards. Blueprint 03 must not contradict what 02 configured — keep the NIC model in a single shared input structure consumed by both.

### 6.3 `03-harvester-network`
Applied as Kubernetes resources against the phase-02 kubeconfig:
- `ClusterNetwork` + `VlanConfig` for the VM network fabric
- NetworkAttachmentDefinitions for individual VM Networks
- The Harvester `storage-network` setting — **required here**, because PowerStore iSCSI/NVMe-TCP traffic must not share the management network

Order matters: ClusterNetwork before VlanConfig before NADs. The storage-network change causes Longhorn pods to restart; treat it as disruptive and sequence it before any workload exists.

### 6.4 `04-powerstore-csi`

Sequence:
1. **Node prerequisites via CloudInit CRD** (not SSH, C5):
   - `multipathd` is disabled by default in SUSE Virtualization and is required by many third-party CSIs. Enable it via a `/oem/99-*.yaml` CloudInit file applied cluster-wide through the CloudInit CRD.
   - Protocol tooling: iSCSI needs `iscsid` and initiator utils; NVMe/TCP needs `nvme-cli` and a unique host NQN per node (`/etc/nvme/hostnqn`). **Whether these are present in the Harvester v1.8 image is an open question — see §9. Do not assume either way.**
2. **Install the CSI driver** via Helm chart or the Dell CSM Operator, images pulled from the local Hauler registry. Pick one method and stay with it; do not mix.
3. **Wire Harvester's `csi-driver-config` setting**: set the `Provisioner` to the PowerStore driver, plus `volumeSnapshotClassName` and `backupVolumeSnapshotClassName`. Without this, Harvester backup/snapshot features will not work against the external storage.
4. Create the StorageClass and VolumeSnapshotClass per Dell's driver documentation.
5. Validate: PowerStore-backed VM image upload, then a VM with root and data volumes on the external StorageClass.

Array-side note: the driver creates its own host entries. Ensure the initiators are not already members of an existing Host or Host Group on the array, or the driver will conflict with them.

---

## 7. Air-gap and Hauler

`airgap/hauler-manifest.yaml` is the single source of truth for what crosses the gap. It must cover:
- Harvester v1.8 boot artefacts: `vmlinuz`, `initrd`, `rootfs.squashfs`, ISO
- Harvester release images
- Dell CSI PowerStore images and Helm chart (or CSM Operator bundle)
- Any DAP plugin wagons not already in the on-prem catalogue

Workflow: `hauler store sync` → `hauler store save` → move → `hauler store load` → `hauler store serve registry` and `hauler store serve fileserver`.

**Hauler CLI has drifted across versions.** `--files` became `--filename/-f`; `apiVersion` moved off `v1alpha1` to `v1`. Do not hardcode syntax from memory — read the installed binary's `--help` and match it. Record the pinned Hauler version in `airgap/Makefile`.

The Hauler fileserver is what the iPXE scripts point at for kernel/initrd/squashfs, and the Hauler registry is what Harvester and the CSI driver pull images from. That means registry TLS/insecure configuration must be handled in the Harvester containerd config — plan for it rather than discovering it at install time.

DAP itself supports air-gapped blueprint and plugin loading (upload, or pull from the AWS ECR public gallery in an unconnected environment). Prefer direct upload of versioned artefacts we control.

---

## 8. Verification loop

Nothing is "done" until it has been through as much of this ladder as available:

1. **Static** — YAML parses; TOSCA lints; no plaintext secrets; no external URLs (`grep` for `http[s]?://` outside the local-endpoint allowlist).
2. **Contract** — declared outputs of each phase match the consumed inputs of the next (§5). Automate this check; it will drift.
3. **Dry-run** — DAP blueprint upload + topology/execution-graph preview without deploying.
4. **Lab** — real deployment. Only the human runs this.

You cannot do step 4. When you believe a change is ready, say what it needs validating against and stop. Do not describe untested work as working.

---

## 9. The uncertainty ledger — `docs/assumptions.md`

**This is the most important convention in this repo.** You may not have live DAP access. Docs are incomplete in exactly the places that matter (plugin node types, types URLs, plugin catalogue contents, exact CRD fields).

Rules:
- Anything you could not verify against a primary source or a live system gets a `# TODO(verify): <specific question>` at the point of use **and** a row in `docs/assumptions.md` with: what was assumed, why, what would confirm or refute it, and the blast radius if wrong.
- Never fabricate: DAP plugin names, node type names, types-file URLs, DAP REST paths, Harvester CRD field names, Helm values keys, or Dell CSM parameter names. A `TODO(verify)` is always better than a plausible invention.
- Distinguish "I read this in the docs" from "I inferred this from the DTIAS/NativeEdge lineage" from "I am guessing." Say which.

**Known open questions at project start** (seed the ledger with these):
- Exact `imports` types URL and plugin set on the target DAP orchestrator version
- Whether `nvme-cli` ships in the Harvester v1.8 image, and what multipath tooling is present
- Whether Dell CSI PowerStore's node prerequisites can be fully satisfied on an immutable Elemental host without a custom image build
- Whether the DAP orchestrator's Kubernetes/Helm plugins can target an arbitrary external cluster (Harvester) or only clusters it provisioned
- How DAP represents a non-NativeEdge OS install as a managed resource, if at all
- Harvester v1.8 `csi-driver-config` schema — confirm against v1.8 docs specifically, not v1.5/v1.6

---

## 10. Working agreements

- **Small, reviewable changes.** One blueprint concern per change. No repo-wide refactors unprompted.
- **Ask before inventing.** If a design decision has more than one defensible answer and the answer shapes the phase contracts, ask. Otherwise proceed and note the choice.
- **French/English:** code, comments, and blueprint content in English. Customer-facing prose follows the language of the source brief.
- **No marketing voice.** No "seamlessly", no "robust", no "enterprise-grade". Technical register, plain claims.
- **Cite when it matters.** When encoding a behaviour from vendor documentation, put the source URL in a comment next to it. Future-you will need to recheck it against a new version.
- **When blocked, stop and say so.** A clear "I need X to proceed" is more useful than a confident guess that costs a lab rebuild.
