# Get existing VM info (source for snapshot)
data "google_compute_instance" "vm1" {
  name    = var.vm_name
  zone    = var.zone
  project = var.project
}

# Snapshot from VM boot disk
resource "google_compute_snapshot" "vm_snapshot" {
  name        = "${var.vm_name}-snapshot"
  project     = var.project
  zone        = var.zone
  source_disk = data.google_compute_instance.vm1.boot_disk[0].source
}

# Custom image from snapshot
resource "google_compute_image" "vm1_custom_image" {
  name            = "${var.vm_name}-custom-image"
  project         = var.project
  source_snapshot = google_compute_snapshot.vm_snapshot.name
}

# Instance template
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
   # Telegraf config pushed via metadata (InfluxDB v2)
  metadata = {
    telegraf_conf = <<-EOT
      [agent]
        interval = "10s"
        round_interval = true

      [[outputs.influxdb_v2]]
        urls = ["http://${var.influxdb_vm_ip}:8086"]
        token = "${var.influxdb_token}"
        organization = "${var.influxdb_org}"
        bucket = "${var.influxdb_bucket}"

      [[inputs.cpu]]
        percpu = true
        totalcpu = true
      [[inputs.mem]]
      [[inputs.disk]]
      [[inputs.net]]
    EOT
  }

  # Startup script installs & applies Telegraf config
  metadata_startup_script = <<-EOT
    #!/bin/bash
    set -e
    apt-get update -y
    apt-get install -y wget gnupg curl

    wget -qO- https://repos.influxdata.com/influxdata-archive.key | apt-key add -
    echo "deb https://repos.influxdata.com/debian stable main" > /etc/apt/sources.list.d/influxdata.list
    apt-get update -y
    apt-get install -y telegraf

    curl -s -H "Metadata-Flavor: Google" \
      http://metadata.google.internal/computeMetadata/v1/instance/attributes/telegraf_conf \
      -o /etc/telegraf/telegraf.conf

    systemctl enable telegraf
    systemctl restart telegraf
  EOT
}

# ✅ Regional Health Check (fixed)
resource "google_compute_region_health_check" "http_health_check" {
  name                = "${var.vm_name}-health-check"
  project             = var.project
  region              = var.region
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2

  http_health_check {
    port         = 80
    request_path = "/"
  }
}

# ✅ Regional MIG
resource "google_compute_region_instance_group_manager" "mig" {
  name               = "${var.vm_name}-regional-mig"
  project            = var.project
  region             = var.region
  base_instance_name = var.vm_name
  target_size        = var.min_replicas

  version {
    instance_template = google_compute_instance_template.vm1_template.self_link
  }

  # Distribute across multiple zones
  distribution_policy_zones = var.zones

  auto_healing_policies {
    health_check      = google_compute_region_health_check.http_health_check.self_link
    initial_delay_sec = 300
  }
}

# ✅ Regional Autoscaler
resource "google_compute_region_autoscaler" "autoscaler" {
  name    = "${var.vm_name}-regional-autoscaler"
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

# ✅ Backend service with depends_on
resource "google_compute_region_backend_service" "backend_service" {
  name                  = "${var.vm_name}-backend-service"
  project               = var.project
  protocol              = "HTTP"
  timeout_sec           = 10
  load_balancing_scheme = "EXTERNAL_MANAGED"
  health_checks         = [google_compute_region_health_check.http_health_check.self_link]

  backend {
    group = google_compute_region_instance_group_manager.mig.instance_group
    balancing_mode  = "UTILIZATION"
    max_utilization = 0.8
    capacity_scaler = 1.0
  }

  depends_on = [
    google_compute_region_health_check.http_health_check
  ]
}

# Regional IP Address
resource "google_compute_address" "lb_ip" {
  name    = "${var.vm_name}-lb-ip"
  project = var.project
  region  = var.region
}

# Regional URL Map
resource "google_compute_region_url_map" "url_map" {
  name            = "${var.vm_name}-url-map"
  project         = var.project
  region          = var.region
  default_service = google_compute_region_backend_service.backend_service.self_link
}

# Regional Target HTTP Proxy
resource "google_compute_region_target_http_proxy" "http_proxy" {
  name    = "${var.vm_name}-http-proxy"
  project = var.project
  region  = var.region
  url_map = google_compute_region_url_map.url_map.self_link
}
resource "google_compute_firewall" "mig_to_influxdb" {
  name    = "allow-mig-to-influxdb"
  network = "default"
  project = var.project

  allow {
    protocol = "tcp"
    ports    = ["8086"]
  }

  source_tags = ["http-server"] # MIG
  target_tags = ["influxdb"]    # Your InfluxDB VM
}
# Proxy-only subnet for LB
resource "google_compute_subnetwork" "proxy_only_subnet" {
  name          = "proxy-only-subnet"
  ip_cidr_range = "10.129.0.0/23"     # must be /23
  region        = var.region
  network       = "default"

  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

resource "google_compute_forwarding_rule" "forwarding_rule" {
  name                   = "${var.vm_name}-forwarding-rule"
  project                = var.project
  region                 = var.region
  ip_address             = google_compute_address.lb_ip.address
  target                 = google_compute_region_target_http_proxy.http_proxy.self_link
  port_range             = "80"
  load_balancing_scheme  = "EXTERNAL_MANAGED"
  network                = "default"

  # 🔑 Required for regional external HTTP(S) LB
  subnetwork             = google_compute_subnetwork.proxy_only_subnet.self_link
}
