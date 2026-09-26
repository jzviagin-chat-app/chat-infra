output "lb_public_ip" {
  value = oci_core_instance.lb.public_ip
}

output "ssh_lb" {
  value = "ssh ubuntu@${oci_core_instance.lb.public_ip}"
}

output "websocket_url" {
  value = "ws://${oci_core_instance.lb.public_ip}/ws"
}

output "free_tier_usage" {
  value = "OCPU ${local.total_ocpus}/4, memory ${local.total_memory_gb}/24 GB, disk ${local.total_disk_gb}/200 GB"
}
