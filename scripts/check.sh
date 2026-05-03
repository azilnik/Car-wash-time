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
#   MIN_WASH_TEMP_C      — temperature (°C) below which the script warns
#                          that a wash will freeze on the car. Compared
#                          against today's overnight low (= tomorrow's
#                          minimum). Default -5. Set to a very negative
#                          number (e.g. -100) to disable the warning
#                          entirely.
#
# Local time is derived from Open-Meteo's response for your coordinates,
# so DST handles itself. The workflow fires every 30 minutes; each
# local day has a morning and an evening slot, and the script records
# in state.json which slot-dates it has already handled. That makes
# the notification robust to GitHub Actions cron drift — if the
# nominally-6:00 firing is delayed past an old narrow window, whichever
# firing actually lands inside the slot still notifies for the day.
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

# How many forecast days to fetch and scan. We use the first WINDOW_DAYS
# to decide the verdict, and the remaining LOOKAHEAD_DAYS - WINDOW_DAYS
# to find the next clean stretch when telling the user "skip today,
# Friday looks better". Open-Meteo gives 7 days for free.
readonly LOOKAHEAD_DAYS=7

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
  local fields="weather_code,precipitation_sum,precipitation_probability_max,temperature_2m_min,temperature_2m_max"
  curl -sf \
    "${OPEN_METEO_URL}?latitude=${lat}&longitude=${lon}&daily=${fields}&timezone=auto&forecast_days=${LOOKAHEAD_DAYS}" \
    || die "Failed to fetch forecast from Open-Meteo"
}

# ── Time-window check ────────────────────────────────────────────────
# GitHub Actions cron is UTC-only, but we want notifications at a
# *local* morning and evening hour. The workflow fires every 30 min; we
# use Open-Meteo's `utc_offset_seconds` (already in the forecast JSON)
# to convert that into local time.
#
# Each local day has two slots:
#   morning slot = [MORNING_HOUR, EVENING_HOUR)
#   evening slot = [EVENING_HOUR, next day's MORNING_HOUR)
#
# A firing proceeds iff the current local time is inside a slot whose
# date has not yet been recorded in state. state.json then remembers
# which local date we last handled for each slot, so subsequent firings
# inside the same slot exit early.
#
# This is robust to GitHub Actions cron drift: even when the 6:00
# firing is delayed to 6:16 (past the old ±15 min window), the next
# firing that lands anywhere inside the slot still catches the day.
# DST is handled automatically because the offset comes back fresh
# with every forecast.
#
# Sets SLOT ("morning" | "evening" | "") and SLOT_DATE (the local date
# the slot belongs to) when returning 0, so main() can record the slot
# as handled after the run. FORCE_RUN leaves both empty so test runs
# don't suppress the next real firing.
should_run_now() {
  local utc_offset_seconds="$1"
  local morning_hour="${MORNING_HOUR:-6}"
  local evening_hour="${EVENING_HOUR:-21.5}"

  SLOT=""
  SLOT_DATE=""

  if [ "${FORCE_RUN:-false}" = "true" ]; then
    log "FORCE_RUN=true — skipping slot check"
    return 0
  fi

  local now_utc local_epoch local_minute local_label local_date prev_date
  now_utc=$(date -u +%s)
  local_epoch=$((now_utc + utc_offset_seconds))
  local_minute=$(( (local_epoch / 60) % 1440 ))
  local_label=$(printf '%02d:%02d' $((local_minute / 60)) $((local_minute % 60)))
  local_date=$(jq -rn --argjson e "$local_epoch" '$e | gmtime | strftime("%Y-%m-%d")')
  prev_date=$(jq -rn --argjson e "$local_epoch" '($e - 86400) | gmtime | strftime("%Y-%m-%d")')

  local morning_min evening_min
  morning_min=$(awk -v h="$morning_hour" 'BEGIN { printf "%.0f", h * 60 }')
  evening_min=$(awk -v h="$evening_hour" 'BEGIN { printf "%.0f", h * 60 }')

  local slot slot_date last_slot_date
  if [ "$local_minute" -ge "$morning_min" ] && [ "$local_minute" -lt "$evening_min" ]; then
    slot="morning"
    slot_date="$local_date"
    last_slot_date="$LAST_MORNING_SLOT_DATE"
  else
    slot="evening"
    # Pre-dawn hours (before morning_hour) still belong to yesterday's
    # evening slot, so subtract a day in that case.
    if [ "$local_minute" -ge "$evening_min" ]; then
      slot_date="$local_date"
    else
      slot_date="$prev_date"
    fi
    last_slot_date="$LAST_EVENING_SLOT_DATE"
  fi

  if [ "$slot_date" != "$last_slot_date" ]; then
    log "Local time ${local_label} — ${slot} slot for ${slot_date} not yet handled (last: '${last_slot_date:-none}')"
    SLOT="$slot"
    SLOT_DATE="$slot_date"
    return 0
  fi

  log "Local time ${local_label} — ${slot} slot for ${slot_date} already handled; skipping"
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

# Bucket a WMO weather code into a short noun phrase for use inside a
# notification sentence ("rain moving in tomorrow", "expect snow"). We
# collapse the 20-odd wet codes into the handful of buckets a driver
# actually cares about: drizzle and showers are just "rain", everything
# frozen-and-liquid is "freezing rain", thunderstorms-with-hail surface
# as "hail" because hail is the real concern for a freshly washed car.
# Dry codes (and anything unrecognized) fall through to the generic
# "precipitation" fallback, which is what analyze_forecast may mark as
# wet purely from precipitation_sum / probability.
precipitation_category() {
  case "$1" in
    51|53|55|61|63|65|80|81|82) echo "rain" ;;
    56|57|66|67)                echo "freezing rain" ;;
    71|73|75|77|85|86)          echo "snow" ;;
    95)                         echo "thunderstorms" ;;
    96|99)                      echo "hail" ;;
    *)                          echo "precipitation" ;;
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
    51|53|55|61|63|65|80|81|82) echo "🌧️" ;;
    56|57|66|67)                echo "🧊"  ;;
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

# Returns 0 if the day at index $1 in $forecast is "wet", non-zero
# otherwise. Wet means any of:
#   - WMO code in PRECIPITATION_CODES
#   - precipitation_sum > 0 mm
#   - precipitation_probability_max > 30 %
day_is_wet() {
  local forecast="$1" i="$2" code precip prob precip_int
  code=$(echo   "$forecast" | jq -r ".daily.weather_code[$i]")
  precip=$(echo "$forecast" | jq -r ".daily.precipitation_sum[$i]")
  prob=$(echo   "$forecast" | jq -r ".daily.precipitation_probability_max[$i]")

  if [[ " $PRECIPITATION_CODES " == *" $code "* ]]; then
    return 0
  fi
  precip_int="${precip%%.*}"
  if [ "${precip_int:-0}" -gt 0 ] || [ "${prob:-0}" -gt 30 ]; then
    return 0
  fi
  return 1
}

# ── Analysis ─────────────────────────────────────────────────────────
# Walks days 1..WINDOW_DAYS (tomorrow onwards) of the forecast for the
# verdict, then days 1..LOOKAHEAD_DAYS-1 to surface a "next clean
# window" hint when the verdict is no/maybe and a "clean stretch"
# count when the verdict is good.
#
# Sets globals used by decide_verdict and compose_notification:
#
#   TOMORROW_WET     — bool, is day 1 wet?
#   ANY_WET          — bool, is any day in the WINDOW_DAYS window wet?
#   TOMORROW_CODE    — WMO code for tomorrow (empty when dry)
#   FIRST_WET_CODE   — WMO code for the first wet day in the window,
#                      used to describe what's coming on a "maybe" day
#   CLEAN_STREAK     — count of consecutive dry days starting at day 1
#                      (capped at LOOKAHEAD_DAYS-1)
#   NEXT_CLEAN_DATE  — first date (YYYY-MM-DD) of a dry day after the
#                      WINDOW_DAYS window (empty if none in lookahead)
#   NEXT_CLEAN_RUN   — length of that next clean stretch
#   FREEZE_WARN      — bool, is the overnight low (= tomorrow's min)
#                      below MIN_WASH_TEMP_C? Set so callers can warn
#                      that a fresh wash will freeze on the car.
#   FREEZE_TEMP      — the actual temperature triggering the warning
analyze_forecast() {
  local forecast="$1"
  local min_wash_temp="${MIN_WASH_TEMP_C:--5}"

  TOMORROW_WET=false
  ANY_WET=false
  TOMORROW_CODE=""
  FIRST_WET_CODE=""
  CLEAN_STREAK=0
  NEXT_CLEAN_DATE=""
  NEXT_CLEAN_RUN=0
  FREEZE_WARN=false
  FREEZE_TEMP=""

  local available
  available=$(echo "$forecast" | jq -r '.daily.time | length')

  # Loop state:
  #   saw_wet              — true once we've passed any wet day; gates
  #                          both CLEAN_STREAK (must stop counting) and
  #                          NEXT_CLEAN_DATE (must come after a wet day).
  #   saw_clean_after_wet  — true once we've recorded NEXT_CLEAN_DATE;
  #                          when the next wet day arrives, that ends
  #                          the run and we exit the loop.
  local i date code precip prob status
  local saw_wet=false saw_clean_after_wet=false
  for i in $(seq 1 "$((available - 1))"); do
    date=$(echo   "$forecast" | jq -r ".daily.time[$i]")
    code=$(echo   "$forecast" | jq -r ".daily.weather_code[$i]")
    precip=$(echo "$forecast" | jq -r ".daily.precipitation_sum[$i]")
    prob=$(echo   "$forecast" | jq -r ".daily.precipitation_probability_max[$i]")

    local is_wet=false
    if day_is_wet "$forecast" "$i"; then
      is_wet=true
    fi

    if [ "$is_wet" = true ]; then
      if [ "$saw_clean_after_wet" = true ]; then
        # We already found the next clean window; this wet day ends it.
        break
      fi
      saw_wet=true
      if [ "$i" -le "$WINDOW_DAYS" ]; then
        ANY_WET=true
        [ -z "$FIRST_WET_CODE" ] && FIRST_WET_CODE="$code"
        if [ "$i" = 1 ]; then
          TOMORROW_WET=true
          TOMORROW_CODE="$code"
        fi
      fi
    else
      if [ "$saw_wet" = false ]; then
        # Day 1 onward, uninterrupted dry streak.
        CLEAN_STREAK=$((CLEAN_STREAK + 1))
      else
        # First dry day after a wet break — that's the next clean window.
        if [ "$saw_clean_after_wet" = false ]; then
          NEXT_CLEAN_DATE="$date"
          saw_clean_after_wet=true
        fi
        NEXT_CLEAN_RUN=$((NEXT_CLEAN_RUN + 1))
      fi
    fi

    status="dry"
    [ "$is_wet" = true ] && status="wet"
    if [ "$i" -le "$WINDOW_DAYS" ]; then
      log "$date: code=$code precip=${precip}mm prob=${prob}% ($status)"
    fi
  done

  # Freeze check: tomorrow's overnight low (which is when a fresh wash
  # would freeze on the car) versus the user's threshold. Open-Meteo
  # returns floats; awk handles the comparison so we don't have to
  # reach for bc.
  local tomorrow_min
  tomorrow_min=$(echo "$forecast" | jq -r '.daily.temperature_2m_min[1] // empty')
  if [ -n "$tomorrow_min" ] && [ "$tomorrow_min" != "null" ]; then
    if awk -v t="$tomorrow_min" -v th="$min_wash_temp" \
        'BEGIN { exit !(t < th) }'; then
      FREEZE_WARN=true
      FREEZE_TEMP="$tomorrow_min"
      log "Tomorrow's low is ${tomorrow_min}°C (threshold ${min_wash_temp}°C) — freeze warning"
    fi
  fi
}

# Four-tier verdict from the globals set by analyze_forecast:
#   "freeze" — overnight low below MIN_WASH_TEMP_C; the wash itself
#              will freeze on the car. Trumps the precipitation
#              verdict because a frozen-shut door beats a clean car.
#   "no"     — skip, tomorrow is already wet
#   "maybe"  — tomorrow is dry but rain is coming in the window
#   "good"   — the whole window is dry, go wash it
decide_verdict() {
  if [ "$FREEZE_WARN" = true ]; then
    echo "freeze"
  elif [ "$TOMORROW_WET" = true ]; then
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

# Compose the lead sentence(s) for each verdict, mixing in the
# extended-forecast hints from analyze_forecast (clean streak, next
# clean window) so the user actually learns when to wash next instead
# of just "skip it".
#
# `category` names the type of precipitation driving the verdict (one of
# "rain", "snow", "freezing rain", "thunderstorms", "hail",
# "precipitation"). Ignored for "good" and "freeze".
compose_lead() {
  local verdict="$1" category="$2"
  local next_hint=""
  if [ -n "$NEXT_CLEAN_DATE" ]; then
    local next_label
    next_label=$(day_label "$NEXT_CLEAN_DATE")
    if [ "$NEXT_CLEAN_RUN" -ge 2 ]; then
      next_hint=$(printf 'Next clean window: %s onward (%d days).' \
        "$next_label" "$NEXT_CLEAN_RUN")
    else
      next_hint=$(printf 'Next clear day: %s.' "$next_label")
    fi
  fi

  case "$verdict" in
    good)
      if [ "$CLEAN_STREAK" -ge "$LOOKAHEAD_DAYS" ] || \
         [ "$CLEAN_STREAK" -ge $((LOOKAHEAD_DAYS - 1)) ]; then
        printf 'Clear all week. Go for it.'
      elif [ "$CLEAN_STREAK" -ge 5 ]; then
        printf 'Clean stretch: %d days ahead. Go for it.' "$CLEAN_STREAK"
      elif [ "$CLEAN_STREAK" -ge 4 ]; then
        printf '%d clear days ahead. Go for it.' "$CLEAN_STREAK"
      else
        printf 'Three clear days ahead. Go for it.'
      fi
      ;;
    maybe)
      local base
      base=$(printf 'Dry today, expect %s. Your call.' "$category")
      if [ -n "$next_hint" ]; then
        printf '%s %s' "$base" "$next_hint"
      else
        printf '%s' "$base"
      fi
      ;;
    no)
      local base
      base=$(printf '%s moving in tomorrow — wait it out.' "${category^}")
      if [ -n "$next_hint" ]; then
        printf '%s %s' "$base" "$next_hint"
      else
        printf '%s' "$base"
      fi
      ;;
    freeze)
      local temp_int="${FREEZE_TEMP%%.*}"
      printf 'Overnight low %s°C — a wash will freeze on the car. Wait for a warmer day.' \
        "$temp_int"
      ;;
  esac
}

# Sets TITLE, BODY, TAGS, CLICK_URL globals with the human-friendly
# notification content. Title leads with a verdict emoji and stays
# short; body is the lead sentence, a "📍 location" line (omitted if
# unknown), a blank line, then the 3-day forecast list. CLICK_URL is
# what ntfy opens when the notification is tapped.
compose_notification() {
  local verdict="$1" category="$2" location="$3" forecast_lines="$4" lead

  case "$verdict" in
    good)
      TITLE="☀️ Good day for a wash"
      TAGS="car,white_check_mark"
      ;;
    maybe)
      TITLE="🤔 Maybe wash it"
      TAGS="car,thinking"
      ;;
    no)
      TITLE="🚫 Skip the wash"
      TAGS="car,x"
      ;;
    freeze)
      TITLE="🥶 Too cold for a wash"
      TAGS="car,snowflake"
      ;;
    *)
      die "Unknown verdict: $verdict"
      ;;
  esac

  lead=$(compose_lead "$verdict" "$category")

  if [ -n "$location" ] && [ "$location" != "Unknown" ]; then
    BODY=$(printf '%s\n📍 %s\n\n%s' "$lead" "$location" "$forecast_lines")
  else
    BODY=$(printf '%s\n\n%s' "$lead" "$forecast_lines")
  fi

  # Tap-to-open: a Google search lands on a familiar weather widget no
  # matter what country / device the user is on. Prefer the resolved
  # city name; fall back to the typed query, then to lat/lon.
  local query
  if [ -n "$location" ] && [ "$location" != "Unknown" ]; then
    query="weather $location"
  elif [ -n "${LOCATION:-}" ]; then
    query="weather ${LOCATION}"
  else
    query="weather ${LATITUDE},${LONGITUDE}"
  fi
  CLICK_URL="https://www.google.com/search?q=$(url_encode "$query")"
}

# Minimal URL encoder — handles spaces, commas, and the punctuation
# that shows up in our typical inputs (city names, street addresses).
# We intentionally don't shell out to a heavier dep just for this.
url_encode() {
  local string="$1" out="" i char
  for (( i=0; i<${#string}; i++ )); do
    char="${string:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-]) out+="$char" ;;
      *)               out+=$(printf '%%%02X' "'$char") ;;
    esac
  done
  printf '%s' "$out"
}

# ── Notifier ─────────────────────────────────────────────────────────
# Posts to ntfy with title, body, tags, and an optional Click URL that
# tells ntfy where to send the user when they tap the notification.
# We point at a Google weather search for the resolved location, which
# renders a familiar forecast widget on iOS / Android / desktop alike.
send_ntfy() {
  local title="$1" body="$2" tags="$3" click_url="${4:-}"
  local headers=( -H "Title: ${title}" -H "Tags: ${tags}" )
  [ -n "$click_url" ] && headers+=( -H "Click: ${click_url}" )
  curl -sf \
    "${headers[@]}" \
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
    LAST_VERDICT=$(jq -r            '.last_verdict            // ""' "$STATE_FILE" 2>/dev/null || echo "")
    LAST_NOTIFIED_VERDICT=$(jq -r   '.last_notified_verdict   // ""' "$STATE_FILE" 2>/dev/null || echo "")
    LAST_NOTIFIED_AT=$(jq -r        '.last_notified_at        // ""' "$STATE_FILE" 2>/dev/null || echo "")
    LAST_MORNING_SLOT_DATE=$(jq -r  '.last_morning_slot_date  // ""' "$STATE_FILE" 2>/dev/null || echo "")
    LAST_EVENING_SLOT_DATE=$(jq -r  '.last_evening_slot_date  // ""' "$STATE_FILE" 2>/dev/null || echo "")
  else
    LAST_VERDICT=""
    LAST_NOTIFIED_VERDICT=""
    LAST_NOTIFIED_AT=""
    LAST_MORNING_SLOT_DATE=""
    LAST_EVENING_SLOT_DATE=""
  fi
  log "Loaded state: last_verdict='${LAST_VERDICT}', last_notified='${LAST_NOTIFIED_VERDICT}', morning_slot='${LAST_MORNING_SLOT_DATE}', evening_slot='${LAST_EVENING_SLOT_DATE}'"
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
  local morning_slot_date="${9:-}" evening_slot_date="${10:-}"
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
    --arg msd "$morning_slot_date" \
    --arg esd "$evening_slot_date" \
    '{
       last_run_utc:           $run,
       last_verdict:           $v,
       last_notified_verdict:  $nv,
       last_notified_at:       $na,
       location:               $loc,
       location_query:         $lq,
       location_lat:           $la,
       location_lon:           $lo,
       location_name:          $ln,
       last_morning_slot_date: $msd,
       last_evening_slot_date: $esd
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

  # Load state before the slot check — should_run_now uses
  # LAST_MORNING_SLOT_DATE / LAST_EVENING_SLOT_DATE for per-day dedup.
  load_state

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

  if should_notify "$verdict"; then
    local precip_category=""
    case "$verdict" in
      no)    precip_category=$(precipitation_category "$TOMORROW_CODE") ;;
      maybe) precip_category=$(precipitation_category "$FIRST_WET_CODE") ;;
    esac
    forecast_lines=$(compose_forecast_lines "$forecast")
    compose_notification "$verdict" "$precip_category" "$location" "$forecast_lines"
    log "Sending notification: $TITLE"
    send_ntfy "$TITLE" "$BODY" "$TAGS" "$CLICK_URL"
    log "Notification sent."
    notified_verdict="$verdict"
    notified_at=$(date -u +%FT%TZ)
  else
    log "No change (verdict=$verdict, last_notified=$LAST_NOTIFIED_VERDICT) — staying silent."
    notified_verdict="$LAST_NOTIFIED_VERDICT"
    notified_at="$LAST_NOTIFIED_AT"
  fi

  # Record which slot (if any) this run handled so subsequent firings in
  # the same slot exit early. FORCE_RUN leaves SLOT empty and preserves
  # the previous dates, so a forced test run can't suppress a real slot.
  local morning_slot_date="$LAST_MORNING_SLOT_DATE"
  local evening_slot_date="$LAST_EVENING_SLOT_DATE"
  case "${SLOT:-}" in
    morning) morning_slot_date="$SLOT_DATE" ;;
    evening) evening_slot_date="$SLOT_DATE" ;;
  esac

  save_state "$verdict" "$notified_verdict" "$notified_at" "$location" \
             "$cache_query" "$cache_lat" "$cache_lon" "$cache_name" \
             "$morning_slot_date" "$evening_slot_date"
  log "State written to $STATE_FILE"
}

# Run main() only when this script is executed directly. When sourced
# (e.g. by scripts/tests/run.sh) we expose the helpers without firing
# off a real forecast / notification.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
