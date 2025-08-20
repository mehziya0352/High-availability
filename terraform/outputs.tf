output "instance_template" {
  value = google_compute_instance_template.vm1_template.name
}

output "regional_mig_name" {
  value = google_compute_region_instance_group_manager.mig.name
}

output "load_balancer_ip" {
  value = google_compute_global_address.lb_ip.address
}
