# 在阿里云部署 Use Brian 私有云

> 适用范围：使用公开的 `hire-brian` 仓库，在阿里云 ECS 上以 Outpost（私有云）模式部署已合并到 `main` 分支的公开 `use-brian`。模型使用 DashScope，数据库使用 PolarDB PostgreSQL，登录邮件通过阿里云邮箱或邮件推送的 SMTP 服务发送。

## 1. 部署结果

完成后会得到以下架构：

| 组件 | 阿里云资源或本机服务 | 说明 |
| --- | --- | --- |
| 应用主机 | ECS，Debian 12 | 原生 systemd 服务，不使用 Docker |
| 数据库 | PolarDB PostgreSQL | 必须满足 PostgreSQL 18、`vector`、`pg_trgm` 要求 |
| 模型 | DashScope | 使用 DashScope API Key |
| 登录邮件 | 阿里云邮箱或邮件推送 SMTP | 使用完整邮箱地址和 SMTP 密码 |
| HTTPS / WSS | ECS 上的 Caddy | 自动申请和续期公开证书 |
| DNS | Cloudflare 或阿里云 DNS | 四个独立主机名指向 ECS 公网 IP |

私有云会运行这些核心服务：

| 服务 | 本机端口 | 公开入口 |
| --- | ---: | --- |
| app-web | 3003 | `https://app.outpost.example.com` |
| API | 4000 | `https://api.outpost.example.com` |
| auth-web | 3005 | `https://auth.outpost.example.com` |
| doc-sync | 8080 | `wss://docs.outpost.example.com` |

这些应用端口不得直接暴露到公网。安全组只允许 80/443 面向所有互联网来源；SSH 22 虽然通过 ECS 公网 IP 到达，但来源必须限制为管理员固定公网 IP 的 `/32`，不能向 `0.0.0.0/0` 开放。

![阿里云私有云部署架构](images/alicloud-outpost-architecture-zh-CN.svg)

## 2. 前置条件

准备以下内容：

1. 阿里云账号，以及创建 ECS、VPC、安全组和 PolarDB 的权限。
2. 已创建的 ECS SSH 密钥对。
3. 一个指向公开 DNS 的域名。
4. DashScope API Key。
5. 阿里云邮箱或邮件推送中已经验证的发件地址，例如 `contact@example.com`，以及对应 SMTP 密码。
6. PolarDB PostgreSQL 18 集群。

推荐 ECS 最低配置：

- 4 vCPU
- 8 GB RAM，推荐 16 GB
- 60 GB ESSD
- Debian 12 x86_64

Next.js 构建会占用较多内存。`hire-brian` 已将发布构建限制为串行执行，但低内存主机仍建议配置 8 GB swap。

## 3. 重要兼容性检查

### 3.1 PolarDB 版本必须是 PostgreSQL 18

阿里云支持 PolarDB PostgreSQL 18。本指南只使用该版本。当前私有云安装器接受 `server_version_num` 为 `180000` 到 `189999` 的数据库；创建集群时必须明确选择 PostgreSQL 18。

### 3.2 必须提供两个数据库角色

私有云使用两个不同角色：

- `brian_owner`：拥有数据库对象，执行迁移和系统操作。
- `app_user`：应用请求使用的 RLS 角色，必须是 `NOSUPERUSER`、`NOBYPASSRLS`，且不能继承特权角色。

两个连接 URL 必须指向同一个 `brian` 数据库。

### 3.3 必须安装 `vector` 和 `pg_trgm`

`vector` 用于向量检索；`pg_trgm` 用于文本相似度、模糊任务匹配以及 transcript、文件、邮件和聊天文本的 GIN 索引。

扩展必须由 PolarDB 高权限/管理员账号安装，不能假设普通对象所有者 `brian_owner` 具有托管扩展权限。`vector` 通过阿里云 PolarDB 控制台的插件/扩展管理页面启用，并选择目标数据库 `brian`。`pg_trgm` 如果没有出现在控制台扩展页面中，则使用 PolarDB 高权限账号通过 DMS 连接 `brian` 后执行：

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;
```

安装器会在连接 PolarDB 后执行自己的数据库前置检查，无需另做手工验证步骤。

## 4. 在阿里云控制台创建 ECS 基础设施

本章全部通过阿里云控制台操作，不使用基础设施自动化工具。

### 4.1 选择地域和可用区

先确定部署地域，例如新加坡。ECS 和 PolarDB 必须在同一地域。若要使用 PolarDB 内网 endpoint，两者还必须在同一 VPC，且网络可以互通。

在创建资源前记录：

- 地域，例如新加坡。
- 可用区，例如新加坡可用区 B；以控制台当前可选项为准。
- 管理员当前公网 IP，用于限制 SSH。
- 已有 SSH 密钥对名称。

### 4.2 创建 VPC 和 vSwitch

进入 **专有网络 VPC -> 专有网络**，创建：

| 项目 | 示例值 |
| --- | --- |
| VPC 名称 | `outpost-vpc` |
| IPv4 CIDR | `10.42.0.0/16` |
| vSwitch 名称 | `outpost-vswitch` |
| vSwitch 可用区 | 与 ECS 和 PolarDB 计划使用的可用区一致 |
| vSwitch IPv4 CIDR | `10.42.1.0/24` |

创建完成后记录 VPC ID、vSwitch ID 和 CIDR。稍后创建 PolarDB 时必须选择同一个 VPC；PolarDB 白名单也要包含 ECS 私网 IP 或 `10.42.1.0/24`。

### 4.3 创建安全组

进入 **云服务器 ECS -> 网络与安全 -> 安全组**，在 `outpost-vpc` 中创建安全组，例如 `outpost-sg`。

入方向规则：

| 协议 | 端口 | 来源 |
| --- | ---: | --- |
| TCP | 22 | `ADMIN_PUBLIC_IP/32` |
| TCP | 80 | `0.0.0.0/0` |
| TCP | 443 | `0.0.0.0/0` |

SSH 22 只允许管理员固定公网 IP。不要使用 `0.0.0.0/0` 开放 SSH。不要开放 3003、3005、4000、8080、8090-8095 或 5901。

更严格的生产环境可以使用阿里云堡垒机、VPN 或专线管理 ECS，并完全删除公网 SSH 规则。无论采用哪种方式，都应只允许 SSH 密钥登录并关闭密码登录。管理员公网 IP 变化时，应更新 `/32` 安全组规则，而不是扩大来源范围。

出方向规则至少需要允许：

- HTTPS 443：GitHub、NodeSource、PostgreSQL apt、DashScope 和证书申请。
- HTTP 80：软件源和 ACME HTTP challenge。
- SMTP 465 或 587：阿里云邮箱发信。
- PolarDB 5432：到同 VPC PolarDB endpoint。

使用默认“允许全部出方向”时，这些通常已经满足。

### 4.4 创建 ECS 实例

进入 **云服务器 ECS -> 实例 -> 创建实例**，选择：

| 控制台字段 | 推荐值 |
| --- | --- |
| 付费类型 | 按量付费用于测试；生产可选包年包月 |
| 地域 | 与 VPC、PolarDB 相同，例如新加坡 |
| 可用区 | 与 `outpost-vswitch` 相同 |
| 网络及可用区 | `outpost-vpc` / `outpost-vswitch` |
| 实例规格 | 至少 4 vCPU / 8 GB RAM，推荐 4 vCPU / 16 GB RAM |
| 镜像 | Debian 12 64 位 x86_64 官方公共镜像 |
| 系统盘 | ESSD，至少 60 GB |
| 公网 IP | 分配公网 IPv4 |
| 公网带宽 | 按业务选择，例如 10 Mbps |
| 安全组 | `outpost-sg` |
| 登录凭证 | SSH 密钥对，不建议启用 root 密码登录 |
| 实例名称 | `use-brian-outpost` |
| 主机名 | `use-brian-outpost` |

创建后记录：

- ECS 公网 IPv4，用于 DNS 和 SSH。
- ECS 私网 IPv4，用于 PolarDB 白名单。
- 实例所在 VPC、vSwitch 和安全组。

### 4.5 首次连接和系统检查

```bash
ssh root@ECS_PUBLIC_IP
cat /etc/os-release
uname -m
free -h
df -h /
```

必须确认：

- 系统为 Debian 12。
- 架构为 `x86_64`/`amd64`。
- 内存至少 8 GB。
- 根盘可用空间满足源码、依赖和多个 release 构建需求。
- systemd 为 PID 1。

如果内存只有 8 GB，建议在安装前按第 9.4 节配置 swap。

## 5. 创建和准备 PolarDB

### 5.1 网络

推荐使用 PolarDB 内网连接地址：

1. 在与 ECS 相同的地域和 VPC 创建 PolarDB PostgreSQL 18。
2. 将 ECS vSwitch 网段 `10.42.1.0/24` 加入 PolarDB 白名单。
3. 使用 PolarDB 控制台显示的集群内网 endpoint 和端口。
4. 不需要为数据库开放公网地址。

白名单是必需项，不是可选优化。即使 ECS 和 PolarDB 位于同一 VPC，PolarDB 仍会拒绝未列入白名单的来源。使用内网 endpoint 时加入 ECS 的私网 IP 或 vSwitch CIDR；使用公网 endpoint 时加入 ECS 的实际公网出口 IP。不要把数据库白名单设置为 `0.0.0.0/0`。

如果 PolarDB 位于另一个 VPC，单纯处于同一地域仍无法访问。需要重新选择 VPC、配置 Cloud Enterprise Network，或改用受白名单保护的公网 endpoint。

### 5.2 创建数据库和角色

使用 PolarDB 高权限/管理员账号登录 DMS 执行本节全部数据库初始化。具体管理权限受 PolarDB 产品限制，以下 SQL 是目标状态示例：

```sql
CREATE ROLE brian_owner LOGIN PASSWORD 'REPLACE_OWNER_PASSWORD';
CREATE ROLE app_user LOGIN PASSWORD 'REPLACE_APP_PASSWORD'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
CREATE DATABASE brian OWNER brian_owner;
```

创建数据库后仍保持高权限/管理员身份处理扩展。不要切换到 `brian_owner` 安装扩展：

1. 打开 PolarDB 集群详情。
2. 进入 **配置与管理 -> 插件管理/扩展管理**。控制台名称可能随版本调整。
3. 选择目标数据库 `brian`，找到 `vector` 并点击启用。
4. 使用 PolarDB 高权限账号在 DMS 中连接 `brian` 数据库，执行：

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;
```

`pg_trgm` 属于 PostgreSQL contrib 扩展。即使控制台页面没有列出，只要 PolarDB 的 `pg_available_extensions` 提供它，高权限账号就可以通过以上 SQL 在当前数据库启用。`brian_owner` 只负责私有云对象和迁移，不承担托管扩展安装。

确保 `brian_owner` 能在 `brian` 中创建对象并向 `app_user` 授权。安装器会在迁移后补充当前对象和默认权限。

### 5.3 构造连接 URL

启用 TLS 的推荐格式：

```text
postgresql://brian_owner:URL_ENCODED_PASSWORD@POLARDB_INTERNAL_ENDPOINT:5432/brian?sslmode=require&connect_timeout=10
postgresql://app_user:URL_ENCODED_PASSWORD@POLARDB_INTERNAL_ENDPOINT:5432/brian?sslmode=require&connect_timeout=10
```

密码中的 `@`、`:`、`/`、`?`、`#`、`%`、`^` 等字符必须进行 URL 编码。

如果该 PolarDB 内网 endpoint 明确不支持 TLS，可使用：

```text
?sslmode=disable&connect_timeout=10
```

安装器会显示风险警告，并要求明确回答 `yes`。内网地址不等于加密连接；生产环境应优先使用 `sslmode=require` 或 `verify-full`。

安装器会检查版本、扩展、两个角色是否不同、是否连接同一数据库，以及应用角色是否具有不允许的特权。

## 6. 配置 DNS

推荐使用一个隔离的私有云 cookie 命名空间：

```text
Public HTTPS application origin: https://app.outpost.example.com
Public HTTPS API origin: https://api.outpost.example.com
Public HTTPS authentication origin: https://auth.outpost.example.com
Public WSS document-sync origin: wss://docs.outpost.example.com
Isolated cookie domain: .outpost.example.com
```

创建四条记录，全部指向 ECS 公网 IPv4：

| 类型 | 名称 | 值 |
| --- | --- | --- |
| A | `app.outpost` | `ECS_PUBLIC_IP` |
| A | `api.outpost` | `ECS_PUBLIC_IP` |
| A | `auth.outpost` | `ECS_PUBLIC_IP` |
| A | `docs.outpost` | `ECS_PUBLIC_IP` |

如果使用 Cloudflare Free，二级主机名（例如 `auth.outpost.example.com`）通常不在默认 Universal SSL 通配范围内。将四条记录设置为 **DNS only**，让 ECS 上的 Caddy 直接申请 Let's Encrypt 证书。

不要使用 `.example.com` 这一类可注册根域作为 cookie domain。应使用 `.outpost.example.com` 这一类部署专属范围；私有云认证配置也会拒绝过宽的根域级 cookie 范围。

## 7. 配置 DashScope

在阿里云 Model Studio / DashScope 控制台创建 API Key。安装器中选择：

```text
Primary model provider: dashscope
DashScope API key: <在控制台创建的 API Key>
DashScope base URL: 留空
```

默认会使用 DashScope 国际服务。只有在阿里云控制台明确要求特定兼容 endpoint 时才填写 DashScope base URL。

## 8. 配置阿里云 SMTP 邮箱

本部署使用：

```text
SMTP account: contact@example.com
Email from address: contact@example.com
```

如果 `contact@example.com` 是阿里企业邮箱账号，常见配置为：

```text
SMTP server host: smtp.qiye.aliyun.com
SMTP server port: 465
Use implicit SMTP TLS: true
```

如果使用阿里云邮件推送 DirectMail，请使用控制台中该地域显示的 SMTP endpoint、已验证发信地址和 SMTP 密码；不要把 DirectMail API AccessKey 当作 SMTP 密码。阿里企业邮箱国际版或区域化服务也可能显示不同 hostname。**控制台提供的 SMTP 设置优先于上面的常见值。**

安装前确认：

- `contact@example.com` 已创建并允许 SMTP 客户端登录。
- 使用邮箱客户端专用密码或 SMTP 密码，不使用阿里云账号登录密码。
- 发件地址与已验证邮箱地址一致。
- ECS 可以出站连接 SMTP 465 或 587。

## 9. 运行私有云安装器

### 9.1 登录 ECS

```bash
ssh root@ECS_PUBLIC_IP
```

### 9.2 获取公开部署仓库

```bash
apt-get update
apt-get install -y git
git clone https://github.com/use-brian/hire-brian.git
cd hire-brian/deployment/outpost
sudo ./install.sh
```

### 9.3 安装器问题和推荐回答

下表使用安装器实际显示的问题，不显示内部环境变量名。条件问题只会在选择对应分支时出现。本指南只列出 DashScope 模型路径，不展开其他模型服务。

| 安装器显示的问题 | 何时出现 | 本指南推荐值或说明 |
| --- | --- | --- |
| Dedicated service user | 总是 | `brian`；必须是合法的小写 Linux 用户名 |
| Outpost source mode (repository/directory) | 总是 | `repository` |
| Use Brian repository | 选择 repository | `https://github.com/use-brian/use-brian.git` |
| Git branch, tag, or commit | 选择 repository | `main` |
| SSH server port to preserve in UFW | 总是 | `22`，或 sshd 的实际端口 |
| Install PostgreSQL 18 and pgvector locally? (yes/no) | 总是 | `no`，使用 PolarDB PostgreSQL 18 |
| Install headless LibreOffice for PDF exports? (yes/no) | 总是 | `yes` |
| Install Chromium, Xfce, Xvfb, and local-only VNC? (yes/no) | 总是 | 一般为 `no` |
| Enable Discord connector? (yes/no) | 总是 | 推荐 `no` |
| Enable WhatsApp connector? (yes/no) | 总是 | 推荐 `no` |
| Enable WeChat connector? (yes/no) | 总是 | 推荐 `yes` |
| Enable Feishu connector? (yes/no) | 总是 | 推荐 `yes` |
| Public HTTPS application origin | 总是 | `https://app.outpost.example.com` |
| Public HTTPS API origin | 总是 | `https://api.outpost.example.com` |
| Public HTTPS authentication origin | 总是 | `https://auth.outpost.example.com` |
| Public WSS document-sync origin | 总是 | `wss://docs.outpost.example.com` |
| Isolated cookie domain (for example .customer.example) | 总是 | `.outpost.example.com` |
| Trust sanitized proxy client-IP headers? (true/false) | 总是 | Caddy 直连为 `false` |
| Primary model provider | 总是 | `dashscope` |
| DashScope API key | 选择 DashScope | 实际 API Key，输入时显示 `*` |
| DashScope base URL | 选择 DashScope | 通常留空；仅按控制台要求填写 |
| Authentication method (email/oidc) | 总是 | `email` |
| Bootstrap administrator email | 总是 | 见下方五个地址，使用一行逗号分隔 |
| SMTP server host | 选择 email | 使用阿里云控制台值；常见为 `smtp.qiye.aliyun.com` |
| SMTP server port | 选择 email | 隐式 TLS 使用 `465` |
| Use implicit SMTP TLS? (true for port 465, false for STARTTLS) | 选择 email | `true` |
| SMTP account | 选择 email | `contact@example.com` |
| SMTP password | 选择 email | SMTP/客户端专用密码，输入时显示 `*` |
| Email from address | 选择 email | `contact@example.com` |
| OIDC discovery issuer URL | 选择 OIDC | 本 email 部署不会出现 |
| OIDC client id | 选择 OIDC | 本 email 部署不会出现 |
| OIDC client secret | 选择 OIDC | 本 email 部署不会出现 |
| OIDC provider display name | 选择 OIDC | 本 email 部署不会出现 |
| External PostgreSQL owner URL with TLS | 不安装本机数据库 | PolarDB `brian_owner` URL，输入时显示 `*` |
| External PostgreSQL RLS-role URL with TLS | 不安装本机数据库 | 同一数据库的 `app_user` URL，输入时显示 `*` |
| TLS is not enforced for every external PostgreSQL URL. Continue insecurely? (yes/no) | URL 未强制 TLS | 推荐 `no` 并修复 TLS |
| VNC password (maximum 8 characters) | 启用 browser desktop | 最多 8 个字符，输入时显示 `*` |
| Reverse proxy setup (default/custom) | 安装末段 | `default`，安装并配置 Caddy |

“Bootstrap administrator email”支持逗号分隔。请在提示中输入以下完整一行：

```text
contact@usebrian.ai,hinson@usebrian.ai,wongkahinhinson@gmail.com,jingles@maliwriter.com,michael@maliwriter.com
```

这五个地址可以在没有邀请的情况下完成初始 email 登录。后续用户应通过工作区邀请加入。

### 9.4 构建内存不足

如果出现 `Killed` 或退出码 `137`，表示构建被 OOM killer 终止。先检查：

```bash
free -h
swapon --show
```

没有 swap 时可创建 8 GB swap：

```bash
fallocate -l 8G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
```

然后重新运行：

```bash
sudo outpost-update
```

失败的构建发生在数据库迁移和发布切换前，可安全重试。

## 10. 安装后验证

### 10.1 本机服务

```bash
sudo outpost-doctor
sudo systemctl status 'use-brian-outpost-*'
sudo systemctl status caddy
sudo caddy validate --config /etc/caddy/Caddyfile
```

所有启用的服务应显示 `active` 和 `OK`。服务刚重启时第一次健康检查可能失败；更新器会自动重试，最终必须显示 `Release healthy`。

### 10.2 公网 HTTPS

```bash
curl -I https://app.outpost.example.com
curl -f https://api.outpost.example.com/health
curl -f https://auth.outpost.example.com/health
curl -f https://docs.outpost.example.com/health
```

预期结果：

- app 返回 `307` 到 `/login`，或登录后返回应用页面。
- API 返回 JSON `status: ok`。
- auth 返回 JSON `status: ok`。
- doc-sync 返回 `ok`。

### 10.3 邮件和邀请

1. 使用五个 bootstrap 地址之一请求登录验证码或 magic link。
2. 确认邮件由 `contact@example.com` 发出。
3. 登录后在 Settings -> Workspace -> Members 创建邀请。
4. 用被邀请邮箱打开 `https://auth.outpost.example.com/invite?token=...`。
5. 接受后应跳到 `https://app.outpost.example.com/w/<workspaceId>`。

## 11. 日常操作

### 11.1 更新

当 `use-brian` 的私有云相关变更已经合并到 `main`：

```bash
sudo outpost-update
sudo outpost-doctor
```

固定测试某个分支或 commit：

```bash
sudo outpost-update BRANCH_OR_TAG_OR_COMMIT
```

该参数只影响本次更新，不会修改持久化的 `main` 更新目标。

### 11.2 Connector 管理

```bash
sudo outpost-connectors status
sudo outpost-connectors enable wechat
sudo outpost-connectors disable whatsapp
```

支持：`discord`、`whatsapp`、`wechat`、`feishu`。

### 11.3 日志

```bash
sudo journalctl -u use-brian-outpost-api -f
sudo journalctl -u use-brian-outpost-auth -f
sudo journalctl -u use-brian-outpost-app -f
sudo journalctl -u caddy -f
```

## 12. 备份和恢复

至少备份：

- PolarDB `brian` 数据库。
- `/var/lib/use-brian-outpost/files`。
- `/etc/use-brian-outpost` 中的配置和密钥，使用受控的加密备份。
- 阿里云邮箱 SMTP 配置和 DNS 记录的运维文档。

更新前创建 PolarDB 备份或快照。

## 13. 故障排查速查表

| 现象 | 常见原因 | 处理 |
| --- | --- | --- |
| `PostgreSQL 18 is required` | 创建集群时选错数据库版本 | 新建或升级到 PolarDB PostgreSQL 18，并重新填写连接 URL |
| 数据库检查长时间无输出 | VPC、白名单或 endpoint 错误 | 添加 `connect_timeout=10`，检查同 VPC 和白名单 |
| `vector` 缺失 | 未在 PolarDB 控制台为 `brian` 启用 | 在插件/扩展管理页面选择 `brian` 并启用 `vector` |
| `pg_trgm` 缺失 | 扩展可用但未在 `brian` 启用 | 使用 PolarDB 高权限账号通过 DMS 对 `brian` 执行 `CREATE EXTENSION pg_trgm` |
| 构建退出 137 | ECS 内存不足 | 使用至少 8 GB RAM，增加 swap，重新执行 `outpost-update` |
| 浏览器无法访问，服务器 curl 正常 | DNS 缓存、AAAA 错误或安全组未开 443 | 检查 DNS A/AAAA、Cloudflare 模式和 ECS 安全组 |

## 14. 上线检查清单

- [ ] ECS 为 Debian 12，至少 4 vCPU / 8 GB RAM / 60 GB disk。
- [ ] SSH 只允许管理员 IP。
- [ ] 安全组和 UFW 允许 80/443。
- [ ] PolarDB 与 ECS 网络互通。
- [ ] PolarDB 白名单包含 ECS 私网 IP 或 vSwitch CIDR，且不是 `0.0.0.0/0`。
- [ ] PolarDB 报告 PostgreSQL 18.x。
- [ ] 已在 PolarDB 控制台为 `brian` 启用 `vector`。
- [ ] 已使用 PolarDB 高权限账号通过 DMS 为 `brian` 启用 `pg_trgm`。
- [ ] owner 和 app 使用不同数据库角色。
- [ ] app 角色不是 superuser，且没有 BYPASSRLS。
- [ ] 四个 DNS 主机名解析到 ECS 公网 IP。
- [ ] cookie domain 为 `.outpost.example.com`。
- [ ] DashScope API Key 可用。
- [ ] 阿里云 SMTP 发件地址为 `contact@example.com`。
- [ ] 五个 bootstrap 邮箱按逗号分隔配置。
- [ ] Caddy 证书签发成功。
- [ ] `outpost-doctor` 全部通过。
- [ ] 登录、邀请、connector 目录和文档同步均已验证。
- [ ] 已配置 PolarDB 和文件目录备份。

## 15. 最终页面验证

访问 `https://app.outpost.example.com` 后，未登录用户最终应看到独立的 auth-web 登录卡片。

![预期的私有云登录页面](images/outpost-expected-login-zh-CN.svg)

图中页面采用默认英文文案，实际语言会随用户选择变化。验证要点：

- 地址栏位于 `auth.outpost.example.com`，证书有效。
- 页面标题为 `Sign in to your workspace`。
- 显示邮箱输入框和 `Send sign-in link` 按钮。
- 输入已配置的 bootstrap 邮箱后能收到阿里云 SMTP 发出的链接和六位验证码。
- 登录完成后返回 `app.outpost.example.com/w/<workspaceId>`。

---

文档版本：2026-08-28。部署时以公开仓库 `main` 分支中的安装器、README 和环境变量示例为准。
