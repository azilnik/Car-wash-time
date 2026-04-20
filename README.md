<div align="center">

# Car Wash Time

**Should I pay for a car wash today, or is the sky about to waste my money?**

A zero-cost, zero-maintenance GitHub Actions workflow that checks the forecast
and sends a push notification telling you whether it's worth washing the car.

[![GitHub Actions](https://img.shields.io/badge/runs%20on-GitHub%20Actions-2088FF?logo=githubactions&logoColor=white)](https://github.com/features/actions)
[![ntfy.sh](https://img.shields.io/badge/notifications-ntfy.sh-57A8EF?logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZD0iTTEyIDJMMiAyMmgyMEwxMiAyeiIgZmlsbD0id2hpdGUiLz48L3N2Zz4=)](https://ntfy.sh)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

</div>

---

## Why This Exists

Every morning I drive past the car wash after school dropoff. The car is filthy.
The kids have opinions about it. But is it worth stopping if it's going to rain
tomorrow? I never know, and I'm not going to check three weather apps while
merging onto the highway.

So I built this. Twice a day it checks the forecast and sends a push notification
to my phone. By the time I'm approaching the car wash, I already know whether to
pull in or keep driving.

## How It Works

```
  ┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐
  │  GitHub Actions   │────▶│   Open-Meteo API  │────▶│     ntfy.sh      │
  │  (cron: 2×/day)   │     │  (3-day forecast)  │     │  (push to phone) │
  └──────────────────┘     └──────────────────┘     └──────────────────┘
```

1. A scheduled workflow fetches the 3-day forecast from [Open-Meteo](https://open-meteo.com/)
2. It checks for rain, snow, drizzle, freezing rain, or thunderstorms using WMO weather codes
3. It sends a push notification via [ntfy.sh](https://ntfy.sh) with one of three verdicts:

| Verdict | Notification | Meaning |
|---|---|---|
| **Good** | ☀️ Good day for a wash | No precipitation in the next 3 days. Go for it. |
| **Maybe** | 🤔 Maybe wash it | Today is dry, but rain is coming. Your call. |
| **Skip** | 🚫 Skip the wash | Rain tomorrow. Save your money. |

> **Smart silence:** Repeated "skip" or "maybe" days don't spam you — you only
> get notified when the verdict is "good" (actionable) or when it *changes*
> from the last one.

## Quick Start

**Time needed:** under 5 minutes. No server, no API keys, no app to build.

1. **Fork** this repo
2. **Set two repo variables** under Settings → Secrets and variables → Actions → Variables:

   | Variable | Example | What it is |
   |---|---|---|
   | `LOCATION` | `Toronto, Ontario` | City, address, or postal code — anything a map can find |
   | `NTFY_TOPIC` | `my-carwash-x7k9m2p4` | A unique [ntfy.sh](https://ntfy.sh) topic |

   Other `LOCATION` values that work: `"Brooklyn, NY"`, `"M5V 3A8"`, `"10001"`,
   `"1600 Amphitheatre Parkway, Mountain View, CA"`. Bare 5-digit inputs are
   auto-scoped to US ZIPs — for a non-US postal code, include the country
   (e.g. `"10115, Germany"` for Berlin, since `"10115"` alone would otherwise
   be read as a US ZIP). Check the country in the first run's log to confirm.

   > **Tip:** Pick a long, random topic name — ntfy topics are public, and anyone
   > who knows yours can see your notifications.
   >
   > Worried about committing your address to a public repo? See [Privacy](#privacy)
   > — you can either use `LATITUDE`/`LONGITUDE` directly, or duplicate the repo
   > to a private one.
   >
   > Skipping this step? The workflow ships with demo defaults (New York City +
   > a shared public demo topic) so you can test immediately.

3. **Install the [ntfy app](https://ntfy.sh)** (Android / iOS) and subscribe to your topic
4. **Enable Actions** on your fork (GitHub disables them on forks by default)
5. That's it. You'll get a notification before your morning commute.

   To test right now: Actions → Daily Car Wash Check → Run workflow.

## Privacy

On a **public** fork, some things leak through normal workflow activity:

- **`state.json` is committed back to `main` after every run.** With `LOCATION` set, it includes the text you typed (e.g. `"123 Main St, Anytown, OH"`), the resolved coordinates, and the city name — all readable in the repo's git history.
- **Workflow run logs are public** and echo the geocode result (`Geocoded 'X' → lat, lon (city, country)`) and your ntfy topic.
- **ntfy topics are public by design.** Anyone who knows the topic name can subscribe and see your notifications.

Repo variables themselves are only visible to collaborators in Settings — but their values leak through the runtime artifacts above.

### Keep your setup private while the project stays public

GitHub won't let you make a fork private. Duplicate the repo to a new private one instead:

```bash
gh repo create you/car-wash-time-private --private --clone=false
git clone --bare https://github.com/azilnik/Car-wash-time.git
cd Car-wash-time.git
git push --mirror git@github.com:you/car-wash-time-private.git
```

You now have a disconnected private copy. Set your real `LOCATION` and `NTFY_TOPIC` there; leave any public fork with demo defaults. Private repos get 2,000 free Actions minutes/month; this workflow uses ~5.

Pulling future upstream updates:

```bash
git remote add upstream https://github.com/azilnik/Car-wash-time.git
git fetch upstream && git merge upstream/main && git push origin main
```

See [GitHub's docs on duplicating a repository](https://docs.github.com/en/repositories/creating-and-managing-repositories/duplicating-a-repository) for the full flow.

### Lighter option: keep your fork public, minimize the leak

- Use `LATITUDE`/`LONGITUDE` directly and leave `LOCATION` unset. Your typed input never hits `state.json` — only the coordinates do, which is a weaker privacy signal than a street address.
- Pick a long, random `NTFY_TOPIC` you don't share.

## Design Constraints

- **$0 budget.** Every API, service, and hosting platform used is completely free.
- **No server.** No backend, no database, no Docker, no cloud bill. Just a GitHub Actions cron job.
- **No app to open.** No website to check. The answer shows up as a push notification.
- **No API keys.** Open-Meteo doesn't need one. ntfy.sh doesn't need an account. GitHub Actions is just... there.
- **No frameworks.** Nothing to `npm install`, nothing to break when you come back to it 6 months later.
- **Minimal maintenance.** It keeps running even if you forget about it — the workflow commits a small state file on each run, which keeps GitHub from auto-disabling it.

## Tech Stack

| What | Why |
|---|---|
| [Open-Meteo](https://open-meteo.com/) | Free weather API, no key required |
| [ntfy.sh](https://ntfy.sh) | Free push notifications, no account required |
| [GitHub Actions](https://github.com/features/actions) | Free scheduled workflows |
| [Nominatim](https://nominatim.openstreetmap.org/) | Free geocoding — resolves `LOCATION` to coordinates and powers the "📍 city" line |

## File Reference

| File | Purpose |
|---|---|
| `scripts/check.sh` | All the logic — fetch, analyze, decide, notify, persist state |
| `.github/workflows/carwash-check.yml` | Thin workflow driver: cron schedule, env config, state commit |
| `state.json` | Tracks last run, last verdict, last notification (for dedup + keepalive), and cached geocode result |

## Make It Yours

The default schedule is tuned for Eastern Time:
- **6:00 AM EST** (11:00 UTC) — morning check, before the commute
- **9:30 PM EST** (02:30 UTC) — evening check, planning for tomorrow

To change the schedule, edit the `cron` lines in `.github/workflows/carwash-check.yml`.
Use [crontab.guru](https://crontab.guru/) to build your expression.

## Contributing

Pull requests welcome. If you have an idea, open an issue first so we can talk
about it.

## License

[MIT](LICENSE) — do whatever you want with it.

---

*Built so I stop wasting money on car washes right before it rains.*
