terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 7.0" }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

resource "google_compute_network" "brian" {
  name                    = "${var.name}-network"
  auto_create_subnetworks = false
}
resource "google_compute_subnetwork" "brian" {
  name          = "${var.name}-subnet"
  region        = var.region
  network       = google_compute_network.brian.id
  ip_cidr_range = "10.42.1.0/24"
}
resource "google_compute_firewall" "ssh" {
  name          = "${var.name}-ssh"
  network       = google_compute_network.brian.name
  source_ranges = [var.ssh_cidr]
  target_tags   = [var.name]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
resource "google_compute_instance" "brian" {
  name         = var.name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = [var.name]
  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = var.disk_size_gb
      type  = "pd-balanced"
    }
  }
  network_interface {
    subnetwork = google_compute_subnetwork.brian.id
    access_config {}
  }
  metadata = { ssh-keys = "${var.ssh_user}:${trimspace(var.ssh_public_key)}" }
  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }
}
