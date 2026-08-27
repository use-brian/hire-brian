variable "subscription_id" { type = string }
variable "location" {
  type    = string
  default = "East US"
}
variable "name" {
  type    = string
  default = "hire-brian"
}
variable "vm_size" {
  type    = string
  default = "Standard_D4s_v5"
}
variable "disk_size_gb" {
  type    = number
  default = 64
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
