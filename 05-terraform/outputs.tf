output "node1_ipv4" {
  value       = multipass_instance.node1.ipv4
  description = "DHCP IP on eth0 (Multipass internal bridge — may change on reboot)"
}

output "node2_ipv4" {
  value       = multipass_instance.node2.ipv4
  description = "DHCP IP on eth0 (Multipass internal bridge — may change on reboot)"
}

output "node1_static_ip" {
  value       = var.node1_ip
  description = "Static IP on eth1 — configured via cloud-init netplan, stable across reboots"
}

output "node2_static_ip" {
  value       = var.node2_ip
  description = "Static IP on eth1 — configured via cloud-init netplan, stable across reboots"
}

output "next_step" {
  value = <<-EOT

    VMs created. Static IPs configured via cloud-init:
      node-1: ${var.node1_ip}  (control-plane + registry)
      node-2: ${var.node2_ip}  (worker)

    Next:
      ansible-playbook 04-ansible/site.yml --ask-become-pass
  EOT
}
