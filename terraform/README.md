# Terraform

Each cloud directory is an independent Terraform root module. All modules create one Debian 12 VM, a public IP, and a firewall/security-group rule allowing SSH only from `ssh_cidr`. Application and VNC ports remain private by design.

## Usage

```bash
cd terraform/aws # or gcp, azure, alicloud
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars, then authenticate with the cloud CLI/environment.
terraform init
terraform plan
terraform apply
terraform output -raw public_ip
```

Recommended minimum is 4 vCPU, 8 GB RAM, and 50 GB disk when building Use Brian on the instance. Reduce the instance size after the build only if runtime memory has been measured.

Cloud credentials are intentionally not accepted as Terraform variables. Use the standard provider authentication methods. Pin and commit `.terraform.lock.hcl` in a real deployment if reproducible provider selection is required.
