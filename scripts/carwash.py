#!/usr/bin/env python3
"""Car Wash Time: decide whether today is worth a car wash and push it.

Runs from .github/workflows/carwash-check.yml on a loose cron. GitHub
Actions fires scheduled workflows late and irregularly (measured on this
repo: roughly every 5 hours, not every 30 minutes), so the script never
relies on running at a particular time. Instead:

  1. The first run inside the prep window (from PREP_HOURS before
     MORNING_HOUR up to MORNING_HOUR, local time) works out today's verdict
     and hands the notification to ntfy with an `At:` header, so ntfy
     delivers it at MORNING_HOUR exactly.
  2. If no run lands in the prep window, the first run before
     MORNING_HOUR + LATE_HOURS sends it right away, marked as late.
  3. After that the day is handled; later runs exit without doing anything.

The verdict looks at the wash day itself (from MORNING_HOUR to midnight)
and the three days after it, using hourly forecasts from several weather
models plus an ensemble so a single model's wobble can't flip the call.
The decision code lives in pure functions (`assess_day`, `decide`) that
the test suite and the backtest (scripts/eval/backtest.py) import directly,
so what we evaluate is exactly what we ship.

Stdlib only. Local usage:

    LOCATION="Toronto, Ontario" NTFY_TOPIC=my-topic FORCE_RUN=true \
        python3 scripts/carwash.py
    DRY_RUN=true ...   # print the notification instead of sending it
"""

from __future__ import annotations

import datetime as dt
import json
import math
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field, asdict
from typing import Any, Iterable, Optional
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

# ── Constants ─────────────────────────────────────────────────────────
FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
ENSEMBLE_URL = "https://ensemble-api.open-meteo.com/v1/ensemble"
NOMINATIM_URL = "https://nominatim.openstreetmap.org/search"
NTFY_URL = "https://ntfy.sh"
STATE_FILE = "state.json"
USER_AGENT = "CarWashTime/2.0 (+https://github.com/azilnik/Car-wash-time)"

# Deterministic models blended for the hourly amounts. Each one is a
# separate opinion; the blend is the median so one outlier can't decide.
DEFAULT_MODELS = "gem_seamless,ecmwf_ifs025,gfs_seamless"
# Ensembles for a member-count probability of a wet day. Each model's
# member fraction is computed separately and then averaged, so ECMWF's
# 51 members don't outvote GEM's 21.
DEFAULT_ENSEMBLE = "gem_global_ensemble,ecmwf_ifs025_ensemble,ncep_gefs025"

# The verdict covers the wash day plus this many days after it.
PAYOFF_DAYS = 3
# Days of forecast fetched; the extra ones power the "next dry stretch"
# hint and the "dry for N days" message.
FORECAST_DAYS = 8
# How many verdicts to keep in state.json for later scoring.
HISTORY_LIMIT = 90

# WMO weather codes, grouped by what they mean for a clean car.
RAIN_CODES = {51, 53, 55, 61, 63, 65, 80, 81, 82}
FREEZING_RAIN_CODES = {56, 57, 66, 67}
SNOW_CODES = {71, 73, 75, 77, 85, 86}
THUNDER_CODES = {95}
HAIL_CODES = {96, 99}
PRECIP_CODES = RAIN_CODES | FREEZING_RAIN_CODES | SNOW_CODES | THUNDER_CODES | HAIL_CODES


# ── Tunables ──────────────────────────────────────────────────────────
@dataclass(frozen=True)
class Thresholds:
    """Knobs for calling a day wet. Defaults come from the backtest
    (scripts/eval/backtest.py); see docs/accuracy.md for the numbers."""

    # A day is wet when the blended models expect at least this much
    # precipitation (mm) over the hours that matter...
    wet_mm: float = 1.0
    # ...or when this share of ensemble members (0-1) produce at least
    # `ensemble_mm` over the same hours.
    wet_prob: float = 0.5
    ensemble_mm: float = 0.5
    # Below this many mm a day is dry no matter what the probability
    # says. Stops "40% chance of a 0.1 mm sprinkle" from killing a wash.
    floor_mm: float = 0.2


DEFAULT_THRESHOLDS = Thresholds()


# ── Logging ───────────────────────────────────────────────────────────
def log(msg: str) -> None:
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%H:%M:%SZ")
    print(f"[{stamp}] {msg}", file=sys.stderr, flush=True)


class ConfigError(Exception):
    pass


class DataError(Exception):
    pass


# ── Config ────────────────────────────────────────────────────────────
@dataclass
class Config:
    ntfy_topic: str
    location: str = ""
    latitude: str = ""
    longitude: str = ""
    morning_hour: float = 8.0
    prep_hours: float = 8.0
    late_hours: float = 3.0
    min_wash_temp_c: float = -5.0
    models: str = DEFAULT_MODELS
    ensemble: str = DEFAULT_ENSEMBLE
    force_run: bool = False
    dry_run: bool = False
    custom_location: bool = True
    custom_topic: bool = True


def _float_env(env: dict, name: str, default: float, lo: float, hi: float) -> float:
    raw = (env.get(name) or "").strip()
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        raise ConfigError(f"{name}={raw!r} is not a number (use decimals, e.g. 8.5 for 8:30)")
    if not (lo <= value < hi) or math.isnan(value):
        raise ConfigError(f"{name}={raw!r} must be between {lo} and {hi}")
    return value


def load_config(env: Optional[dict] = None) -> Config:
    env = dict(os.environ if env is None else env)
    topic = (env.get("NTFY_TOPIC") or "").strip()
    if not topic:
        raise ConfigError("NTFY_TOPIC not set")
    location = (env.get("LOCATION") or "").strip()
    lat = (env.get("LATITUDE") or "").strip()
    lon = (env.get("LONGITUDE") or "").strip()
    if not location and not (lat and lon):
        raise ConfigError("Set LOCATION (easier) or LATITUDE+LONGITUDE")
    return Config(
        ntfy_topic=topic,
        location=location,
        latitude=lat,
        longitude=lon,
        morning_hour=_float_env(env, "MORNING_HOUR", 8.0, 0, 24),
        prep_hours=_float_env(env, "PREP_HOURS", 8.0, 0, 24),
        late_hours=_float_env(env, "LATE_HOURS", 3.0, 0, 24),
        min_wash_temp_c=_float_env(env, "MIN_WASH_TEMP_C", -5.0, -1000, 1000),
        models=(env.get("MODELS") or DEFAULT_MODELS).strip(),
        ensemble=(env.get("ENSEMBLE_MODEL") or DEFAULT_ENSEMBLE).strip(),
        force_run=(env.get("FORCE_RUN") or "").lower() == "true",
        dry_run=(env.get("DRY_RUN") or "").lower() == "true",
        custom_location=bool(env.get("LOCATION") or (env.get("VARS_LAT") and env.get("VARS_LON"))),
        custom_topic=bool(env.get("VARS_TOPIC", "x")),
    )


# ── HTTP ──────────────────────────────────────────────────────────────
def http(url: str, *, method: str = "GET", data: Optional[bytes] = None,
         headers: Optional[dict] = None, timeout: float = 20, attempts: int = 4) -> bytes:
    """Small urllib wrapper with timeouts and backoff on 429/5xx/network."""
    hdrs = {"User-Agent": USER_AGENT, **(headers or {})}
    delay = 2.0
    for attempt in range(1, attempts + 1):
        req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except urllib.error.HTTPError as e:
            retryable = e.code == 429 or e.code >= 500
            body = e.read()[:300].decode("utf-8", "replace")
            if not retryable or attempt == attempts:
                raise DataError(f"{method} {url.split('?')[0]} → HTTP {e.code}: {body}")
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            if attempt == attempts:
                raise DataError(f"{method} {url.split('?')[0]} failed: {e}")
        log(f"Retrying {url.split('?')[0]} in {delay:.0f}s (attempt {attempt}/{attempts})")
        time.sleep(delay)
        delay *= 2
    raise AssertionError("unreachable")


def get_json(url: str, params: dict) -> Any:
    raw = http(f"{url}?{urllib.parse.urlencode(params)}")
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        raise DataError(f"{url} returned non-JSON: {raw[:200]!r}")


# ── Geocoding ─────────────────────────────────────────────────────────
def resolve_location(cfg: Config, state: dict) -> tuple[str, str, str]:
    """Return (lat, lon, name). LOCATION wins over LATITUDE/LONGITUDE.
    Geocodes once per LOCATION value and caches the answer in state."""
    if not cfg.location:
        return cfg.latitude, cfg.longitude, state.get("location_name") or f"{cfg.latitude},{cfg.longitude}"
    if state.get("location_query") == cfg.location and state.get("location_lat") and state.get("location_lon"):
        log(f"Geocode cache hit: {cfg.location!r} → {state['location_lat']}, {state['location_lon']}")
        return state["location_lat"], state["location_lon"], state.get("location_name") or cfg.location
    params = {"q": cfg.location, "format": "json", "limit": 1, "addressdetails": 1}
    # Bare 5-digit inputs are ambiguous across countries (10001 is both
    # Manhattan and Tallinn); scope them to the US.
    if cfg.location.isdigit() and len(cfg.location) == 5:
        params["countrycodes"] = "us"
    results = get_json(NOMINATIM_URL, params)
    if not results:
        raise ConfigError(f"Couldn't find {cfg.location!r}. Try something like 'Toronto, Ontario' or a postal code.")
    top = results[0]
    addr = top.get("address", {})
    name = addr.get("city") or addr.get("town") or addr.get("village") or addr.get("county") or cfg.location
    log(f"Geocoded {cfg.location!r} → {top['lat']}, {top['lon']} ({name}, {addr.get('country', '?')})")
    state.update(location_query=cfg.location, location_lat=top["lat"], location_lon=top["lon"], location_name=name)
    return top["lat"], top["lon"], name


# ── Forecast fetching ─────────────────────────────────────────────────
@dataclass
class Forecast:
    """Hourly forecast in local time, already blended across models.

    `precip` maps each deterministic model to its hourly mm. Spans are
    totalled per model and *then* blended (median), never hour by hour:
    models often agree a shower is coming but disagree on the hour, and an
    hourly median would erase it. `members` holds ensemble member series.
    Values may be None where a source has no data.
    """

    utc_offset_seconds: int
    times: list[dt.datetime]                 # naive local datetimes
    precip: dict[str, list[Optional[float]]]
    temp: list[Optional[float]]
    code: list[Optional[int]]
    # ensemble model name → list of member series (hourly mm)
    members: dict[str, list[list[Optional[float]]]] = field(default_factory=dict)
    timezone: str = ""                        # IANA name, e.g. America/Toronto

    def zone(self) -> dt.tzinfo:
        try:
            return ZoneInfo(self.timezone) if self.timezone else dt.timezone(dt.timedelta(seconds=self.utc_offset_seconds))
        except (ZoneInfoNotFoundError, ValueError):
            return dt.timezone(dt.timedelta(seconds=self.utc_offset_seconds))

    def to_local(self, when_utc: dt.datetime) -> dt.datetime:
        return when_utc.astimezone(self.zone()).replace(tzinfo=None)

    def to_epoch(self, local: dt.datetime) -> int:
        """Naive local wall time → unix seconds, DST-aware."""
        return int(local.replace(tzinfo=self.zone()).timestamp())

    def index_of(self, when: dt.datetime) -> Optional[int]:
        try:
            return self.times.index(when)
        except ValueError:
            return None


def _median(values: Iterable[Optional[float]]) -> Optional[float]:
    vals = sorted(v for v in values if v is not None)
    if not vals:
        return None
    mid = len(vals) // 2
    return vals[mid] if len(vals) % 2 else (vals[mid - 1] + vals[mid]) / 2


def _model_columns(hourly: dict, var: str) -> list[list]:
    """Columns for `var`: suffixed per model (multi-model request) or the
    bare column (single model)."""
    cols = [v for k, v in hourly.items() if k == var or k.startswith(var + "_")]
    # precipitation_probability would match "precipitation_"; exclude other vars.
    if var == "precipitation":
        cols = [v for k, v in hourly.items()
                if k == var or (k.startswith("precipitation_") and not k.startswith("precipitation_probability"))]
    return cols


def parse_forecast(det: dict, ens: Optional[dict] = None) -> Forecast:
    """Turn Open-Meteo JSON (deterministic multi-model + optional ensemble)
    into a blended Forecast. Raises DataError on malformed input."""
    try:
        hourly = det["hourly"]
        times = [dt.datetime.fromisoformat(t) for t in hourly["time"]]
        offset = int(det["utc_offset_seconds"])
    except (KeyError, TypeError, ValueError) as e:
        raise DataError(f"forecast response missing hourly data: {e}")
    n = len(times)
    if n < 24:
        raise DataError(f"forecast only has {n} hours")

    def blended(var: str, cast=float):
        cols = [c for c in _model_columns(hourly, var) if isinstance(c, list) and len(c) == n]
        out = []
        for i in range(n):
            vals = [cast(c[i]) for c in cols if c[i] is not None]
            out.append(_median(vals) if cast is float else (max(vals) if vals else None))
        return out

    precip = {}
    for k, col in hourly.items():
        if k == "precipitation" or (k.startswith("precipitation_") and not k.startswith("precipitation_probability")):
            if isinstance(col, list) and len(col) == n and any(v is not None for v in col):
                precip[k[len("precipitation_"):] or "default"] = [None if v is None else float(v) for v in col]
    if not precip:
        raise DataError("forecast has no precipitation data")
    temp = blended("temperature_2m")
    # For the code, take the most common precip-ish signal: the median
    # model is noisy for categorical data, so use the max code among
    # models that also have precip in that hour; fall back to None.
    code_cols = [c for c in _model_columns(hourly, "weather_code") if isinstance(c, list) and len(c) == n]
    codes: list[Optional[int]] = []
    for i in range(n):
        vals = [int(c[i]) for c in code_cols if c[i] is not None]
        wet = [v for v in vals if v in PRECIP_CODES]
        codes.append(max(wet) if len(wet) * 2 >= len(vals) and wet else (min(vals) if vals else None))

    members: dict[str, list[list[Optional[float]]]] = {}
    if ens and isinstance(ens.get("hourly"), dict):
        eh = ens["hourly"]
        pos = {t: i for i, t in enumerate(eh.get("time", []))}
        lookup = [pos.get(t.isoformat(timespec="minutes")) for t in times]
        for k, col in eh.items():
            if not k.startswith("precipitation") or not isinstance(col, list):
                continue
            # precipitation_<model> (control) or precipitation_memberNN_<model>
            rest = k[len("precipitation_"):] if k.startswith("precipitation_") else ""
            model = rest.split("_", 1)[1] if rest.startswith("member") and "_" in rest else (rest or "ensemble")
            series = [col[j] if j is not None and j < len(col) else None for j in lookup]
            if any(v is not None for v in series):
                members.setdefault(model, []).append(series)
    return Forecast(offset, times, precip, temp, codes, members, str(det.get("timezone") or ""))


def fetch_forecast(lat: str, lon: str, cfg: Config) -> Forecast:
    base = {"latitude": lat, "longitude": lon, "timezone": "auto", "forecast_days": FORECAST_DAYS}
    det = get_json(FORECAST_URL, {**base, "hourly": "precipitation,temperature_2m,weather_code",
                                  "models": cfg.models})
    ens = None
    if cfg.ensemble and cfg.ensemble.lower() != "none":
        try:
            ens = get_json(ENSEMBLE_URL, {**base, "hourly": "precipitation", "models": cfg.ensemble})
        except DataError as e:
            # The ensemble sharpens the call but isn't essential.
            log(f"Ensemble unavailable, continuing with deterministic models only: {e}")
    return parse_forecast(det, ens)


# ── Decision ──────────────────────────────────────────────────────────
@dataclass
class DayAssessment:
    date: dt.date
    label: str                  # "today", "tomorrow", "Sat"
    hours: int                  # hours with data
    mm: Optional[float]         # blended expected precip over the span
    prob: Optional[float]       # share of ensemble members ≥ ensemble_mm (0-1)
    wet: Optional[bool]         # None = not enough data to say
    category: str               # "rain", "snow", ...
    min_temp: Optional[float]


def category_for(codes: Iterable[Optional[int]], min_temp: Optional[float]) -> str:
    present = {c for c in codes if c is not None}
    if present & HAIL_CODES:
        return "hail"
    if present & THUNDER_CODES:
        return "thunderstorms"
    if present & FREEZING_RAIN_CODES:
        return "freezing rain"
    if present & SNOW_CODES:
        return "snow"
    if present & RAIN_CODES:
        return "rain"
    # Precip with no wet code: guess from temperature.
    if min_temp is not None and min_temp <= 0:
        return "snow"
    return "rain"


def day_label(day: dt.date, wash_day: dt.date) -> str:
    delta = (day - wash_day).days
    if delta == 0:
        return "today"
    if delta == 1:
        return "tomorrow"
    return day.strftime("%a")


def assess_span(fc: Forecast, start: dt.datetime, end: dt.datetime, wash_day: dt.date,
                th: Thresholds = DEFAULT_THRESHOLDS) -> DayAssessment:
    """Assess precipitation over [start, end) local time."""
    idx = [i for i, t in enumerate(fc.times) if start <= t < end]
    expected = int((end - start).total_seconds() // 3600)
    temps = [fc.temp[i] for i in idx if fc.temp[i] is not None]
    min_temp = min(temps) if temps else None

    # Per-model totals over the span; a model missing >25% of the hours
    # doesn't get a vote.
    totals, have = [], 0
    for series in fc.precip.values():
        vals = [series[i] for i in idx if series[i] is not None]
        have = max(have, len(vals))
        if idx and len(vals) * 4 >= expected * 3:
            totals.append(sum(vals))
    mm = _median(totals)
    prob = None
    fractions = []
    for series_list in fc.members.values():
        totals = []
        for m in series_list:
            vals = [m[i] for i in idx if m[i] is not None]
            if idx and len(vals) * 4 >= len(idx) * 3:  # member covers ≥75% of the span
                totals.append(sum(vals))
        if totals:
            fractions.append(sum(1 for t in totals if t >= th.ensemble_mm) / len(totals))
    if fractions:
        prob = sum(fractions) / len(fractions)

    wet: Optional[bool]
    if mm is None:
        # No model covers the span: refuse to call it dry.
        wet = None
    else:
        if mm < th.floor_mm:
            wet = False
        elif mm >= th.wet_mm:
            wet = True
        else:
            wet = prob is not None and prob >= th.wet_prob
    day = start.date()
    return DayAssessment(day, day_label(day, wash_day), have,
                         None if mm is None else round(mm, 2),
                         None if prob is None else round(prob, 2),
                         wet, category_for((fc.code[i] for i in idx), min_temp), min_temp)


@dataclass
class Verdict:
    kind: str                       # good | maybe | no | freeze | unknown
    wash_day: dt.date
    days: list[DayAssessment]       # wash day + following days
    reason_day: Optional[DayAssessment] = None
    freeze_temp: Optional[float] = None
    dry_streak: int = 0             # dry days in a row starting at the wash day
    next_dry: Optional[dt.date] = None
    next_dry_len: int = 0


def decide(fc: Forecast, wash_day: dt.date, wash_hour: float = 8.0,
           min_wash_temp_c: float = -5.0, th: Thresholds = DEFAULT_THRESHOLDS) -> Verdict:
    """Verdict for washing at `wash_hour` on `wash_day`.

    Window: the rest of the wash day (from wash_hour) plus PAYOFF_DAYS
    full days after it.
      freeze — tonight's low drops below min_wash_temp_c
      no     — wet today or tomorrow
      maybe  — dry today and tomorrow, wet later in the window
      good   — dry all window
      unknown — forecast missing for part of the window; say nothing
    """
    start = dt.datetime.combine(wash_day, dt.time()) + dt.timedelta(hours=wash_hour)
    days: list[DayAssessment] = []
    midnight = dt.datetime.combine(wash_day, dt.time())
    days.append(assess_span(fc, start, midnight + dt.timedelta(days=1), wash_day, th))
    last = fc.times[-1]
    d = 1
    while midnight + dt.timedelta(days=d + 1) <= last + dt.timedelta(hours=1):
        days.append(assess_span(fc, midnight + dt.timedelta(days=d),
                                midnight + dt.timedelta(days=d + 1), wash_day, th))
        d += 1

    window = days[: PAYOFF_DAYS + 1]
    v = Verdict("good", wash_day, days)

    # Dry streak / next dry window over the whole lookahead.
    i = 0
    while i < len(days) and days[i].wet is False:
        i += 1
    v.dry_streak = i
    j = i
    while j < len(days) and days[j].wet is not False:
        j += 1
    if i < len(days) and j < len(days):
        k = j
        while k < len(days) and days[k].wet is False:
            k += 1
        v.next_dry, v.next_dry_len = days[j].date, k - j

    # Tonight's low: from wash time until 10:00 the next morning.
    night_end = midnight + dt.timedelta(days=1, hours=10)
    night = [fc.temp[i] for i, t in enumerate(fc.times) if start <= t < night_end and fc.temp[i] is not None]
    low = min(night) if night else None

    if len(window) < PAYOFF_DAYS + 1 or any(x.wet is None for x in window[:2]):
        v.kind = "unknown"
    elif low is not None and low < min_wash_temp_c:
        v.kind, v.freeze_temp = "freeze", low
    elif window[0].wet or window[1].wet:
        v.kind = "no"
        v.reason_day = window[0] if window[0].wet else window[1]
    elif any(x.wet is None for x in window):
        v.kind = "unknown"
    elif any(x.wet for x in window[2:]):
        v.kind = "maybe"
        v.reason_day = next(x for x in window[2:] if x.wet)
    return v


# ── Message composition ───────────────────────────────────────────────
TITLES = {
    "good": ("☀️ Good day for a wash", "car,white_check_mark"),
    "maybe": ("🤔 Maybe wash it", "car,thinking"),
    "no": ("🚫 Skip the wash", "car,x"),
    "freeze": ("🥶 Too cold for a wash", "car,snowflake"),
}


def _chance(day: DayAssessment) -> str:
    if day.prob is None:
        return ""
    return f" ({round(day.prob * 100 / 10) * 10:.0f}% chance)"


def _next_hint(v: Verdict) -> str:
    if not v.next_dry:
        return ""
    label = day_label(v.next_dry, v.wash_day)
    label = label if label in ("today", "tomorrow") else label
    if v.next_dry_len >= 2:
        return f" Next dry stretch: {label} onward ({v.next_dry_len} days)."
    return f" Next dry day: {label}."


def compose(v: Verdict) -> tuple[str, str, str]:
    """Return (title, body, tags)."""
    if v.kind not in TITLES:
        raise ValueError(f"no message for verdict {v.kind!r}")
    title, tags = TITLES[v.kind]
    if v.kind == "good":
        horizon = len(v.days) - 1
        if v.dry_streak > horizon:
            body = "Dry all week. Go for it."
        elif v.dry_streak - 1 > PAYOFF_DAYS:
            body = f"Dry for the next {v.dry_streak - 1} days. Go for it."
        else:
            body = "Dry today and the next 3 days. Go for it."
    elif v.kind == "no":
        r = v.reason_day
        assert r is not None
        when = "today" if r.label == "today" else "tomorrow"
        body = f"{r.category.capitalize()} {when}{_chance(r)}, wait it out.{_next_hint(v)}"
    elif v.kind == "maybe":
        r = v.reason_day
        assert r is not None
        body = f"Dry today and tomorrow, then {r.category} {r.label}{_chance(r)}. Your call.{_next_hint(v)}"
    else:
        assert v.freeze_temp is not None
        t = round(v.freeze_temp)
        body = f"Tonight drops to {0 if t == 0 else t}°C; a fresh wash would freeze on the car."
    return title, body.strip(), tags


# ── Notifier ──────────────────────────────────────────────────────────
def send_ntfy(topic: str, title: str, body: str, tags: str, deliver_at: Optional[int] = None) -> None:
    """Publish via ntfy's JSON API (UTF-8 safe, unlike headers). With
    `deliver_at` (unix seconds) ntfy holds the message and delivers it
    then; the free ntfy.sh server allows up to 3 days of delay."""
    payload: dict[str, Any] = {"topic": topic, "title": title, "message": body,
                               "tags": [t for t in tags.split(",") if t]}
    if deliver_at is not None:
        payload["delay"] = str(deliver_at)
    http(NTFY_URL, method="POST", data=json.dumps(payload).encode(),
         headers={"Content-Type": "application/json"})


# ── State ─────────────────────────────────────────────────────────────
def load_state(path: str = STATE_FILE) -> dict:
    try:
        with open(path) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_state(state: dict, path: str = STATE_FILE) -> None:
    with open(path, "w") as f:
        json.dump(state, f, indent=2, ensure_ascii=False)
        f.write("\n")


def should_notify(verdict: str, last_notified: str) -> bool:
    """Ping on every "good" (actionable). Otherwise only when the verdict
    changes, so a rainy week doesn't send seven "skip" messages."""
    return verdict == "good" or verdict != last_notified


# ── Scheduling ────────────────────────────────────────────────────────
@dataclass
class Plan:
    action: str                 # "schedule" | "send_late" | "skip"
    wash_day: dt.date
    deliver_at_local: dt.datetime
    reason: str


def plan_run(now_local: dt.datetime, morning_hour: float, prep_hours: float, late_hours: float,
             last_handled: str) -> Plan:
    """Decide what this firing should do. `now_local` is naive local time."""
    today = now_local.date()
    for day in (today, today + dt.timedelta(days=1)):
        target = dt.datetime.combine(day, dt.time()) + dt.timedelta(hours=morning_hour)
        opens = target - dt.timedelta(hours=prep_hours)
        closes = target + dt.timedelta(hours=late_hours)
        if not (opens <= now_local < closes):
            continue
        if last_handled == day.isoformat():
            return Plan("skip", day, target, f"{day} already handled")
        if now_local < target:
            return Plan("schedule", day, target, f"in prep window for {target:%a %H:%M}")
        return Plan("send_late", day, target, f"missed prep window; {target:%H:%M} slot is open until {closes:%H:%M}")
    return Plan("skip", today, now_local, "outside the notification window")


# ── Main ──────────────────────────────────────────────────────────────
def summarize(v: Verdict) -> list[dict]:
    return [{"date": d.date.isoformat(), "mm": d.mm, "prob": d.prob, "wet": d.wet}
            for d in v.days[: PAYOFF_DAYS + 1]]


def run(cfg: Config, state: dict, now_utc: Optional[dt.datetime] = None,
        fetch=fetch_forecast, notify=send_ntfy) -> dict:
    """One firing. Returns the new state (caller persists it)."""
    now_utc = now_utc or dt.datetime.now(dt.timezone.utc)
    state = dict(state)
    log(f"Location: {cfg.location or f'{cfg.latitude}, {cfg.longitude}'}"
        + ("" if cfg.custom_location else " (demo default; set vars.LOCATION)"))
    if not cfg.custom_topic:
        log(f"ntfy topic: {cfg.ntfy_topic} (demo default; set vars.NTFY_TOPIC for privacy)")
    lat, lon, name = resolve_location(cfg, state)

    # The local clock comes from the forecast's UTC offset, so DST and the
    # timezone of LOCATION are handled without configuration. The last
    # offset is cached so most firings can skip without any API call; the
    # prep window is hours wide, so a DST change can't make that wrong.
    last_handled = state.get("last_handled_date", "")
    cached_offset = state.get("utc_offset_seconds")
    if not cfg.force_run and isinstance(cached_offset, int):
        guess = (now_utc + dt.timedelta(seconds=cached_offset)).replace(tzinfo=None)
        pre = plan_run(guess, cfg.morning_hour, cfg.prep_hours, cfg.late_hours, last_handled)
        if pre.action == "skip":
            log(f"Local time ~{guess:%Y-%m-%d %H:%M}: skip ({pre.reason})")
            return state

    fc = fetch(lat, lon, cfg)
    state["utc_offset_seconds"] = fc.utc_offset_seconds
    now_local = fc.to_local(now_utc)

    if cfg.force_run:
        plan = Plan("send_now", now_local.date(), now_local, "FORCE_RUN")
        if now_local.hour + now_local.minute / 60 >= cfg.morning_hour + cfg.late_hours:
            # Evening test run: the useful answer is about tomorrow morning.
            plan.wash_day = now_local.date() + dt.timedelta(days=1)
    else:
        plan = plan_run(now_local, cfg.morning_hour, cfg.prep_hours, cfg.late_hours, last_handled)
    log(f"Local time {now_local:%Y-%m-%d %H:%M}: {plan.action} ({plan.reason})")
    if plan.action == "skip":
        return state

    v = decide(fc, plan.wash_day, cfg.morning_hour, cfg.min_wash_temp_c)
    for d in v.days[: PAYOFF_DAYS + 1]:
        log(f"  {d.date} {d.label:>8}: {d.mm} mm, ensemble {d.prob}, wet={d.wet}, {d.category}, min {d.min_temp}")
    log(f"Verdict for {plan.wash_day}: {v.kind}")

    last_notified = state.get("last_notified_verdict", "")
    entry = {"wash_day": plan.wash_day.isoformat(), "verdict": v.kind,
             "decided_at": now_utc.strftime("%Y-%m-%dT%H:%M:%SZ"), "forecast": summarize(v)}

    if v.kind == "unknown":
        log("Forecast incomplete for the window; not sending a guess.")
        entry["notified"] = False
    elif cfg.force_run or should_notify(v.kind, last_notified):
        title, body, tags = compose(v)
        if plan.action == "send_late":
            body += f" (Late: forecast checked {now_local:%-I:%M %p}.)"
        deliver_at = None
        if plan.action == "schedule":
            deliver_at = fc.to_epoch(plan.deliver_at_local)
            # ntfy needs at least 10 seconds of delay.
            if deliver_at - now_utc.timestamp() < 15:
                deliver_at = None
        when = "now" if deliver_at is None else f"at {plan.deliver_at_local:%a %H:%M} local"
        log(f"Notification ({when}): {title} | {body}")
        if cfg.dry_run:
            log("DRY_RUN: not sending.")
        else:
            notify(cfg.ntfy_topic, title, body, tags, deliver_at)
        entry.update(notified=True, title=title, body=body,
                     deliver_at=dt.datetime.fromtimestamp(deliver_at or now_utc.timestamp(), dt.timezone.utc)
                     .strftime("%Y-%m-%dT%H:%M:%SZ"))
        if not cfg.force_run:
            state["last_notified_verdict"] = v.kind
            state["last_notified_at"] = entry["deliver_at"]
    else:
        log(f"Verdict unchanged ({v.kind}); staying quiet.")
        entry["notified"] = False

    if cfg.force_run or cfg.dry_run:
        return state  # test runs never consume the real slot
    state["last_handled_date"] = plan.wash_day.isoformat()
    state["location"] = name
    history = [h for h in state.get("history", []) if h.get("wash_day") != entry["wash_day"]]
    state["history"] = (history + [entry])[-HISTORY_LIMIT:]
    return state


def main() -> int:
    try:
        cfg = load_config()
        state = load_state()
        new_state = run(cfg, state)
        if new_state != state:
            save_state(new_state)
            log(f"State written to {STATE_FILE}")
        return 0
    except (ConfigError, DataError) as e:
        print(f"::error::{e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
