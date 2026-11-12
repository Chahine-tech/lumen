#cloud-config
# backup-1: Garage object store for the PostgreSQL backups (not a K3s node)
# Template variables: ssh_public_key, node_ip
# Garage itself is configured and started by the Ansible garage role.

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_public_key}

packages:
  - docker.io

package_update: true
package_upgrade: false

write_files:
  # Static IP on eth1 (bridged interface, requires: multipass set local.bridged-network=<iface>)
  - path: /etc/netplan/99-airgap-static.yaml
    permissions: "0600"
    content: |
      network:
        version: 2
        ethernets:
          eth1:
            addresses:
              - ${node_ip}/24

runcmd:
  - netplan apply
  - systemctl enable docker
  - systemctl start docker
  - usermod -aG docker ubuntu
