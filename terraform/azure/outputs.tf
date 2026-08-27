output "public_ip" {
  value = azurerm_public_ip.brian.ip_address
}
output "ssh_command" {
  value = "ssh ${var.ssh_user}@${azurerm_public_ip.brian.ip_address}"
}
