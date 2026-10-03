# Terra-Cogitia — Installation Command Reference

Every command of the deployment toolkit in `D:\Cogitia\Installation`. Run the scripts from that
folder in PowerShell. For how the containers fit together, see [ARCHITECTURE.md](ARCHITECTURE.md);
for troubleshooting and background, see [README.md](README.md).

## At a glance

| Script | Target | Purpose |
|---|---|---|
| [`deploy-local.ps1`](#deploy-localps1) | Your PC (Docker Desktop) | Build and (re)deploy the three containers, then verify |
| [`db-access.ps1`](#db-accessps1) | Your PC | Browse the local PostgreSQL (Adminer UI, `psql`, or TCP tunnel) |
| [`clean-all-local.ps1`](#clean-all-localps1) | Your PC | Remove the local deployment |
| [`deploy-all.ps1`](#deploy-allps1) | Hetzner | Build → export → transfer → deploy → verify |
| [`update-secrets.ps1`](#update-secretsps1) | Hetzner | Apply an API-key change without redeploying |
| [`renew-certificates.ps1`](#renew-certificatesps1) | Hetzner | Issue, check and renew the HTTPS certificate |
| [`clean-all.ps1`](#clean-allps1) | Hetzner | Remove the deployment from the server |

Common to every script:

- **Exit code:** `0` = success, `1` = failure (the error is printed in red). Scripts stop at the first failed step.
- **`-RegistryPath <file>`:** use another registry instead of `cogitia-registry.json` (for testing).
- **Scope:** only Terra-Cogitia resources are touched; other Docker projects are never affected.
- **Hetzner scripts** connect with your SSH key if one is installed. Otherwise they read the password
  from `$env:COGITIA_SSH_PASSWORD`, or prompt for it.

---

## Local (Docker Desktop)

### `db-access.ps1`

Opens a practical local access to `Cogitia-Database` (PostgreSQL is not published on the host).

| Parameter | Default | Effect |
|---|---|---|
| *(none)* | Adminer | Starts Adminer on http://127.0.0.1:8210 and opens the browser |
| `-Shell` | off | Interactive `psql` inside the database container |
| `-Tunnel` | off | Exposes `127.0.0.1:15432` for DBeaver / pgAdmin / etc. |
| `-Stop` | off | Stops Adminer and the tunnel helpers |
| `-Port` | `8210` | Local Adminer port |
| `-TunnelPort` | `15432` | Local tunnel port (5432/5433 often unavailable on Windows/Docker) |
| `-NoBrowser` | off | Do not open the browser |

```powershell
.\db-access.ps1              # Adminer UI
.\db-access.ps1 -Shell       # psql
.\db-access.ps1 -Tunnel      # TCP for a desktop client
.\db-access.ps1 -Stop
```

Adminer / tunnel login: System **PostgreSQL**, Server **`cogitia-database`** (Adminer) or Host
**`127.0.0.1`** port **`15432`** (tunnel), Database **`terracogitia`**, User **`postgres`**, Password =
`POSTGRES_PASSWORD` in `secrets.local.env`.

### `deploy-local.ps1`

Builds the images and starts `Cogitia-FrontEnd` (http://localhost:8200), `Cogitia-BackEnd`
(http://localhost:8201) and `Cogitia-Database`. Safe to run repeatedly: only what changed is recreated,
and the data is kept.

| Parameter | Default | Effect |
|---|---|---|
| `-NoCache` | off | Rebuild the images from scratch (`docker build --no-cache`) |
| `-SkipBuild` | off | Reuse the existing images (fails if they don't exist) |
| `-SkipBackup` | off | Don't back up the database before redeploying |
| `-HealthTimeoutSec <30-1800>` | `300` | How long to wait for the containers to become healthy |
| `-SyncDbPassword` | off | Set the database password to the one in `secrets.local.env`, **keeping the data** (fixes "password authentication failed") |

```powershell
.\deploy-local.ps1               # build + deploy + verify (first run ~5 min)
.\deploy-local.ps1 -SkipBuild    # redeploy existing images, e.g. after a secrets change (~20 s)
.\deploy-local.ps1 -NoCache      # clean rebuild
.\deploy-local.ps1 -SyncDbPassword   # database password differs from secrets.local.env (data kept)
```

It checks prerequisites, builds the 3 images, generates `.runtime\local\`, backs up the database to
`backups\local\` (last 5 kept), creates `NetCogitia`, runs `docker compose up`, waits until all containers
are healthy, runs 13 verification checks, and removes dangling Terra-Cogitia images.

**`secrets.local.env` is required**: create it once from `secrets.env.example`, then copy the same file to every machine. Before starting the Back-End, the script checks that the database accepts its `POSTGRES_PASSWORD` and stops within seconds if not.

### `clean-all-local.ps1`

Removes the local containers, the `NetCogitia` network (only if no other container uses it), the
Terra-Cogitia images, `.runtime\local\` and `exports\`. **Data volumes, `secrets.local.env` and `backups\` are kept.**

| Parameter | Default | Effect |
|---|---|---|
| `-KeepImages` | off | Keep the images (faster redeploy with `deploy-local.ps1 -SkipBuild`) |
| `-PurgeData` | off | **Also delete the database and media volumes** (a backup is taken first); asks you to type `cogitia` |
| `-Force` | off | Skip the `-PurgeData` confirmation |

```powershell
.\clean-all-local.ps1               # remove containers, network, images (data kept)
.\clean-all-local.ps1 -KeepImages   # remove containers only, keep images
.\clean-all-local.ps1 -PurgeData    # full reset; next deploy reseeds the database
```

---

## Hetzner (production)

### `deploy-all.ps1`

Complete production deployment to `95.217.14.18` (`/root/cogitia`). Requires `secrets.prod.env`.

| Parameter | Default | Effect |
|---|---|---|
| `-SkipBuild` | off | Reuse the archives already in `exports\` |
| `-SkipTransfer` | off | Don't upload image archives (configuration and secrets are still synced) |
| `-SkipDeploy` | off | Build and transfer only; don't start anything |
| `-SkipNginx` | off | Don't install or refresh the host nginx vhost |
| `-NoCache` | off | Rebuild the images from scratch |
| `-CleanTar` | off | Delete the archives on the server once loaded (saves disk; the next deploy re-uploads them) |

```powershell
.\deploy-all.ps1                              # everything
.\deploy-all.ps1 -NoCache                     # clean rebuild, then deploy
.\deploy-all.ps1 -SkipBuild                   # redeploy the existing exports
.\deploy-all.ps1 -SkipBuild -SkipTransfer     # re-apply configuration + secrets, re-verify
.\deploy-all.ps1 -SkipDeploy                  # prepare and upload, deploy later
```

Its phases:

1. **Validation:** registry, secrets, Docker, sources, SSH, server prerequisites.
2. **Build and export:** `exports\*.tar` with SHA-256 checksums.
3. **Transfer:** archives are checksum-verified, and unchanged ones are skipped.
4. **Remote deploy:** database backup, `NetCogitia`, load, start, health, 11 in-server checks.
5. **nginx vhost:** installs the site for `app.` and `api.terra-cogitia.com`.
6. **Verification from your PC:** direct ports and public URLs.

### `update-secrets.ps1`

Pushes a change made in `secrets.prod.env` (`MISTRAL_API_KEY`, `MISTRAL_MODEL`, `OPENAI_API_KEY`) to the
server and recreates **only** `Cogitia-BackEnd` (~10-20 s of Back-End downtime). No build, no transfer.
If nothing changed, it does nothing. It **refuses** a changed `POSTGRES_PASSWORD`.

| Parameter | Default | Effect |
|---|---|---|
| *(none)* | | |

```powershell
.\update-secrets.ps1
```

### `renew-certificates.ps1`

Manages the Let's Encrypt certificate `app.terra-cogitia.com` (covers `app.` and `api.`) with certbot on
the server. Other certificates on the server are never touched.

| Parameter | Default | Effect |
|---|---|---|
| `-Issue` | off | Obtain the certificate the first time (needs DNS A records pointing at the server) |
| `-Email <address>` | — | Required with `-Issue`. Running `-Issue` accepts the Let's Encrypt terms for that address |
| `-DaysThreshold <1-89>` | `30` | Renew when fewer days than this remain |
| `-Force` | off | Renew even if not due (Let's Encrypt limits renewals per week) |
| `-DryRun` | off | Test against Let's Encrypt staging without changing the live certificate |

```powershell
.\renew-certificates.ps1 -Issue -Email you@terra-cogitia.com -DryRun   # test first issuance
.\renew-certificates.ps1 -Issue -Email you@terra-cogitia.com           # first certificate, switches site to HTTPS
.\renew-certificates.ps1                                               # check; renew if < 30 days left
.\renew-certificates.ps1 -DaysThreshold 14                             # tighter renewal window
.\renew-certificates.ps1 -DryRun                                       # test the renewal path
.\renew-certificates.ps1 -Force                                        # force renewal
```

After any change it reloads nginx and checks, from your PC, that both domains serve the new certificate.

### `clean-all.ps1`

Removes the deployment from the server: containers, `NetCogitia` (if unused), images, uploaded archives
and secrets. **Data volumes, the nginx vhost, certificates and `/root/cogitia/backups` are kept** by default.
It shows the current state and asks for confirmation.

| Parameter | Default | Effect |
|---|---|---|
| `-KeepImages` | off | Keep the images on the server |
| `-PurgeData` | off | **Also delete the production database and media volumes** (a backup is taken first); asks you to type `cogitia` |
| `-RemoveNginx` | off | Also remove the nginx vhost (certificates are always kept) |
| `-Force` | off | Skip the confirmation prompt |

```powershell
.\clean-all.ps1                           # asks, then removes (data kept)
.\clean-all.ps1 -KeepImages -Force        # no prompt, keep images
.\clean-all.ps1 -PurgeData -RemoveNginx   # full removal (backup kept)
```

---

## Server-side commands (`cogitia-remote.sh`)

The Hetzner scripts drive `/root/cogitia/cogitia-remote.sh` over SSH. You can also run it directly
on the server:

```bash
ssh root@95.217.14.18 bash /root/cogitia/cogitia-remote.sh <command>
```

| Command | Effect |
|---|---|
| `status` | Containers, network members, images, volumes |
| `backup` | `pg_dump` now, into `/root/cogitia/backups/` |
| `deploy [--clean-tar]` | Load archives, start, wait healthy, verify (used by `deploy-all.ps1`) |
| `apply-secrets` | Recreate the Back-End with `secrets/backend.env` (used by `update-secrets.ps1`) |
| `clean [--purge-data] [--remove-nginx] [--keep-images]` | Remove the deployment (used by `clean-all.ps1`) |
| `nginx` | Install or refresh the vhost; HTTPS once the certificate exists; rolls back if `nginx -t` fails |
| `cert-status` | Show the certificate (`certbot certificates`) |
| `cert-issue <email> [--dry-run]` | Obtain the certificate |
| `cert-renew [--dry-run] [--force]` | Renew the certificate |

---

## Typical workflows

**First production rollout**

1. Create `secrets.prod.env` from `secrets.env.example`, then set the DNS A records for
   `app.terra-cogitia.com` and `api.terra-cogitia.com` to `95.217.14.18`.

   ```powershell
   Copy-Item secrets.env.example secrets.prod.env   # then fill in POSTGRES_PASSWORD and MISTRAL_API_KEY
   ```
2. Deploy:

   ```powershell
   .\deploy-all.ps1
   ```
3. Get the certificate, testing against staging first:

   ```powershell
   .\renew-certificates.ps1 -Issue -Email you@terra-cogitia.com -DryRun
   .\renew-certificates.ps1 -Issue -Email you@terra-cogitia.com
   ```

**Release a code change**

```powershell
.\deploy-local.ps1     # test locally
.\deploy-all.ps1       # ship to Hetzner
```

**Change the Mistral key**

```powershell
# edit secrets.prod.env, then:
.\update-secrets.ps1
```

**Monthly certificate check**

```powershell
.\renew-certificates.ps1
```

**Reset local data to the seed**

```powershell
.\clean-all-local.ps1 -PurgeData
.\deploy-local.ps1
```

**Skip the SSH password prompt for this session**

```powershell
$env:COGITIA_SSH_PASSWORD = Read-Host -AsSecureString "SSH password" | ForEach-Object { [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) }
```

Better: install an SSH key once (see README), and no password is needed at all.
