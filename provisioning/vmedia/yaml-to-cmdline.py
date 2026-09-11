#!/usr/bin/env python3
"""
yaml-to-cmdline.py — Convert Harvester configuration YAML to kernel cmdline arguments.

Parses Harvester install configuration (CREATE or JOIN mode) and emits the
exact dot-notated 'harvester.*' kernel parameters expected by Harvester v1.8 installer.
Operates with standard library only (fallback parser included if PyYAML is unavailable).
"""

import sys
import os
import re
import argparse
import json
from typing import Any

def parse_simple_yaml(text):
    """
    Lightweight YAML parser using standard library only.
    Handles nested dicts, lists of strings, and lists of dicts (e.g. interfaces).
    """
    lines = text.splitlines()
    root: dict[str, Any] = {}
    stack: list[tuple[Any, int]] = [(root, -1)]  # (current_dict_or_list, indent_level)

    i = 0
    while i < len(lines):
        line = lines[i]
        # Remove comments and trailing whitespace
        stripped_comment = re.split(r'(?<!\\)#', line)[0].rstrip()
        if not stripped_comment.strip():
            i += 1
            continue

        indent = len(stripped_comment) - len(stripped_comment.lstrip(' '))
        content = stripped_comment.strip()

        # Unwind stack to parent indent
        while len(stack) > 1 and stack[-1][1] >= indent:
            stack.pop()

        parent, parent_indent = stack[-1]

        # List item
        if content.startswith('- '):
            item_text = content[2:].strip()
            # If parent is a dict, we might need a list container
            # But usually list item appears under a key that was already created as a list
            if isinstance(parent, list):
                if ':' in item_text and not (item_text.startswith('"') or item_text.startswith("'")):
                    # List of dict items, e.g. - name: "eth0"
                    item_dict = {}
                    parts = item_text.split(':', 1)
                    k = parts[0].strip()
                    v = clean_value(parts[1].strip()) if len(parts) > 1 else ""
                    item_dict[k] = v
                    parent.append(item_dict)
                    stack.append((item_dict, indent))
                else:
                    parent.append(clean_value(item_text))
            elif isinstance(parent, dict):
                # An orphaned list item, should not happen in valid YAML
                pass
            i += 1
            continue

        # Key-value pair
        if ':' in content:
            parts = content.split(':', 1)
            key = parts[0].strip()
            raw_val = parts[1].strip() if len(parts) > 1 else ""

            if raw_val == "":
                # Could be parent of a dict or list
                # Lookahead to check next non-empty line
                next_is_list = False
                j = i + 1
                while j < len(lines):
                    next_line = lines[j]
                    next_stripped = re.split(r'(?<!\\)#', next_line)[0].rstrip()
                    if next_stripped.strip():
                        next_indent = len(next_line) - len(next_line.lstrip(' '))
                        if next_indent > indent and next_stripped.strip().startswith('- '):
                            next_is_list = True
                        break
                    j += 1

                if next_is_list:
                    new_list = []
                    parent[key] = new_list
                    stack.append((new_list, indent))
                else:
                    new_dict = {}
                    parent[key] = new_dict
                    stack.append((new_dict, indent))
            else:
                parent[key] = clean_value(raw_val)

        i += 1

    return root

def clean_value(val):
    """Strip quotes and coerce simple types."""
    if not val:
        return ""
    if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
        return val[1:-1]
    if val.lower() == 'true':
        return True
    if val.lower() == 'false':
        return False
    try:
        if '.' in val:
            return float(val)
        return int(val)
    except ValueError:
        return val

def load_yaml(file_path):
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()

    try:
        import yaml
        return yaml.safe_load(content) or {}
    except ImportError:
        return parse_simple_yaml(content)

def flatten_config(cfg, mode_override=None):
    """
    Flatten Harvester config into harvester.* kernel parameters.
    """
    params = []

    # Always enforce automatic installation
    params.append("harvester.install.automatic=true")

    # Scheme version
    scheme_version = cfg.get("scheme_version", 1)
    params.append(f"harvester.scheme_version={scheme_version}")

    # Determine install mode
    install_section = cfg.get("install", {})
    mode = mode_override or install_section.get("mode", "create")
    params.append(f"harvester.install.mode={mode}")

    # Server URL (mandatory in join mode, skipped in create mode)
    server_url = cfg.get("server_url") or install_section.get("server_url")
    if mode == "join" and server_url:
        params.append(f'harvester.server_url="{server_url}"')

    # Token
    token = cfg.get("token") or install_section.get("token")
    if token:
        params.append(f'harvester.token="{token}"')

    # OS Settings
    os_sec = cfg.get("os", {})
    if os_sec.get("hostname"):
        params.append(f'harvester.os.hostname="{os_sec["hostname"]}"')
    if os_sec.get("password"):
        params.append(f'harvester.os.password="{os_sec["password"]}"')

    # SSH Authorized Keys
    ssh_keys = os_sec.get("ssh_authorized_keys")
    if ssh_keys:
        if isinstance(ssh_keys, list):
            for key in ssh_keys:
                params.append(f'harvester.os.ssh_authorized_keys="{key}"')
        elif isinstance(ssh_keys, str):
            params.append(f'harvester.os.ssh_authorized_keys="{ssh_keys}"')

    # DNS Nameservers
    dns = os_sec.get("dns_nameservers")
    if dns:
        dns_str = ",".join(str(d) for d in dns) if isinstance(dns, list) else str(dns)
        params.append(f'harvester.os.dns_nameservers="{dns_str}"')

    # NTP Servers
    ntp = os_sec.get("ntp_servers")
    if ntp:
        ntp_str = ",".join(str(n) for n in ntp) if isinstance(ntp, list) else str(ntp)
        params.append(f'harvester.os.ntp_servers="{ntp_str}"')

    # Target Device & Data Disk
    if install_section.get("device"):
        params.append(f'harvester.install.device="{install_section["device"]}"')
    if install_section.get("data_disk"):
        params.append(f'harvester.install.data_disk="{install_section["data_disk"]}"')

    # VIP (Create mode)
    if mode == "create":
        if install_section.get("vip"):
            params.append(f'harvester.install.vip="{install_section["vip"]}"')
        if install_section.get("vip_mode"):
            params.append(f'harvester.install.vip_mode="{install_section["vip_mode"]}"')
        if install_section.get("vip_hw_addr"):
            params.append(f'harvester.install.vip_hw_addr="{install_section["vip_hw_addr"]}"')

    # Skip checks
    if install_section.get("skipchecks"):
        params.append('harvester.install.skipchecks=true')

    # Management Interface Configuration
    mgmt = install_section.get("management_interface", {})
    if mgmt:
        method = mgmt.get("method", "dhcp")
        params.append(f'harvester.install.management_interface.method="{method}"')
        if method == "static":
            if mgmt.get("ip"):
                params.append(f'harvester.install.management_interface.ip="{mgmt["ip"]}"')
            if mgmt.get("subnet_mask"):
                params.append(f'harvester.install.management_interface.subnet_mask="{mgmt["subnet_mask"]}"')
            if mgmt.get("gateway"):
                params.append(f'harvester.install.management_interface.gateway="{mgmt["gateway"]}"')

        if mgmt.get("vlan_id") is not None:
            params.append(f'harvester.install.management_interface.vlan_id={mgmt["vlan_id"]}')
        if mgmt.get("mtu"):
            params.append(f'harvester.install.management_interface.mtu={mgmt["mtu"]}')

        # Slaves / Interfaces: Harvester accepts "name:eth0,name:eth1" or "eth0,eth1"
        ifaces = mgmt.get("interfaces", [])
        if ifaces:
            if_details = []
            for iface in ifaces:
                if isinstance(iface, dict):
                    name = iface.get("name", "")
                    hw = iface.get("hwAddr", "")
                    if hw and name:
                        if_details.append(f"hwAddr:{hw},name:{name}")
                    elif name:
                        if_details.append(f"name:{name}")
                    elif hw:
                        if_details.append(f"hwAddr:{hw}")
                elif isinstance(iface, str):
                    if_details.append(f"name:{iface}")
            if if_details:
                params.append(f'harvester.install.management_interface.interfaces="{",".join(if_details)}"')

        # Bond options
        bond_opts = mgmt.get("bond_options", {})
        if isinstance(bond_opts, dict):
            if bond_opts.get("mode"):
                params.append(f'harvester.install.management_interface.bond_options.mode="{bond_opts["mode"]}"')
            if bond_opts.get("miimon"):
                params.append(f'harvester.install.management_interface.bond_options.miimon={bond_opts["miimon"]}')

    return " ".join(params)

def main():
    parser = argparse.ArgumentParser(description="Convert Harvester YAML config to kernel boot parameters.")
    parser.add_argument("config_file", help="Path to Harvester configuration YAML file")
    parser.add_argument("--mode", choices=["create", "join"], default=None, help="Override install mode")
    args = parser.parse_args()

    if not os.path.exists(args.config_file):
        sys.stderr.write(f"Error: configuration file '{args.config_file}' not found.\n")
        sys.exit(1)

    cfg = load_yaml(args.config_file)
    cmdline = flatten_config(cfg, mode_override=args.mode)
    print(cmdline)

if __name__ == "__main__":
    main()
