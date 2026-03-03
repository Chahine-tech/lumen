variable "node1_name" {
  default     = "node-1"
  description = "Multipass VM name for control-plane"
}

variable "node1_cpus" {
  default     = 4
  description = "CPUs for node-1 (control-plane + registry)"
}

variable "node1_memory" {
  default     = "6G"
  description = "RAM for node-1"
}

variable "node1_disk" {
  default     = "40G"
  description = "Disk for node-1 (needs room for registry data)"
}

variable "node1_ip" {
  default     = "192.168.2.2"
  description = "Static IP for node-1 (configured on eth1 via cloud-init)"
}

variable "node2_name" {
  default     = "node-2"
  description = "Multipass VM name for worker"
}

variable "node2_cpus" {
  default     = 2
  description = "CPUs for node-2 (worker)"
}

variable "node2_memory" {
  default     = "4G"
  description = "RAM for node-2"
}

variable "node2_disk" {
  default     = "30G"
  description = "Disk for node-2"
}

variable "node2_ip" {
  default     = "192.168.2.3"
  description = "Static IP for node-2 (configured on eth1 via cloud-init)"
}

variable "ubuntu_image" {
  default     = "24.04"
  description = "Ubuntu LTS image for Multipass VMs"
}

variable "ssh_public_key_path" {
  default     = "~/.ssh/id_ed25519.pub"
  description = "Path to SSH public key injected into VMs via cloud-init"
}
