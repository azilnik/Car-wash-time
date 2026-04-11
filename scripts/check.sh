#!/usr/bin/env bash
#
# Car Wash Time — daily forecast check & notification.
#
# Fetches a short-range forecast from Open-Meteo, decides whether it's a
# good day to wash the car, and sends a push notification via ntfy.sh.
#
# Normally invoked by .github/workflows/carwash-check.yml, but can also
# be run locally for testing with the same environment variables:
#
#     LATITUDE=43.7 LONGITUDE=-79.4 NTFY_TOPIC=my-topic bash scripts/check.sh
#
# Required env:
#   LATITUDE, LONGITUDE  — decimal coordinates
#   NTFY_TOPIC           — ntfy.sh topic (no URL prefix)
#
# Optional env (set by the workflow to distinguish custom config from
# the baked-in demo defaults — empty means "using the default"):
#   VARS_LAT, VARS_LON, VARS_TOPIC

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────
readonly OPEN_METEO_URL="https://api.open-meteo.com/v1/forecast"
readonly NTFY_URL="https://ntfy.sh"

# WMO weather codes that indicate any form of precipitation.
# See https://open-meteo.com/en/docs#weathervariables
readonly PRECIPITATION_CODES="51 53 55 56 57 61 63 65 66 67 71 73 75 77 80 81 82 85 86 95 96 99"

# How many days out from today we care about — tomorrow plus the next
# two days, so someone who washes today gets three clear days of payoff.
readonly WINDOW_DAYS=3

# ── Logging helpers ───────────────────────────────────────────────────
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die() { echo "::error::$*" >&2; exit 1; }

# ── Config validation ────────────────────────────────────────────────
# The workflow injects defaults via `${{ vars.X || 'default' }}`, so in
# CI these should always be set. We still check here so a misconfigured
# local run fails with a readable error instead of a broken curl later.
#
# VARS_LAT / VARS_LON / VARS_TOPIC are set to the raw repo-variable
# values (empty when the user hasn't configured them). We use them
# purely to log whether the active config is custom or the demo default.
require_config() {
  [ -n "${LATITUDE:-}"   ] || die "LATITUDE not set"
  [ -n "${LONGITUDE:-}"  ] || die "LONGITUDE not set"
  [ -n "${NTFY_TOPIC:-}" ] || die "NTFY_TOPIC not set"

  if [ -z "${VARS_LAT:-}" ] || [ -z "${VARS_LON:-}" ]; then
    log "Location: ${LATITUDE}, ${LONGITUDE} (demo default — set vars.LATITUDE / vars.LONGITUDE to customize)"
  else
    log "Location: ${LATITUDE}, ${LONGITUDE}"
  fi

  if [ -z "${VARS_TOPIC:-}" ]; then
    log "ntfy topic: ${NTFY_TOPIC} (demo default — set vars.NTFY_TOPIC for privacy)"
  else
    log "ntfy topic: ${NTFY_TOPIC}"
  fi
}

# ── Reverse geocoding ────────────────────────────────────────────────
# Best-effort city-name lookup for the notification title. Falls back
# to "Unknown" if Nominatim is unreachable or returns nothing useful —
# we never want a reverse-geocode blip to fail the whole run.
reverse_geocode() {
  local lat="$1" lon="$2"
  curl -sf \
    -H "User-Agent: CarWashTime/1.0" \
    "https://nominatim.openstreetmap.org/reverse?lat=${lat}&lon=${lon}&format=json&zoom=10" 2>/dev/null \
    | jq -r '.address.city // .address.town // .address.village // "Unknown"' \
    || echo "Unknown"
}

# ── Forecast fetching ────────────────────────────────────────────────
# Returns the raw Open-Meteo JSON on stdout. Exits hard on failure so
# the workflow log makes a broken forecast immediately obvious.
fetch_forecast() {
  local lat="$1" lon="$2"
  curl -sf \
    "${OPEN_METEO_URL}?latitude=${lat}&longitude=${lon}&daily=weather_code,precipitation_sum,precipitation_probability_max&timezone=auto&forecast_days=7" \
    || die "Failed to fetch forecast from Open-Meteo"
}

# ── Analysis ─────────────────────────────────────────────────────────
# Walks days 1..WINDOW_DAYS (tomorrow onwards) of the forecast and sets
# three globals for the rest of the script:
#
#   TOMORROW_WET      — bool, is day 1 wet?
#   ANY_WET           — bool, is any day in the window wet?
#   FORECAST_SUMMARY  — multi-line string, one line per day
#
# A day counts as "wet" if any of these are true:
#   - its WMO code is in PRECIPITATION_CODES
#   - precipitation_sum > 0 mm
#   - precipitation_probability_max > 30 %
analyze_forecast() {
  local forecast="$1"
  TOMORROW_WET=false
  ANY_WET=false
  FORECAST_SUMMARY=""

  local i date code precip prob precip_int is_wet status
  for i in $(seq 1 "$WINDOW_DAYS"); do
    date=$(echo   "$forecast" | jq -r ".daily.time[$i]")
    code=$(echo   "$forecast" | jq -r ".daily.weather_code[$i]")
    precip=$(echo "$forecast" | jq -r ".daily.precipitation_sum[$i]")
    prob=$(echo   "$forecast" | jq -r ".daily.precipitation_probability_max[$i]")

    is_wet=false
    if echo " $PRECIPITATION_CODES " | grep -q " $code "; then
      is_wet=true
    fi

    # precipitation_sum is a float; bash integer comparison needs the int part.
    precip_int=$(echo "$precip" | cut -d. -f1)
    if [ "${precip_int:-0}" -gt 0 ] || [ "${prob:-0}" -gt 30 ]; then
      is_wet=true
    fi

    if [ "$is_wet" = true ]; then
      ANY_WET=true
      [ "$i" = 1 ] && TOMORROW_WET=true
    fi

    status="Dry"
    [ "$is_wet" = true ] && status="Wet"

    FORECAST_SUMMARY+="${date}: code=${code} precip=${precip}mm prob=${prob}% [${status}]"$'\n'
    log "$date: code=$code precip=${precip}mm prob=${prob}% [$status]"
  done
}

# ── Verdict ──────────────────────────────────────────────────────────
# Three-tier verdict based on the globals set by analyze_forecast:
#   "no"    — skip, tomorrow is already wet
#   "maybe" — tomorrow is dry but rain is coming in the window
#   "good"  — the whole window is dry, go wash it
decide_verdict() {
  if [ "$TOMORROW_WET" = true ]; then
    echo "no"
  elif [ "$ANY_WET" = true ]; then
    echo "maybe"
  else
    echo "good"
  fi
}

# ── Message composition ──────────────────────────────────────────────
# Sets TITLE, BODY, TAGS globals. This is the legacy "techy" format —
# PR 2 rewrites it into a human-friendly shape with emoji and the
# location moved to the body.
compose_message() {
  local verdict="$1" location="$2" time_label="$3"
  case "$verdict" in
    no)
      TITLE="${location}: No wash ${time_label}"
      BODY="Precipitation expected tomorrow."
      TAGS="car,x"
      ;;
    maybe)
      TITLE="${location}: Maybe worth a wash ${time_label}"
      BODY="Possible rain or snow in 3 days."
      TAGS="car,thinking"
      ;;
    good)
      TITLE="${location}: Good day for a car wash ${time_label}!"
      BODY="No precipitation for 3 days."
      TAGS="car,white_check_mark"
      ;;
    *)
      die "Unknown verdict: $verdict"
      ;;
  esac
}

# ── Notifier ─────────────────────────────────────────────────────────
send_ntfy() {
  local title="$1" body="$2" tags="$3"
  curl -sf \
    -H "Title: ${title}" \
    -H "Tags: ${tags}" \
    -d "${body}" \
    "${NTFY_URL}/${NTFY_TOPIC}" \
    > /dev/null \
    || die "Failed to post to ntfy"
}

# ── Main ─────────────────────────────────────────────────────────────
main() {
  require_config

  local location forecast verdict hour_utc time_label full_body

  location=$(reverse_geocode "$LATITUDE" "$LONGITUDE")
  log "Resolved location: $location"

  log "Fetching forecast..."
  forecast=$(fetch_forecast "$LATITUDE" "$LONGITUDE")

  log "Analyzing forecast..."
  analyze_forecast "$forecast"

  verdict=$(decide_verdict)
  log "Verdict: $verdict"

  # "today" for the morning run, "tomorrow" for the evening run.
  # Morning fires at ~11 UTC (6am EST), evening at ~02:30 UTC (9:30pm EST).
  hour_utc=$(date -u +%H)
  if [ "$hour_utc" -ge 10 ]; then
    time_label="today"
  else
    time_label="tomorrow"
  fi

  compose_message "$verdict" "$location" "$time_label"

  # Append the per-day forecast summary to the notification body.
  full_body=$(printf '%s\n\n%s' "$BODY" "$FORECAST_SUMMARY")

  log "Sending notification: $TITLE"
  send_ntfy "$TITLE" "$full_body" "$TAGS"
  log "Notification sent."
}

main "$@"
