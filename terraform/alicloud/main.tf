terraform {
  required_version = ">= 1.6.0"
  required_providers { alicloud = { source = "aliyun/alicloud", version = "~> 1.250" } }
}
provider "alicloud" { region = var.region }

data "alicloud_images" "debian" {
  owners       = "system"
  name_regex   = "^debian_12_.*_x64_"
  architecture = "x86_64"
  most_recent  = true
}
resource "alicloud_vpc" "brian" {
  vpc_name  = "${var.name}-vpc"
  cidr_block = "10.42.0.0/16"
}
resource "alicloud_vswitch" "brian" {
  vpc_id       = alicloud_vpc.brian.id
  cidr_block   = "10.42.1.0/24"
  zone_id      = var.zone_id
  vswitch_name = "${var.name}-vswitch"
}
resource "alicloud_security_group" "brian" {
  security_group_name = "${var.name}-sg"
  vpc_id              = alicloud_vpc.brian.id
}
resource "alicloud_security_group_rule" "ssh" {
  security_group_id = alicloud_security_group.brian.id
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "22/22"
  cidr_ip           = var.ssh_cidr
  policy            = "accept"
  priority          = 1
}
resource "alicloud_instance" "brian" {
  instance_name              = var.name
  host_name                  = var.name
  image_id                   = data.alicloud_images.debian.images[0].id
  instance_type              = var.instance_type
  vswitch_id                 = alicloud_vswitch.brian.id
  security_groups            = [alicloud_security_group.brian.id]
  internet_max_bandwidth_out = var.bandwidth_mbps
  system_disk_category       = "cloud_essd"
  system_disk_size           = var.disk_size_gb
  key_name                   = var.key_pair_name
}
