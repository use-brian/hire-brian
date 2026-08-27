# Deployment targets

- `oss/`: native Debian 12/13 installation of the public Use Brian OSS edition.
- `outpost/`: fully native production Debian 12/13 installation built from an operator-supplied Outpost source tree.

The targets are independent. Do not run both installers on the same host or point them at the same database. Start with the README inside the selected target.

`common.sh` contains installer behavior shared by both targets: prompting, secret input, environment serialization, model-provider configuration, and external PostgreSQL validation.
