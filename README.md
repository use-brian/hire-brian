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
4. Run `sudo deployment/oss/install.sh` for OSS, or supply an Outpost release and run `sudo deployment/outpost/install.sh`.
5. Put the configured HTTPS origins behind a reverse proxy/tunnel, then forward loopback listeners for diagnostics if needed:

```bash
ssh -L 3003:127.0.0.1:3003 \
  -L 4000:127.0.0.1:4000 \
  -L 8080:127.0.0.1:8080 debian@SERVER_IP
```

Both targets support local or external PostgreSQL 18 with separate owner and RLS application roles. Each target builds its supplied source tree into versioned native releases and runs services directly under systemd.

See `terraform/README.md`, `deployment/oss/README.md`, and `deployment/outpost/README.md` for complete instructions.
