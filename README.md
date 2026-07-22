# Codex / Claude Code — VPN-Isolated Docker Sandbox

A Docker environment that runs **Codex** and/or **Claude Code** behind a hard **OpenVPN kill switch**, so agent-initiated network traffic can only leave through the VPN tunnel — never through your host's regular internet connection.

## What this gives you

- **One container, either CLI.** Switch between Codex and Claude Code with a single `.env` variable; both are pre-installed.
- **Hard kill switch.** `iptables` blocks all outbound IPv4 traffic by default. Only the VPN handshake, the tunnel (`tun0`), and a short allow-list of host ports are permitted. IPv6 is disabled at the namespace level and verified at startup.
- **DNS lockdown.** Docker's embedded DNS resolver is blocked once the VPN is up; only DNS servers pushed by the VPN (or ones you set explicitly) can resolve names, and their routes are checked to guarantee they go through `tun0`.
- **Locked-down VPN credentials.** Your VPN profile/credentials are bind-mounted read-only under a `root:root 0700` directory, so the unprivileged `dev` user inside the container can never read them.
- **Nested sandboxing supported.** The container is configured (via `security_opt` and capabilities) so Claude Code's and Codex's *own* internal sandboxes (bubblewrap / `codex sandbox`) work correctly inside Docker.
- **Health-checked.** Docker's `HEALTHCHECK` continuously verifies the VPN process, routing, DNS, and HTTPS connectivity — the container reports `unhealthy` if the tunnel drops.
- **Isolated agent state.** Claude Code and Codex each get their own persisted config/auth directory in a named volume, separate from your host `~/.claude` or `~/.codex`.

## Requirements

- Docker with Docker Compose v2
- An OpenVPN profile (`.ovpn` file), tested with Windscribe but any standard OpenVPN provider works
- Linux, macOS, or Windows (native, WSL, or Git Bash) as the host

## Setup

### 1. Configure environment

Copy the example and fill in your paths:

```bash
cp .env.example .env   # if you keep an example file; otherwise edit .env directly
```

Key variables in `.env`:

| Variable | Purpose |
|---|---|
| `AI_TOOL` | `codex` or `claude` — which CLI the launcher scripts drive |
| `PROJECT_PATH` | Host path to your project source, mounted at `/workspace` |
| `M2_REPO_PATH` | Host path to your Maven **repository cache only** (not all of `~/.m2`, so `settings.xml`/credentials never enter the container) |
| `CLAUDE_CODE_OAUTH_TOKEN` | Required only if `AI_TOOL=claude`; generate with `claude setup-token` |
| `OPENAI_API_KEY` | Optional; only needed for API-billed Codex usage instead of ChatGPT subscription login |
| `VPN_DIR_PATH` | Host directory containing your VPN profile (default `./vpn`) |
| `VPN_CONFIG_FILE` / `VPN_CREDS_FILE` | Filenames inside that directory (defaults `windscribe.ovpn` / `credentials.txt`) |
| `HOST_SERVICE_TCP_PORTS` | Comma-separated host ports (via `host.docker.internal`) the container may still reach, e.g. a local Postgres/Kafka for the project under test |
| `VPN_HEALTHCHECK_*` | Host/URL/IP used to confirm the tunnel is actually working |

### 2. Add your VPN profile

Place your VPN files in the directory pointed to by `VPN_DIR_PATH` (default `./vpn/`):

```
vpn/
├── windscribe.ovpn
└── credentials.txt
```

These files are **git-ignored** and mounted read-only, one level below a root-owned `0700` directory the entrypoint creates — the `dev` user can never read them directly, even if their host file permissions are loose.

### 3. Build and start

```bash
docker compose up -d --build
```

On startup the entrypoint (running as root) will, in order:

1. Lock down and validate the mounted VPN directory/credentials
2. Verify IPv6 is disabled on every interface
3. Resolve and pin the VPN server, then install the IPv4 kill switch (deny-by-default)
4. Launch OpenVPN and wait for `tun0` and a valid route
5. Wait for VPN-pushed DNS, then block Docker's own DNS resolver
6. Verify all DNS routes go through `tun0`, then allow-list your chosen host service ports
7. Verify DNS resolution and HTTPS connectivity through the tunnel, and log the exit-node IP
8. Mark the VPN "ready" and hand off to `CMD` (`sleep infinity`, keeping the container alive for `docker exec`)

Check progress with:

```bash
docker logs -f ai-vpn
```

The container reports **healthy** in `docker ps` once the VPN is fully verified.

### 4. Authenticate the CLI

```bash
# Codex (subscription login)
./scripts/ai.sh login

# Claude Code — generate CLAUDE_CODE_OAUTH_TOKEN locally first, then set it in .env
claude setup-token
```

Auth state persists in the `ai-state` named volume (`/home/dev/.ai-state/{codex,claude}`), separate from your host config.

### 5. Use it

```bash
./scripts/ai.sh              # launch the active AI_TOOL from .env
AI_TOOL=claude ./scripts/ai.sh   # one-off override
./scripts/ai.sh status
./scripts/ai.sh doctor
./scripts/ai.sh sandbox-check    # verify nested bubblewrap/codex sandboxes work
```

On Windows, use the PowerShell equivalent: `./scripts/ai.ps1` (same subcommands).

## Verifying isolation

- `docker exec -it ai-vpn curl https://ifconfig.me` should return your VPN exit node's IP, not your real one.
- `./scripts/ai.sh sandbox-check` confirms Node 24, both CLIs, `bwrap`, and `unshare` all work as the unprivileged `dev` user, and that both Claude's and Codex's internal sandboxes can actually execute commands.
- If the VPN drops mid-session, the kill switch keeps all non-tunnel traffic blocked and the container's health check flips to `unhealthy` — it will not silently fall back to your real IP.

## Project layout

```
.
├── Dockerfile                    # Ubuntu 22.04 + Node 24 + Java 21/Maven + Codex & Claude Code CLIs
├── docker-compose.yml            # Container config: NET_ADMIN, tun device, volumes, env
├── .env                          # Your local config (git-ignored)
├── vpn/                          # Your VPN profile + credentials (git-ignored)
└── scripts/
    ├── entrypoint.sh             # VPN bring-up, kill switch, DNS lockdown, health gate
    ├── vpn-dns.sh                 # OpenVPN --up hook: applies pushed DNS servers
    ├── vpn-healthcheck.sh        # Docker HEALTHCHECK: process/route/DNS/HTTPS checks
    ├── ai-sandbox-check.sh       # Verifies nested bubblewrap/codex sandboxes work
    ├── ai.sh / ai.ps1            # Cross-platform launcher for either CLI
    └── claude-managed-settings.json  # Enables Claude's weaker-nested-sandbox mode for Docker
```

## Notes & gotchas

- **Don't run privileged.** The container only gets `NET_ADMIN`/`NET_RAW` and `seccomp=unconfined` (needed for bubblewrap's nested namespaces), plus `no-new-privileges`. It is deliberately not `--privileged` and has no `SYS_ADMIN`.
- **IPv6 is fully disabled**, not just deprioritized — both the entrypoint and the health check fail closed if any interface still has it enabled.
- **Maven secrets stay on the host.** Only `~/.m2/repository` (the artifact cache) is mounted; `settings.xml`/`settings-security.xml` are not.
- **Rebuilding with new CLI versions:** override at build time, e.g. `docker compose build --build-arg CLAUDE_CODE_VERSION=X.Y.Z`, or bump the defaults in `.env`.
