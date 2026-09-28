# Deploy Use Brian Outpost on Alibaba Cloud

> Scope: deploy the public `use-brian` source from the public `hire-brian` deployment repository in native Outpost mode on Alibaba Cloud ECS. This guide uses DashScope for models, PolarDB for PostgreSQL, and Alibaba Mail or DirectMail SMTP for sign-in email.

## 1. Resulting deployment

The deployment uses these components:

| Component | Alibaba Cloud resource or host service | Notes |
| --- | --- | --- |
| Application host | ECS running Debian 12 | Native systemd services; no Docker |
| Database | PolarDB for PostgreSQL | PostgreSQL 18 with `vector` and `pg_trgm` is a deployment gate |
| Models | Alibaba Cloud Model Studio / DashScope | API key and API Host must belong to the same region |
| Sign-in email | Alibaba Mail or DirectMail SMTP | Use a complete mailbox address and an SMTP password |
| HTTPS and WSS | Caddy on ECS | Default proxy mode obtains and renews public certificates |
| DNS | Alibaba Cloud DNS or another public DNS provider | Four distinct hostnames point to the ECS public IP |

Core services use these host ports:

| Service | Host port | Public entry point |
| --- | ---: | --- |
| app-web | 3003 | `https://app.outpost.example.com` |
| API | 4000 | `https://api.outpost.example.com` |
| auth-web | 3005 | `https://auth.outpost.example.com` |
| doc-sync | 8080 | `wss://docs.outpost.example.com` |

Do not expose application or connector ports directly. The service units set ports but do not guarantee that every application listens only on loopback. Their protection therefore depends on both UFW and the ECS security group. Permit public inbound traffic only to 80/443. Restrict SSH to an administrator-controlled source, such as a fixed public IP `/32`, a VPN, or a bastion.

![Alibaba Cloud Outpost deployment architecture](images/alicloud-outpost-architecture.svg)

## 2. Prerequisites

Prepare:

1. An Alibaba Cloud account permitted to create ECS, VPC, security-group, and PolarDB resources.
2. An ECS SSH key pair.
3. A domain with publicly managed DNS.
4. A Model Studio / DashScope API key and the matching regional API Host.
5. A verified Alibaba Mail or DirectMail sender, such as `notifications@customer.example`, and its SMTP password.
6. A PolarDB for PostgreSQL 18 cluster whose exact engine edition and region pass the extension gate in section 3.
7. Approval for the five bootstrap administrator addresses listed in section 9.2. Each address can complete initial sign-in without an invitation.

Suggested minimum ECS capacity:

- 4 vCPU
- 8 GB RAM; 16 GB is preferable
- 60 GB ESSD system disk
- Debian 12, amd64 or arm64

The installer supports Debian 12 or 13 and amd64 or arm64. This guide standardizes on Debian 12. Next.js builds are memory intensive. Builds are serialized, but an 8 GB host should also have persistent swap.

## 3. Compatibility gates

### 3.1 PostgreSQL 18 is mandatory

The installer accepts `server_version_num` from `180000` through `189999`. Select PostgreSQL 18 when creating PolarDB and verify the actual endpoint before deployment:

```sql
SHOW server_version;
SHOW server_version_num;
```

Alibaba Cloud product availability varies by region and edition. Confirm PostgreSQL 18 is offered in the target PolarDB console rather than assuming another region's catalog applies. The installer is the final version check.

### 3.2 Two database roles are mandatory

Outpost uses separate roles:

- `brian_owner` owns objects and runs migrations and system operations.
- `app_user` handles RLS-scoped application queries. It must be `NOSUPERUSER`, `NOBYPASSRLS`, and must not inherit a privileged role.

Both URLs should target the same `brian` database. The installer verifies PostgreSQL 18, distinct roles, the same target database, both installed extensions, and the application's privilege restrictions. It does not enforce these example role or database names.

### 3.3 `vector` and `pg_trgm` are deployment gates

`vector` supports vector search. `pg_trgm` supports text similarity and trigram indexes. PostgreSQL documents [`pg_trgm`](https://www.postgresql.org/docs/18/pgtrgm.html) and distinguishes extensions available to install from those already installed in [`pg_available_extensions`](https://www.postgresql.org/docs/18/view-pg-available-extensions.html).

Do not purchase or deploy a PolarDB PostgreSQL 18 configuration until the target engine edition, minor version, and region show both extensions as available. Connect to the intended `brian` database with a PolarDB privileged account and run:

```sql
SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('vector', 'pg_trgm')
ORDER BY name;
```

Both rows must exist. In particular, absence of `pg_trgm` is a hard deployment stop; PostgreSQL including it as a supplied module does not prove that a managed PolarDB build exposes it. Change the PolarDB edition, version, or region, or obtain confirmation and enablement from Alibaba Cloud support before continuing.

Extensions are database-local. Enable both in `brian` using a PolarDB privileged account through the console and/or DMS as supported by the selected product:

```sql
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;
```

Do not assume `brian_owner` can administer managed extensions. Even though upstream PostgreSQL classifies `pg_trgm` as trusted, PolarDB controls available packages and managed-account privileges. After enablement, verify in `brian`:

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('vector', 'pg_trgm')
ORDER BY extname;
```

The installer queries `pg_extension` and exits unless both are installed. Alibaba Cloud's current PolarDB product documentation and console remain authoritative for edition-specific extension and privileged-account procedures: [PolarDB for PostgreSQL documentation](https://www.alibabacloud.com/help/en/polardb/polardb-for-postgresql/).

## 4. Create Alibaba Cloud infrastructure

These steps use the Alibaba Cloud console.

### 4.1 Choose region and zone

Place ECS and PolarDB in the same region. For a private PolarDB endpoint, place them in the same VPC and ensure routes allow communication. Record the region, available zone, administrator source IP, and SSH key-pair name before creating resources.

### 4.2 Create the VPC and vSwitch

Under **Virtual Private Cloud -> VPC**, create values such as:

| Item | Example |
| --- | --- |
| VPC name | `outpost-vpc` |
| VPC IPv4 CIDR | `10.42.0.0/16` |
| vSwitch name | `outpost-vswitch` |
| vSwitch zone | A zone available to the intended ECS and PolarDB resources |
| vSwitch IPv4 CIDR | `10.42.1.0/24` |

Record the VPC ID, vSwitch ID, and CIDR. Select the same VPC for PolarDB. Add either the ECS private IP or the narrowly scoped vSwitch CIDR to the PolarDB allowlist.

### 4.3 Create the security group

Create `outpost-sg` in `outpost-vpc` with inbound rules:

| Protocol | Port | Source |
| --- | ---: | --- |
| TCP | 22 | `ADMIN_PUBLIC_IP/32` |
| TCP | 80 | `0.0.0.0/0` |
| TCP | 443 | `0.0.0.0/0` |

Do not open 3003, 3005, 4000, 8080, 8090-8095, or 5901. If IPv6 is enabled, create equally restrictive IPv6 rules; do not accidentally bypass the IPv4 policy. Prefer a bastion, VPN, or private management path and remove public SSH where possible. Permit SSH keys only and disable password authentication. When the administrator's public IP changes, update the `/32` rule instead of widening its source range.

For a restricted outbound policy, permit at least:

| Protocol | Port | Destination or purpose |
| --- | ---: | --- |
| TCP | 443 | GitHub, NodeSource, PostgreSQL apt, DashScope, and certificate services |
| TCP | 80 | Package repositories and ACME HTTP challenge traffic where required |
| TCP | 465 or 587 | The selected Alibaba Mail or DirectMail SMTP endpoint |
| TCP | Displayed database port | The selected private PolarDB endpoint |

A default allow-all outbound policy normally covers these requirements. Use the database port displayed by PolarDB rather than assuming it is always 5432.

### 4.4 Create ECS

Use settings such as:

| Console field | Recommended value |
| --- | --- |
| Billing | Pay-as-you-go for evaluation; an appropriate subscription for production |
| Region | Same as VPC and PolarDB |
| Zone and network | `outpost-vpc` / `outpost-vswitch` |
| Instance type | At least 4 vCPU / 8 GB; preferably 16 GB RAM |
| Image | Official Debian 12 64-bit image |
| System disk | ESSD, at least 60 GB |
| Public IP | Allocate public IPv4 if using direct public ingress |
| Security group | `outpost-sg` |
| Credentials | SSH key pair |
| Instance and host name | `use-brian-outpost` |

Record the public IP, private IP, VPC, vSwitch, and security group.

### 4.5 First login and persistent swap

```bash
ssh root@ECS_PUBLIC_IP
cat /etc/os-release
dpkg --print-architecture
free -h
df -h /
ps -p 1 -o comm=
```

Confirm Debian 12, amd64 or arm64, adequate memory and disk, and systemd as PID 1.

On an 8 GB host, create persistent 8 GB swap before installation:

```bash
fallocate -l 8G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
swapon --show
```

Before appending, check `/etc/fstab` and do not add a duplicate `/swapfile` entry. A swap file reduces build failures but is not a substitute for sufficient RAM or monitoring.

## 5. Create and prepare PolarDB

### 5.1 Network and allowlist

1. Create PolarDB for PostgreSQL 18 in the ECS region and VPC.
2. Add the ECS private IP, preferably as `/32`, or the required vSwitch CIDR to the PolarDB allowlist.
3. Use the private endpoint and its displayed port.
4. Do not enable a public database endpoint unless there is a documented need.

An allowlist remains required in the same VPC. Never use `0.0.0.0/0`. If VPCs differ, configure an explicit supported connection such as Cloud Enterprise Network, or redesign the placement.

### 5.2 Create database and roles

Use a PolarDB privileged account in DMS. These statements express the required state; adjust account-management steps to current PolarDB controls:

```sql
CREATE ROLE brian_owner LOGIN PASSWORD 'REPLACE_OWNER_PASSWORD';
CREATE ROLE app_user LOGIN PASSWORD 'REPLACE_APP_PASSWORD'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
CREATE DATABASE brian OWNER brian_owner;
```

Reconnect explicitly to `brian`, run the availability gate in section 3.3, and use the PolarDB privileged account to enable `vector` and `pg_trgm`. Ensure `brian_owner` can create objects in `brian` and grant privileges to `app_user`. The installer grants current and default object privileges after migrations.

### 5.3 TLS, endpoints, and connection URLs

Treat these as separate controls:

1. **Endpoint choice:** use the PolarDB endpoint type supported for SSL by the selected product. If Alibaba Cloud requires its primary endpoint for SSL configuration or certificate association, use that primary endpoint; a private endpoint is not automatically encrypted.
2. **Server SSL enablement:** enable SSL for the cluster/endpoint in the PolarDB console. Merely adding `sslmode` to a URL cannot enable server-side SSL.
3. **Client enforcement:** `sslmode=require` encrypts but does not normally authenticate the server identity. `verify-ca` validates the CA. `verify-full` validates the CA and that the URL hostname matches the certificate, and is preferred where supported.
4. **CA installation:** download the current CA chain from the PolarDB console/documentation, store the public CA certificate in a root-owned file that both the installer and the `brian` service account can read, and reference it with `sslrootcert`. For example, install it as `/etc/ssl/certs/polardb-ca.pem` with mode `0644`. Do not invent a CA path or use an IP address with `verify-full` unless the certificate covers it.
5. **Renewal:** record certificate and CA expiry, monitor Alibaba Cloud notices, and replace CA material and restart/reload Outpost clients before expiry or provider rotation. Caddy's public web-certificate renewal is unrelated and does not renew PolarDB certificates.

PostgreSQL explains the exact guarantees of each mode in [libpq SSL support](https://www.postgresql.org/docs/18/libpq-ssl.html). Confirm current endpoint restrictions, certificate download steps, validity periods, and restart effects in the [Alibaba Cloud PolarDB documentation](https://www.alibabacloud.com/help/en/polardb/polardb-for-postgresql/) before enabling SSL.

Example with encryption but no identity verification:

```text
postgresql://brian_owner:URL_ENCODED_PASSWORD@POLARDB_PRIMARY_ENDPOINT:5432/brian?sslmode=require&connect_timeout=10
postgresql://app_user:URL_ENCODED_PASSWORD@POLARDB_PRIMARY_ENDPOINT:5432/brian?sslmode=require&connect_timeout=10
```

Preferred example after installing the correct provider CA:

```text
postgresql://brian_owner:URL_ENCODED_PASSWORD@POLARDB_PRIMARY_ENDPOINT:5432/brian?sslmode=verify-full&sslrootcert=%2Fetc%2Fssl%2Fcerts%2Fpolardb-ca.pem&connect_timeout=10
postgresql://app_user:URL_ENCODED_PASSWORD@POLARDB_PRIMARY_ENDPOINT:5432/brian?sslmode=verify-full&sslrootcert=%2Fetc%2Fssl%2Fcerts%2Fpolardb-ca.pem&connect_timeout=10
```

URL-encode passwords and parameter values. If SSL truly is unavailable, `sslmode=disable` is possible only after accepting the installer's explicit warning. That is not recommended for production.

## 6. Configure DNS

Use a deployment-specific cookie namespace:

```text
Public HTTPS application origin: https://app.outpost.example.com
Public HTTPS API origin: https://api.outpost.example.com
Public HTTPS authentication origin: https://auth.outpost.example.com
Public WSS document-sync origin: wss://docs.outpost.example.com
Isolated cookie domain (for example .customer.example): .outpost.example.com
```

Create four A records pointing to the ECS public IP:

| Type | Name | Value |
| --- | --- | --- |
| A | `app.outpost` | `ECS_PUBLIC_IP` |
| A | `api.outpost` | `ECS_PUBLIC_IP` |
| A | `auth.outpost` | `ECS_PUBLIC_IP` |
| A | `docs.outpost` | `ECS_PUBLIC_IP` |

Remove stale AAAA records unless IPv6 ingress is deliberately configured. If a DNS proxy does not cover these multi-level names with its certificate, use DNS-only records and let Caddy terminate TLS. Do not use a registrable root such as `.example.com` as the cookie domain.

## 7. Configure DashScope

Create the key in Model Studio and identify the API Host for that same region/workspace. Alibaba Cloud states that regional API keys are not interchangeable and that Base URLs vary by region; see [First API call to Qwen](https://www.alibabacloud.com/help/en/model-studio/first-api-call-to-qwen).

The key and API Host must match. Test them together before installation. At the prompts use:

```text
Primary model provider (gemini/vertex/dashscope/openai-codex): dashscope
DashScope API key: <matching regional key>
DashScope base URL (leave blank for default): <matching API Host, or blank only as described below>
```

Leaving `DashScope base URL` blank is not a general Alibaba Cloud auto-detection mechanism. It selects this implementation's built-in international default because the installer sets `USEBRIAN_PREFERRED_PROVIDER=dashscope-intl`. Leave it blank only when the key is for that implementation default. For China or another regional/workspace endpoint, enter the compatible API Host supplied by Model Studio and ensure the key was created in that region.

## 8. Configure Alibaba SMTP

Use organization-controlled values, for example:

```text
SMTP account: notifications@customer.example
Email from address: notifications@customer.example
```

For Alibaba Mail, a commonly encountered configuration is:

```text
SMTP server host: smtp.qiye.aliyun.com
SMTP server port: 465
Use implicit SMTP TLS? (true for port 465, false for STARTTLS): true
```

Console-provided settings take precedence. For DirectMail, use the regional SMTP endpoint, verified sender, and SMTP password shown by that service. An Alibaba Cloud API AccessKey is not an SMTP password. Confirm sender verification, SMTP client access, outbound connectivity, SPF/DKIM/DMARC policy, and receipt in the organization's mail system.

## 9. Run the installer

### 9.1 Fetch the public deployment repository

```bash
ssh root@ECS_PUBLIC_IP
apt-get update
apt-get install -y git
git clone https://github.com/use-brian/hire-brian.git
cd hire-brian/deployment/outpost
sudo ./install.sh
```

### 9.2 Exact installer prompts

The text below is copied from `deployment/common.sh` and `deployment/outpost/install.sh`. Defaults may be appended in square brackets by the prompt helper. Conditional prompts appear only for the selected path.

| Exact prompt text | Condition | Recommended answer for this guide |
| --- | --- | --- |
| `Dedicated service user` | Always | `brian` |
| `Outpost source mode (repository/directory)` | Always | `repository` |
| `Use Brian repository` | Repository | `https://github.com/use-brian/use-brian.git` |
| `Git branch, tag, or commit` | Repository | `main` |
| `Absolute path to an existing use-brian source tree` | Directory | Not used here |
| `SSH server port to preserve in UFW` | Always | Actual sshd port, normally `22` |
| `Install PostgreSQL 18 and pgvector locally? (yes/no)` | Always | `no` |
| `Install headless LibreOffice for PDF exports? (yes/no)` | Always | Default `yes`; keep it if PDF export is required |
| `Install Chromium, Xfce, Xvfb, and local-only VNC? (yes/no)` | Always | Normally `no` |
| `Enable Discord connector? (yes/no)` | Always | Default `yes`; enable only if required |
| `Enable WhatsApp connector? (yes/no)` | Always | Default `yes`; enable only if required |
| `Enable WeChat connector? (yes/no)` | Always | Default `yes`; enable only if required |
| `Enable Feishu connector? (yes/no)` | Always | Default `yes`; enable only if required |
| `Public HTTPS application origin` | Always | `https://app.outpost.example.com` |
| `Public HTTPS API origin` | Always | `https://api.outpost.example.com` |
| `Public HTTPS authentication origin` | Always | `https://auth.outpost.example.com` |
| `Public WSS document-sync origin` | Always | `wss://docs.outpost.example.com` |
| `Isolated cookie domain (for example .customer.example)` | Always | `.outpost.example.com` |
| `Trust sanitized proxy client-IP headers? (true/false)` | Always | `false` for direct Caddy ingress |
| `Primary model provider (gemini/vertex/dashscope/openai-codex)` | Always | `dashscope` |
| `Gemini API key` | Gemini | Not used here |
| `Google Cloud project id` | Vertex | Not used here |
| `Vertex AI location` | Vertex | Not used here |
| `DashScope API key` | DashScope | Matching regional key |
| `DashScope base URL (leave blank for default)` | DashScope | Matching API Host; blank only for implementation's international default |
| `Authentication method (email/oidc)` | Always | `email` for this guide |
| `Bootstrap administrator email` | Always | The five comma-separated addresses below |
| `SMTP server host` | Email | Console-provided host |
| `SMTP server port` | Email | `465` for implicit TLS or normally `587` for STARTTLS |
| `Use implicit SMTP TLS? (true for port 465, false for STARTTLS)` | Email | Match the SMTP service |
| `SMTP account` | Email | `notifications@customer.example` |
| `SMTP password` | Email | SMTP/app password |
| `Email from address` | Email | Verified sender such as `notifications@customer.example` |
| `OIDC discovery issuer URL` | OIDC | Not used here |
| `OIDC client id` | OIDC | Not used here |
| `OIDC client secret` | OIDC | Not used here |
| `OIDC provider display name` | OIDC | Not used here |
| `External PostgreSQL owner URL with TLS` | External PostgreSQL | `brian_owner` URL |
| `External PostgreSQL RLS-role URL with TLS` | External PostgreSQL | `app_user` URL to the same database |
| `TLS is not enforced for every external PostgreSQL URL. Continue insecurely? (yes/no)` | A URL lacks an enforcing `sslmode` | `no`; correct TLS first |
| `VNC password (maximum 8 characters)` | Browser desktop enabled interactively | Organization-controlled secret, at most 8 characters |
| `Reverse proxy setup (default/custom)` | Final setup | `default` to install Caddy |

Secret values display as asterisks.

For `Bootstrap administrator email`, enter this complete comma-separated line:

```text
contact@usebrian.ai,hinson@usebrian.ai,wongkahinhinson@gmail.com,jingles@maliwriter.com,michael@maliwriter.com
```

These five identities can sign in without an invitation. Confirm that all five are approved for administrative access to this deployment. Remove obsolete entries from `/etc/use-brian-outpost/api.env` and `auth.env`, then restart the API and auth services.

### 9.3 Build failure

If a build exits with code 137 or `Killed`, check memory and persistent swap:

```bash
free -h
swapon --show
grep -F /swapfile /etc/fstab
```

Correct capacity and run:

```bash
sudo outpost-update
```

A failure during dependency installation or build happens before services stop and before migrations. Once the updater prints `Applying standalone Outpost migrations`, use the failure rules in section 11.1 instead. During the initial installation there is no previous release to restart or restore, so a migration or privilege-grant failure can leave services stopped or failed after database changes have committed. Diagnose the database state and retry `sudo outpost-update` only when it is safe.

## 10. Verify the deployment

### 10.1 Services and exposure

```bash
sudo outpost-doctor
sudo systemctl status 'use-brian-outpost-*'
sudo systemctl status caddy
sudo caddy validate --config /etc/caddy/Caddyfile
sudo ss -lntp
sudo ufw status verbose
```

Check, rather than assume, that enabled units are active, doctor checks pass, Caddy is valid, UFW allows only intended public ports, and the security group matches. `ss` may show application listeners on non-loopback addresses; this is why UFW and the security group are required.

Services can need time to become ready immediately after a restart. The updater retries health checks; a transient first failure is acceptable only if the update ultimately reports a healthy release and `outpost-doctor` passes.

### 10.2 Public ingress

```bash
curl -I https://app.outpost.example.com
curl -f https://api.outpost.example.com/health
curl -f https://auth.outpost.example.com/health
curl -f https://docs.outpost.example.com/health
```

Observe the actual status, redirects, response body, certificate hostname, chain, and expiry. Do not depend on an exact UI title, redirect code, or JSON shape unless the deployed source revision documents it. Also verify WebSocket document sync from a browser session.

### 10.3 Authentication and email

1. Request sign-in using one of the five configured bootstrap addresses.
2. Confirm delivery, sender, links, and codes through the configured SMTP service.
3. Confirm unapproved external addresses cannot bootstrap access.
4. Create a workspace invitation for a controlled test account that is not in the bootstrap set.
5. Accept the invitation and confirm the account reaches the intended workspace.
6. Confirm users outside the bootstrap set must join through workspace invitations.
7. Confirm the resulting app and auth origins remain under `.outpost.example.com` and cookies have the expected secure scope.

## 11. Operations

### 11.1 Updates and migration failure boundaries

Create and validate a backup before every update, then run:

```bash
sudo outpost-update
sudo outpost-doctor
```

To test a branch, tag, or commit once:

```bash
sudo outpost-update BRANCH_OR_TAG_OR_COMMIT
```

The argument affects one repository-mode update and does not change the persisted `main` target.

The updater builds first, then stops application writers, runs migrations, and grants application-role privileges. If migration execution itself fails, it attempts to start the previous release, but any statements already committed by the migration remain committed. On an initial installation no previous release exists, so that restart cannot recover service. If the privilege-grant step fails, the updater exits while application services remain stopped; migrations and some grants may already be committed. Correct that failure before restarting services or restoring the database according to the recovery plan. If API readiness or later health checks fail, the updater switches the code symlink back when a previous release exists, but **migrations are not rolled back**. Previous code may therefore be incompatible with the changed schema. Do not repeatedly retry or manually reverse DDL without examining migration state and logs. Restore the pre-update database backup when required by the tested recovery plan, or deploy a forward fix.

### 11.2 Connectors and logs

```bash
sudo outpost-connectors status
sudo outpost-connectors enable wechat
sudo outpost-connectors disable whatsapp
sudo journalctl -u use-brian-outpost-api -f
sudo journalctl -u use-brian-outpost-auth -f
sudo journalctl -u use-brian-outpost-app -f
sudo journalctl -u caddy -f
```

Supported connector names are `discord`, `whatsapp`, `wechat`, and `feishu`.

### 11.3 Certificate monitoring

Monitor both independent certificate paths:

- Caddy public certificates for app/API/auth/doc-sync: inspect Caddy logs and externally check chain, hostname, and expiry. Keep port 80 or the selected ACME challenge path reachable and account for CA rate limits.
- PolarDB server/CA certificates: follow provider notices and expiry, stage replacement CA files, test `verify-full`, and restart affected services before rotation deadlines.

## 12. Backup and restore

### 12.1 Define protection objectives

Set documented RPO and RTO values. Configure PolarDB automated backups and point-in-time recovery retention to meet them. Take an on-demand backup or snapshot before updates. Also schedule logical dumps when portability or object-level recovery is required; a provider snapshot and `pg_dump` solve different recovery problems. Keep backups in an appropriate region/account and test their retention and encryption.

### 12.2 Back up all state

At minimum protect:

- The complete PolarDB `brian` database, including schema, data, migration state, ownership, grants, and extension metadata.
- Role definitions and a secure procedure to recreate/reset `brian_owner` and `app_user` credentials. Do not place plaintext passwords in an ordinary logical dump archive.
- `/var/lib/use-brian-outpost/files`, preserving ownership, permissions, timestamps, and links.
- `/etc/use-brian-outpost`, including environment files, `deploy.conf`, encryption keys, connector secrets, SMTP settings, and optional `vnc.pass`.
- `/var/lib/use-brian-outpost/chromium` if browser profiles or browser-held state are operationally required.
- The deployed source revision, installer revision, package/runtime versions, connector choices, Caddy configuration, UFW policy, ECS security group, DNS records, PolarDB parameters/allowlists, DashScope region/API Host, and SMTP sender configuration.

Encrypt backups containing `/etc/use-brian-outpost`; restrict and audit access. The encryption keys there are required to read encrypted application credentials after restore. Store backup credentials separately from the ECS host so host loss does not also lose recovery access.

For a consistent file/database recovery point, stop application writer units or use a documented application-consistent procedure, record the database recovery timestamp, copy files and configuration, then restart services. Crash-consistent copies taken while writes continue may not correspond to the database. Verify backup job completion and periodically restore into an isolated environment.

### 12.3 Restore sequence

1. Contain the incident and preserve logs. Decide the exact recovery point; avoid mixing a newer database with older files or vice versa without impact analysis.
2. Provision supported Debian and networking with restrictive security-group rules. Keep public ingress disabled while restoring.
3. Restore PolarDB to a new cluster or approved recovery target. Recreate required login roles securely, verify PostgreSQL 18, and use a PolarDB privileged account to make `vector` and `pg_trgm` available and enabled in `brian` as needed by the restore method.
4. Verify ownership, grants, RLS-role restrictions, extension versions, allowlist, SSL enablement, endpoint hostname, CA, and both connection URLs. A restored cluster normally has a new endpoint and may need new certificates/allowlists.
5. Install the same known-good `hire-brian` installer revision and deploy the source revision compatible with the restored migration state. Do not run an unreviewed latest migration against a historical restore.
6. Restore `/etc/use-brian-outpost` with root ownership and original restrictive modes, update endpoints or rotated credentials, and restore `/var/lib/use-brian-outpost/files` with the configured service user/group. Restore optional browser state only if required and trusted.
7. Validate Caddy and UFW, start services, run `outpost-doctor`, and test database access, files, authentication, email, model calls, connectors, and document sync in isolation.
8. Repoint DNS or attach the production address only after validation. Monitor closely, document the achieved recovery point, and rotate credentials if compromise was possible.

A code symlink rollback is not a database restore. Practice both full-region/host recovery and pre-update rollback, including the case where migrations committed before a failed release.

## 13. Troubleshooting

| Symptom | Likely cause | Action |
| --- | --- | --- |
| `PostgreSQL 18 is required.` | Wrong engine version or endpoint | Connect to the intended PostgreSQL 18 cluster and verify `server_version_num` |
| Database check hangs | Routing, allowlist, DNS, or endpoint error | Add `connect_timeout=10`; check VPC routing and allowlist |
| `pg_trgm` absent from `pg_available_extensions` | Unsupported PolarDB edition/version/region | Stop deployment; select a supported configuration or contact Alibaba Cloud |
| `External database requires vector and pg_trgm.` | Extensions available but not enabled in `brian` | Enable both using a PolarDB privileged account and verify `pg_extension` |
| TLS URL fails | SSL not enabled, wrong endpoint, stale CA, or hostname mismatch | Check each TLS control in section 5.3; do not weaken verification as the first fix |
| DashScope authentication or endpoint error | API key and API Host regions differ | Use a matching regional pair; blank base URL only for the implementation default |
| Build exits 137 | Insufficient memory and swap | Add persistent swap or resize ECS, then retry |
| Host curl works but browser access fails | DNS/AAAA, certificate, UFW, or security group | Check DNS from outside and both firewall layers |
| Update restores old code but remains unhealthy | Migrations committed and were not rolled back | Inspect logs and migration state; restore backup or deploy a compatible forward fix |
| Update exits after migrations and services remain stopped | Application-role privilege grant failed | Inspect the updater output and database grants; repair or restore before restarting services |

## 14. Go-live checklist

- [ ] ECS runs Debian 12 with adequate CPU, RAM, disk, and persistent swap.
- [ ] SSH is restricted to organization-controlled administration paths.
- [ ] Security group and UFW expose only intended ingress; app/connector ports are not public.
- [ ] PolarDB and ECS have private network connectivity and a narrow allowlist.
- [ ] The intended endpoint reports PostgreSQL 18.x.
- [ ] Both `vector` and `pg_trgm` appear in `pg_available_extensions` before deployment.
- [ ] A PolarDB privileged account enabled both extensions in `brian`.
- [ ] Owner and application URLs use different roles against the same database.
- [ ] `app_user` is neither superuser nor `BYPASSRLS` and inherits no privileged role.
- [ ] PolarDB SSL is enabled for the chosen endpoint and `verify-full` plus CA renewal is configured where supported.
- [ ] Four DNS names resolve correctly and stale AAAA records are absent.
- [ ] Cookie domain is deployment-specific, such as `.outpost.example.com`.
- [ ] DashScope API key and API Host belong to the same region/workspace.
- [ ] SMTP sender and credentials are organization controlled.
- [ ] All five configured bootstrap administrator addresses are approved for administrative access.
- [ ] Caddy certificates are valid and renewal is monitored.
- [ ] `outpost-doctor`, external health observations, login, invitations, files, model calls, selected connectors, and document sync have been tested.
- [ ] Automated database, file, configuration, and secret backups meet RPO/RTO.
- [ ] A complete isolated restore has been tested, including a post-migration update failure.

## 15. Final page verification

Open `https://app.outpost.example.com` in a private browser session. Confirm that the application directs the unauthenticated session to the configured auth origin, the certificate is valid for the displayed hostname, and the auth-web email form loads without a redirect loop or service error.

![Illustrative Outpost auth-web sign-in page](images/outpost-expected-login.svg)

The image is an illustrative verification reference rather than a fixed UI contract. Wording and styling can change with the deployed `use-brian` revision. Verify the actual deployment behavior:

- The address bar uses `auth.outpost.example.com` and a valid certificate.
- The page provides an email sign-in flow.
- One of the five configured bootstrap addresses receives the sign-in message through Alibaba SMTP.
- Successful sign-in returns the user to the configured application origin.

---

Guide version: 2026-08-29. At deployment time, compare this guide with the installer, README, Alibaba Cloud console, and current provider documentation.
