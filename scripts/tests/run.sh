#!/usr/bin/env bash
#
# Tests for scripts/check.sh.
#
# These exercise the analysis + verdict + message-composition logic
# against synthetic Open-Meteo forecast JSON. No network, no notifications
# — we source check.sh and call the helpers directly.
#
# Usage:
#   bash scripts/tests/run.sh
#
# Exit code: 0 if every assertion passes, 1 on the first failure.

# Globals like LATITUDE / LAST_NOTIFIED_VERDICT below are read by the
# functions sourced from check.sh; shellcheck doesn't follow the source
# so it flags them as unused.
# shellcheck disable=SC2034

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../check.sh
source "$ROOT_DIR/scripts/check.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

# ── Test helpers ─────────────────────────────────────────────────────
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  ✓ %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  ✗ %s\n      expected: %q\n      actual:   %q\n' \
      "$label" "$expected" "$actual"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$label")
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  ✓ %s\n' "$label"
    PASS=$((PASS + 1))
  else
    printf '  ✗ %s\n      needle:   %q\n      haystack: %q\n' \
      "$label" "$needle" "$haystack"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$label")
  fi
}

# Build a forecast JSON fixture from a compact pattern string. Each
# character encodes one day starting at "today" (index 0):
#
#   D — dry, mild (10°C)
#   W — wet (rain, code 63), 2mm, 80% probability, mild
#   S — wet (snow, code 73), 2mm, 80% probability, cold (-3°C)
#   F — dry, freezing cold (min -10°C)
#
# Pattern length must be ≥ LOOKAHEAD_DAYS so analyze_forecast finds a
# full 7-day window.
make_forecast() {
  local pattern="$1"
  local times=() codes=() precip=() probs=() tmin=() tmax=()
  local i char today
  today=$(date -u +%Y-%m-%d)
  for (( i=0; i<${#pattern}; i++ )); do
    char="${pattern:i:1}"
    times+=("$(jq -rn --arg d "$today" --argjson o "$i" \
        '($d + "T00:00:00Z") | fromdateiso8601 + ($o * 86400) | gmtime | strftime("%Y-%m-%d")')")
    case "$char" in
      D) codes+=(1)  precip+=(0)   probs+=(5)  tmin+=(5)   tmax+=(15) ;;
      W) codes+=(63) precip+=(2)   probs+=(80) tmin+=(8)   tmax+=(14) ;;
      S) codes+=(73) precip+=(2)   probs+=(80) tmin+=(-5)  tmax+=(0)  ;;
      F) codes+=(1)  precip+=(0)   probs+=(5)  tmin+=(-10) tmax+=(-2) ;;
      *) echo "make_forecast: unknown pattern char '$char'" >&2; exit 2 ;;
    esac
  done
  jq -n \
    --argjson t   "$(printf '%s\n' "${times[@]}"  | jq -R . | jq -s .)" \
    --argjson c   "$(printf '%s\n' "${codes[@]}"  | jq -s .)" \
    --argjson p   "$(printf '%s\n' "${precip[@]}" | jq -s .)" \
    --argjson pr  "$(printf '%s\n' "${probs[@]}"  | jq -s .)" \
    --argjson tn  "$(printf '%s\n' "${tmin[@]}"   | jq -s .)" \
    --argjson tx  "$(printf '%s\n' "${tmax[@]}"   | jq -s .)" \
    '{
       utc_offset_seconds: 0,
       daily: {
         time: $t,
         weather_code: $c,
         precipitation_sum: $p,
         precipitation_probability_max: $pr,
         temperature_2m_min: $tn,
         temperature_2m_max: $tx
       }
     }'
}

# Run analyze_forecast + decide_verdict + compose_lead for a pattern
# and return "verdict|lead" so a single assert can cover the chain.
run_pattern() {
  local pattern="$1" forecast verdict lead category=""
  forecast=$(make_forecast "$pattern")
  analyze_forecast "$forecast"
  verdict=$(decide_verdict)
  case "$verdict" in
    no)    category=$(precipitation_category "$TOMORROW_CODE")   ;;
    maybe) category=$(precipitation_category "$FIRST_WET_CODE")  ;;
  esac
  lead=$(compose_lead "$verdict" "$category")
  printf '%s|%s' "$verdict" "$lead"
}

verdict_of() { printf '%s' "${1%%|*}"; }
lead_of()    { printf '%s' "${1#*|}";  }

# ── Tests: verdicts ─────────────────────────────────────────────────
echo ""
echo "## Verdict logic"

# Pattern: today=D (irrelevant; we look at days 1..N), then 6 days.
# Day 0 is today's data and analyze_forecast skips it; the first
# pattern char is "today" which maps to forecast index 0.

# All clear → good, with a strong "clear all week" lead.
result=$(run_pattern "DDDDDDD")
assert_eq "all-dry → good"            "good"  "$(verdict_of "$result")"
assert_contains "all-dry lead mentions full week" "Clear all week" "$(lead_of "$result")"

# 3 clear days, then rain at the end → still good (window is met).
result=$(run_pattern "DDDDWWW")
assert_eq "3 clear then rain → good"  "good"  "$(verdict_of "$result")"
assert_contains "3-clear lead is the simple form" "Three clear days" "$(lead_of "$result")"

# Today dry, tomorrow rain → no.
result=$(run_pattern "DWWDDDD")
assert_eq "rain tomorrow → no"        "no"    "$(verdict_of "$result")"
assert_contains "no lead names rain"  "Rain"  "$(lead_of "$result")"

# Tomorrow dry, but rain inside the 3-day window (day 2) → maybe.
result=$(run_pattern "DDWDDDD")
assert_eq "rain inside 3-day window → maybe" "maybe" "$(verdict_of "$result")"

# Rain on day 4 only — outside the window — verdict is still good.
result=$(run_pattern "DDDDWDD")
assert_eq "rain past 3-day window → good (not maybe)" \
  "good" "$(verdict_of "$result")"

# Snow tomorrow (and snow temps drag tomorrow's min to -5, but our
# threshold is -5; snow temp is exactly -5, not below, so no freeze).
result=$(run_pattern "DSDDDDD")
assert_eq "snow tomorrow → no"        "no"    "$(verdict_of "$result")"
assert_contains "no/snow lead names snow" "Snow" "$(lead_of "$result")"

# Freezing temps (-10°C overnight low) tomorrow → freeze trumps everything.
result=$(run_pattern "DFDDDDD")
assert_eq "freeze tomorrow → freeze"  "freeze" "$(verdict_of "$result")"
assert_contains "freeze lead names temp" "-10" "$(lead_of "$result")"

# Freeze trumps even rain.
result=$(run_pattern "DFWWWDD")
assert_eq "freeze + rain → freeze still wins" "freeze" "$(verdict_of "$result")"

# Custom MIN_WASH_TEMP_C disables the freeze warning.
result=$(MIN_WASH_TEMP_C=-50 run_pattern "DFDDDDD")
assert_eq "freeze with permissive threshold → good" \
  "good" "$(verdict_of "$result")"

# ── Tests: next clean window hint ───────────────────────────────────
echo ""
echo "## Next-clean-window hint"

# Rain tomorrow, dry rest of week → "no" with next-clear hint.
result=$(run_pattern "DWDDDDD")
assert_eq "rain tomorrow, dry after → no" "no" "$(verdict_of "$result")"
assert_contains "no lead surfaces next clean window" \
  "Next clean window" "$(lead_of "$result")"

# Long stretch of rain, then 2 dry days at the end.
result=$(run_pattern "DWWWWDD")
assert_eq "long rain → no" "no" "$(verdict_of "$result")"
assert_contains "no lead mentions multi-day clean window" \
  "(2 days)" "$(lead_of "$result")"

# Dry-wet-dry-then-clean — maybe verdict, with next-clean hint.
result=$(run_pattern "DDWDDDD")
assert_eq "dry-wet-clean → maybe" "maybe" "$(verdict_of "$result")"
assert_contains "maybe lead surfaces next clean window" \
  "Next clean window" "$(lead_of "$result")"

# ── Tests: clean streak counting ────────────────────────────────────
echo ""
echo "## Clean streak counting"

result=$(run_pattern "DDDDDDD")
analyze_forecast "$(make_forecast "DDDDDDD")"
assert_eq "clean streak (all dry, scan 6 days)" "6" "$CLEAN_STREAK"

analyze_forecast "$(make_forecast "DDDDWDD")"
assert_eq "clean streak stops at first wet day" "3" "$CLEAN_STREAK"

analyze_forecast "$(make_forecast "DWDDDDD")"
assert_eq "clean streak is 0 when day 1 is wet" "0" "$CLEAN_STREAK"

# ── Tests: precipitation categories ─────────────────────────────────
echo ""
echo "## Precipitation categories"

assert_eq "code 63 → rain"            "rain"          "$(precipitation_category 63)"
assert_eq "code 73 → snow"            "snow"          "$(precipitation_category 73)"
assert_eq "code 67 → freezing rain"   "freezing rain" "$(precipitation_category 67)"
assert_eq "code 95 → thunderstorms"   "thunderstorms" "$(precipitation_category 95)"
assert_eq "code 99 → hail"            "hail"          "$(precipitation_category 99)"
assert_eq "code 0  → precipitation"   "precipitation" "$(precipitation_category 0)"

# ── Tests: notification composition ─────────────────────────────────
echo ""
echo "## Notification composition"

analyze_forecast "$(make_forecast "DDDDDDD")"
LATITUDE=43.65 LONGITUDE=-79.38 LOCATION="Toronto"
compose_notification "good" "" "Toronto" "Tomorrow: ☀️ Clear"
assert_eq "good title" "☀️ Good day for a wash" "$TITLE"
assert_contains "good body has location" "📍 Toronto" "$BODY"
assert_contains "good body has forecast" "Tomorrow: ☀️ Clear" "$BODY"
assert_contains "click URL is google search" \
  "google.com/search?q=weather%20Toronto" "$CLICK_URL"

analyze_forecast "$(make_forecast "DWDDDDD")"
compose_notification "no" "rain" "Toronto" "Tomorrow: 🌧️ Rain"
assert_eq "no title" "🚫 Skip the wash" "$TITLE"
assert_contains "no body capitalises 'rain'" "Rain moving in" "$BODY"

analyze_forecast "$(make_forecast "DFDDDDD")"
compose_notification "freeze" "" "Toronto" "Tomorrow: ☀️ Clear"
assert_eq "freeze title" "🥶 Too cold for a wash" "$TITLE"
assert_contains "freeze body explains the risk" "freeze on the car" "$BODY"

# ── Tests: URL encoding ─────────────────────────────────────────────
echo ""
echo "## URL encoding"

assert_eq "encode space"    "Toronto%2C%20Ontario" "$(url_encode "Toronto, Ontario")"
assert_eq "encode plain"    "Brooklyn"             "$(url_encode "Brooklyn")"
assert_eq "encode coords"   "43.65%2C-79.38"       "$(url_encode "43.65,-79.38")"
assert_eq "encode preserves -._~" "a.b-c_d~e"      "$(url_encode "a.b-c_d~e")"

# ── Tests: should_notify ────────────────────────────────────────────
echo ""
echo "## should_notify dedup"

LAST_NOTIFIED_VERDICT="good"
should_notify "good" && r="notify" || r="silent"
assert_eq "good always notifies"        "notify" "$r"

LAST_NOTIFIED_VERDICT="no"
should_notify "no" && r="notify" || r="silent"
assert_eq "no when last=no → silent"    "silent" "$r"

LAST_NOTIFIED_VERDICT="no"
should_notify "maybe" && r="notify" || r="silent"
assert_eq "maybe when last=no → notify" "notify" "$r"

LAST_NOTIFIED_VERDICT=""
should_notify "freeze" && r="notify" || r="silent"
assert_eq "freeze first time → notify"  "notify" "$r"

LAST_NOTIFIED_VERDICT="freeze"
should_notify "freeze" && r="notify" || r="silent"
assert_eq "freeze when last=freeze → silent" "silent" "$r"

# ── Summary ─────────────────────────────────────────────────────────
echo ""
echo "──────────────────────────────────────"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
echo "──────────────────────────────────────"
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Failed:"
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
  exit 1
fi
