variable "project_id" { type = string }
variable "region" {
  type    = string
  default = "us-central1"
}
variable "zone" {
  type    = string
  default = "us-central1-a"
}
variable "name" {
  type    = string
  default = "hire-brian"
}
variable "machine_type" {
  type    = string
  default = "e2-standard-4"
}
variable "disk_size_gb" {
  type    = number
  default = 60
}
variable "ssh_user" {
  type    = string
  default = "debian"
}
variable "ssh_public_key" {
  type      = string
  sensitive = true
}
variable "ssh_cidr" {
  type = string
  validation {
    condition     = var.ssh_cidr != "0.0.0.0/0"
    error_message = "Do not expose SSH to the entire internet."
  }
}
