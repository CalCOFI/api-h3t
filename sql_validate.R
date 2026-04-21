# thin R wrapper around sql_validate.py (sqlglot)
# call `validate_sql(sql)` → list(ok, reason, has_n, normalized)

suppressPackageStartupMessages(library(reticulate))

`%||%` <- function(a, b) if (is.null(a)) b else a

.h3t_py <- new.env(parent = emptyenv())

h3t_load_validator <- function(
  py_path = "",
  py_file = NULL
) {
  # honour either env var; SQLGLOT_PY wins if both are set
  if (!nzchar(py_path)) py_path <- Sys.getenv("SQLGLOT_PY", "")
  if (!nzchar(py_path)) py_path <- Sys.getenv("RETICULATE_PYTHON", "")
  # explicitly pin the interpreter BEFORE any reticulate::import() call — the
  # RETICULATE_PYTHON env var alone is not always respected inside Docker if
  # reticulate has already initialized a different interpreter. Use use_python()
  # with the exact path (not use_virtualenv) so there's no `python` vs `python3`
  # symlink mismatch warning when RETICULATE_PYTHON points at .../python3.
  if (nzchar(py_path) && file.exists(py_path)) {
    reticulate::use_python(py_path, required = TRUE)
  }
  # locate sql_validate.py relative to this R file when possible; otherwise cwd
  if (is.null(py_file)) {
    here_file <- tryCatch(sys.frame(1)$ofile, error = function(e) NULL)
    if (!is.null(here_file) && file.exists(here_file)) {
      py_file <- file.path(dirname(normalizePath(here_file)), "sql_validate.py")
    }
    if (is.null(py_file) || !file.exists(py_file)) {
      py_file <- file.path(getwd(), "sql_validate.py")
    }
    if (!file.exists(py_file)) {
      stop("cannot locate sql_validate.py (tried sys.frame ofile and cwd)")
    }
  }
  # fail fast if sqlglot is missing
  sqlglot <- reticulate::import("sqlglot", delay_load = FALSE)
  # import sql_validate as a proper Python module (preserves module globals
  # like MAX_SQL_BYTES, which py_run_file(local=TRUE) would hide from validate())
  mod_dir  <- dirname(py_file)
  mod_name <- tools::file_path_sans_ext(basename(py_file))
  mod <- reticulate::import_from_path(mod_name, path = mod_dir, convert = TRUE)
  .h3t_py$validate <- mod$validate
  .h3t_py$sqlglot_version <- reticulate::py_to_r(sqlglot$`__version__`)
  .h3t_py$loaded <- TRUE
  invisible(.h3t_py)
}

validate_sql <- function(sql) {
  if (!isTRUE(.h3t_py$loaded)) h3t_load_validator()
  stopifnot(is.character(sql), length(sql) == 1L, !is.na(sql))
  res <- tryCatch(
    .h3t_py$validate(sql),
    error = function(e) list(ok = FALSE, reason = paste("validator error:", conditionMessage(e)))
  )
  list(
    ok         = isTRUE(res$ok),
    reason     = if (is.null(res$reason)) NA_character_ else as.character(res$reason),
    has_n      = isTRUE(res$has_n),
    normalized = if (is.null(res$normalized)) NA_character_ else as.character(res$normalized)
  )
}
