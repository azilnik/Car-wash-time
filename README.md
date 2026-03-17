# Car Wash Time

**Should I wash my car today, or is the sky about to undo all my hard work?**

I'm a busy dad in Toronto. I have exactly one free hour on the weekend to wash the car — and nothing stings more than scrubbing it on Saturday only to watch it rain on Sunday. So I built this little tool to save myself the heartbreak (and the wasted hour I could've spent napping).

Car Wash Time checks the weather forecast and tells you, in plain terms, whether now is a good time to wash your car. It even sends you a push notification so you don't have to remember to check.

## How It Works

Every morning at 6 AM and evening at 9:30 PM (Toronto time), a GitHub Actions workflow:

1. Fetches the 3-day forecast from the [Open-Meteo API](https://open-meteo.com/)
2. Checks for rain, snow, drizzle, freezing rain, or thunderstorms using WMO weather codes
3. Sends a push notification to your phone via [ntfy.sh](https://ntfy.sh) with one of three verdicts:

| Verdict | Meaning |
|---|---|
| **Good day for a wash** | No precipitation in the next 3 days. Go for it. |
| **Maybe worth a wash** | Tomorrow looks dry, but rain is coming. Wash at your own risk. |
| **Skip the wash** | Rain tomorrow. Save your energy. Take that nap. |

## The Web Dashboard

There's also a simple web page (hosted on GitHub Pages) that shows a 7-day forecast grid with temperatures, precipitation probability, and a clear recommendation banner at the top. Handy for when you want the full picture before committing to the bucket and sponge.

## The Constraints (a.k.a. the fun part)

This project was built under a strict set of "busy dad" constraints:

- **$0 budget.** Every API, service, and hosting platform used is completely free.
- **No server.** No backend, no database, no Docker, no cloud bill that surprises you at the end of the month. It's a static site on GitHub Pages and a cron job in GitHub Actions.
- **No frameworks.** Vanilla HTML, CSS, and JavaScript. Nothing to `npm install`, nothing to break when you come back to it 6 months later.
- **No authentication.** Open-Meteo doesn't need an API key. ntfy.sh doesn't need an account. GitHub Actions is just... there.
- **Minimal maintenance.** It should keep running even if I forget about it. (There's even a keepalive workflow that prevents GitHub from auto-disabling the scheduled actions.)

## Tech Stack

| What | Why |
|---|---|
| [Open-Meteo](https://open-meteo.com/) | Free weather API, no key required |
| [ntfy.sh](https://ntfy.sh) | Free push notifications, no account required |
| [GitHub Actions](https://github.com/features/actions) | Free scheduled workflows |
| [GitHub Pages](https://pages.github.com/) | Free static site hosting |
| Vanilla JS/HTML/CSS | Zero dependencies, zero build step |

## Getting Notifications

To receive the car wash verdicts on your phone:

1. Install the [ntfy app](https://ntfy.sh) (Android / iOS)
2. Subscribe to the topic listed in the workflow file
3. That's it. You'll get a push notification twice a day.

## Local Development

It's a static site. Open `index.html` in a browser. Done.

---

*Built by a dad who just wants a clean car and a dry forecast.*
