variable "region" {
  type    = string
  default = "cn-hongkong"
}
variable "zone_id" {
  type    = string
  default = "cn-hongkong-b"
}
variable "name" {
  type    = string
  default = "hire-brian"
}
variable "instance_type" {
  type    = string
  default = "ecs.g7.xlarge"
}
variable "disk_size_gb" {
  type    = number
  default = 60
}
variable "bandwidth_mbps" {
  type    = number
  default = 10
}
variable "key_pair_name" {
  type        = string
  description = "Existing ECS SSH key pair name."
}
variable "ssh_cidr" {
  type = string
  validation {
    condition     = var.ssh_cidr != "0.0.0.0/0"
    error_message = "Do not expose SSH to the entire internet."
  }
}
