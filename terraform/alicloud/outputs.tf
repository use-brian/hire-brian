output "public_ip" {
  value = alicloud_instance.brian.public_ip
}
output "ssh_command" {
  value = "ssh root@${alicloud_instance.brian.public_ip}"
}
