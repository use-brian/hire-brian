# Terraform

Each cloud directory is an independent Terraform root module. All modules create one Debian 12 VM with a public IP and permit inbound TCP port 22 only from `ssh_cidr`; application and VNC ports remain private. If using a non-22 installer `SSH_PORT`, update the selected cloud firewall too.

## Usage

```bash
cd terraform/aws # or gcp, azure, alicloud
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars, then authenticate with the cloud CLI/environment.
terraform init
terraform plan
terraform apply
terraform output -raw public_ip
terraform output -raw ssh_command

# When no longer needed:
terraform destroy
```

Required inputs are AWS `key_name`/`ssh_cidr`; GCP `project_id`/`ssh_public_key`/`ssh_cidr`; Azure `subscription_id`/`ssh_public_key`/`ssh_cidr`; and Alibaba Cloud `key_pair_name`/`ssh_cidr`. GCP/Azure default to user `debian`, AWS outputs `admin`, and Alibaba outputs `root`.

Recommended minimum is 4 vCPU, 8 GB RAM, and 50 GB disk. Defaults are 60 GB for AWS/GCP/Alibaba and 64 GB for Azure. Reduce capacity only after measuring build/runtime requirements.

Cloud credentials are intentionally not accepted as Terraform variables. Use the standard provider authentication methods. Pin and commit `.terraform.lock.hcl` in a real deployment if reproducible provider selection is required.
