# helpers: tile bbox, zoom → H3 resolution, SQL wrappers for tile / stats
# all functions here are pure — no DB access — so they are easy to unit-test

# --- zoom / resolution ----------------------------------------------------

# mirrors int-app/app/global.R:175-181; keep in sync
h3t_zoom_breaks <- local({
  min_res <- 1L; max_res <- 10L
  b <- seq(1, 13, length.out = (max_res - min_res + 1) + 1)
  b[1] <- 0
  b[length(b)] <- 22
  b
})

zoom_to_res <- function(z) {
  # findInterval returns 1..length(breaks)-1 for z in [breaks[i], breaks[i+1]);
  # values beyond are clamped to the end bin.
  i <- findInterval(z, h3t_zoom_breaks, rightmost.closed = TRUE, all.inside = TRUE)
  as.integer(pmax(1L, pmin(10L, i)))
}

# --- H3 cell geometry ----------------------------------------------------

# Average H3 cell edge length (in degrees), computed from the H3 recursion:
# each resolution shrinks edge length by 1/sqrt(7). res 0 edge ≈ 1106.54 km;
# 1 deg ≈ 111.32 km at the equator. Used to buffer the tile bbox so cells
# whose centroids fall just outside the tile — but whose geometry straddles
# it — are still returned; otherwise geojson-vt clips the partial hex out
# of the neighbour and you see seams at tile boundaries.
h3_edge_length_deg <- function(r) {
  1106.54 / (sqrt(7))^as.integer(r) / 111.32
}

# --- tile bbox ------------------------------------------------------------

tile_bbox <- function(z, x, y) {
  # Web Mercator XYZ → lon/lat bbox. y=0 is the north edge.
  stopifnot(is.numeric(z), is.numeric(x), is.numeric(y))
  z <- as.integer(z); x <- as.integer(x); y <- as.integer(y)
  n <- 2^z
  stopifnot(x >= 0, x < n, y >= 0, y < n)
  lon_min <- x / n * 360 - 180
  lon_max <- (x + 1) / n * 360 - 180
  lat_max <- atan(sinh(pi * (1 - 2 * y / n))) * 180 / pi
  lat_min <- atan(sinh(pi * (1 - 2 * (y + 1) / n))) * 180 / pi
  list(
    lon_min = lon_min, lon_max = lon_max,
    lat_min = lat_min, lat_max = lat_max
  )
}

# --- SQL wrapping --------------------------------------------------------

# wrap a validated user SELECT as an inner subquery, then project h3id (hex
# string) and value (+ optional n), with a bbox filter on the cell centroid and
# a row cap. `has_n` decides whether the inner query emits `n` or we fill NULL.
wrap_tile_sql <- function(user_sql, bbox, has_n = FALSE,
                          max_rows = 50000L,
                          buffer_deg = 0) {
  # contract: user_q.cell_id must be BIGINT (i.e. the `hex_h3resN` column
  # or anything castable to BIGINT). If the user starts with a hex string
  # they should wrap it: `h3_string_to_h3(x) AS cell_id`.
  stopifnot(is.character(user_sql), length(user_sql) == 1L)
  lm <- bbox$lon_min - buffer_deg; lM <- bbox$lon_max + buffer_deg
  aM <- bbox$lat_max + buffer_deg; am <- bbox$lat_min - buffer_deg
  n_select <- if (isTRUE(has_n)) "TRY_CAST(n AS BIGINT) AS n" else "NULL::BIGINT AS n"
  sprintf(
    "WITH user_q AS (\n%s\n),\ncells AS (\n  SELECT\n    CAST(cell_id AS BIGINT)                 AS _cell,\n    value::DOUBLE                           AS value,\n    %s\n  FROM user_q\n  WHERE value IS NOT NULL\n    AND NOT isnan(value::DOUBLE)\n    AND isfinite(value::DOUBLE)\n)\nSELECT\n  h3_h3_to_string(_cell) AS h3id,\n  value,\n  n\nFROM cells\nWHERE h3_cell_to_lng(_cell) BETWEEN %.10f AND %.10f\n  AND h3_cell_to_lat(_cell) BETWEEN %.10f AND %.10f\nLIMIT %d",
    user_sql, n_select, lm, lM, am, aM, as.integer(max_rows)
  )
}

wrap_stats_sql <- function(user_sql) {
  stopifnot(is.character(user_sql), length(user_sql) == 1L)
  sprintf(
    "WITH user_q AS (\n%s\n)\nSELECT\n  MIN(value::DOUBLE)                           AS min,\n  MAX(value::DOUBLE)                           AS max,\n  approx_quantile(value::DOUBLE, 0.02)         AS p02,\n  approx_quantile(value::DOUBLE, 0.98)         AS p98,\n  COUNT(*)                                     AS n\nFROM user_q\nWHERE value IS NOT NULL\n  AND NOT isnan(value::DOUBLE)\n  AND isfinite(value::DOUBLE)",
    user_sql
  )
}
