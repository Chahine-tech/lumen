#cloud-config
# node-1: control-plane + Docker registry
# Template variables: ssh_public_key, node_ip

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_public_key}

packages:
  - docker.io
  - iptables-persistent

package_update: true
package_upgrade: false

write_files:
  # Static IP on eth1 (bridged interface — requires: multipass set local.bridged-network=<iface>)
  - path: /etc/netplan/99-airgap-static.yaml
    permissions: "0600"
    content: |
      network:
        version: 2
        ethernets:
          eth1:
            addresses:
              - ${node_ip}/24

  # Kernel parameters for Falco (inotify) and general K8s stability
  - path: /etc/sysctl.d/99-lumen.conf
    content: |
      fs.inotify.max_user_instances=8192
      fs.inotify.max_user_watches=524288
      vm.max_map_count=262144

runcmd:
  - netplan apply
  - sysctl -p /etc/sysctl.d/99-lumen.conf
  - systemctl enable docker
  - systemctl start docker
  - usermod -aG docker ubuntu
