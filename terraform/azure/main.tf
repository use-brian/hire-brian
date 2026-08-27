terraform {
  required_version = ">= 1.6.0"
  required_providers { azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" } }
}
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

resource "azurerm_resource_group" "brian" {
  name     = "${var.name}-rg"
  location = var.location
}
resource "azurerm_virtual_network" "brian" {
  name                = "${var.name}-vnet"
  location            = var.location
  resource_group_name = azurerm_resource_group.brian.name
  address_space       = ["10.42.0.0/16"]
}
resource "azurerm_subnet" "brian" {
  name                 = "${var.name}-subnet"
  resource_group_name  = azurerm_resource_group.brian.name
  virtual_network_name = azurerm_virtual_network.brian.name
  address_prefixes     = ["10.42.1.0/24"]
}
resource "azurerm_public_ip" "brian" {
  name                = "${var.name}-ip"
  location            = var.location
  resource_group_name = azurerm_resource_group.brian.name
  allocation_method   = "Static"
  sku                 = "Standard"
}
resource "azurerm_network_security_group" "brian" {
  name                = "${var.name}-nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.brian.name
  security_rule {
    name                       = "SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.ssh_cidr
    destination_address_prefix = "*"
  }
}
resource "azurerm_network_interface" "brian" {
  name                = "${var.name}-nic"
  location            = var.location
  resource_group_name = azurerm_resource_group.brian.name
  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.brian.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.brian.id
  }
}
resource "azurerm_network_interface_security_group_association" "brian" {
  network_interface_id = azurerm_network_interface.brian.id
  network_security_group_id = azurerm_network_security_group.brian.id
}
resource "azurerm_linux_virtual_machine" "brian" {
  name                            = var.name
  location                        = var.location
  resource_group_name             = azurerm_resource_group.brian.name
  size                            = var.vm_size
  admin_username                  = var.ssh_user
  network_interface_ids           = [azurerm_network_interface.brian.id]
  disable_password_authentication = true
  admin_ssh_key {
    username   = var.ssh_user
    public_key = trimspace(var.ssh_public_key)
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.disk_size_gb
  }
  source_image_reference {
    publisher = "Debian"
    offer     = "debian-12"
    sku       = "12-gen2"
    version   = "latest"
  }
}
