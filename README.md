# api-h3t

An **h3t tile server**: takes a base64-encoded SQL `SELECT` against a read-only
[DuckDB](https://duckdb.org) file and returns
[h3j](https://github.com/INSPIDE/h3j-h3t)-format JSON tiles suitable for the
`h3tiles://` MapLibre protocol.

Drop-in companion to [`mapgl::add_h3t_source()`][add_h3t_source]. Together they
replace *preload-every-hexagon-at-every-resolution* with *fetch-just-the-cells-in-view*,
for any DuckDB dataset that has H3 cells per row.

> Why this exists: rendering dense H3 hex layers in a web map usually means
> either (a) loading a huge GeoJSON/FlatGeoBuf up front, or (b) running a
> bespoke tile server per dataset. `api-h3t` lets you point a single server
> at any DuckDB file and drive any number of layers with different filters —
> the filter *is* the cache key.

## How it works

```
 MapLibre (h3tiles:// protocol)                         h3t tile server
     │                                                        │
     │ GET  /h3t/{z}/{x}/{y}.h3t ?q=<base64(SELECT ...)>      │
     │ ────────────────────────────────────────────────────►  │
     │                                                        │ sqlglot validate
     │                                                        │ wrap with bbox +
     │                                                        │ h3_h3_to_string +
     │                                                        │ LIMIT
     │                                                        │ run vs read-only DuckDB
     │                                                        │
     │ { "cells": [{ h3id, value, n }, …] }                   │
     │ ◄────────────────────────────────────────────────────  │
```

Cells are returned in the h3j "cells" schema the `h3tiles://` protocol handler
expects; it converts them to MVT client-side so standard MapLibre layer styling
(`fill-color`, `interpolate`, hover state, etc.) just works.

## The SQL contract

Your `SELECT` must project **exactly** these columns (extras are rejected):

| column    | type    | required | purpose                                       |
|-----------|---------|----------|-----------------------------------------------|
| `cell_id` | BIGINT  | yes      | H3 cell index (use `hex_h3resN` or `h3_latlng_to_cell`) |
| `value`   | numeric | yes      | the value the map colorizes                   |
| `n`       | BIGINT  | optional | count / weight passed through to the client   |

Two conveniences the server layers on:

- `{{res}}` placeholder — substituted with the H3 resolution for each tile
  (derived from zoom). Use it once in your SELECT (e.g. `hex_h3res{{res}}`)
  and one cached query serves every zoom level.
- An outer BBox + row-cap is added automatically — you don't write
  `WHERE lon BETWEEN ...` yourself. Hex cells whose centroids fall outside
  the current tile are filtered out before the response is built.

Full SQL freedom otherwise: `JOIN`, `WITH`, `WITH RECURSIVE`, window functions,
subqueries. See [`example/demo.sql`](example/demo.sql).

## Endpoints

All GET, all return JSON unless noted.

| route | description |
|---|---|
| `/h3t/{z}/{x}/{y}.h3t ?q=<b64>[&res_h3=N][&release=v]` | tile in [h3j cells format](https://github.com/INSPIDE/h3j-h3t#h3j) |
| `/h3t/stats ?q=<b64>[&res_h3=N][&release=v]` | `{min, max, p02, p98, n}` for color-ramp construction |
| `/h3t/meta` | DuckDB file metadata + table list + zoom→res mapping |
| `/h3t/health` | liveness |

### Response headers

- `Cache-Control: public, max-age=600`
- `ETag: W/"<sha256(q, z, x, y, res, release)>"`
- `X-Calcofi-Release: <release>` — echoed for cache-key hygiene

These headers make the service trivially fronted by any HTTP cache
(Varnish, nginx, Cloudflare). Pass a `release` query param that changes whenever
your underlying data changes, and you get safe, automatic invalidation.

## Quickstart — Docker

Assume you have a DuckDB file `my.duckdb` with an H3 column `hex_h3res5` on a
table `my_points`.

```bash
git clone https://github.com/CalCOFI/api-h3t.git
cd api-h3t

docker build -t api-h3t .

docker run --rm -p 8889:8889 \
  -e DUCKDB_PATH=/data/my.duckdb \
  -v "$(pwd)/path/to/data:/data:ro" \
  api-h3t

# another terminal
SQL="SELECT hex_h3res{{res}} AS cell_id, COUNT(*) AS value, COUNT(*) AS n
       FROM my_points GROUP BY 1"
Q=$(printf '%s' "$SQL" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')

curl -s "http://localhost:8889/h3t/health"
curl -s "http://localhost:8889/h3t/stats?q=$Q" | jq .
curl -s "http://localhost:8889/h3t/4/3/6.h3t?q=$Q" | jq '.cells | length'
```

## Quickstart — local R (no Docker)

```bash
# Python side — sqlglot is used via reticulate for SQL validation
python3 -m venv .venv
./.venv/bin/pip install -r requirements.txt

# R side
Rscript -e 'install.packages(c("plumber","duckdb","DBI","glue","jsonlite",
                               "digest","reticulate","base64enc"),
                             repos = "https://cloud.r-project.org")'

DUCKDB_PATH=$PWD/example/my.duckdb \
RETICULATE_PYTHON=$PWD/.venv/bin/python \
Rscript run-api.R
# Running plumber API at http://0.0.0.0:8889
```

## Using it from R (maplibre client)

Requires `mapgl` with [`add_h3t_source()`][add_h3t_source]:

```r
library(mapgl)
library(base64enc)

sql <- "SELECT hex_h3res{{res}} AS cell_id, COUNT(*) AS value, COUNT(*) AS n
          FROM my_points GROUP BY 1"
q   <- base64encode(charToRaw(sql)) |>
         chartr("+/", "-_", x = _) |> sub("=+$", "", x = _)

tiles <- sprintf("h3tiles://localhost:8889/h3t/{z}/{x}/{y}.h3t?q=%s", q)

maplibre(center = c(-119, 34), zoom = 5) |>
  add_h3t_source(id = "cells", tiles = tiles) |>
  add_fill_layer(
    id = "cells", source = "cells", source_layer = "cells",
    fill_color   = interpolate(
      column = "value", values = c(1, 100),
      stops  = c("#ffffcc", "#e31a1c")),
    fill_opacity = 0.7
  )
```

A reference end-to-end Shiny integration — legend, zoom-aware resolution,
swapping filters via proxy — lives in the
[CalCOFI/db-viz-hex](https://github.com/CalCOFI/db-viz-hex) repo under the
`USE_H3T=TRUE` code path.

## Security model

The server must never execute arbitrary client SQL as-is. Defence in depth:

1. **sqlglot AST validation** before execution:
   - exactly one statement; root must be `SELECT` (with optional `WITH` / `WITH RECURSIVE`);
   - projections must be `{cell_id, value, [n]}` — rejects `SELECT *`;
   - denylist covers `read_csv/read_parquet/read_json/read_blob`, `attach`, `detach`, `load_extension`, `install_extension`, `pg_*`, `mysql_*`, `sqlite_scan`, `shell`, `system`, and friends;
   - external catalog refs (`postgres.`, `sqlite_*`, `pg_*`) rejected;
   - AST size capped (default 2000 nodes); raw SQL size capped (default 16 KB).
2. **DuckDB connection opened read-only** — writes fail at the driver layer even if a write somehow slipped past the validator.
3. **Per-request wall clock** via R `setTimeLimit` (default 3 s).
4. **Tile-level row cap** (`H3T_MAX_ROWS`, default 50 000).

See [`sql_validate.py`](sql_validate.py) for the exact ruleset.

## Configuration

| env var | default | purpose |
|---|---|---|
| `DUCKDB_PATH` | *(required)* | path to the DuckDB file; opened read-only |
| `H3T_PORT` | `8889` | listen port |
| `H3T_HOST` | `0.0.0.0` | bind host |
| `H3T_MAX_ROWS` | `50000` | row cap per tile |
| `H3T_STMT_TIMEOUT_MS` | `3000` | per-request wall-clock timeout |
| `RETICULATE_PYTHON` | *(auto)* | path to Python with `sqlglot` |
| `SQLGLOT_PY` | *(auto)* | alias for `RETICULATE_PYTHON` for the validator |

## Related work

- **[INSPIDE/h3j-h3t](https://github.com/INSPIDE/h3j-h3t)** — the JS client
  that registers the `h3tiles://` protocol and converts JSON cells to MVT.
- **[mapgl][add_h3t_source]** — `add_h3t_source()` is the R-side wrapper;
  the upstream PR is tracked [here](https://github.com/walkerke/mapgl/pulls?q=add_h3t_source).
- **[DuckDB H3 community extension](https://community-extensions.duckdb.org/extensions/h3)**
  — used for `h3_latlng_to_cell`, `h3_cell_to_lat`, `h3_h3_to_string`, etc.
- **[uber/h3](https://h3geo.org/)** — the H3 spec itself.

## License

MIT. See [LICENSE](LICENSE).

[add_h3t_source]: https://walker-data.com/mapgl/reference/add_h3t_source.html
