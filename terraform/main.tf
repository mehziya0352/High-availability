# Get existing VM info
data "google_compute_instance" "vm1" {
  name    = var.vm_name
  zone    = var.zone
  project = var.project
}

resource "google_compute_snapshot" "vm_snapshot" {
  name        = "${var.vm_name}-snapshot"
  project     = var.project
  zone        = var.zone
  source_disk = data.google_compute_instance.vm1.boot_disk[0].source
}

resource "google_compute_image" "vm1_custom_image" {
  name            = "${var.vm_name}-custom-image"
  project         = var.project
  source_snapshot = google_compute_snapshot.vm_snapshot.name
}

# Create instance template using the custom image
resource "google_compute_instance_template" "vm1_template" {
  name         = "${var.vm_name}-template"
  machine_type = var.machine_type
  project      = var.project

  disk {
    source_image = google_compute_image.vm1_custom_image.self_link
    auto_delete  = true
    boot         = true
  }

  network_interface {
    network = "default"
    access_config {}
  }

  tags = ["http-server"]
}

# Create health check for autoscaling and load balancer
resource "google_compute_health_check" "http_health_check" {
  name    = "${var.vm_name}-health-check"
  project = var.project

  http_health_check {
    port = 80
  }
}

# Firewall rule to allow health checks (Google Cloud's health check IP ranges)
resource "google_compute_firewall" "allow_health_checks" {
  name    = "${var.vm_name}-allow-hc"
  project = var.project
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["http-server"]
}

# Firewall rule to allow HTTP traffic to instances in MIG
resource "google_compute_firewall" "allow_http" {
  name    = "${var.vm_name}-allow-http"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  target_tags = ["http-server"]
}

# Create regional managed instance group for high availability
resource "google_compute_region_instance_group_manager" "mig" {
  name               = "${var.vm_name}-mig"
  project            = var.project
  region             = var.region
  base_instance_name = var.vm_name
  target_size        = var.min_replicas

  auto_healing_policies {
    health_check      = google_compute_health_check.http_health_check.self_link
    initial_delay_sec = 300
  }

  version {
    instance_template = google_compute_instance_template.vm1_template.self_link
  }
}

# Named port for MIG - required to link backend service port_name
resource "google_compute_instance_group_named_port" "http" {
  group   = google_compute_region_instance_group_manager.mig.instance_group
  region  = var.region
  name    = "http"
  port    = 80
  project = var.project
}

# Create regional autoscaler for the MIG
resource "google_compute_region_autoscaler" "autoscaler" {
  name    = "${var.vm_name}-autoscaler"
  project = var.project
  region  = var.region
  target  = google_compute_region_instance_group_manager.mig.id

  autoscaling_policy {
    max_replicas    = var.max_replicas
    min_replicas    = var.min_replicas
    cpu_utilization {
      target = var.cpu_utilization_target
    }
    cooldown_period = 60
  }
}

# Backend service for load balancer pointing to the regional MIG with port_name linked to named port
resource "google_compute_backend_service" "backend_service" {
  name          = "${var.vm_name}-backend-service"
  project       = var.project
  protocol      = "HTTP"
  timeout_sec   = 10
  health_checks = [google_compute_health_check.http_health_check.self_link]
  port_name     = "http"

  backend {
    group = google_compute_region_instance_group_manager.mig.instance_group
  }
}

# URL map to route all traffic to backend service
resource "google_compute_url_map" "url_map" {
  name            = "${var.vm_name}-url-map"
  project         = var.project
  default_service = google_compute_backend_service.backend_service.self_link
}

# Target HTTP proxy for load balancer
resource "google_compute_target_http_proxy" "http_proxy" {
  name    = "${var.vm_name}-http-proxy"
  project = var.project
  url_map = google_compute_url_map.url_map.self_link
}

# Reserve a global static IP for the load balancer
resource "google_compute_global_address" "lb_ip" {
  name    = "${var.vm_name}-lb-ip"
  project = var.project
}

# Forwarding rule to route external traffic to the HTTP proxy
resource "google_compute_global_forwarding_rule" "forwarding_rule" {
  name       = "${var.vm_name}-forwarding-rule"
  project    = var.project
  ip_address = google_compute_global_address.lb_ip.address
  target     = google_compute_target_http_proxy.http_proxy.self_link
  port_range = "80"
}
