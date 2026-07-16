#!/usr/bin/env bash
# pgrls PR gate — DB-free base<->head RLS regression + lint check.
#
# Builds an offline snapshot of the migrations directory at the PR base and at
# the PR head (via detached git worktrees — no database, no Docker), then runs
# `pgrls pr` (diff base->head + lint-on-head) as ONE gate. The step's exit code
# is pgrls's own, so the check fails exactly when a dangerous RLS regression or
# a >=threshold lint finding lands in the change.
#
# Inputs arrive via environment (set by action.yml, never interpolated into the
# script body — a value can't be parsed as part of a command):
#   PGRLS_MIGRATIONS    (required) migrations dir, repo-relative (e.g. supabase/migrations)
#   PGRLS_BASE_REF      (required) git ref/sha of the PR base
#   PGRLS_HEAD_REF      (optional) git ref/sha of the head; empty = the checked-out tree
#   PGRLS_FAIL_ON       (optional) diff gate: safe|breaking|requires-review|dangerous (pgrls default: dangerous)
#   PGRLS_LINT_FAIL_ON  (optional) lint gate: error|warning|info (pgrls default: warning)
#   PGRLS_CONFIG        (optional) path to pgrls.toml
#   PGRLS_SCHEMAS       (optional) comma-separated schemas (URL sources only)
#
# No `set -e`: the final `pgrls pr` exit code must be the script's exit code.
set -uo pipefail

REPORT="${RUNNER_TEMP:-/tmp}/pgrls-pr-report.md"
mkdir -p "$(dirname "$REPORT")" 2>/dev/null || true
: > "$REPORT"

emit_output() {
  # Surface the report path + verdict for the comment step, even on failure.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "report-file=${REPORT}"
      echo "verdict=${1}"
    } >> "$GITHUB_OUTPUT"
  fi
}

fail() {
  printf 'pgrls PR gate: %s\n' "$1" | tee -a "$REPORT" >&2
  emit_output "error"
  exit 2
}

[ -n "${PGRLS_MIGRATIONS:-}" ] || fail "no migrations directory (set the 'migrations' input)"
[ -n "${PGRLS_BASE_REF:-}" ]   || fail "no base ref (set 'base-ref', or run on a pull_request event)"

TMP="$(mktemp -d)"
WORKTREES=()
cleanup() {
  for w in "${WORKTREES[@]:-}"; do
    [ -n "$w" ] && git worktree remove --force "$w" >/dev/null 2>&1 || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- base snapshot: a detached worktree at the base rev ------------------------
git worktree add --detach --force "$TMP/base" "$PGRLS_BASE_REF" >/dev/null 2>&1 \
  || fail "cannot check out base '$PGRLS_BASE_REF' — is the full history fetched? (actions/checkout with fetch-depth: 0)"
WORKTREES+=("$TMP/base")
[ -d "$TMP/base/$PGRLS_MIGRATIONS" ] \
  || fail "migrations dir '$PGRLS_MIGRATIONS' does not exist at the base rev (a brand-new migrations tree diffs cleanly against an empty base — that is expected)"
pgrls snapshot --migrations "$TMP/base/$PGRLS_MIGRATIONS" -o "$TMP/base.json" 2>>"$REPORT" \
  || fail "could not build the base snapshot from '$PGRLS_MIGRATIONS'"

# --- head snapshot: a worktree at the head rev, else the checked-out tree ------
if [ -n "${PGRLS_HEAD_REF:-}" ]; then
  git worktree add --detach --force "$TMP/head" "$PGRLS_HEAD_REF" >/dev/null 2>&1 \
    || fail "cannot check out head '$PGRLS_HEAD_REF'"
  WORKTREES+=("$TMP/head")
  head_dir="$TMP/head/$PGRLS_MIGRATIONS"
else
  head_dir="./$PGRLS_MIGRATIONS"
fi
[ -d "$head_dir" ] || fail "migrations dir '$PGRLS_MIGRATIONS' does not exist at the head"
pgrls snapshot --migrations "$head_dir" -o "$TMP/head.json" 2>>"$REPORT" \
  || fail "could not build the head snapshot from '$PGRLS_MIGRATIONS'"

# --- the gate: `pgrls pr` diff(base->head) + lint(head), one verdict ----------
# Redirect to a file (no pipe) so `$?` is pgrls's own exit code.
args=(pr "$TMP/base.json" "$TMP/head.json" --format markdown)
[ -n "${PGRLS_FAIL_ON:-}" ]      && args+=(--fail-on "$PGRLS_FAIL_ON")
[ -n "${PGRLS_LINT_FAIL_ON:-}" ] && args+=(--lint-fail-on "$PGRLS_LINT_FAIL_ON")
[ -n "${PGRLS_CONFIG:-}" ]       && args+=(--config "$PGRLS_CONFIG")
[ -n "${PGRLS_SCHEMAS:-}" ]      && args+=(--schemas "$PGRLS_SCHEMAS")

echo "+ pgrls ${args[*]}"
pgrls "${args[@]}" > "$REPORT" 2>&1
code=$?
cat "$REPORT"   # echo the Markdown report into the job log
emit_output "$([ "$code" -eq 0 ] && echo pass || echo fail)"
exit "$code"
