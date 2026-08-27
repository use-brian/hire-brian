# Hire Brian

Infrastructure and Debian deployment tooling for single-host Use Brian installations.

## Layout

- `terraform/`: independent AWS, Google Cloud, Azure, and Alibaba Cloud configurations.
- `deployment/oss/`: public OSS edition using native systemd services.
- `deployment/outpost/`: fully native multi-user production Outpost setup.

## Quick start

1. Provision a host with one of the configurations in `terraform/`.
2. SSH to the host and clone this repository.
3. Choose a target and read its deployment guide.
4. Run `sudo deployment/oss/install.sh` for OSS or `sudo deployment/outpost/install.sh` for Outpost. Outpost defaults to cloning `BRIAN_REPO` at `BRIAN_REF`; directory mode accepts an existing source tree.
5. Keep loopback listeners private. The installers default to Caddy-managed HTTPS/WSS; choose `REVERSE_PROXY_SETUP=custom` for another proxy or tunnel. For diagnostics:

```bash
ssh -L 3003:127.0.0.1:3003 \
  -L 4000:127.0.0.1:4000 \
  -L 8080:127.0.0.1:8080 SSH_USER@SERVER_IP
```

Use `terraform output -raw ssh_command` in the selected Terraform directory for the provider-specific login.
When using default Caddy setup, add cloud firewall/security-group rules for public TCP 80/443; Terraform keeps application ingress closed by default.

Both targets support local or external PostgreSQL 18 with separate owner and RLS application roles. They clone public `use-brian` by default, build versioned native releases, and run services directly under systemd.

`BRIAN_USER` defaults to `brian`. Local PostgreSQL, LibreOffice, and each channel connector default to enabled; the browser desktop defaults to disabled.

See `terraform/README.md`, `deployment/oss/README.md`, and `deployment/outpost/README.md` for complete instructions.
