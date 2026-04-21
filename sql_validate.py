"""SELECT-only SQL validator for the h3t endpoint.

Validates a candidate user SQL string against a strict ruleset before the
server wraps and executes it against a read-only DuckDB connection.

Public entry point:
    validate(sql: str) -> dict with keys:
        ok           (bool)
        reason       (str, when ok is False)
        has_n        (bool, whether the SELECT projects a column aliased `n`)
        normalized   (str, the canonical SQL re-serialized by sqlglot)

Rules (reject → ok=False with a short reason):
  1. Non-empty utf-8, len <= MAX_SQL_BYTES.
  2. sqlglot parses to exactly one statement.
  3. Root statement is SELECT (optionally wrapped in WITH / WITH RECURSIVE).
  4. Final SELECT projects aliases `cell_id` and `value`; `n` optional.
  5. No denylisted functions (read_csv, attach, load_extension, ...).
  6. No schema qualifiers into external catalogs (postgres., sqlite_, ...).
  7. AST node count <= MAX_AST_NODES.
"""

from __future__ import annotations

import sqlglot
from sqlglot import exp

MAX_SQL_BYTES = 16 * 1024
MAX_AST_NODES = 2000

REQUIRED_PROJECTIONS = {"cell_id", "value"}
OPTIONAL_PROJECTIONS = {"n"}

DENY_FUNCTION_PREFIXES = (
    "read_csv", "read_parquet", "read_json", "read_blob",
    "copy_from_database", "copy_to_database",
    "load_extension", "install_extension",
    "pg_exec", "postgres_query", "postgres_scan",
    "mysql_query", "mysql_scan", "sqlite_scan",
    "duckdb_attach", "shell", "system", "set_variable",
    "set_session_variable", "httpfs_",
)
DENY_FUNCTION_NAMES = set(DENY_FUNCTION_PREFIXES) | {
    "attach", "detach", "use", "export", "import", "copy",
}

DENY_SCHEMA_PREFIXES = ("postgres.", "sqlite_", "pg_", "mysql.")


def _deny_kw_matches(name: str) -> bool:
    n = name.lower()
    if n in DENY_FUNCTION_NAMES:
        return True
    return any(n.startswith(p) for p in DENY_FUNCTION_PREFIXES)


def _count_nodes(tree) -> int:
    # dfs / walk is O(n); use tree.walk() which yields (node, parent, key)
    return sum(1 for _ in tree.walk())


def _final_select(tree):
    """Return the terminal SELECT expression.

    - Bare SELECT → returns tree.
    - WITH wrapping a SELECT → returns the wrapped SELECT.
    - UNION/INTERSECT/EXCEPT at the top level → returns the outermost Union;
      we validate its projections via union.selects[0] by convention.
    """
    if isinstance(tree, exp.Select):
        return tree
    if isinstance(tree, exp.Union):
        return tree
    if isinstance(tree, exp.With):
        inner = tree.this
        return _final_select(inner) if inner is not None else None
    # some sqlglot versions wrap SELECT with CTEs inside exp.Select.args["with"]
    return tree if isinstance(tree, (exp.Select, exp.Union)) else None


def _projection_aliases(select_expr) -> set[str]:
    """Return the lower-cased set of output column names for a SELECT/Union."""
    sel = select_expr
    if isinstance(sel, exp.Union):
        sel = sel.left  # union arms must agree on column names; validate left
    if not isinstance(sel, exp.Select):
        return set()
    out = set()
    for e in sel.expressions:
        # Alias: `<expr> AS foo` → exp.Alias(this=<expr>, alias=foo)
        if isinstance(e, exp.Alias):
            out.add(e.alias.lower())
            continue
        # Bare column ref like `cell_id`
        if isinstance(e, exp.Column):
            out.add(e.name.lower())
            continue
        # Star: not allowed (we need specific named outputs)
        if isinstance(e, exp.Star):
            return {"*"}
    return out


def validate(sql: str) -> dict:
    if not isinstance(sql, str) or not sql:
        return {"ok": False, "reason": "empty SQL"}
    b = sql.encode("utf-8", errors="strict") if isinstance(sql, str) else None
    if b is None:
        return {"ok": False, "reason": "SQL is not valid utf-8"}
    if len(b) > MAX_SQL_BYTES:
        return {"ok": False, "reason": f"SQL too large ({len(b)} > {MAX_SQL_BYTES})"}

    try:
        stmts = sqlglot.parse(sql, dialect="duckdb")
    except Exception as e:
        return {"ok": False, "reason": f"parse error: {e}"}

    stmts = [s for s in stmts if s is not None]
    if len(stmts) != 1:
        return {"ok": False, "reason": f"expected 1 statement, got {len(stmts)}"}

    tree = stmts[0]

    # Reject non-SELECT roots: CREATE, DROP, INSERT, UPDATE, DELETE, ATTACH,
    # COPY, EXPORT, CALL, PRAGMA, SET, BEGIN, COMMIT, LOAD, INSTALL, USE.
    if isinstance(tree, (exp.Select, exp.Union)):
        pass
    elif isinstance(tree, exp.With):
        if not isinstance(tree.this, (exp.Select, exp.Union)):
            return {"ok": False, "reason": "WITH must wrap a SELECT"}
    else:
        return {"ok": False, "reason": f"only SELECT is allowed (got {type(tree).__name__})"}

    # AST size cap
    n_nodes = _count_nodes(tree)
    if n_nodes > MAX_AST_NODES:
        return {"ok": False, "reason": f"AST too large ({n_nodes} > {MAX_AST_NODES})"}

    # Function denylist — scan every Func node (covers builtin + anonymous UDFs).
    # sqlglot types `read_csv(...)` as exp.ReadCSV (a Func subclass); its `.name`
    # attribute is the *argument* (filename), so use sql_name() for builtins and
    # `.name` only for exp.Anonymous (user-typed unknown function calls).
    for pair in tree.walk():
        expr = pair[0] if isinstance(pair, tuple) else pair
        if isinstance(expr, exp.Anonymous):
            fname = (getattr(expr, "name", "") or "").lower()
        elif isinstance(expr, exp.Func):
            # sql_name() → canonical "READ_CSV" / "READ_PARQUET" / etc.
            fname = (expr.sql_name() if hasattr(expr, "sql_name") else "").lower()
            if not fname:
                fname = type(expr).__name__.lower()
        else:
            continue
        if _deny_kw_matches(fname):
            return {"ok": False, "reason": f"function not allowed: {fname}"}

    # Schema / catalog denylist — inspect Table refs
    for t in tree.find_all(exp.Table):
        qualified = t.sql(dialect="duckdb").lower()
        for pfx in DENY_SCHEMA_PREFIXES:
            if qualified.startswith(pfx) or f".{pfx}" in qualified:
                return {"ok": False, "reason": f"schema not allowed: {qualified}"}

    # Required projections
    select_node = _final_select(tree.this if isinstance(tree, exp.With) else tree)
    if select_node is None:
        return {"ok": False, "reason": "could not locate final SELECT"}
    aliases = _projection_aliases(select_node)
    if "*" in aliases:
        return {"ok": False, "reason": "SELECT * not allowed; project cell_id, value[, n]"}
    missing = REQUIRED_PROJECTIONS - aliases
    if missing:
        return {"ok": False,
                "reason": f"missing required output columns: {sorted(missing)}"}
    extra = aliases - (REQUIRED_PROJECTIONS | OPTIONAL_PROJECTIONS)
    if extra:
        return {"ok": False,
                "reason": f"unexpected output columns: {sorted(extra)}"}
    has_n = "n" in aliases

    normalized = tree.sql(dialect="duckdb")
    return {"ok": True, "reason": None, "has_n": has_n, "normalized": normalized}
