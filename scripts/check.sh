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
#     LOCATION="Toronto, Ontario" NTFY_TOPIC=my-topic bash scripts/check.sh
#     # or the lower-level form:
#     LATITUDE=40.7128 LONGITUDE=-74.0060 NTFY_TOPIC=my-topic bash scripts/check.sh
#
# Required env:
#   NTFY_TOPIC           — ntfy.sh topic (no URL prefix)
#   plus one of:
#     LOCATION           — any human-readable place (preferred); geocoded once
#     LATITUDE+LONGITUDE — decimal coordinates (fallback for power users)
#
# Optional env:
#   MORNING_HOUR         — local hour for morning notification (default 6,
#                          decimals OK: 6.5 = 6:30 AM)
#   EVENING_HOUR         — local hour for evening notification (default 21.5
#                          for 9:30 PM)
#
# Local time is derived from Open-Meteo's response for your coordinates,
# so DST handles itself. The workflow fires every 30 minutes; out-of-
# window firings exit early without writing state, so only morning and
# evening firings produce commits and notifications.
#
# Internal env (set by the workflow to distinguish custom config from
# the baked-in demo defaults — empty means "using the default"):
#   VARS_LAT, VARS_LON, VARS_TOPIC

set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────
readonly OPEN_METEO_URL="https://api.open-meteo.com/v1/forecast"
readonly NTFY_URL="https://ntfy.sh"
readonly STATE_FILE="state.json"

# WMO weather codes that indicate any form of precipitation.
# See https://open-meteo.com/en/docs#weathervariables
readonly PRECIPITATION_CODES="51 53 55 56 57 61 63 65 66 67 71 73 75 77 80 81 82 85 86 95 96 99"

# How many days out from today we care about — tomorrow plus the next
# two days, so someone who washes today gets three clear days of payoff.
readonly WINDOW_DAYS=3

# ── Logging helpers ───────────────────────────────────────────────────
# Log to stderr so command substitution on functions below never
# accidentally captures log noise into its result.
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; }
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
  [ -n "${NTFY_TOPIC:-}" ] || die "NTFY_TOPIC not set"

  if [ -n "${LOCATION:-}" ]; then
    log "Location: ${LOCATION} (to be geocoded)"
  else
    [ -n "${LATITUDE:-}"  ] || die "Set LOCATION (easier) or LATITUDE+LONGITUDE"
    [ -n "${LONGITUDE:-}" ] || die "Set LOCATION (easier) or LATITUDE+LONGITUDE"

    if [ -z "${VARS_LAT:-}" ] || [ -z "${VARS_LON:-}" ]; then
      log "Location: ${LATITUDE}, ${LONGITUDE} (demo default — set vars.LOCATION for the easy path)"
    else
      log "Location: ${LATITUDE}, ${LONGITUDE}"
    fi
  fi

  if [ -z "${VARS_TOPIC:-}" ]; then
    log "ntfy topic: ${NTFY_TOPIC} (demo default — set vars.NTFY_TOPIC for privacy)"
  else
    log "ntfy topic: ${NTFY_TOPIC}"
  fi
}

# ── Forward geocoding ────────────────────────────────────────────────
# Turn a human-readable place (city, address, postal code) into decimal
# lat/lon via Nominatim. Caches the result in STATE_FILE keyed on the
# query string, so only the first run after LOCATION changes hits the
# geocoder — subsequent runs are free.
#
# On success, sets LATITUDE, LONGITUDE, GEOCODED_LOCATION.
# On failure, exits hard — sending a forecast for the wrong place is
# worse than breaking loudly.
resolve_location() {
  local query="$1"
  local cached_query cached_lat cached_lon cached_name

  if [ -f "$STATE_FILE" ]; then
    cached_query=$(jq -r '.location_query // ""' "$STATE_FILE" 2>/dev/null || echo "")
    cached_lat=$(jq -r   '.location_lat   // ""' "$STATE_FILE" 2>/dev/null || echo "")
    cached_lon=$(jq -r   '.location_lon   // ""' "$STATE_FILE" 2>/dev/null || echo "")
    cached_name=$(jq -r  '.location_name  // ""' "$STATE_FILE" 2>/dev/null || echo "")

    if [ "$cached_query" = "$query" ] && [ -n "$cached_lat" ] && [ -n "$cached_lon" ]; then
      log "Geocode cache hit: '$query' → $cached_lat, $cached_lon ($cached_name)"
      LATITUDE="$cached_lat"
      LONGITUDE="$cached_lon"
      GEOCODED_LOCATION="$cached_name"
      return 0
    fi
  fi

  log "Geocoding '$query' via Nominatim..."

  # Bare 5-digit inputs are ambiguous across countries (10001 is both
  # Manhattan and Tallinn, Estonia, and Nominatim's relevance ranking
  # picks Tallinn). Scope to the US — by far the most likely intent for
  # a bare 5-digit input. If the caller actually meant a non-US postal
  # code (e.g. a German PLZ), the country in the success log below makes
  # the mis-scope obvious on the very first run.
  local curl_args=(
    -sf -G
    -H "User-Agent: CarWashTime/1.0"
    --data-urlencode "q=${query}"
    --data-urlencode "format=json"
    --data-urlencode "limit=1"
    --data-urlencode "addressdetails=1"
  )
  if [[ "$query" =~ ^[0-9]{5}$ ]]; then
    log "'$query' looks like a US ZIP — scoping search to United States"
    curl_args+=( --data-urlencode "countrycodes=us" )
  fi

  local result
  result=$(curl "${curl_args[@]}" "https://nominatim.openstreetmap.org/search") \
    || die "Failed to reach Nominatim — check network or try again later"

  LATITUDE=$(echo  "$result" | jq -r '.[0].lat // ""')
  LONGITUDE=$(echo "$result" | jq -r '.[0].lon // ""')
  GEOCODED_LOCATION=$(echo "$result" | jq -r \
    '.[0].address.city // .[0].address.town // .[0].address.village // .[0].address.county // "Unknown"')
  local country
  country=$(echo "$result" | jq -r '.[0].address.country // "?"')

  [ -n "$LATITUDE" ] && [ -n "$LONGITUDE" ] \
    || die "Couldn't find '$query' — try something like 'Toronto, Ontario' or a postal code."

  log "Geocoded '$query' → $LATITUDE, $LONGITUDE ($GEOCODED_LOCATION, $country)"
}

# ── Reverse geocoding ────────────────────────────────────────────────
# Best-effort city-name lookup for the notification body when the user
# supplied raw lat/lon. Falls back to "Unknown" if Nominatim is
# unreachable or returns nothing useful — we never want a reverse-geocode
# blip to fail the whole run.
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

# ── Time-window check ────────────────────────────────────────────────
# GitHub Actions cron is UTC-only, but we want notifications at a
# *local* morning and evening hour. The workflow fires every 30 min; we
# use Open-Meteo's `utc_offset_seconds` (already in the forecast JSON)
# to convert that into local time and return 0 only on the firings that
# fall within 15 minutes of MORNING_HOUR or EVENING_HOUR. All other
# firings exit main() without touching state, so the state commit is
# skipped and the Actions tab stays quiet.
#
# The 15-minute window matches our 30-minute cron exactly: for any
# whole-or-half target hour (e.g. 6, 6.5, 21.5), only one cron firing
# falls within ±15 min, so we never double-notify. DST flips are
# automatic since the offset comes back fresh with every forecast.
should_run_now() {
  local utc_offset_seconds="$1"
  local morning_hour="${MORNING_HOUR:-6}"
  local evening_hour="${EVENING_HOUR:-21.5}"

  local now_utc local_epoch local_minute local_label
  now_utc=$(date -u +%s)
  local_epoch=$((now_utc + utc_offset_seconds))
  local_minute=$(( (local_epoch / 60) % 1440 ))
  [ "$local_minute" -lt 0 ] && local_minute=$((local_minute + 1440))
  local_label=$(printf '%02d:%02d' $((local_minute / 60)) $((local_minute % 60)))

  local target_hour target_min diff
  for target_hour in "$morning_hour" "$evening_hour"; do
    target_min=$(awk -v h="$target_hour" 'BEGIN { printf "%.0f", h * 60 }')
    diff=$(( local_minute - target_min ))
    diff=${diff#-}
    # Wrap-around: for targets near midnight, the shortest distance
    # might cross the 00:00 boundary.
    [ "$diff" -gt 720 ] && diff=$(( 1440 - diff ))
    if [ "$diff" -le 15 ]; then
      log "Local time ${local_label} matches target ${target_hour}h (diff ${diff}min)"
      return 0
    fi
  done

  log "Local time ${local_label} out of window (morning=${morning_hour}h, evening=${evening_hour}h) — skipping"
  return 1
}

# ── Weather code lookups ─────────────────────────────────────────────
# Short, human-readable English description for a WMO weather code.
weather_description() {
  case "$1" in
    0)        echo "Clear" ;;
    1)        echo "Mostly clear" ;;
    2)        echo "Partly cloudy" ;;
    3)        echo "Overcast" ;;
    45|48)    echo "Fog" ;;
    51|53|55) echo "Drizzle" ;;
    56|57)    echo "Freezing drizzle" ;;
    61)       echo "Light rain" ;;
    63)       echo "Rain" ;;
    65)       echo "Heavy rain" ;;
    66|67)    echo "Freezing rain" ;;
    71)       echo "Light snow" ;;
    73)       echo "Snow" ;;
    75)       echo "Heavy snow" ;;
    77)       echo "Snow grains" ;;
    80)       echo "Light showers" ;;
    81)       echo "Showers" ;;
    82)       echo "Heavy showers" ;;
    85|86)    echo "Snow showers" ;;
    95)       echo "Thunderstorm" ;;
    96|99)    echo "Thunderstorm with hail" ;;
    *)        echo "Unknown" ;;
  esac
}

# Single emoji for a WMO weather code, to give each forecast line a
# glanceable visual cue.
weather_emoji() {
  case "$1" in
    0|1)                  echo "☀️"  ;;
    2)                    echo "⛅"  ;;
    3)                    echo "☁️"  ;;
    45|48)                echo "🌫️" ;;
    51|53|55|61|63|80|81) echo "🌧️" ;;
    65|82)                echo "🌧️" ;;
    56|57|66|67)          echo "🧊"  ;;
    71|73|75|77|85|86)    echo "🌨️" ;;
    95|96|99)             echo "⛈️"  ;;
    *)                    echo "❓"  ;;
  esac
}

# Given a YYYY-MM-DD, return "Tomorrow" if it's tomorrow, "Today" if
# it's today, else a short day name like "Fri". Date arithmetic goes
# through jq (already a hard dep) so this works under both GNU date
# (CI) and BSD date (macOS dev machines).
day_label() {
  local target="$1"
  local today tomorrow
  today=$(date -u +%Y-%m-%d)
  tomorrow=$(jq -rn '(now + 86400) | gmtime | strftime("%Y-%m-%d")')

  if   [ "$target" = "$tomorrow" ]; then echo "Tomorrow"
  elif [ "$target" = "$today"    ]; then echo "Today"
  else jq -rn --arg d "$target" '($d + "T00:00:00Z") | fromdateiso8601 | gmtime | strftime("%a")'
  fi
}

# ── Analysis ─────────────────────────────────────────────────────────
# Walks days 1..WINDOW_DAYS (tomorrow onwards) of the forecast and sets
# two globals used by decide_verdict:
#
#   TOMORROW_WET — bool, is day 1 wet?
#   ANY_WET      — bool, is any day in the window wet?
#
# A day counts as "wet" if any of these are true:
#   - its WMO code is in PRECIPITATION_CODES
#   - precipitation_sum > 0 mm
#   - precipitation_probability_max > 30 %
analyze_forecast() {
  local forecast="$1"
  TOMORROW_WET=false
  ANY_WET=false

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

    status="dry"
    [ "$is_wet" = true ] && status="wet"
    log "$date: code=$code precip=${precip}mm prob=${prob}% ($status)"
  done
}

# Three-tier verdict from the globals set by analyze_forecast:
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
# Builds a human-readable 3-line forecast list from the forecast JSON.
# Each line uses the day label, a weather emoji, and a short English
# description. Precipitation probability is appended only when it's
# notable (>30%), to avoid "(5%)" noise on clear days.
compose_forecast_lines() {
  local forecast="$1"
  local lines="" i date code prob label desc emoji line
  for i in $(seq 1 "$WINDOW_DAYS"); do
    date=$(echo "$forecast" | jq -r ".daily.time[$i]")
    code=$(echo "$forecast" | jq -r ".daily.weather_code[$i]")
    prob=$(echo "$forecast" | jq -r ".daily.precipitation_probability_max[$i]")

    label=$(day_label "$date")
    desc=$(weather_description "$code")
    emoji=$(weather_emoji "$code")

    if [ "${prob:-0}" -gt 30 ]; then
      line=$(printf '%s: %s %s (%s%%)' "$label" "$emoji" "$desc" "$prob")
    else
      line=$(printf '%s: %s %s' "$label" "$emoji" "$desc")
    fi

    if [ -z "$lines" ]; then
      lines="$line"
    else
      lines=$(printf '%s\n%s' "$lines" "$line")
    fi
  done
  printf '%s' "$lines"
}

# Sets TITLE, BODY, TAGS globals with the human-friendly notification
# content. Title leads with a verdict emoji and stays short; body is
# a one-line reason, a "📍 location" line (omitted if unknown), a
# blank line, then the 3-day forecast list.
compose_notification() {
  local verdict="$1" location="$2" forecast_lines="$3" lead

  case "$verdict" in
    good)
      TITLE="☀️ Good day for a wash"
      lead="Three clear days ahead. Go for it."
      TAGS="car,white_check_mark"
      ;;
    maybe)
      TITLE="🤔 Maybe wash it"
      lead="Dry today, but rain is coming. Your call."
      TAGS="car,thinking"
      ;;
    no)
      TITLE="🚫 Skip the wash"
      lead="Rain moving in tomorrow — wait it out."
      TAGS="car,x"
      ;;
    *)
      die "Unknown verdict: $verdict"
      ;;
  esac

  if [ -n "$location" ] && [ "$location" != "Unknown" ]; then
    BODY=$(printf '%s\n📍 %s\n\n%s' "$lead" "$location" "$forecast_lines")
  else
    BODY=$(printf '%s\n\n%s' "$lead" "$forecast_lines")
  fi
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

# ── State ────────────────────────────────────────────────────────────
# Persistent state lives in state.json, committed back to main by the
# workflow after each run. We use it for two things:
#
#   1. Notification dedup — "only ping when the verdict changes" needs
#      to remember what we last notified about.
#   2. Repository activity — committing state.json twice a day is real,
#      legitimate repo activity, which keeps GitHub from auto-disabling
#      the scheduled workflow after 60 days of inactivity. (This is why
#      the old keepalive.yml is no longer needed.)

# Load last-run state from STATE_FILE. Missing or malformed file is
# treated as empty-state, which makes fresh forks work on first run.
load_state() {
  if [ -f "$STATE_FILE" ]; then
    LAST_VERDICT=$(jq -r          '.last_verdict          // ""' "$STATE_FILE" 2>/dev/null || echo "")
    LAST_NOTIFIED_VERDICT=$(jq -r '.last_notified_verdict // ""' "$STATE_FILE" 2>/dev/null || echo "")
    LAST_NOTIFIED_AT=$(jq -r      '.last_notified_at      // ""' "$STATE_FILE" 2>/dev/null || echo "")
  else
    LAST_VERDICT=""
    LAST_NOTIFIED_VERDICT=""
    LAST_NOTIFIED_AT=""
  fi
  log "Loaded state: last_verdict='${LAST_VERDICT}', last_notified='${LAST_NOTIFIED_VERDICT}'"
}

# Returns 0 (notify) or 1 (stay silent). Rule:
#   - always ping on "good" (actionable — go wash the car)
#   - otherwise only ping when the verdict differs from what we last
#     notified about, so repeated "no wash" days don't spam
should_notify() {
  local verdict="$1"
  if [ "$verdict" = "good" ]; then
    return 0
  fi
  if [ "$verdict" != "$LAST_NOTIFIED_VERDICT" ]; then
    return 0
  fi
  return 1
}

# Write the full state object back to STATE_FILE. The workflow commit
# step picks up the diff and pushes it to main.
save_state() {
  local verdict="$1" notified_verdict="$2" notified_at="$3" location="$4"
  local cache_query="${5:-}" cache_lat="${6:-}" cache_lon="${7:-}" cache_name="${8:-}"
  jq -n \
    --arg run "$(date -u +%FT%TZ)" \
    --arg v   "$verdict" \
    --arg nv  "$notified_verdict" \
    --arg na  "$notified_at" \
    --arg loc "$location" \
    --arg lq  "$cache_query" \
    --arg la  "$cache_lat" \
    --arg lo  "$cache_lon" \
    --arg ln  "$cache_name" \
    '{
       last_run_utc:          $run,
       last_verdict:          $v,
       last_notified_verdict: $nv,
       last_notified_at:      $na,
       location:              $loc,
       location_query:        $lq,
       location_lat:          $la,
       location_lon:          $lo,
       location_name:         $ln
     }' \
    > "$STATE_FILE"
}

# ── Main ─────────────────────────────────────────────────────────────
main() {
  require_config

  local location forecast verdict forecast_lines notified_verdict notified_at
  local cache_query="" cache_lat="" cache_lon="" cache_name=""

  if [ -n "${LOCATION:-}" ]; then
    GEOCODED_LOCATION=""
    resolve_location "$LOCATION"
    location="$GEOCODED_LOCATION"
    cache_query="$LOCATION"
    cache_lat="$LATITUDE"
    cache_lon="$LONGITUDE"
    cache_name="$GEOCODED_LOCATION"
  else
    location=$(reverse_geocode "$LATITUDE" "$LONGITUDE")
  fi
  log "Resolved location: $location"

  log "Fetching forecast..."
  forecast=$(fetch_forecast "$LATITUDE" "$LONGITUDE")

  local utc_offset
  utc_offset=$(echo "$forecast" | jq -r '.utc_offset_seconds // 0')
  if ! should_run_now "$utc_offset"; then
    exit 0
  fi

  log "Analyzing forecast..."
  analyze_forecast "$forecast"

  verdict=$(decide_verdict)
  log "Verdict: $verdict"

  load_state

  if should_notify "$verdict"; then
    forecast_lines=$(compose_forecast_lines "$forecast")
    compose_notification "$verdict" "$location" "$forecast_lines"
    log "Sending notification: $TITLE"
    send_ntfy "$TITLE" "$BODY" "$TAGS"
    log "Notification sent."
    notified_verdict="$verdict"
    notified_at=$(date -u +%FT%TZ)
  else
    log "No change (verdict=$verdict, last_notified=$LAST_NOTIFIED_VERDICT) — staying silent."
    notified_verdict="$LAST_NOTIFIED_VERDICT"
    notified_at="$LAST_NOTIFIED_AT"
  fi

  save_state "$verdict" "$notified_verdict" "$notified_at" "$location" \
             "$cache_query" "$cache_lat" "$cache_lon" "$cache_name"
  log "State written to $STATE_FILE"
}

main "$@"
