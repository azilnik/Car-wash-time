# Customization

## Change the notification times

The default schedule sends notifications at:

- **6:00 AM** (local time at your `LOCATION`) — morning commute
- **9:30 PM** (local time at your `LOCATION`) — evening planning

To change these times, add `MORNING_HOUR` and `EVENING_HOUR` repo variables under **Settings → Secrets and variables → Actions → Variables**. Values are decimal local hours at your location — no need to think in UTC.

| Variable | Example | Effect |
|---|---|---|
| `MORNING_HOUR` | `7` | Morning notification at 7:00 AM |
| `EVENING_HOUR` | `20` | Evening notification at 8:00 PM |

Decimals are supported: `6.5` = 6:30 AM, `21.5` = 9:30 PM. Timezone is derived automatically from your `LOCATION`, so DST is handled without any extra config.

The underlying cron fires every 30 minutes. Only edit that expression (in [`.github/workflows/carwash-check.yml`](../.github/workflows/carwash-check.yml)) if you want to add or remove a notification slot entirely.

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
