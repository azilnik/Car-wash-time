# Car Wash Time

**Should I pay for a car wash today, or is the sky about to waste my money?**

Every morning I drive past the car wash after school dropoff. The car is filthy. The kids have opinions about it. But is it worth stopping if it's going to rain tomorrow? I never know, and I'm not going to check three weather apps while merging onto the highway.

So I built this. It checks the forecast and sends a push notification to my phone telling me whether it's worth pulling into the car wash this morning.

## How It Works

On weekdays at 5:30 AM and most evenings (Sunday–Thursday at 9:30 PM), a GitHub Actions workflow:

1. Fetches the 3-day forecast from the [Open-Meteo API](https://open-meteo.com/)
2. Checks for rain, snow, drizzle, freezing rain, or thunderstorms using WMO weather codes
3. Sends a push notification via [ntfy.sh](https://ntfy.sh) with one of three verdicts:

| Verdict | Meaning |
|---|---|
| **Good day for a wash** | No precipitation in the next 3 days. Money well spent. |
| **Maybe worth a wash** | Today looks dry, but rain is coming. Your call. |
| **Skip it** | Rain tomorrow. Save your $15. |

The morning notification hits before school dropoff (Monday–Friday), so I know whether to stop or keep driving. No notifications on Saturday — the Sunday evening alert is the only weekend notification, giving a heads-up for Monday morning.

## The Constraints (a.k.a. the fun part)

- **$0 budget.** Every API, service, and hosting platform used is completely free.
- **No server.** No backend, no database, no Docker, no cloud bill. Just a GitHub Actions cron job.
- **No UI.** No app to open, no website to check. The answer shows up as a push notification. That's it.
- **No frameworks.** Nothing to `npm install`, nothing to break when you come back to it 6 months later.
- **No authentication.** Open-Meteo doesn't need an API key. ntfy.sh doesn't need an account. GitHub Actions is just... there.
- **Minimal maintenance.** It keeps running even if I forget about it. (There's a keepalive workflow that prevents GitHub from auto-disabling the scheduled actions.)

## Tech Stack

| What | Why |
|---|---|
| [Open-Meteo](https://open-meteo.com/) | Free weather API, no key required |
| [ntfy.sh](https://ntfy.sh) | Free push notifications, no account required |
| [GitHub Actions](https://github.com/features/actions) | Free scheduled workflows |

## Getting Notifications

1. Install the [ntfy app](https://ntfy.sh) (Android / iOS)
2. Subscribe to the topic listed in the workflow file
3. That's it. You'll get notifications on weekday mornings (5:30 AM EST) and Sunday–Thursday evenings (9:30 PM EST).

---

*Built so I stop wasting money on car washes right before it rains.*
