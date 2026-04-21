# Deploy h3t API + Varnish to the CalCOFI server

## Context

Phase 4 of the earlier h3t plan wrote the container + VCL + Caddy config but
nothing is live yet. These are the one-time and ongoing commands for deploying
`h3t_api` + `varnish` to the production server and cutting traffic over.

Assumptions:
- You SSH into the host that runs `docker compose` out of `~/Github/CalCOFI/server`
  (path on the server is likely `/share/github/CalCOFI/server`).
- The CalCOFI org repos (`api-h3t`, `server`, `mapgl`, `int-app`) live at
  `/share/github/...` on the server and are kept in sync via `git pull`.
- A released DuckDB file is available locally on the server under
  `/share/github/int-app/data/`. A symlink `calcofi_latest.duckdb` points at the
  current release (e.g. `calcofi_v2026.04.08.duckdb`).
- DNS for `h3t.calcofi.io` already resolves to the host (Caddy auto-provisions
  TLS on first request).

---

## Step 1 — ✅ DONE: already pushed to GitHub

The four repos are all published:
- **CalCOFI/api-h3t** (public, MIT) — <https://github.com/CalCOFI/api-h3t>
- **CalCOFI/server** — <https://github.com/CalCOFI/server> (commit adds h3t_api + varnish)
- **CalCOFI/int-app** — <https://github.com/CalCOFI/int-app> (commit adds USE_H3T flag)
- **bbest/mapgl** `feat/add-h3t-source` branch → upstream PR
  <https://github.com/walkerke/mapgl/pull/199>

## Step 2 — on the server: pull the new code

```bash
ssh <server-host>

# pull the four repos that changed
for repo in server api-h3t int-app ; do
  git -C /share/github/$repo pull --ff-only
done
git -C /share/github/bbest/mapgl pull --ff-only   # or wherever the fork lives
```

## Step 3 — on the server: stage the released DuckDB

The `h3t_api` container mounts `/share/github/int-app/data:/data:ro` and opens
`/data/calcofi_latest.duckdb`. Point the symlink at the current release:

```bash
# one-off: ensure the data dir exists
# sudo mkdir -p /share/github/int-app/data

# copy (or hard-link) the latest release into place
# sudo cp /share/github/CalCOFI/int-app/data/calcofi_v2026.04.08.duckdb \
#         /share/github/int-app/data/

# atomically flip the "latest" pointer
#sudo ln -sfn calcofi_v2026.04.08.duckdb /share/github/int-app/data/calcofi_latest.duckdb
#bebest_ucsd_edu@shiny-server:/share/github/int-app/data$
cd /share/github/int-app/data 
sudo -u bebest ln -s calcofi_v2026.04.08.duckdb calcofi_latest.duckdb
ls -l /share/github/int-app/data/
```

## Step 4 — on the server: build & launch the new containers

```bash
# cd /share/github
# sudo -u bebest mkdir CalCOFI
# sudo -u bebest mv server CalCOFI/server
# sudo -u bebest mv api-h3t CalCOFI/api-h3t
cd /share/github/CalCOFI/server

# build only the new service (pulls rocker base + python venv + sqlglot)
sudo docker compose build h3t_api
# docker compose build --no-cache h3t_api

# bring up the new containers (varnish depends_on h3t_api so it follows)
docker compose up -d h3t_api varnish

# tail logs until h3t_api reports ready
docker compose logs -f h3t_api
#  expect: "Running plumber API at http://0.0.0.0:8889"
#  Ctrl-C to detach once you see it
```

## Step 5 — on the server: reload Caddy for the new host

Caddy picks up the new `h3t.calcofi.io` block and will ACME-provision TLS
on first request:

```bash
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

## Step 6 — verify the chain end-to-end

From the server (or any machine that can reach it):

```bash
# direct backend (skip Varnish + Caddy)
docker compose exec h3t_api curl -s http://localhost:8889/h3t/health

# through Varnish only (inside the docker network)
docker compose exec varnish curl -s http://localhost/h3t/health

# through Caddy → Varnish → h3t_api (public path)
curl -s https://h3t.calcofi.io/h3t/health
curl -s https://h3t.calcofi.io/h3t/meta | jq .

# a real tile
SQL="SELECT hex_h3res{{res}} AS cell_id, AVG(std_tally) AS value, COUNT(*) AS n
     FROM bio_obs WHERE scientific_name = 'Sardinops sagax' GROUP BY 1"
Q=$(printf '%s' "$SQL" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
curl -sI "https://h3t.calcofi.io/h3t/4/3/6.h3t?q=$Q&release=v2026.04.08" \
  | grep -Ei '^(HTTP|X-Cache|Cache-Control|ETag|X-Calcofi-Release)'
# on the first hit expect: X-Cache: MISS; on a repeat: X-Cache: HIT
```

## Step 7 — deploy the int-app with the flag flipped

If the int-app runs under Shiny Server (the `rstudio:3838` container), drop an
environment file for the app and restart:

```bash
# option A: env vars via /etc/Renviron.site (reached by all Shiny apps)
sudo echo 'H3T_USE=TRUE'                                 | sudo tee -a /etc/R/Renviron.site
sudo echo 'H3T_BASE_URL=https://h3t.calcofi.io/h3t'      | sudo tee -a /etc/R/Renviron.site
sudo echo 'H3T_RELEASE=v2026.04.08'                      | sudo tee -a /etc/R/Renviron.site

# option B: per-app Renviron inside the int-app directory (preferred — scoped)
# cat <<EOF | sudo tee /srv/shiny-server/int-app/.Renviron
# H3T_USE=TRUE
# H3T_BASE_URL=https://h3t.calcofi.io/h3t
# H3T_RELEASE=v2026.04.08
# EOF

# force a fresh R process for the app (Shiny Server auto-restarts on file touch)
sudo touch /srv/shiny-server/int-app/restart.txt
```

Visit `https://app.calcofi.io` (or wherever the int-app is routed) and watch
the browser network panel — you should see `h3tiles://.../{z}/{x}/{y}.h3t`
requests firing on pan/zoom.

---

## Ongoing — release invalidation

Every time `release_database.qmd` produces a new release:

1. Update the symlink:
   ```bash
   sudo ln -sfn calcofi_v2026.MM.DD.duckdb /share/github/int-app/data/calcofi_latest.duckdb
   ```
2. Bounce the API so it reopens the DuckDB file (it holds the handle):
   ```bash
   docker compose restart h3t_api
   ```
3. Ban old Varnish objects (optional — URLs already carry the old `release`
   param so new clients won't hit them):
   ```bash
   docker compose exec varnish varnishadm ban 'req.url ~ "^/h3t/"'
   ```
4. Update the `H3T_RELEASE` env var in the int-app's `.Renviron` and touch
   `restart.txt`.

---

## Troubleshooting quick refs

```bash
# is the backend up?
docker compose ps h3t_api varnish caddy

# backend errors
docker compose logs --tail=200 h3t_api

# Varnish cache stats
docker compose exec varnish varnishstat -1 \
  -f MAIN.cache_hit -f MAIN.cache_miss -f MAIN.cache_hitpass

# request-level Varnish trace
docker compose exec varnish varnishlog -g request -q 'ReqURL ~ "/h3t"'

# Caddy access log for the new host
docker compose logs caddy | grep h3t.calcofi.io
```
