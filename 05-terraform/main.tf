terraform {
  required_version = ">= 1.5"
  required_providers {
    multipass = {
      source  = "larstobi/multipass"
      version = "~> 1.4"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

provider "multipass" {}

# ─────────────────────────────────────────────────────────────────────────────
# Render cloud-init templates with SSH key injected dynamically
# ─────────────────────────────────────────────────────────────────────────────

resource "local_file" "node1_cloudinit" {
  content = templatefile("${path.module}/cloud-init/node1.yaml.tpl", {
    ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
    node_ip        = var.node1_ip
  })
  filename        = "${path.module}/cloud-init/node1-rendered.yaml"
  file_permission = "0600"
}

resource "local_file" "node2_cloudinit" {
  content = templatefile("${path.module}/cloud-init/node2.yaml.tpl", {
    ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
    node_ip        = var.node2_ip
  })
  filename        = "${path.module}/cloud-init/node2-rendered.yaml"
  file_permission = "0600"
}

# ─────────────────────────────────────────────────────────────────────────────
# Multipass VMs
# ─────────────────────────────────────────────────────────────────────────────

resource "multipass_instance" "node1" {
  name           = var.node1_name
  cpus           = var.node1_cpus
  memory         = var.node1_memory
  disk           = var.node1_disk
  image          = var.ubuntu_image
  cloudinit_file = local_file.node1_cloudinit.filename

  depends_on = [local_file.node1_cloudinit]
}

resource "multipass_instance" "node2" {
  name           = var.node2_name
  cpus           = var.node2_cpus
  memory         = var.node2_memory
  disk           = var.node2_disk
  image          = var.ubuntu_image
  cloudinit_file = local_file.node2_cloudinit.filename

  depends_on = [local_file.node2_cloudinit]
}
