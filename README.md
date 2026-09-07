# Hire Brian

Infrastructure and deployment tooling for single-host Use Brian installations.

## Layout

- `terraform/`: independent AWS, Google Cloud, Azure, and Alibaba Cloud configurations.
- `deployment/oss/`: public OSS edition using native systemd services.
- `deployment/compose/`: public OSS edition using Docker Compose and GHCR images.
- `deployment/outpost/`: fully native multi-user production Outpost setup.

## Quick start

1. Provision a host with one of the configurations in `terraform/`.
2. SSH to the host and clone this repository.
3. Choose the OSS Docker Compose, OSS native systemd, or native Outpost target.
4. For Compose, set the four DNS hostnames and run `deployment/compose/install.sh`. See [`deployment/compose/README.md`](deployment/compose/README.md).
5. For native OSS, run `sudo deployment/oss/install.sh`. For native Outpost, run `sudo deployment/outpost/install.sh`; Outpost accepts a repository/ref or an existing source tree.
6. Keep application listeners private. All default paths use Caddy-managed HTTPS/WSS; the native installers also support `REVERSE_PROXY_SETUP=custom`. For native-install diagnostics:

```bash
ssh -L 3003:127.0.0.1:3003 \
  -L 4000:127.0.0.1:4000 \
  -L 8080:127.0.0.1:8080 SSH_USER@SERVER_IP
```

Use `terraform output -raw ssh_command` in the selected Terraform directory for the provider-specific login.
When using default Caddy setup, add cloud firewall/security-group rules for public TCP 80/443; Terraform keeps application ingress closed by default.

All targets use PostgreSQL 18 with separate owner and RLS application roles.
The Compose target runs local PostgreSQL and containerized services. The native
targets support local or external PostgreSQL, build versioned releases, and run
services directly under systemd.

`BRIAN_USER` defaults to `brian`. Local PostgreSQL, LibreOffice, and each channel connector default to enabled; the browser desktop defaults to disabled.

See `terraform/README.md`, `deployment/compose/README.md`,
`deployment/oss/README.md`, and `deployment/outpost/README.md` for complete
instructions.
