# Customization

## Change the notification time

The verdict arrives at **8:00 AM** local time at your `LOCATION`. To change it, add a `MORNING_HOUR` repo variable under **Settings → Secrets and variables → Actions → Variables**. Decimals work: `7.5` = 7:30 AM. Timezone and DST come from your location automatically.

| Variable | Default | Effect |
|---|---|---|
| `MORNING_HOUR` | `8` | Local hour the notification is delivered. |

Delivery is exact even though GitHub's scheduler isn't: the first workflow run in the 8 hours before `MORNING_HOUR` computes the verdict and schedules it with ntfy for that time. If no run lands in that window, the first run in the 3 hours after sends it immediately with a "(Late …)" note. After that the day is done, so you get at most one notification per day.

The old evening notification is gone; `EVENING_HOUR` is ignored if you still have it set.

## Tune the freeze warning

When tonight's low (from the wash time to 10 AM tomorrow) is below the freeze threshold, the verdict becomes **🥶 Too cold for a wash** instead of the usual go / maybe / skip — a fresh wash will freeze in the locks, doors, and on the paint.

| Variable | Default | Effect |
|---|---|---|
| `MIN_WASH_TEMP_C` | `-5` | Trigger the freeze warning when tonight's low (in °C) is below this. |

Examples:

- `MIN_WASH_TEMP_C=0` — warn whenever it'll dip below freezing overnight.
- `MIN_WASH_TEMP_C=-15` — only warn on really hard freezes (heated garages, climate-controlled lots).
- `MIN_WASH_TEMP_C=-100` — disable the freeze warning entirely; you'll always get the precipitation verdict.

Add it under **Settings → Secrets and variables → Actions → Variables** alongside the other variables (the workflow already forwards it to the script).

## Use coordinates instead of an address

Set `LATITUDE` and `LONGITUDE` repo variables and leave `LOCATION` unset. The script uses the coordinates directly and skips the geocode call. Useful if you want a public fork without your address showing up in git history (see [Privacy](privacy.md)).

## Location formats that work

`LOCATION` accepts anything Nominatim can resolve:

- `Toronto, Ontario`
- `Brooklyn, NY`
- `M5V 3A8` (Canadian postal code)
- `10001` (US ZIP)
- `1600 Amphitheatre Parkway, Mountain View, CA`

Bare 5-digit inputs are auto-scoped to US ZIPs. For a non-US postal code, include the country (e.g. `10115, Germany` for Berlin, since `10115` alone would otherwise be read as a US ZIP). Check the country in the first run's log to confirm it resolved correctly.

## File reference

| File | Purpose |
|---|---|
| [`scripts/carwash.py`](../scripts/carwash.py) | All the logic: fetch, decide, schedule, notify, persist state. Python 3.9+, stdlib only. |
| [`scripts/tests/test_carwash.py`](../scripts/tests/test_carwash.py) | Offline test suite: verdicts, thresholds, bad data, freeze, scheduling, end-to-end runs. |
| [`scripts/eval/backtest.py`](../scripts/eval/backtest.py) | Scores the decision rule against archived forecasts and Environment Canada observations. |
| [`.github/workflows/carwash-check.yml`](../.github/workflows/carwash-check.yml) | Workflow driver: cron, env config, state commit. |
| [`state.json`](../state.json) | Which day was last handled, last notified verdict, cached geocode, and a 90-day history of verdicts and the forecast behind them. |

## Run it locally

```bash
python3 -m unittest discover -s scripts/tests -v          # tests, offline
LOCATION="Toronto, Ontario" NTFY_TOPIC=x DRY_RUN=true FORCE_RUN=true \
  python3 scripts/carwash.py                               # live forecast, no notification
```

## Why state.json gets committed back

1. **Once a day.** It records which morning has been handled, so the many workflow runs don't notify more than once.
2. **Deduplication.** Repeated "skip" days stay quiet; it needs the last verdict to know.
3. **History.** Each day's verdict and the forecast numbers behind it, so accuracy can be checked against what actually happened.
4. **Keepalive.** GitHub disables scheduled workflows after 60 days without repo activity. The daily commit counts.
