#!/usr/bin/env bash
# autopilot-stop-hook.sh — The autonomous loop engine.
# Registered as a Stop event hook. Reads stdin JSON, checks session state,
# and either allows exit (0) or blocks with a continuation prompt (exit 2).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source state management
# shellcheck source=../scripts/lib/state.sh
source "${PLUGIN_ROOT}/scripts/lib/state.sh"

# ---------------------------------------------------------------------------
# Read hook input from stdin
# ---------------------------------------------------------------------------
INPUT=""
if [[ ! -t 0 ]]; then
  INPUT="$(cat)"
fi

# Extract transcript_path if available (for promise scanning)
TRANSCRIPT_PATH=""
if [[ -n "$INPUT" ]]; then
  if _has_jq; then
    TRANSCRIPT_PATH="$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
  fi
fi

# ---------------------------------------------------------------------------
# Skip subagent Stop events — only the parent autopilot session drives the loop
# ---------------------------------------------------------------------------
# Stop hooks fire on every Stop event in the Claude Code process, including
# subagent (Task tool / TeamCreate) stops. Subagent transcripts often include
# the literal "<promise>" string (it's documented in skill files Read by agents),
# which would falsely trip the promise-scan below and end the session early.
IS_SUBAGENT=""
if [[ -n "$INPUT" ]] && _has_jq; then
  IS_SUBAGENT="$(echo "$INPUT" | jq -r '
    if .parent_session_id != null then "1"
    elif .agent_id != null then "1"
    elif .subagent_id != null then "1"
    elif (.transcript_path // "") | test("/subagents/") then "1"
    else ""
    end' 2>/dev/null || true)"
fi
if [[ -z "$IS_SUBAGENT" && -n "$TRANSCRIPT_PATH" ]]; then
  # Fallback: path-based check even without jq fields
  case "$TRANSCRIPT_PATH" in
    */subagents/*) IS_SUBAGENT="1" ;;
  esac
fi
if [[ -n "$IS_SUBAGENT" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Check for active session
# ---------------------------------------------------------------------------
SESSION_ID="$(get_active_session_id)"

if [[ -z "$SESSION_ID" ]]; then
  # No active autopilot session — allow normal exit
  exit 0
fi

SESSION_DIR="$(get_session_dir "$SESSION_ID")"
STATE_FILE="$(get_state_file "$SESSION_ID")"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "[autopilot] State file missing for session ${SESSION_ID}, allowing exit." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Read current state
# ---------------------------------------------------------------------------
PHASE="$(read_state_field "phase" "$SESSION_ID")"
ITERATION="$(read_state_field "iteration" "$SESSION_ID")"
MAX_ITERATIONS="$(read_state_field "max_iterations" "$SESSION_ID")"
FIX_ATTEMPTS="$(read_state_field "fix_attempts" "$SESSION_ID")"
MAX_FIX_ATTEMPTS="$(read_state_field "max_fix_attempts" "$SESSION_ID")"
REVIEW_ROUNDS="$(read_state_field "review_rounds" "$SESSION_ID")"
MAX_REVIEW_ROUNDS="$(read_state_field "max_review_rounds" "$SESSION_ID")"
TOTAL_FIX_ATTEMPTS="$(read_state_field "total_fix_attempts" "$SESSION_ID")"
MAX_TOTAL_FIXES="$(read_state_field "max_total_fixes" "$SESSION_ID")"

# Defaults
ITERATION="${ITERATION:-0}"
MAX_ITERATIONS="${MAX_ITERATIONS:-10}"
FIX_ATTEMPTS="${FIX_ATTEMPTS:-0}"
MAX_FIX_ATTEMPTS="${MAX_FIX_ATTEMPTS:-3}"
REVIEW_ROUNDS="${REVIEW_ROUNDS:-0}"
MAX_REVIEW_ROUNDS="${MAX_REVIEW_ROUNDS:-2}"
TOTAL_FIX_ATTEMPTS="${TOTAL_FIX_ATTEMPTS:-0}"
MAX_TOTAL_FIXES="${MAX_TOTAL_FIXES:-5}"

# ---------------------------------------------------------------------------
# Terminal phases — allow exit
# ---------------------------------------------------------------------------
case "$PHASE" in
  DONE|CANCELLED|SPEC)
    update_session_status "$SESSION_ID" "completed" "$PHASE" 2>/dev/null || true
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# Safety limit checks
# ---------------------------------------------------------------------------
if (( ITERATION >= MAX_ITERATIONS )); then
  echo "[autopilot] Max iterations (${MAX_ITERATIONS}) reached. Completing." >&2
  set_phase "DONE" "$SESSION_ID"
  update_session_status "$SESSION_ID" "completed" "DONE" 2>/dev/null || true
  exit 0
fi

if (( TOTAL_FIX_ATTEMPTS >= MAX_TOTAL_FIXES )); then
  echo "[autopilot] Total fix budget (${MAX_TOTAL_FIXES}) exhausted. Completing." >&2
  set_phase "DONE" "$SESSION_ID"
  update_session_status "$SESSION_ID" "completed" "DONE" 2>/dev/null || true
  exit 0
fi

# ---------------------------------------------------------------------------
# Promise tag scanning — only honored from REVIEW phase (DONE is a legitimate
# transition only from REVIEW). Restrict to the latest assistant text to avoid
# matching skill-file Reads that happen to quote "<promise>".
# ---------------------------------------------------------------------------
if [[ "$PHASE" == "REVIEW" && -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
  PROMISE_HIT=""
  if _has_jq; then
    PROMISE_HIT="$(tac "$TRANSCRIPT_PATH" 2>/dev/null | jq -rs '
      map(select(.type == "assistant"
                 and ((.isSidechain // false) == false)
                 and ((.message.content // []) | map(select(.type == "text")) | length > 0)))
      | (.[0].message.content // [])
      | map(select(.type == "text"))
      | (.[0].text // "")
      | select(test("<promise>"))
      | "1"' 2>/dev/null || true)"
  fi
  if [[ -n "$PROMISE_HIT" ]]; then
    echo "[autopilot] Promise tag found in REVIEW transcript. Marking DONE." >&2
    set_phase "DONE" "$SESSION_ID"
    update_session_status "$SESSION_ID" "completed" "DONE" 2>/dev/null || true
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Active phase — build continuation prompt and block exit
# ---------------------------------------------------------------------------
increment_iteration "$SESSION_ID"

# Phase-specific continuation messages
# All phases delegate to the phase-runner skill which has concrete orchestration recipes.
#
# AUTONOMOUS DISCIPLINE: Every continuation prompt includes explicit instructions to
# NOT stop, NOT ask the user, and NOT summarize/wait. Inspired by autoresearch's
# "NEVER STOP" pattern — the session runs until DONE or iteration limits hit.
PREAMBLE="You are in an AUTONOMOUS autopilot session. DO NOT ask the user if you should continue. DO NOT summarize what happened and wait for input. DO NOT output 'let me know if you want to continue' or similar. Execute the next phase IMMEDIATELY."

CONTINUATION=""
case "$PHASE" in
  EXPLORE)
    CONTINUATION="${PREAMBLE} Continue autopilot session ${SESSION_ID}. Session directory: ${SESSION_DIR}. Plugin root: ${PLUGIN_ROOT}. Current phase: EXPLORE. Invoke the phase-runner skill to execute the EXPLORE phase. After EXPLORE completes, transition to BUILD and execute it in the same turn."
    ;;
  BUILD)
    CONTINUATION="${PREAMBLE} Continue autopilot session ${SESSION_ID}. Session directory: ${SESSION_DIR}. Plugin root: ${PLUGIN_ROOT}. Current phase: BUILD (iteration ${ITERATION}/${MAX_ITERATIONS}). Invoke the phase-runner skill to execute the BUILD phase. After BUILD completes, transition to TEST and execute it in the same turn."
    ;;
  TEST)
    CONTINUATION="${PREAMBLE} Continue autopilot session ${SESSION_ID}. Session directory: ${SESSION_DIR}. Plugin root: ${PLUGIN_ROOT}. Current phase: TEST. Invoke the phase-runner skill to execute the TEST phase — runs quality gates (lint, typecheck, tests, custom checks), preferring scoped runs against affected files when the project's runner supports it. This runs directly in the main session — do NOT spawn agents for quality gates. After TEST, transition to the next phase (VALIDATE if verification_loop is true, otherwise COMMIT, or FIX on failure) and execute it in the same turn."
    ;;
  VALIDATE)
    CONTINUATION="${PREAMBLE} Continue autopilot session ${SESSION_ID}. Session directory: ${SESSION_DIR}. Plugin root: ${PLUGIN_ROOT}. Current phase: VALIDATE. Invoke the phase-runner skill to execute the VALIDATE phase — actually run the feature end-to-end in the environment. Spawn ONE general-purpose validator agent and write results to validate-results.md. If real bugs are found and validate_attempts < max_validate_attempts, transition to FIX with fix_source=validate (FIX returns to TEST, which will re-enter VALIDATE). If attempts are exhausted or only env-level skips occurred, transition to COMMIT — never deadlock."
    ;;
  FIX)
    CONTINUATION="${PREAMBLE} Continue autopilot session ${SESSION_ID}. Session directory: ${SESSION_DIR}. Plugin root: ${PLUGIN_ROOT}. Current phase: FIX (attempt $((FIX_ATTEMPTS + 1))/${MAX_FIX_ATTEMPTS}). Read fix_source from state.json — 'test' means quality-gate failures (read quality-gate-results.txt), 'validate' means runtime bugs (read validate-results.md Bugs Found). Invoke the phase-runner skill to execute the FIX phase. After FIX completes, transition to TEST and execute it in the same turn."
    ;;
  COMMIT)
    CONTINUATION="${PREAMBLE} Continue autopilot session ${SESSION_ID}. Session directory: ${SESSION_DIR}. Plugin root: ${PLUGIN_ROOT}. Current phase: COMMIT. Invoke the phase-runner skill to execute the COMMIT phase. This runs directly in the main session — stage, commit, push, create draft PR. After COMMIT, transition to REVIEW and execute it in the same turn."
    ;;
  REVIEW)
    CONTINUATION="${PREAMBLE} Continue autopilot session ${SESSION_ID}. Session directory: ${SESSION_DIR}. Plugin root: ${PLUGIN_ROOT}. Current phase: REVIEW (round $((REVIEW_ROUNDS + 1))/${MAX_REVIEW_ROUNDS}). Invoke the phase-runner skill to execute the REVIEW phase. After REVIEW, if approved transition to DONE. If changes requested, transition to BUILD and execute it in the same turn."
    ;;
  *)
    echo "[autopilot] Unknown phase: ${PHASE}. Allowing exit." >&2
    exit 0
    ;;
esac

update_session_status "$SESSION_ID" "active" "$PHASE" 2>/dev/null || true

# Output blocking response as JSON to stdout
if _has_jq; then
  jq -n \
    --arg decision "block" \
    --arg reason "Autopilot phase: ${PHASE}" \
    --arg msg "$CONTINUATION" \
    '{"decision": $decision, "reason": $reason, "updatedUserMessage": $msg}'
else
  # Manual JSON construction
  # Escape special chars in continuation message
  ESCAPED_CONTINUATION="$(printf '%s' "$CONTINUATION" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '{"decision":"block","reason":"Autopilot phase: %s","updatedUserMessage":"%s"}\n' \
    "$PHASE" "$ESCAPED_CONTINUATION"
fi

# Exit 2 to block the stop and continue the loop
exit 2
