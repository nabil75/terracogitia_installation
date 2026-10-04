# Terra-Cogitia — Docker Deployment Toolkit

Build, deploy, verify and clean Terra-Cogitia locally (Docker Desktop) and on the Hetzner
server. Modelled on the PlanningPowerTools toolkit (`D:\PowerProjects\documentation\installation`):
same registry-driven design, `docker save` → SCP → `docker load` transfer, a server-side
shell script, host nginx + certbot for TLS. Every operation is **scoped to Terra-Cogitia**.

- **[ARCHITECTURE.md](ARCHITECTURE.md)**: the containers and how they communicate
- **[INSTALLATION.md](INSTALLATION.md)**: every command and parameter, with typical workflows

```powershell
.\deploy-local.ps1                     # local build + deploy + verify   (http://localhost:8200)
.\clean-all-local.ps1                  # local cleanup (data volumes kept)
.\deploy-all.ps1                       # Hetzner: build -> transfer -> deploy -> verify
.\renew-certificates.ps1 -Issue -Email you@terra-cogitia.com   # first TLS certificate
.\renew-certificates.ps1               # check + renew when < 30 days
.\clean-all.ps1                        # Hetzner cleanup (asks for confirmation)
.\update-secrets.ps1                   # Hetzner: apply secrets.prod.env changes (API keys) without redeploying
```

## Architecture

| Container          | Image              | Port (host) | Role |
|--------------------|--------------------|-------------|------|
| `Cogitia-FrontEnd` | `cogitia-frontend` | `8200`      | Angular SPA served by unprivileged nginx |
| `Cogitia-BackEnd`  | `cogitia-backend`  | `8201`      | FastAPI/uvicorn (API, AI layer: Mistral, routing, prompts) |
| `Cogitia-Models`   | `cogitia-models`   | — (internal) | Open-weight models on CPU: Laya (decisions), Whisper (speech-to-text) |
| `Cogitia-Worker`   | `cogitia-worker`   | — (internal) | Media jobs (uploads, transcoding, imports, generation calls, ffmpeg composition) |
| `Cogitia-Voice`    | `cogitia-voice`    | — (internal) | **Optional, off by default.** Cloned voices for narrations (VibeVoice-1.5B, MIT) |
| `Cogitia-Database` | `cogitia-database` | — (internal) | PostgreSQL 17, seeded from `schema.sql` + `data.sql` |

All four are on the Docker network **`NetCogitia`** (DNS aliases `cogitia-frontend`,
`cogitia-backend`, `cogitia-models`, `cogitia-database`). `Cogitia-Models` is, like the database,
**not published** on the host: only the Back-End calls it. The database is deliberately **not published** on the
host. It is the third container agreed on top of the original two-container spec, because the
Back-End cannot run without PostgreSQL.

### Front-End ↔ Back-End communication (preserved)

The Front-End is a pure browser SPA: **the browser calls the Back-End directly** (no
server-side rendering, no proxy). This is the existing design (`ApiService.baseurl`) and it is
kept. Only the URL became configurable at run time:

```
Browser ──► http://localhost:8200        (Cogitia-FrontEnd: static files + assets/env.js)
Browser ──► http://localhost:8201        (Cogitia-BackEnd, CORS allows the Front-End origin)
Cogitia-BackEnd ──► cogitia-database:5432   (NetCogitia)
```

| Environment | Browser opens | API URL injected into the SPA | CORS origins allowed |
|---|---|---|---|
| `ng serve` (dev) | `http://localhost:4200` | `http://localhost:8002` (unchanged default) | `:4200` (default) |
| local Docker | `http://localhost:8200` | `http://localhost:8201` | `:8200`, `:4200` |
| Hetzner | `https://app.terra-cogitia.com` | `https://api.terra-cogitia.com` | app domain, `http://95.217.14.18:8200` |

`Cogitia-FrontEnd` generates `assets/env.js` at start from `API_BASE_URL`, so **the same image**
runs everywhere. Container-to-container connectivity (`cogitia-frontend` → `cogitia-backend`) is
verified by the scripts, but the application does not need it.

### Application changes (the minimum needed to run in Docker)

| File | Change | Why |
|---|---|---|
| `terracogitia_backend/database.py` | DB settings from `DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD`; hard-coded password removed | Container DNS name for the host; no secret in source or image |
| `terracogitia_backend/main.py` | CORS origins from `CORS_ORIGINS` (default unchanged: `:4200`) | Front-End served from `:8200` / public domain |
| `terracogitia_backend/requirements.txt` | Added `mistralai==2.10.1` | Imported by `mistral/*.py` (`from mistralai.client import Mistral`) but missing: a clean install crashed at startup |
| `terracogitia_backend/.env.example`, `README.md`, `docs/print_prompts_question.py` | Document/adapt to the above | — |
| `terracogitia_frontend/src/app/api/api.service.ts` | `baseurl` read from `window.__TC_CONFIG__.apiBaseUrl`, falls back to `http://localhost:8002` | Runtime API URL per environment |
| `terracogitia_frontend/src/index.html`, `src/assets/env.js` | Load the runtime config before the bundle | same |
| `terracogitia_frontend/angular.json` | Budget **error** limits raised (initial 1.5 MB → 3 MB, component style 12 kB → 64 kB); warning limits unchanged | `ng build` (production) failed before any Docker work: bundle 2.18 MB, styles up to 52 kB |

> **Local `python run_dev.py` now needs `DB_PASSWORD` in `terracogitia_backend/.env`**
> (see `.env.example`). The previous password was committed in `database.py`, so **rotate it**.

## Layout

```
Installation\
  deploy-local.ps1  clean-all-local.ps1            local (Docker Desktop)
  deploy-all.ps1    clean-all.ps1  renew-certificates.ps1   Hetzner
  cogitia-registry.json     all non-secret configuration (names, ports, paths, server, domains)
  secrets.env.example       template for secrets.local.env / secrets.prod.env (git-ignored)
  lib\Cogitia.Common.psm1   shared functions (logging, registry, docker, HTTP checks, SSH/SCP)
  docker\                   Dockerfiles (+ .dockerignore), docker-compose.yml, SPA nginx config
  remote\cogitia-remote.sh  server-side operations (deploy/clean/status/nginx/certbot)
  remote\nginx\             host vhost templates (HTTP before the certificate, HTTPS after)
  exports\  .runtime\  backups\   generated (git-ignored)
```

On the server everything lives in **`/root/cogitia`** (images, compose, `cogitia.env`,
`secrets/` chmod 600, `backups/`), apart from one nginx vhost file `terra-cogitia.conf`.

## Configuration

**`cogitia-registry.json`**: the only place for names, ports, network, image label, source
paths, server host/user/deploy dir, domains, API URL and CORS origins per environment. Every
script validates it and stops with an explicit error when a mandatory value is missing.

**Secrets** (never committed, never in images):

| File | Keys | Notes |
|---|---|---|
| `secrets.local.env` | `POSTGRES_PASSWORD` (req.), `MISTRAL_API_KEY` | Create **once** from `secrets.env.example`, then copy the **same file** to every machine (git-ignored: a clone never brings it). Never auto-generated |
| `secrets.prod.env` | `POSTGRES_PASSWORD`, `MISTRAL_API_KEY` (both req.) | Create from `secrets.env.example`; never auto-generated |

Optional: `MISTRAL_MODEL`, `OPENAI_API_KEY`. `POSTGRES_PASSWORD` only takes effect when the
database volume is **first** created.

**SSH**: key-based auth when available (recommended). Otherwise the password comes from
`$env:COGITIA_SSH_PASSWORD` or a secure prompt, and is handed to OpenSSH through the same
`SSH_ASKPASS` mechanism as PlanningPowerTools, **without being written to disk**. To set up a key once:

```powershell
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh root@95.217.14.18 "cat >> ~/.ssh/authorized_keys"
```

## Prerequisites

- **Windows**: Docker Desktop (engine + compose v2 + buildx), Windows PowerShell 5.1 or
  PowerShell 7, Windows OpenSSH client (System32).
- **Hetzner server**: Docker engine, Docker Compose v2 plugin, `curl`; for public HTTPS also
  host `nginx` + `certbot` (already used by PlanningPowerTools), DNS **A records**
  `app.terra-cogitia.com` and `api.terra-cogitia.com` → `95.217.14.18`, ports 80/443 open (and
  8200/8201 in the Hetzner Cloud firewall if the direct ports must be reachable).

## Local deployment

```powershell
.\deploy-local.ps1              # full build (first run ~5-10 min: torch CPU + Whisper + Laya weights in cogitia-models)
.\deploy-local.ps1 -SkipBuild   # redeploy existing images
.\deploy-local.ps1 -NoCache     # clean rebuild
```

Phases: prerequisites → build (4 images) → runtime config (`.runtime\local`) → DB backup
(`backups\local`, last 5 kept) → `NetCogitia` → stray containers removed → `compose up -d`
(only changed containers are recreated, volumes kept) → wait healthy → verification →
label-scoped removal of dangling Cogitia images. Idempotent: re-running converges to the same
state.

Verification: Front-End health/SPA/runtime API URL, Back-End OpenAPI, a **database-backed**
endpoint (`/disciplines/db_check`), the **CORS preflight** the browser performs, all
five containers on `NetCogitia`, FrontEnd→BackEnd, BackEnd→Database, BackEnd→Models and Worker→Database by container DNS, worker ffmpeg,
restart policy `unless-stopped`, database and models not published.

## Hetzner deployment

```powershell
.\deploy-all.ps1                         # everything
.\deploy-all.ps1 -SkipBuild              # re-send / redeploy the existing exports
.\deploy-all.ps1 -SkipBuild -SkipTransfer   # re-apply configuration + secrets only
.\deploy-all.ps1 -CleanTar               # delete archives on the server after loading
```

1. **Validation**: registry, `secrets.prod.env`, Docker, sources, SSH, server prerequisites.
2. **Build and export**: `exports\*.tar` with SHA-256.
3. **Transfer**: tooling, `cogitia.env`, secrets (chmod 600, local staging copy deleted),
   archives uploaded as `.part`, SHA-256 verified, then renamed. Unchanged archives are skipped.
4. **Remote deploy** (`cogitia-remote.sh deploy`): `pg_dump` backup (last 5), `NetCogitia`,
   `docker load`, `compose up -d`, health wait (container logs printed on timeout), in-server
   verification (same checks as local), label-scoped prune of dangling Cogitia images.
5. **nginx**: renders `terra-cogitia.conf` (HTTP, or HTTPS once the certificate exists), runs
   `nginx -t` and **rolls back** on failure, then reloads.
6. **Verification from your PC**: direct `http://95.217.14.18:8200/8201` and the public URLs
   (a DNS record not yet pointing at the server shows as a WARN, not a FAIL).

Any failure stops the run with exit code 1.

**First production rollout**
1. Create `secrets.prod.env`, then set the DNS A records.
2. `.\deploy-all.ps1`: containers up, HTTP vhost installed.
3. `.\renew-certificates.ps1 -Issue -Email <you> -DryRun`, then without `-DryRun`.
4. `.\deploy-all.ps1 -SkipBuild -SkipTransfer` (optional): re-verifies over HTTPS.

## Cloned voices (optional Cogitia-Voice)

`Cogitia-Voice` runs VibeVoice-1.5B: text-to-speech that imitates a voice from a 10-30 s sample.
Authors store their voice in **Administration › IA › Voix** (sample recorded in the browser or
uploaded, plus a consent statement) and pick it as a narration voice in the Creation Studio.

It is **off by default** because it is heavy: image ~10 GB (weights 5.5 GB baked at a pinned
revision), about 11.5 GB of RAM (limit `memory` 14g), and on CPU it is **much slower than real
time**: measured 6.8 s of French audio in 125 s on 4 cores (~18x), so a 30 s narration takes about
9 minutes. To turn it on:

1. It follows the environment: `environments.<env>.optional_services` in `cogitia-registry.json`
   lists it for **local** (on) and not for **production** (off, to spare the server's RAM). Add
   `"voice"` to production's list to deploy it on Hetzner (adjust `services.voice.cpus` / `memory`).
2. `.\deploy-local.ps1` (or `.\deploy-all.ps1`): the image is built, started under the compose
   profile `voice`, and checked (Back-End -> Voice, not published).
3. First start of the Back-End with the voice enabled seeds the deployment `vibevoice@voice` as
   **active**, routed second on « Audio : narration » (Piper stays the default voice). If the stack
   ran before with the voice off, activate `vibevoice@voice` in **Administration › IA › Modèles &
   fournisseurs**.

On a GPU host, build with `--build-arg TORCH_INDEX=https://download.pytorch.org/whl/cu128` and give
the container GPU access: synthesis becomes faster than real time. Nothing in the application names
VibeVoice: any voice deployment whose settings declare `voice_cloning` receives the cloned voices.

## Changing an API key (no redeploy)

Edit `secrets.prod.env` (the single source of truth), then:

```powershell
.\update-secrets.ps1
```

This uploads only `secrets/backend.env` and recreates **only** `Cogitia-BackEnd`: env files are
read when a container is created, so a plain restart isn't enough. It then waits until the
container is healthy and runs the in-server verification. No build, no image transfer; the
Front-End and database keep running. Downtime is the Back-End restart (~10-20 s).

- Applies to `MISTRAL_API_KEY`, `MISTRAL_MODEL`, `OPENAI_API_KEY`.
- If nothing changed, it says so and does nothing.
- It **refuses** a changed `POSTGRES_PASSWORD` (the database keeps its original password; see
  Troubleshooting to rotate it).

Locally, the equivalent is `.\deploy-local.ps1 -SkipBuild` (about 20 s).

## Cleanup

| | Local `clean-all-local.ps1` | Hetzner `clean-all.ps1` |
|---|---|---|
| Containers (by exact name) | removed | removed |
| `NetCogitia` | removed if no foreign container is attached | same |
| Cogitia images (label) | removed (`-KeepImages` to keep) | same |
| Artifacts | `.runtime\local`, `exports\` | `images/*.tar`, `secrets/` |
| Data volumes | kept; `-PurgeData` deletes them after a `pg_dump` | same |
| nginx vhost | — | kept; `-RemoveNginx` removes it (certificates always kept) |
| Backups | kept | kept |
| Confirmation | only with `-PurgeData` | always (unless `-Force`) |

No global `docker system/image/network prune` is ever run. Scripts are safe on absent or
partial deployments.

## Certificates

Same architecture as PlanningPowerTools: certbot on the host with the **nginx authenticator**,
certificates in `/etc/letsencrypt`, nginx reload. One certificate (`app.terra-cogitia.com`)
covers `app.` and `api.`. Other certbot certificates on the server are never touched.

```powershell
.\renew-certificates.ps1 -Issue -Email you@x.com -DryRun   # staging test (no rate limit)
.\renew-certificates.ps1 -Issue -Email you@x.com           # obtain + switch vhost to HTTPS
.\renew-certificates.ps1                                   # renew if < 30 days (-DaysThreshold N)
.\renew-certificates.ps1 -DryRun                           # test renewal plumbing
.\renew-certificates.ps1 -Force                            # force (mind LE rate limits)
```

Expiry is parsed from `certbot certificates` (not certbot's label). After a renewal the script
reloads nginx and checks, **over TLS from your PC**, that both domains serve the new certificate.
certbot's own systemd timer still renews automatically; this script is the explicit, verified path.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Docker engine is not reachable` | Start Docker Desktop. |
| `Cogitia-FrontEnd` restarting, logs show `40-cogitia-env.sh: not found` | The script was checked out with Windows line endings (Git `core.autocrlf=true`). Fixed in the image (CR stripped at build) and in `.gitattributes` (LF forced for new checkouts). On the affected machine: pull, then run `deploy-local.ps1` again. |
| `Cogitia-BackEnd` unhealthy, logs show `password authentication failed` | `POSTGRES_PASSWORD` changed after the volume was created. Restore the old value, or `docker exec -it Cogitia-Database psql -U postgres -c "ALTER USER postgres PASSWORD '<new>'"`. |
| Backend logs `DB_PASSWORD manquant` | `secrets/backend.env` missing; rerun the deploy script. |
| Page loads but API calls fail (browser console: CORS) | Add the page origin to `cors_origins` in the registry and redeploy. |
| AI generation returns 500/502 | `MISTRAL_API_KEY` empty or invalid in the secrets file. |
| Direct checks fail, in-server checks pass | Hetzner Cloud firewall: open TCP 8200/8201 (or set `bind_address` to `127.0.0.1` to serve through nginx only). |
| `DNS ... resolves to ...` WARN | Create/fix the A records; wait for propagation. |
| certbot timeout / failure | Port 80 reachable, A records correct, nginx running; test with `-DryRun`. |
| `SSH password authentication failed` | Wrong password, or set up a key (see above). |
| Seed data not re-applied | By design: the seed runs only on an empty volume. `clean-all(-local).ps1 -PurgeData` then redeploy to reseed. |
| Server state | `ssh root@95.217.14.18 bash /root/cogitia/cogitia-remote.sh status` |
| Restore a backup | `docker exec -i Cogitia-Database pg_restore -U postgres -d terracogitia --clean --if-exists < backups/<file>.dump` |
