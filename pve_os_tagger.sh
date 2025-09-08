#!/bin/bash
#
# Proxmox VE: OS Version Auto-Tagger
# 
# Description:
# This script scans running LXC containers and QEMU VMs on a Proxmox VE host,
# retrieves OS version info, and applies a standardized, all-lowercase tag (e.g., "os-ubuntu-24.04-lts").
# It is idempotent (skips if tag exists) and cleans up old/duplicate OS tags.
#
# Requirements:
# 1. Must be run as root on the PVE host.
# 2. 'jq' package must be installed: apt install -y jq
# 3. For VMs: QEMU Guest Agent must be installed, running, and enabled in the VM options.
#

# --- Configuration ---
# Tag prefix (must be lowercase to comply with PVE tag specs)
TAG_PREFIX="os-"

# Timeout in seconds for 'qm agent ping'
AGENT_TIMEOUT=3

# --- Function: Generate Safe Tag ---
# Converts an OS PRETTY_NAME string into a PVE-compliant, all-lowercase tag.
generate_safe_tag() {
    local os_name="$1"
    local safe_name
    
    # 1. Replace spaces, slashes, and parentheses with hyphens.
    safe_name=$(echo "${os_name}" | tr ' /' '--' | tr '()' '--' | tr -s '-' | sed 's/^-//;s/-$//')
    
    if [[ -n "$safe_name" ]]; then
        local full_tag="${TAG_PREFIX}${safe_name}"
        
        # 2. Convert the entire tag to lowercase (PVE requirement).
        echo "${full_tag}" | tr '[:upper:]' '[:lower:]'
    else
        return 1
    fi
}

# --- Function: Update Tags ---
# Applies the new OS tag, preserving other tags and cleaning up old ones.
# Skips if the correct tag already exists.
update_tags() {
    local set_cmd="$1"   # "pct" or "qm"
    local vmid="$2"
    local new_os_tag="$3" # This is already fully formatted and lowercase (e.g., "os-ubuntu-24.04-lts")
    
    local current_config
    local current_tags_line
    
    # Get current tag configuration
    if [[ "$set_cmd" == "pct" ]]; then
        current_config=$(pct config "${vmid}")
        current_tags_line=$(echo "${current_config}" | grep '^tags:')
    else
        current_config=$(qm config "${vmid}")
        current_tags_line=$(echo "${current_config}" | grep '^tags:')
    fi
    
    local existing_tags=""
    if [[ -n "$current_tags_line" ]]; then
        existing_tags=$(echo "$current_tags_line" | awk -F': ' '{print $2}')
    fi

    # 1. [Idempotency Check]
    # Check if the correctly formatted tag already exists.
    if echo "${existing_tags}" | tr ',;' '\n\n' | grep -q -x "${new_os_tag}"; then
        # The exact tag exists. Do nothing.
        echo "  [INFO] Tag '${new_os_tag}' already exists. Skipping update."
        return 
    fi

    # --- Tag does not exist; proceed with update/cleanup ---

    # 2. [Cleanup]
    # Filter out ANY tag starting with our prefix, case-insensitive ("os-" OR "OS-").
    local other_tags_list
    other_tags_list=$(echo "${existing_tags}" | tr ',;' '\n\n' | sed '/^[[:space:]]*$/d' | grep -vi "^${TAG_PREFIX}")

    # Re-join remaining tags with commas
    local other_tags
    other_tags=$(echo "${other_tags_list}" | tr '\n' ',')
    other_tags=$(echo "$other_tags" | sed 's/,$//') # Trim trailing comma, if any

    # 3. [Build New List]
    local new_tag_list
    if [[ -n "$other_tags" ]]; then
        new_tag_list="${other_tags},${new_os_tag}"
    else
        new_tag_list="${new_os_tag}"
    fi

    # 4. [Apply Update]
    echo "  [INFO] Setting tags: ${new_tag_list}"
    if [[ "$set_cmd" == "pct" ]]; then
        pct set "${vmid}" --tags "${new_tag_list}"
    else
        qm set "${vmid}" --tags "${new_tag_list}"
    fi
}


echo "### Starting OS version tagging process for LXC and QEMU guests ###"

# --- 1. Process LXC Containers ---
echo
echo "--- Processing LXC Containers ---"

# List only running LXCs, skip header (NR>1)
pct list | awk 'NR>1 && $2 == "running" {print $1}' | while read -r VMID; do
    echo "[LXC ${VMID}] Processing..."
    
    os_pretty_name=$(pct exec "${VMID}" -- sh -c '. /etc/os-release && echo "$PRETTY_NAME"' 2>/dev/null)

    if [[ -z "$os_pretty_name" ]]; then
        echo "  [WARN] Could not retrieve PRETTY_NAME from LXC ${VMID}. Skipping."
        continue
    fi
    
    echo "  [INFO] Found OS: ${os_pretty_name}"
    
    new_tag=$(generate_safe_tag "${os_pretty_name}") # Tag is generated and lowercased here
    
    if [[ $? -eq 0 ]]; then
        update_tags "pct" "${VMID}" "${new_tag}"
    else
        echo "  [ERROR] Failed to generate safe tag name from: ${os_pretty_name}"
    fi
done


# --- 2. Process QEMU VMs ---
echo
echo "--- Processing QEMU VMs ---"

# List only running VMs, skip header (NR>1)
qm list | awk 'NR>1 && $3 == "running" {print $1}' | while read -r VMID; do
    echo "[VM ${VMID}] Processing..."

    # 1. Check if Guest Agent is responding (with timeout)
    if ! timeout "${AGENT_TIMEOUT}" qm agent "${VMID}" ping 1>/dev/null 2>&1; then
        echo "  [WARN] QEMU Guest Agent for VM ${VMID} is not responding. Skipping."
        continue
    fi

    # 2. Get OS info via agent
    os_info_json=$(qm agent "${VMID}" get-osinfo 2>/dev/null)

    if [[ -z "$os_info_json" ]]; then
        echo "  [WARN] Agent responded but failed to get os-info for VM ${VMID}. Skipping."
        continue
    fi

    # 3. Parse JSON output with jq to get "pretty-name"
    os_pretty_name=$(echo "${os_info_json}" | jq -r '."pretty-name" // empty')

    if [[ -z "$os_pretty_name" || "$os_pretty_name" == "null" ]]; then
        echo "  [WARN] Could not parse 'pretty-name' from VM ${VMID} agent data. Skipping."
        continue
    fi

    echo "  [INFO] Found OS: ${os_pretty_name}"

    new_tag=$(generate_safe_tag "${os_pretty_name}") # Tag is generated and lowercased here

    if [[ $? -eq 0 ]]; then
        update_tags "qm" "${VMID}" "${new_tag}"
    else
        echo "  [ERROR] Failed to generate safe tag name from: ${os_pretty_name}"
    fi
done

echo
echo "### Tagging process finished. ###"
