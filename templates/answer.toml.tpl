# Proxmox VE Auto-Install Answer File Template
# Placeholders: {{KEYBOARD}}, {{COUNTRY}}, {{FQDN}}, {{EMAIL}}, {{TIMEZONE}},
#               {{ROOT_PASSWORD}}, {{FILESYSTEM}}, {{ZFS_RAID}}, {{DISK_LIST}}
#
# See: https://pve.proxmox.com/wiki/Automated_Installation

[global]
    keyboard = "{{KEYBOARD}}"
    country = "{{COUNTRY}}"
    fqdn = "{{FQDN}}"
    mailto = "{{EMAIL}}"
    timezone = "{{TIMEZONE}}"
    root-password = "{{ROOT_PASSWORD}}"
    reboot-on-error = false

[network]
    source = "from-dhcp"

[disk-setup]
    filesystem = "{{FILESYSTEM}}"
    {{ZFS_OPTIONS}}
    disk-list = {{DISK_LIST}}
