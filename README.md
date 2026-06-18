# Claude Code + Windscribe VPN — Isolated Dev Container

Isolated Docker environment for Claude Code where **all internet traffic
is routed through Windscribe VPN** running inside the container.  
Your host machine never sees Claude Code traffic.  
Your Java project is bind-mounted so IntelliJ sees every change instantly.

```
Host OS  (IntelliJ watches ~/projects/my-app)
  │
  └── Docker container
        ├── OpenVPN → Windscribe exit node  (all Claude Code API traffic)
        ├── iptables kill switch            (blocks any non-VPN outbound)
        ├── Claude Code                     (runs as non-root user)
        └── /workspace  ←→  ~/projects/my-app  (bind mount, zero delay)
```

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Docker Engine ≥ 24 | or Docker Desktop |
| Linux host | macOS/WSL2 also work; see notes below |
| Windscribe account | Free tier is enough |
| Anthropic API key | https://console.anthropic.com |

---

## One-time setup

### Step 1 — Download the Windscribe OpenVPN config

1. Log in to **windscribe.com**
2. Go to **My Account → OpenVPN Config Generator**
3. Select a server close to you (e.g. `DE-Frankfurt` or any EU server)
4. Choose protocol **UDP** (faster) or **TCP** (more firewall-friendly)
5. Download the `.ovpn` file
6. Copy it into this repo's `vpn/` folder:

```bash
cp ~/Downloads/Windscribe-DE-Frankfurt.ovpn ./vpn/windscribe.ovpn
```

### Step 2 — Create VPN credentials file

```bash
cp vpn/credentials.txt.example vpn/credentials.txt
# Edit the file:
nano vpn/credentials.txt
# Line 1: your Windscribe username
# Line 2: your Windscribe password
```

> **Note:** Windscribe's OpenVPN configs contain `auth-user-pass`.
> The entrypoint passes `credentials.txt` automatically.

### Step 3 — Create your .env file

```bash
cp .env.example .env
nano .env
```

Fill in:
- `ANTHROPIC_API_KEY` — from console.anthropic.com
- `PROJECT_PATH` — absolute path to your Java project on the host  
  e.g. `PROJECT_PATH=/home/yourname/work/my-fintech-app`

### Step 4 — Build the image

```bash
docker compose build
```

Takes 2–3 minutes the first time (downloads Node.js, Claude Code).

---

## Daily workflow

### Start the container (once per workday)

```bash
docker compose up -d
```

The container will:
1. Resolve the Windscribe server hostname
2. Install the iptables kill switch (all outbound blocked except VPN)
3. Start OpenVPN
4. Wait for `tun0` to appear
5. Allow `tun0` traffic through iptables
6. Verify external IP
7. Stay alive (sleeping) — ready for you to exec in

Watch startup:
```bash
docker logs -f claude-vpn
```

Expected output:
```
[VPN] VPN server: fra-xxx.windscribe.com → 185.x.x.x:443/udp
[VPN] Installing iptables kill switch...
[VPN] Kill switch active — all other outbound is blocked
[VPN] Launching OpenVPN...
[VPN] tun0 is up after 12s ✓
[VPN] tun0 outbound traffic allowed
[VPN] External IP: 185.x.x.x  ← should be a Windscribe exit node
[VPN] VPN is active.  Workspace: /workspace
[VPN] Run:  docker exec -it claude-vpn claude
```

### Open a Claude Code session

```bash
# Option A — helper script (easiest)
chmod +x scripts/cc.sh
./scripts/cc.sh

# Option B — direct docker exec
docker exec -it -w /workspace claude-vpn su -c claude dev
```

Claude Code opens in `/workspace` which is your host project.  
**IntelliJ IDEA will see all file changes immediately** — it's the same
filesystem path, no sync layer.

### IntelliJ tip — enable auto-refresh

`Settings → Appearance & Behavior → System Settings`  
☑ **Synchronize external changes on frame or editor tab activation**  
(or just press `Ctrl+Alt+Y` to manually refresh)

### Stop the container

```bash
docker compose down
```

---

## Verifying isolation

```bash
# 1. Check that container traffic goes through VPN
docker exec claude-vpn curl -s https://ifconfig.me
# → Should show a Windscribe IP, not your home IP

# 2. Check iptables kill switch is active
docker exec claude-vpn iptables -L OUTPUT -v -n
# → Policy: DROP, with only lo / ESTABLISHED / tun0 / VPN-server rules

# 3. Confirm host outbound is NOT affected
curl https://ifconfig.me   # on your host — shows your real IP
```

---

## Troubleshooting

### `tun0 did not appear within 90s`

- Check `docker logs claude-vpn` for OpenVPN errors
- Try switching to TCP protocol in the .ovpn file:
  ```
  proto tcp   # change from udp
  ```
- Ensure `/dev/net/tun` exists on the host:
  ```bash
  ls -la /dev/net/tun
  ```

### `AUTH_FAILED` in OpenVPN log

- Your Windscribe credentials are wrong in `vpn/credentials.txt`
- Check the `.ovpn` config doesn't already embed credentials; if it does,
  remove the `auth-user-pass` line and don't use `credentials.txt`

### Claude Code auth fails

- Verify `ANTHROPIC_API_KEY` in your `.env` is correct
- Run `docker exec claude-vpn env | grep ANTHROPIC` to check it's set

### Changes not appearing in IntelliJ

- This should not happen with bind mounts on Linux
- On WSL2/Windows: ensure `PROJECT_PATH` uses the WSL2 path format
  (`/mnt/c/...`) not the Windows path

---

## Windows / macOS notes

**macOS (Docker Desktop):**  
Docker Desktop uses a VM; bind mounts use `virtiofs` which is fast enough.  
Use the macOS absolute path in `.env`: `PROJECT_PATH=/Users/yourname/projects/...`

**Windows (Docker Desktop + WSL2):**  
Store the project inside WSL2's filesystem (`~/projects/...`) for best
performance, not on the Windows drive (`/mnt/c/...`).  
`PROJECT_PATH=/home/yourname/projects/my-app`

---

## Security notes

- `vpn/credentials.txt` and `vpn/*.ovpn` are in `.gitignore`
- `.env` is in `.gitignore`
- Claude Code runs as non-root user `dev` inside the container
- The iptables kill switch ensures that if the VPN drops, Claude Code
  loses internet entirely rather than falling back to your host IP
