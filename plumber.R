# h3t tile API — serves base64-encoded SELECT queries against a read-only
# DuckDB as h3j-format JSON tiles for use with mapgl::add_h3t_source().
#
# endpoints:
#   GET /h3t/{z}/{x}/{y}.h3t ?q=<b64>[&res=1..10][&release=v]  → h3j tile
#   GET /h3t/stats           ?q=<b64>[&release=v]              → value summary
#   GET /h3t/meta                                              → schema + release
#   GET /h3t/health                                            → liveness

suppressPackageStartupMessages({
  library(plumber)
  library(DBI)
  library(duckdb)
  library(jsonlite)
  library(base64enc)
  library(digest)
})

# --- setup ---------------------------------------------------------------

API_DIR <- local({
  # try sys.frame first (works when sourced from another R file)
  of <- tryCatch(sys.frame(1)$ofile, error = function(e) NULL)
  if (!is.null(of) && file.exists(of)) return(dirname(normalizePath(of)))
  # fall back to the --file= arg from Rscript, then cwd
  args <- commandArgs(trailingOnly = FALSE)
  m <- regmatches(args, regexpr("--file=.+", args))
  if (length(m) == 1L) return(dirname(normalizePath(sub("--file=", "", m, fixed = TRUE))))
  getwd()
})

source(file.path(API_DIR, "sql_validate.R"))
source(file.path(API_DIR, "h3t_query.R"))
h3t_load_validator()

DUCKDB_PATH <- Sys.getenv("DUCKDB_PATH", "")
if (!nzchar(DUCKDB_PATH) || !file.exists(DUCKDB_PATH)) {
  stop("DUCKDB_PATH env var must point at an existing read-only DuckDB file")
}

MAX_ROWS_PER_TILE <- as.integer(Sys.getenv("H3T_MAX_ROWS", "50000"))
STMT_TIMEOUT_MS   <- as.integer(Sys.getenv("H3T_STMT_TIMEOUT_MS", "3000"))

# single shared read-only connection per plumber worker (DuckDB is thread-safe
# for reads; plumber serializes requests on a worker anyway)
.h3t_con <- local({
  drv <- duckdb(dbdir = DUCKDB_PATH, read_only = TRUE)
  con <- dbConnect(drv)
  dbExecute(con, "INSTALL h3 FROM community; LOAD h3;")
  dbExecute(con, "INSTALL spatial; LOAD spatial;")
  con
})

DB_MTIME <- as.character(file.info(DUCKDB_PATH)$mtime)

# --- helpers -------------------------------------------------------------

decode_sql <- function(q) {
  if (is.null(q) || !nzchar(q)) return(NULL)
  raw <- tryCatch(base64enc::base64decode(q), error = function(e) NULL)
  if (is.null(raw)) return(NULL)
  # raw -> utf-8 string
  rawToChar(raw)
}

bad_request <- function(res, reason) {
  res$status <- 400L
  list(error = "bad_request", reason = reason)
}

set_cache_headers <- function(res, etag, release = "") {
  res$setHeader("Cache-Control", "public, max-age=600")
  res$setHeader("ETag", sprintf('W/"%s"', etag))
  if (nzchar(release)) res$setHeader("X-Calcofi-Release", release)
}

validate_and_unwrap <- function(res, q, res_h3 = NULL) {
  sql <- decode_sql(q)
  if (is.null(sql)) return(bad_request(res, "q is required and must be valid base64"))
  # optional {{res}} template substitution — client can bake `hex_h3res{{res}}`
  # into the SQL so a single base64 string covers every zoom level.
  if (!is.null(res_h3) && grepl("\\{\\{\\s*res\\s*\\}\\}", sql)) {
    sql <- gsub("\\{\\{\\s*res\\s*\\}\\}", as.character(as.integer(res_h3)), sql)
  }
  v <- validate_sql(sql)
  if (!isTRUE(v$ok)) return(bad_request(res, v$reason))
  v
}

# --- endpoints -----------------------------------------------------------

#* @get /h3t/health
function() {
  list(ok = TRUE, db = basename(DUCKDB_PATH), db_mtime = DB_MTIME)
}

#* serve an h3j tile
#* @serializer unboxedJSON
#* @get /h3t/<z:int>/<x:int>/<y:int>.h3t
function(z, x, y, req, res, q = NULL, res_h3 = NULL, release = "") {
  # note: the query-param name for the H3 resolution is `res_h3`, not `res`,
  # because `res` is reserved as the plumber response object.
  bbox <- tryCatch(tile_bbox(z, x, y), error = function(e) NULL)
  if (is.null(bbox)) return(bad_request(res, "invalid z/x/y"))

  query_res <- res_h3
  if (is.character(query_res)) query_res <- suppressWarnings(as.integer(query_res))
  if (is.null(query_res) || is.na(query_res)) query_res <- zoom_to_res(z)
  if (query_res < 1L || query_res > 10L) return(bad_request(res, "res_h3 must be in [1, 10]"))

  v <- validate_and_unwrap(res, q, res_h3 = query_res)
  if (is.list(v) && identical(v$error, "bad_request")) return(v)

  wrapped <- wrap_tile_sql(v$normalized, bbox, has_n = v$has_n,
                           max_rows = MAX_ROWS_PER_TILE)

  rows <- tryCatch({
    setTimeLimit(elapsed = STMT_TIMEOUT_MS / 1000, transient = TRUE)
    on.exit(setTimeLimit(elapsed = Inf), add = TRUE)
    dbGetQuery(.h3t_con, wrapped)
  }, error = function(e) e)

  if (inherits(rows, "error")) {
    res$status <- 500L
    return(list(error = "query_failed", reason = conditionMessage(rows)))
  }

  etag <- digest::digest(list(q, z, x, y, query_res, release, DB_MTIME), algo = "sha256")
  set_cache_headers(res, etag, release)

  # build h3j cells payload
  cells <- if (nrow(rows) == 0L) list() else
    unname(lapply(seq_len(nrow(rows)), function(i) {
      o <- list(h3id = rows$h3id[[i]], value = rows$value[[i]])
      if (!is.na(rows$n[[i]])) o$n <- rows$n[[i]]
      o
    }))
  list(cells = cells)
}

#* value stats across the whole SELECT (no bbox), for legend ramp
#* @serializer unboxedJSON
#* @get /h3t/stats
function(req, res, q = NULL, release = "", res_h3 = 5L) {
  # stats use a fixed reference resolution (default res=5) so the color ramp
  # is stable across zoom levels. client can override with ?res_h3=N.
  if (is.character(res_h3)) res_h3 <- suppressWarnings(as.integer(res_h3))
  if (is.null(res_h3) || is.na(res_h3) || res_h3 < 1L || res_h3 > 10L) {
    return(bad_request(res, "res_h3 must be in [1, 10]"))
  }
  v <- validate_and_unwrap(res, q, res_h3 = res_h3)
  if (is.list(v) && identical(v$error, "bad_request")) return(v)

  wrapped <- wrap_stats_sql(v$normalized)
  row <- tryCatch({
    setTimeLimit(elapsed = STMT_TIMEOUT_MS / 1000, transient = TRUE)
    on.exit(setTimeLimit(elapsed = Inf), add = TRUE)
    dbGetQuery(.h3t_con, wrapped)
  }, error = function(e) e)
  if (inherits(row, "error")) {
    res$status <- 500L
    return(list(error = "query_failed", reason = conditionMessage(row)))
  }

  etag <- digest::digest(list("stats", q, release, DB_MTIME), algo = "sha256")
  set_cache_headers(res, etag, release)

  as.list(row[1, , drop = FALSE]) |>
    (\(x) c(x, list(release = release, db_mtime = DB_MTIME)))()
}

#* schema + release metadata for populating UI dropdowns
#* @serializer unboxedJSON
#* @get /h3t/meta
function(res) {
  tables <- dbGetQuery(.h3t_con,
    "SELECT table_name FROM information_schema.tables
       WHERE table_schema = 'main' ORDER BY 1")
  res$setHeader("Cache-Control", "public, max-age=60")
  list(
    db       = basename(DUCKDB_PATH),
    db_mtime = DB_MTIME,
    tables   = as.list(tables$table_name),
    h3_columns_per_row = paste0("hex_h3res", 1:10),
    default_zoom_breaks = h3t_zoom_breaks
  )
}

`%||%` <- function(a, b) if (is.null(a)) b else a
