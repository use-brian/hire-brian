output "public_ip" {
  value = google_compute_instance.brian.network_interface[0].access_config[0].nat_ip
}
output "ssh_command" {
  value = "ssh ${var.ssh_user}@${google_compute_instance.brian.network_interface[0].access_config[0].nat_ip}"
}
