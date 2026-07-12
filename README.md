# Codex + Claude Code + Windscribe VPN — Isolated Dev Container

Universal Docker environment for running either:

* OpenAI Codex CLI
* Anthropic Claude Code

Both tools are installed in the same image. Select the active tool in `.env`:

```dotenv
AI_TOOL=codex
# AI_TOOL=claude
```

The selected CLI runs inside a Docker container whose public internet traffic is routed through Windscribe OpenVPN.

The environment also provides:

* IPv4 and IPv6 kill switches
* persistent Codex and Claude state
* non-root CLI execution
* Java 21 and Maven
* a bind-mounted project workspace
* restricted access to selected host services
* PowerShell and Bash launcher scripts

```text
Host OS
│
├── IntelliJ / editor
│     └── watches the host project directory
│
├── Postgres / Kafka / other host services
│     └── reachable through explicitly allowed ports
│
└── Docker container "ai-vpn"
      ├── OpenVPN → Windscribe exit node
      ├── IPv4 and IPv6 kill switches
      ├── Codex CLI
      ├── Claude Code
      ├── Java 21 + Maven
      └── /workspace ←→ host project bind mount
```

---

## Prerequisites

| Requirement                    | Notes                            |
| ------------------------------ | -------------------------------- |
| Docker Engine 24 or newer      | Docker Desktop is also supported |
| Docker Compose v2              | Use `docker compose`             |
| Linux, macOS, Windows, or WSL2 | See platform notes below         |
| Windscribe account             | Required for the VPN tunnel      |
| Codex or Claude access         | Depending on the selected tool   |
| OpenVPN configuration          | Generated through Windscribe     |
| TUN device support             | Required for OpenVPN             |

On Linux, verify that the TUN device exists:

```bash
ls -la /dev/net/tun
```

---

## Repository layout

```text
.
├── Dockerfile
├── docker-compose.yml
├── .env
├── .gitignore
│
├── scripts/
│   ├── ai.ps1
│   ├── ai.sh
│   └── entrypoint.sh
│
└── vpn/
    ├── windscribe.ovpn
    ├── credentials.txt
    └── credentials.txt.example
```

Recommended `.gitignore`:

```gitignore
.env

vpn/credentials.txt
vpn/*.ovpn
vpn/*.conf

docker-compose.override.yml
```

---

## One-time setup

### 1. Download the Windscribe OpenVPN configuration

1. Sign in to Windscribe.
2. Open the OpenVPN configuration generator.
3. Select a VPN location.
4. Choose UDP or TCP.
5. Download the generated `.ovpn` file.
6. Copy it into the repository:

```bash
cp ~/Downloads/Windscribe-DE-Frankfurt.ovpn ./vpn/windscribe.ovpn
```

The default configuration path inside the container is:

```text
/vpn/windscribe.ovpn
```

To use another file, configure:

```dotenv
VPN_CONFIG=/vpn/windscribe-de.ovpn
```

---

### 2. Create the VPN credentials file

Create:

```text
vpn/credentials.txt
```

Its contents must be:

```text
windscribe-username
windscribe-password
```

The username is on the first line and the password is on the second line.

You can start from an example file:

```bash
cp vpn/credentials.txt.example vpn/credentials.txt
```

---

### 3. Create `.env`

Copy the example file:

```bash
cp .env.example .env
```

Example Windows configuration:

```dotenv
# ── Active AI coding tool ───────────────────────────────────────
AI_TOOL=codex
# AI_TOOL=claude

# ── Claude Code authentication ──────────────────────────────────
CLAUDE_CODE_OAUTH_TOKEN=

# ── Codex authentication ────────────────────────────────────────
# Usually leave these empty when using interactive login.
OPENAI_API_KEY=
CODEX_ACCESS_TOKEN=

# ── Project paths ───────────────────────────────────────────────
PROJECT_PATH=C:/Users/user/IdeaProjects/subo
M2_REPO_PATH=C:/Users/user/.m2

# ── VPN ─────────────────────────────────────────────────────────
VPN_TIMEOUT=90
VPN_CONFIG=/vpn/windscribe.ovpn

# ── Allowed host services ───────────────────────────────────────
HOST_SERVICE_TCP_PORTS=5434,19092

# ── Spring Boot container overrides ─────────────────────────────
SPRING_DATASOURCE_URL=jdbc:postgresql://host.docker.internal:5434/postgres
SPRING_DATASOURCE_USERNAME=postgres
SPRING_DATASOURCE_PASSWORD=postgres
SPRING_KAFKA_BOOTSTRAP_SERVERS=host.docker.internal:19092
```

Linux example:

```dotenv
PROJECT_PATH=/home/user/projects/subo
M2_REPO_PATH=/home/user/.m2
```

macOS example:

```dotenv
PROJECT_PATH=/Users/user/projects/subo
M2_REPO_PATH=/Users/user/.m2
```

WSL example:

```dotenv
PROJECT_PATH=/mnt/c/Users/user/IdeaProjects/subo
M2_REPO_PATH=/mnt/c/Users/user/.m2
```

Do not put real tokens or passwords into `.env.example`.

---

### 4. Build the image

```bash
docker compose build
```

Both Codex and Claude Code are installed into the same image.

For reproducible builds, pin their versions:

```bash
docker compose build \
  --build-arg CODEX_VERSION=<version> \
  --build-arg CLAUDE_CODE_VERSION=<version>
```

PowerShell:

```powershell
docker compose build `
  --build-arg CODEX_VERSION=<version> `
  --build-arg CLAUDE_CODE_VERSION=<version>
```

---

### 5. Start the container

```bash
docker compose up -d
```

Follow startup logs:

```bash
docker logs -f ai-vpn
```

The startup process:

1. resolves the VPN endpoint
2. installs the IPv4 and IPv6 kill switches
3. starts OpenVPN
4. waits for `tun0`
5. allows traffic through the VPN tunnel
6. allows selected host-service ports
7. verifies the external IP
8. keeps the container running

Example output:

```text
[VPN] VPN server: fra-xxx.windscribe.com → [185.x.x.x] :443/udp
[VPN] Installing iptables kill switch (IPv4)...
[VPN] Installing kill switch (IPv6 — full block)...
[VPN] Launching OpenVPN...
[VPN] Waiting for tunnel interface tun0...
[VPN] tun0 is up after 12s
[VPN] tun0 outbound traffic allowed
[VPN] Allowed host services at 192.168.x.x on TCP ports: 5434,19092
[VPN] External IP: 185.x.x.x
[VPN] AI development container is active
[VPN] Workspace: /workspace
```

---

## Selecting the AI tool

Both CLIs are always installed.

Select Codex:

```dotenv
AI_TOOL=codex
# AI_TOOL=claude
```

Select Claude Code:

```dotenv
# AI_TOOL=codex
AI_TOOL=claude
```

Changing only `AI_TOOL` does not require rebuilding or recreating the container. The launcher reads the setting directly from the host `.env` file.

A container recreation is required when changing variables that must be passed into the container, such as:

* authentication tokens
* API keys
* Spring settings
* VPN settings
* allowed host-service ports

Apply those changes with:

```bash
docker compose up -d --force-recreate
```

---

## Codex setup

### Select Codex

```dotenv
AI_TOOL=codex
# AI_TOOL=claude
```

### Sign in

Start the container:

```bash
docker compose up -d
```

Then run:

```powershell
./scripts/ai.ps1 login
```

or:

```bash
./scripts/ai.sh login
```

For device-code authentication:

```bash
docker exec -it \
  -u dev \
  -w /workspace \
  ai-vpn \
  codex login --device-auth
```

Check authentication status:

```powershell
./scripts/ai.ps1 status
```

or:

```bash
./scripts/ai.sh status
```

Log out:

```powershell
./scripts/ai.ps1 logout
```

or:

```bash
./scripts/ai.sh logout
```

### Codex API-key authentication

To use an OpenAI API key, set:

```dotenv
OPENAI_API_KEY=sk-...
```

Then recreate the container:

```bash
docker compose up -d --force-recreate
```

Leave `OPENAI_API_KEY` empty when using interactive ChatGPT login.

### Codex state persistence

Codex state is stored under:

```text
/home/dev/.ai-state/codex
```

The container sets:

```text
CODEX_HOME=/home/dev/.ai-state/codex
```

This directory is backed by the `ai-state` named volume, so authentication and configuration survive container recreation.

---

## Claude Code setup

### Select Claude Code

```dotenv
# AI_TOOL=codex
AI_TOOL=claude
```

### Generate a long-lived token

Generate the token on the host:

```bash
claude setup-token
```

Or generate it inside the container:

```bash
docker exec -it \
  -u dev \
  -w /workspace \
  ai-vpn \
  claude setup-token
```

Copy the token into `.env`:

```dotenv
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
```

Recreate the container:

```bash
docker compose up -d --force-recreate
```

### Claude state persistence

Claude state is stored under:

```text
/home/dev/.ai-state/claude
```

The container sets:

```text
CLAUDE_CONFIG_DIR=/home/dev/.ai-state/claude
```

This preserves configuration, history, project metadata, and resumable sessions.

---

## Daily workflow

### Start the container

```bash
docker compose up -d
```

Check status:

```bash
docker ps
```

The container should eventually show:

```text
healthy
```

### Start the selected tool

PowerShell:

```powershell
./scripts/ai.ps1
```

Bash, Git Bash, Linux, macOS, or WSL:

```bash
./scripts/ai.sh
```

Arguments are forwarded to the selected CLI:

```powershell
./scripts/ai.ps1 --help
```

```bash
./scripts/ai.sh --help
```

### Override the selected tool for one invocation

PowerShell:

```powershell
$env:AI_TOOL = "claude"
./scripts/ai.ps1
Remove-Item Env:AI_TOOL
```

Bash:

```bash
AI_TOOL=claude ./scripts/ai.sh
```

### Run a tool directly

Codex:

```bash
docker exec -it \
  -u dev \
  -w /workspace \
  ai-vpn \
  codex
```

Claude Code:

```bash
docker exec -it \
  -u dev \
  -w /workspace \
  ai-vpn \
  claude
```

### Stop the container

```bash
docker compose down
```

This preserves the named state volume.

To also delete persisted Codex and Claude state:

```bash
docker compose down -v
```

---

## Project workspace

The host project is mounted at:

```text
/workspace
```

Compose configuration:

```yaml
volumes:
  - ${PROJECT_PATH}:/workspace
```

Codex, Claude Code, IntelliJ, and other host tools work on the same files. Changes made inside the container are immediately visible on the host.

### IntelliJ refresh

Enable:

```text
Settings
→ Appearance & Behavior
→ System Settings
→ Synchronize external changes on frame or editor tab activation
```

Manual refresh:

```text
Ctrl+Alt+Y
```

---

## Maven local repository

The host Maven repository is mounted into the container:

```yaml
volumes:
  - ${M2_REPO_PATH}:/home/dev/.m2
```

This avoids downloading dependencies again after every image rebuild.

Verify it:

```bash
docker exec -u dev ai-vpn sh -lc '
ls -ld /home/dev/.m2
mvn --version
'
```

---

## Connecting to host services

Inside the container, `localhost` refers to the container itself.

Services running on the host must be accessed through:

```text
host.docker.internal
```

Compose provides:

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

---

### Allowed host ports

Only explicitly configured host TCP ports are allowed through the kill switch:

```dotenv
HOST_SERVICE_TCP_PORTS=5434,19092
```

Example:

* PostgreSQL: `5434`
* Kafka: `19092`

To allow another service:

```dotenv
HOST_SERVICE_TCP_PORTS=5434,19092,8080
```

Recreate the container after changing the list:

```bash
docker compose up -d --force-recreate
```

---

### Spring Boot overrides

The host application can keep using `localhost` in `application.yml`.

Inside the container, Compose overrides the relevant properties:

```yaml
environment:
  SPRING_DATASOURCE_URL: ${SPRING_DATASOURCE_URL:-jdbc:postgresql://host.docker.internal:5434/postgres}
  SPRING_DATASOURCE_USERNAME: ${SPRING_DATASOURCE_USERNAME:-postgres}
  SPRING_DATASOURCE_PASSWORD: ${SPRING_DATASOURCE_PASSWORD:-postgres}
  SPRING_KAFKA_BOOTSTRAP_SERVERS: ${SPRING_KAFKA_BOOTSTRAP_SERVERS:-host.docker.internal:19092}
```

These values apply only to processes running inside the container.

---

### PostgreSQL requirements

The host PostgreSQL service must:

* publish its port to the host
* listen on a reachable address
* allow the Docker gateway or subnet in `pg_hba.conf`

Example:

```yaml
ports:
  - "5434:5432"
```

Container URL:

```text
jdbc:postgresql://host.docker.internal:5434/postgres
```

---

### Kafka advertised listeners

Kafka may return an advertised broker address after the initial connection.

If Kafka advertises:

```text
localhost:9092
```

the container may connect initially and then fail.

Configure Kafka to advertise an address reachable from the container, for example:

```text
host.docker.internal:19092
```

---

### Test host-service connectivity

```bash
docker exec -u dev ai-vpn bash -lc '
for p in 5434 19092; do
  if timeout 3 bash -c "exec 3<>/dev/tcp/host.docker.internal/$p" 2>/dev/null; then
    echo "port $p OPEN"
  else
    echo "port $p CLOSED or blocked"
  fi
done
'
```

---

## VPN and kill switch

The entrypoint runs as root because OpenVPN and firewall configuration require elevated privileges.

Codex, Claude Code, Maven, and Git are run as the non-root `dev` user.

The kill switch:

1. resolves the VPN endpoint before blocking outbound traffic
2. sets the IPv4 `OUTPUT` policy to `DROP`
3. blocks non-loopback IPv6 traffic
4. allows the VPN endpoint
5. starts OpenVPN
6. waits for `tun0`
7. allows traffic through `tun0`
8. allows selected host-service ports

If the VPN tunnel disappears, ordinary public outbound traffic remains blocked.

---

## Health check

The image checks whether `tun0` exists:

```dockerfile
HEALTHCHECK \
  --interval=30s \
  --timeout=5s \
  --start-period=100s \
  --retries=3 \
  CMD ip link show tun0 >/dev/null 2>&1 || exit 1
```

Check the status:

```bash
docker ps
```

Possible states:

* `health: starting`
* `healthy`
* `unhealthy`

The launcher scripts warn when the container is starting or unhealthy.

---

## Verifying the setup

### Check the container public IP

```bash
docker exec ai-vpn curl -s https://ifconfig.me
```

It should show the Windscribe exit address.

### Check the host public IP

Run on the host:

```bash
curl https://ifconfig.me
```

The host and container addresses should normally differ.

### Inspect IPv4 rules

```bash
docker exec ai-vpn iptables -S OUTPUT
```

Expected policy:

```text
-P OUTPUT DROP
```

### Inspect IPv6 rules

```bash
docker exec ai-vpn ip6tables -S OUTPUT
```

Expected policy:

```text
-P OUTPUT DROP
```

### Verify non-root execution

Codex:

```bash
docker exec -u dev ai-vpn sh -lc '
id
codex --version
'
```

Claude Code:

```bash
docker exec -u dev ai-vpn sh -lc '
id
claude --version
'
```

---

## Updating the CLIs

Update Codex and Claude Code by rebuilding the image:

```bash
docker compose build \
  --build-arg CODEX_VERSION=latest \
  --build-arg CLAUDE_CODE_VERSION=latest
```

Then recreate the container:

```bash
docker compose up -d --force-recreate
```

For reproducible builds, use explicit versions instead of `latest`.

Check installed versions:

```bash
docker exec -u dev ai-vpn codex --version
docker exec -u dev ai-vpn claude --version
```

---

## Troubleshooting

### Container is not running

```bash
docker compose up -d
docker compose ps
docker logs ai-vpn
```

---

### `tun0 did not appear`

Inspect logs:

```bash
docker logs ai-vpn
docker exec ai-vpn cat /var/log/openvpn.log
```

Possible causes:

* incorrect VPN credentials
* invalid `.ovpn` file
* blocked UDP traffic
* missing `/dev/net/tun`
* insufficient container capabilities
* timeout too short

Increase the timeout if needed:

```dotenv
VPN_TIMEOUT=180
```

Then recreate:

```bash
docker compose up -d --force-recreate
```

---

### OpenVPN reports `AUTH_FAILED`

Check:

```text
vpn/credentials.txt
```

Ensure that:

* the username is on line 1
* the password is on line 2
* there is no accidental whitespace
* the credentials are valid

---

### Container is unhealthy

Check the tunnel:

```bash
docker exec ai-vpn ip link show tun0
```

Inspect logs:

```bash
docker logs ai-vpn
docker exec ai-vpn tail -n 100 /var/log/openvpn.log
```

Restart:

```bash
docker compose restart ai-vpn
```

---

### Codex authentication does not persist

Check:

```bash
docker exec -u dev ai-vpn sh -lc '
echo "$CODEX_HOME"
ls -la "$CODEX_HOME"
'
```

Confirm that Compose mounts:

```yaml
- ai-state:/home/dev/.ai-state
```

Do not run `docker compose down -v` unless you want to delete persisted state.

---

### Claude asks for login repeatedly

Confirm that the token is set without printing it:

```bash
docker exec ai-vpn sh -lc '
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "CLAUDE_CODE_OAUTH_TOKEN is set"
else
  echo "CLAUDE_CODE_OAUTH_TOKEN is not set"
fi
'
```

After changing the token:

```bash
docker compose up -d --force-recreate
```

---

### Launcher starts the wrong tool

Check `.env`:

```dotenv
AI_TOOL=codex
```

or:

```dotenv
AI_TOOL=claude
```

Check for a shell override.

PowerShell:

```powershell
Get-ChildItem Env:AI_TOOL
```

Remove it:

```powershell
Remove-Item Env:AI_TOOL
```

Bash:

```bash
echo "${AI_TOOL:-not set}"
unset AI_TOOL
```

---

### Host service is blocked

Check that its port appears in:

```dotenv
HOST_SERVICE_TCP_PORTS=5434,19092
```

Recreate:

```bash
docker compose up -d --force-recreate
```

Inspect firewall rules:

```bash
docker exec ai-vpn iptables -S OUTPUT
```

---

### `host.docker.internal` does not resolve

Check:

```bash
docker exec ai-vpn getent ahostsv4 host.docker.internal
```

Ensure Compose contains:

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

---

### Kafka connects and then fails

Check Kafka’s advertised listeners.

The broker must not advertise:

```text
localhost:9092
```

Use an address reachable from the container, such as:

```text
host.docker.internal:19092
```

---

### Project changes do not appear on the host

Check the bind mount:

```bash
docker inspect ai-vpn
```

Verify `PROJECT_PATH` in `.env`.

Create a test file:

```bash
docker exec -u dev ai-vpn touch /workspace/.container-write-test
```

The file should appear immediately on the host.

Remove it:

```bash
docker exec -u dev ai-vpn rm -f /workspace/.container-write-test
```

---

## Platform notes

### Linux

Use native absolute paths:

```dotenv
PROJECT_PATH=/home/user/projects/subo
M2_REPO_PATH=/home/user/.m2
```

Ensure `/dev/net/tun` exists.

### macOS

Use macOS paths:

```dotenv
PROJECT_PATH=/Users/user/projects/subo
M2_REPO_PATH=/Users/user/.m2
```

### Windows with Docker Desktop

Use forward slashes:

```dotenv
PROJECT_PATH=C:/Users/user/IdeaProjects/subo
M2_REPO_PATH=C:/Users/user/.m2
```

Run:

```powershell
./scripts/ai.ps1
```

### WSL2

Example:

```dotenv
PROJECT_PATH=/home/user/projects/subo
M2_REPO_PATH=/home/user/.m2
```

Windows-mounted paths also work:

```dotenv
PROJECT_PATH=/mnt/c/Users/user/IdeaProjects/subo
```

### Git Bash

The Bash launcher sets:

```bash
export MSYS_NO_PATHCONV=1
```

This prevents Git Bash from rewriting container paths such as `/workspace`.
