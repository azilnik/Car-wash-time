# Customization

## Change the schedule

The default schedule runs twice a day in Eastern Time:

- **6:00 AM ET** (11:00 UTC) for the morning commute
- **9:30 PM ET** (02:30 UTC) for tomorrow's planning

To change it, edit the `cron` lines in [`.github/workflows/carwash-check.yml`](../.github/workflows/carwash-check.yml). Use [crontab.guru](https://crontab.guru/) to build the expression. GitHub Actions cron is in UTC.

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
| [`scripts/check.sh`](../scripts/check.sh) | All the logic: fetch, analyze, decide, notify, persist state |
| [`.github/workflows/carwash-check.yml`](../.github/workflows/carwash-check.yml) | Workflow driver: cron schedule, env config, state commit |
| [`state.json`](../state.json) | Tracks last run, last verdict, last notification (for dedup and keepalive), and cached geocode result |

## Why state.json gets committed back

Two reasons:

1. **Deduplication.** The script only notifies you when the verdict is "good" or has changed. It needs to remember the last verdict between runs.
2. **Keepalive.** GitHub auto-disables scheduled workflows that haven't seen repo activity in 60 days. The state commit counts as activity.
