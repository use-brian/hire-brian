variable "region" {
  type    = string
  default = "us-east-1"
}
variable "name" {
  type    = string
  default = "hire-brian"
}
variable "instance_type" {
  type    = string
  default = "t3.xlarge"
}
variable "disk_size_gb" {
  type    = number
  default = 60
}
variable "key_name" {
  type        = string
  description = "Existing EC2 key pair name."
}
variable "ssh_cidr" {
  type = string
  description = "Trusted source CIDR for SSH, preferably your.ip/32."
  validation {
    condition     = var.ssh_cidr != "0.0.0.0/0"
    error_message = "Do not expose SSH to the entire internet."
  }
}
