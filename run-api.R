#!/usr/bin/env Rscript
# launcher for h3t tile API
# env vars:
#   DUCKDB_PATH  — path to read-only DuckDB file (required)
#   H3T_PORT     — port (default 8889)
#   H3T_HOST     — bind host (default 0.0.0.0)
#   SQLGLOT_PY   — optional path to a python with sqlglot

suppressPackageStartupMessages({
  library(plumber)
})

# locate plumber.R next to this script — resilient to cwd changes
script_path <- local({
  args <- commandArgs(trailingOnly = FALSE)
  file_flag <- "--file="
  m <- regmatches(args, regexpr(paste0(file_flag, ".+"), args))
  if (length(m) == 1L) sub(file_flag, "", m, fixed = TRUE) else "run-api.R"
})
api_dir <- dirname(normalizePath(script_path))
plumber_r <- file.path(api_dir, "plumber.R")

port <- as.integer(Sys.getenv("H3T_PORT", "8889"))
host <- Sys.getenv("H3T_HOST", "0.0.0.0")

pr(plumber_r) |>
  pr_run(port = port, host = host, docs = TRUE)
