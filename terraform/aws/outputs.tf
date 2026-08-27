output "public_ip" {
  value = aws_instance.brian.public_ip
}
output "ssh_command" {
  value = "ssh admin@${aws_instance.brian.public_ip}"
}
