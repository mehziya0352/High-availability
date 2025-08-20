variable "project" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "zone" {
  description = "GCP zone"
  type        = string
}
variable "zones" {
  description = "List of zones inside the region for Regional MIG"
  type        = list(string)
  default     = ["us-central1-b", "us-central1-c"]
}

variable "vm_name" {
  description = "Name of existing VM to create image from"
  type        = string
  default     = "vm1-monitoring"
}

variable "machine_type" {
  description = "Machine type for instance template"
  type        = string
  default     = "e2-medium"
}

variable "min_replicas" {
  description = "Minimum number of instances in MIG"
  type        = number
  default     = 1
}

variable "max_replicas" {
  description = "Maximum number of instances in MIG"
  type        = number
  default     = 5
}

variable "cpu_utilization_target" {
 description = "CPU utilization target for autoscaling"
  type        = number
  default     = 0.8
}
variable "influxdb_org" {
  description = "Influxdb organisation name"
  type        = string
}
variable "influxdb_bucket" {
  description = "Influxdb bucket name"
  type        = string
}
variable "influxdb_token" {
  description = "Influxdb token"
  type        = string
}

variable "influxdb_vm_ip" {
  description = "Private or public IP of the InfluxDB + Grafana VM"
  type        = string
}
