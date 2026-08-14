# Harvester Install Blueprint (`02-harvester-install`)

Automated, scriptless installation blueprint for SUSE Virtualization (Harvester) v1.8.2 on Dell PowerEdge hardware backed by Dell Automation Platform (DAP).

## Features & Architecture

- **Dialect**: TOSCA `dell_1_1` multi-file blueprint layout.
- **Scriptless Design**: Operates purely via standard DAP packaged plugins (`redfish-plugin`, `rest-plugin`, `utilities-plugin`, `kubernetes-plugin`).
- **Constraint C2 Idempotency Guard**: Queries cluster VIP REST health endpoint prior to boot trigger. Prevents accidental re-imaging of healthy active nodes.
- **DAG Workflow**:
  1. `idempotency_guard`: Validates target state.
  2. `config_stager`: Renders unattended install configuration files.
  3. `primary_node`: Triggers UEFI PXE boot for Node 1 in `CREATE` mode.
  4. `cluster_api_wait`: Polls cluster VIP until Harvester control plane responds (`max_retries: 30`, `retry_interval: 10`).
  5. `kubeconfig_secret`: Registers cluster kubeconfig into DAP Secret Store.
  6. `secondary_nodes`: Triggers staggered PXE boot for secondary nodes in `JOIN` mode.

## Input Parameters

See `inputs.yaml` for complete parameter schema, UI input groups, and constraints.

## Capabilities & Phase Contracts

Outputs generated for downstream consumption by `03-harvester-network` and `04-powerstore-csi`:
- `cluster_vip`: Virtual IP address of the Harvester cluster.
- `kubeconfig_secret_name`: Name of secret holding the administrative kubeconfig in DAP Secret Store.
- `harvester_version`: Installed Harvester release version.
- `node_inventory`: Enriched list of cluster members and management IPs.
