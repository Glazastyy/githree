# Githree

Githree is an open-source, read-only repository browser.

- No user accounts
- No login/session flow
- No write operations on repository contents
- One backend API that handles all git operations

The goal is simple: browse any git repository (public or private, when credentials are provided) through a clean UI and download code snapshots.

## Highlights

- Add repositories by URL (`https://...` or `git@host:org/repo.git`)
- Browse refs (branches/tags)
- Browse trees and files
- Render README automatically
- View commit history and commit diffs
- Download raw files, `.tar.gz`, and `.zip`
- Background periodic fetch (optional)
- Request-time fetch guard cache (short TTL) to avoid repeated git network calls
- Flat-file registry (`data/repos.json`) with file locking

## Stack

- Backend: Rust 2024, Axum, Tokio, git2/libgit2, tracing
- Frontend: Svelte 5 + SvelteKit + Tailwind, Bun package manager
- Rendering: Shiki, marked, DOMPurify, lucide-svelte
- Caching: moka (in-memory tree cache, 60s TTL)

## CI

- GitHub: security scanning via CodeQL workflow (`.github/workflows/codeql.yml`)
- GitHub: container publishing to GHCR (`.github/workflows/container-publish.yml`)
  - Publishes `ghcr.io/<owner>/githree` on `main` and tags
- GitLab: test/build pipeline via `.gitlab-ci.yml`:
  - backend (`cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test`)
  - frontend (`bun run check`, `bun run build`)
  - Docker image build verification (`docker build`)
  - Container publish to GitLab Registry (`$CI_REGISTRY_IMAGE`)
    - automatic on tags
    - manual on `main` / `master`

The GitLab pipeline validates build/test and can publish the Docker image to the GitLab Container Registry.

## Repository Layout

```text
backend/              Rust backend API and git services
frontend/             SvelteKit frontend
tools/githreectl/     Host CLI for installed stack management
config/default.toml   Runtime config
data/                 Runtime state (repos cache + repos.json)
Dockerfile
docker-compose.yml
```

## Quick Start

### Guided Docker Installer (Recommended)

Hosted quick install:

```bash
curl --proto '=https' --tlsv1.2 -fsSL https://install.githree.org | bash
```

Hosted quick install (non-interactive defaults):

```bash
curl --proto '=https' --tlsv1.2 -fsSL https://install.githree.org | bash -s -- --yes
```

`wget` alternative:

```bash
wget -qO- https://install.githree.org | bash
```

Restricted environments (no pipe-to-shell policy, strict proxies, or shell limitations):

```bash
curl --proto '=https' --tlsv1.2 -fSL https://install.githree.org -o githree-install.sh
less githree-install.sh
bash githree-install.sh
```

Local script mode (inside a checkout):

```bash
./install.sh
./install.sh --yes
```

After install, manage the running stack with `githreectl`:

```bash
githreectl status
githreectl logs --follow
githreectl repo list
githreectl repo add --url https://github.com/user/repo.git --name my-repo
githreectl backup
githreectl update --backup
```

If Docker socket access requires privilege, keep using `githreectl` and let it resolve the runner automatically, or force one:

```bash
githreectl --runner docker status
githreectl --runner sudo-docker status
```

What the installer does:

- Detects Linux/macOS and checks required dependencies (`docker`, compose support)
- Offers to install missing dependencies immediately when possible
- Verifies Docker daemon availability (and helps start it)
- If a full checkout is not found next to `install.sh`, it bootstraps source from `https://github.com/Glazastyy/githree.git`
- Prompts for ports, `RUST_LOG`, and optional Caddy reverse proxy setup
- Generates runtime deployment files:
  - `.run/install/docker-compose.install.yml`
  - `.run/install/Caddyfile` (when Caddy is enabled)
  - `~/.config/githreectl/config.env` (or `$GITHREECTL_CONFIG`) for host CLI
- Optionally builds and installs host CLI (`githreectl`) to `~/.local/bin`
- Pulls a prebuilt GHCR image by default (optional local build fallback)
  - Default image: `ghcr.io/sarahsec/githree:latest`
  - Override repo with `GITHREE_IMAGE_REPO=<repo>`
- Writes a detailed timestamped log file:
  - `.logs/install-YYYYMMDD-HHMMSS.log`

### Docker

```bash
docker compose up --build
```

Open `http://localhost:3001`.

### Local Development

1. Backend

```bash
cd backend
cargo check
cargo run
```

2. Frontend (Bun)

```bash
cd frontend
bun install
bun run dev
```

Frontend API base defaults to `http://localhost:3001`.  
Override with `PUBLIC_API_URL` if needed.

## Configuration

Default file: [`config/default.toml`](./config/default.toml)

```toml
[server]
host = "0.0.0.0"
port = 3001

[storage]
repos_dir = "../data/repos"
registry_file = "../data/repos.json"
static_dir = "../static"

[git]
clone_timeout_secs = 120
fetch_on_request = true
fetch_cooldown_secs = 20
ssh_private_key_path = "~/.ssh/id_rsa"

[fetch]
enabled = true
interval = "60s"

[repos]
credentials = []

[features]
web_repo_management = false
show_repo_controls = true

[branding]
app_name = "Githree"
logo_url = "/logo.svg"
site_url = "https://githree.org"
domain = "githree.org"

[caddy]
enabled = false
command = "caddy"
config_file = "./Caddyfile"
adapter = "caddyfile"
args = []
# working_dir = "."
```

Paths in the config file are resolved relative to the config file directory (except absolute paths and `~/...` paths, which are preserved/expanded).

When `web_repo_management = false`, `POST /api/repos`, `DELETE /api/repos/{name}`, and `POST /api/repos/{name}/fetch` are blocked from the web API and the frontend switches to CLI-command generation.

Use `features.show_repo_controls = false` to hide add/remove repository controls from the UI entirely.

### `githreectl` Host CLI

`githreectl` is a host-side helper for installations created by `install.sh`.
It reads stack metadata from `~/.config/githreectl/config.env` and works from any directory.

Examples:

```bash
githreectl status
githreectl logs --follow
githreectl repo add --url https://github.com/user/repo.git --name my-repo
githreectl backup --output ./backup/githree.tar.gz
githreectl update --backup
```

UI and config control examples:

```bash
githreectl ui status
githreectl ui repo-controls hide --restart
githreectl ui web-management disable --restart
githreectl config set fetch.interval 120s --restart
githreectl config get features.show_repo_controls
```

If it is not in your `PATH`, use:

```bash
~/.local/bin/githreectl status
```

You can override this flag at runtime:

```bash
GITHREE_WEB_REPO_MANAGEMENT=true ./githree
```

Background sync interval supports seconds, minutes, and hours:

- `interval = "60s"` (default when omitted)
- `interval = "5m"`
- `interval = "1h"`

You can also override it at runtime:

```bash
GITHREE_FETCH_INTERVAL=2m ./githree
```

### Branding and Public URL

You can define application identity and links directly in config:

- `branding.app_name`: UI product name
- `branding.logo_url`: logo path or URL used in header/footer
- `branding.site_url`: canonical project URL
- `branding.domain`: domain label shown in navigation

Runtime overrides are available:

```bash
GITHREE_APP_NAME="My Git Viewer" \
GITHREE_LOGO_URL="/assets/logo.svg" \
GITHREE_SITE_URL="https://git.example.com" \
GITHREE_DOMAIN="git.example.com" \
./githree
```

### Optional Caddy Launcher

Set `caddy.enabled = true` to let Githree spawn Caddy on startup.

- If `caddy.args` is set, those args are used as-is.
- Else if `caddy.config_file` is set, Githree runs:
  - `caddy run --config <file> --adapter <adapter>`
- Else Githree falls back to:
  - `caddy reverse-proxy --from <branding.domain|branding.site_url> --to 127.0.0.1:<server.port>`

Runtime overrides:

```bash
GITHREE_CADDY_ENABLED=true \
GITHREE_CADDY_COMMAND=caddy \
GITHREE_CADDY_CONFIG_FILE=./config/Caddyfile \
GITHREE_CADDY_WORKING_DIR=. \
./githree
```

A starter Caddyfile is included at [`config/Caddyfile`](./config/Caddyfile).

### HTTPS Credentials Per Host

```toml
[[repos.credentials]]
host = "gitlab.mycompany.com"
username = "gitlab-ci"
password = "token"
```

### SSH Behavior

- Uses libgit2 credential callbacks
- Tries configured HTTPS host credentials first when requested
- Supports SSH key auth (`ssh_private_key_path`)
- Falls back to SSH agent (`ssh_key_from_agent`)

## API Reference

All endpoints are under `/api`.

| Method | Endpoint | Description |
|---|---|---|
| GET | `/settings` | Runtime settings (repo management mode, branding, and Caddy flag) |
| POST | `/repos` | Register/clone repository |
| GET | `/repos` | List registered repositories |
| DELETE | `/repos/{name}` | Remove repository from registry/cache |
| POST | `/repos/{name}/fetch` | Force fetch from remote |
| GET | `/repos/{name}/refs` | Branches, tags, default branch |
| GET | `/repos/{name}/tree?ref=&path=` | List directory entries |
| GET | `/repos/{name}/blob?ref=&path=` | File content + metadata |
| GET | `/repos/{name}/raw?ref=&path=` | Raw file download |
| GET | `/repos/{name}/readme?ref=` | README auto-detection |
| GET | `/repos/{name}/commits?ref=&path=&skip=&limit=` | Commit history |
| GET | `/repos/{name}/commit/{hash}` | Commit detail + file diffs |
| GET | `/repos/{name}/archive?ref=&format=tar.gz\|zip` | Archive download stream |

## Frontend Routes

| Route | Purpose |
|---|---|
| `/` | Add/list repositories, fuzzy search |
| `/{repo}` | Repository overview |
| `/{repo}/tree/{...path}` | Directory browsing |
| `/{repo}/blob/{...path}` | File viewer |
| `/{repo}/commits` | Commit history |
| `/{repo}/commit/{hash}` | Commit detail |

## Build and Validation

Backend:

```bash
cd backend
cargo fmt
cargo clippy -- -D warnings
cargo test
```

Frontend:

```bash
cd frontend
bun run check
bun run build
```

## Security and Governance

- Security policy: [`SECURITY.md`](./SECURITY.md)
- Contribution guide: [`CONTRIBUTING.md`](./CONTRIBUTING.md)
- Contribution licensing: [`CONTRIBUTION_LICENSE.md`](./CONTRIBUTION_LICENSE.md)
- Code of conduct: [`CODE_OF_CONDUCT.md`](./CODE_OF_CONDUCT.md)
- Support channels: [`SUPPORT.md`](./SUPPORT.md)

## License

MIT — see [`LICENSE`](./LICENSE).
