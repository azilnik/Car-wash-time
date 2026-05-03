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

# Globals like LAST_NOTIFIED_VERDICT below are read by the functions
# sourced from check.sh; shellcheck doesn't follow the source so it
# flags them as unused.
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
# Pattern length must be ≥ 4 so analyze_forecast finds a full
# (1 + WINDOW_DAYS) window starting at index 1.
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

# All dry → good. Lead is the simple form regardless of how far the
# clean stretch extends past the window — by design, since the
# notification's job is "wash or no", not a forecast widget.
result=$(run_pattern "DDDD")
assert_eq "all-dry → good"            "good"  "$(verdict_of "$result")"
assert_contains "good lead is the simple form" \
  "Three clear days ahead. Go for it." "$(lead_of "$result")"

# Today dry, tomorrow rain → no.
result=$(run_pattern "DWWD")
assert_eq "rain tomorrow → no"        "no"    "$(verdict_of "$result")"
assert_contains "no lead names rain"  "Rain"  "$(lead_of "$result")"
assert_contains "no lead is brief"    "wait it out." "$(lead_of "$result")"

# Tomorrow dry, but rain inside the 3-day window → maybe.
result=$(run_pattern "DDWD")
assert_eq "rain inside window → maybe" "maybe" "$(verdict_of "$result")"
assert_contains "maybe lead names rain" "rain" "$(lead_of "$result")"

# Snow tomorrow.
result=$(run_pattern "DSDD")
assert_eq "snow tomorrow → no"        "no"    "$(verdict_of "$result")"
assert_contains "no/snow lead names snow" "Snow" "$(lead_of "$result")"

# Freezing temps (-10°C overnight low) tomorrow → freeze trumps everything.
result=$(run_pattern "DFDD")
assert_eq "freeze tomorrow → freeze"  "freeze" "$(verdict_of "$result")"
assert_contains "freeze lead names temp" "-10°C" "$(lead_of "$result")"

# Freeze trumps even rain.
result=$(run_pattern "DFWW")
assert_eq "freeze + rain → freeze still wins" "freeze" "$(verdict_of "$result")"

# Custom MIN_WASH_TEMP_C disables the freeze warning.
result=$(MIN_WASH_TEMP_C=-50 run_pattern "DFDD")
assert_eq "freeze with permissive threshold → good" \
  "good" "$(verdict_of "$result")"

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

# Each composition test asserts the body is just the lead — no
# forecast list, no location line, no click URL. The verdict carries
# itself; everything else was noise.
analyze_forecast "$(make_forecast "DDDD")"
compose_notification "good" ""
assert_eq "good title"      "☀️ Good day for a wash" "$TITLE"
assert_eq "good body"       "Three clear days ahead. Go for it." "$BODY"
assert_eq "good tags"       "car,white_check_mark"   "$TAGS"

analyze_forecast "$(make_forecast "DWDD")"
compose_notification "no" "rain"
assert_eq "no title"        "🚫 Skip the wash" "$TITLE"
assert_eq "no body"         "Rain moving in tomorrow — wait it out." "$BODY"

analyze_forecast "$(make_forecast "DDWD")"
compose_notification "maybe" "rain"
assert_eq "maybe title"     "🤔 Maybe wash it" "$TITLE"
assert_eq "maybe body"      "Dry today, expect rain. Your call." "$BODY"

analyze_forecast "$(make_forecast "DFDD")"
compose_notification "freeze" ""
assert_eq "freeze title"    "🥶 Too cold for a wash" "$TITLE"
assert_eq "freeze body"     "Overnight low -10°C." "$BODY"

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
