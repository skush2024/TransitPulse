#!/usr/bin/env bash
# =============================================================================
# TransitPulse Pipeline Orchestrator
# Manages Static GTFS, Realtime Ingestion, and dbt Transformations
#
# Cron schedule (add to crontab with: crontab -e):
#   # Realtime ingestion: every 2 minutes
#   */2 * * * * /Users/skush/CodeX/transitpulse/pipeline_scheduler.sh realtime >> /Users/skush/CodeX/transitpulse/logs/cron.log 2>&1
#
#   # dbt transformation run: every hour at :05 (after realtime has settled)
#   5 * * * * /Users/skush/CodeX/transitpulse/pipeline_scheduler.sh dbt >> /Users/skush/CodeX/transitpulse/logs/cron.log 2>&1
#
#   # Static GTFS refresh: every Sunday at 03:00 AM (GTFS schedules update weekly)
#   0 3 * * 0 /Users/skush/CodeX/transitpulse/pipeline_scheduler.sh static >> /Users/skush/CodeX/transitpulse/logs/cron.log 2>&1
#
#   # Full pipeline (static + dbt): same weekly cadence, 30 min after static
#   30 3 * * 0 /Users/skush/CodeX/transitpulse/pipeline_scheduler.sh full >> /Users/skush/CodeX/transitpulse/logs/cron.log 2>&1
# =============================================================================

set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────
REPO_DIR="/Users/skush/CodeX/transitpulse"
INGESTION_DIR="${REPO_DIR}/ingestion"
DBT_DIR="${REPO_DIR}/vta_transformations"
LOG_DIR="${REPO_DIR}/logs"
VENV_PYTHON="${REPO_DIR}/.venv/bin/python"
VENV_DBT="${REPO_DIR}/.venv/bin/dbt"

# ── Helpers ──────────────────────────────────────────────────────────────────
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [$MODE] $*"
}

fail() {
    log "❌ FATAL: $*"
    exit 1
}

check_dependencies() {
    [[ -x "${VENV_PYTHON}" ]] || fail "Python venv not found at ${VENV_PYTHON}. Run: python -m venv .venv && pip install -r ingestion/requirements.txt"
    [[ -x "${VENV_DBT}" ]]    || fail "dbt not found at ${VENV_DBT}. Run: pip install dbt-postgres"
    [[ -f "${REPO_DIR}/.env" ]] || fail ".env file missing. Create it from .env.example"
}

# ── Pipeline Stages ───────────────────────────────────────────────────────────

run_static() {
    log "🚌 Starting Static GTFS ingestion (load_vta_static.py)..."
    "${VENV_PYTHON}" "${INGESTION_DIR}/load_vta_static.py" \
        && log "✅ Static GTFS ingestion complete." \
        || fail "Static GTFS ingestion failed."
}

run_realtime() {
    log "📡 Starting Realtime GTFS ingestion (load_vta_realtime.py)..."
    "${VENV_PYTHON}" "${INGESTION_DIR}/load_vta_realtime.py" \
        && log "✅ Realtime ingestion complete." \
        || fail "Realtime ingestion failed."
}

run_dbt() {
    log "⚙️  Running dbt transformations..."
    cd "${DBT_DIR}"

    # Run with --no-version-check to keep logs clean in cron
    "${VENV_DBT}" run --no-version-check --profiles-dir "${DBT_DIR}" \
        && log "✅ dbt run complete." \
        || fail "dbt run failed."

    # Optional: run dbt tests after every transformation
    log "🧪 Running dbt data quality tests..."
    "${VENV_DBT}" test --no-version-check --profiles-dir "${DBT_DIR}" \
        && log "✅ dbt tests passed." \
        || log "⚠️  WARNING: dbt tests reported failures — check logs."

    cd "${REPO_DIR}"
}

# ── Mode Dispatch ─────────────────────────────────────────────────────────────
MODE="${1:-help}"
mkdir -p "${LOG_DIR}"

case "${MODE}" in
    realtime)
        check_dependencies
        run_realtime
        ;;
    static)
        check_dependencies
        run_static
        ;;
    dbt)
        check_dependencies
        run_dbt
        ;;
    full)
        # Full pipeline: static first, then dbt (used for weekly refresh)
        check_dependencies
        run_static
        run_dbt
        log "🚀 Full pipeline complete."
        ;;
    help|*)
        echo ""
        echo "TransitPulse Pipeline Orchestrator"
        echo "Usage: $0 [MODE]"
        echo ""
        echo "  realtime   - Fetch and ingest one GTFS-RT frame (run every 2 min)"
        echo "  static     - Download and reload full static GTFS network (run weekly)"
        echo "  dbt        - Run dbt transformations and tests (run hourly)"
        echo "  full       - Static + dbt in sequence (run weekly after static)"
        echo ""
        echo "See cron setup instructions at the top of this file."
        ;;
esac
