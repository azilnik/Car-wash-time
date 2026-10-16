# Accuracy

How the verdict is computed, why it changed in October 2026, and how it was tested against what actually fell.

## The decision

For a wash at `MORNING_HOUR` (8 AM) on the wash day, the script looks at four spans: the rest of today (8 AM to midnight) and the next three full days.

Each span is called **wet** or **dry**:

1. Each of three independent models (Canada's GEM, ECMWF IFS, NOAA's GFS) totals its hourly precipitation over the span. The **median** of those totals is the expected amount. Totals are summed per model first, so models that agree on a shower but disagree on its hour still count it.
2. Under **0.2 mm**: dry, whatever the probability says.
3. **1.5 mm** or more: wet.
4. In between: wet only if **30%+** of ensemble runs (GEM 21, ECMWF 51, GFS 31 members; each model's share computed separately, then averaged) produce at least 0.2 mm.
5. If no model covers at least three-quarters of the span's hours, the span is **unknown**, and the script sends nothing rather than guess.

Then: wet today or tomorrow → **Skip**; dry for two days, wet on day 2 or 3 → **Maybe**; all dry → **Good**. If the low between the wash and 10 AM the next morning drops below `MIN_WASH_TEMP_C`, it's **Too cold**, which overrides the rest.

The thresholds live in `Thresholds` in [`scripts/carwash.py`](../scripts/carwash.py).

## What was wrong before

| Problem | Effect |
|---|---|
| Today was never checked: the window started tomorrow | "Good day for a wash" while it was raining |
| Any WMO precip code in the daily summary meant wet. Open-Meteo's daily code is the worst hour, so one 0.01 mm hour gives code 51 | Dry days called wet |
| `precipitation_probability_max > 30` meant wet | Verdicts flipped as the peak hour wobbled across 30% between runs |
| Only `best_match`, which for Toronto is HRRR/GFS and leaves out GEM | One model's miss became the verdict. On 2026-10-16 it said 1.2 mm while GEM, ECMWF, ICON and NBM said 4–10 mm and Environment Canada said 10–15 mm |
| Missing values (`null`) and short responses counted as dry | False "good" |
| Day labels used UTC dates | Evening messages said "Today" for tomorrow |
| GitHub ran the `*/30` cron roughly every 5 hours. The morning slot ran 6 AM–9:30 PM and the evening slot 9:30 PM–6 AM | "Morning" pings arrived 9 AM–2:40 PM, "evening" pings 1–5 AM, and a late-night run judged the wrong days |

## Backtest

Ground truth comes from Environment and Climate Change Canada's daily totals at Toronto Pearson. As a cross-check, the Toronto City station (U of T, about 2 km from downtown) was also used. A day is observed wet at ≥ 0.5 mm.

Forecasts come from Open-Meteo's archives:

- the Previous Runs API: what `best_match` and GEM said 0–3 days ahead, Sep 2025–Oct 2026, 409 days;
- per-run archives: GEM, ECMWF and GFS for about 92 days.

Archived ensembles don't exist, so the backtest stands in `best_match`'s hourly precipitation probability for the in-between zone (see [`backtest.py`](../scripts/eval/backtest.py)).

A verdict is scored the way you'd experience it: the call made on the morning of day D versus the call the actual weather on D..D+3 would have produced.

| Full year, Pearson | Old (as shipped) | New |
|---|---|---|
| Verdict matched what happened | 67% | **80%** |
| Times it said "good" | 67 | 79 |
| …and it rained in the next 3 days | 27% | **16%** |
| …and it rained that day or the next | 24% | **6%** |
| Truly good windows it caught | 49 / 99 | **66 / 99** |
| Days called right, 1 day out | 84% | **86%** |
| Days called right, 3 days out | 70% | **77%** |
| Dry days called wet, 3 days out | 43% | **27%** |

With the true three-model median (92 days), "good" calls that busted dropped from 39% to 16%. Against the Toronto City gauge they dropped from 30% to 5%. The thresholds were picked from the Pareto front of bust rate versus good days caught. Within ±0.5 mm the results are stable, so they aren't overfit to one spike.

**What's left.** About 1 in 6 "good" calls still sees some rain within three days, usually light and two or three days out. Day-3 precipitation is genuinely hard to forecast. A dry day 3 days out was called wet about a quarter of the time; that's where "Maybe" comes from.

## Re-running it

`state.json` keeps a 90-day `history`: each morning's verdict and the per-day amounts and probabilities behind it. That's enough to score the live system against ECCC observations later. To re-run the threshold study, rebuild a dataset with the columns `backtest.py` reads (forecast per date and lead from the [Previous Runs API](https://open-meteo.com/en/docs/previous-runs-api), observations from [ECCC climate-daily](https://api.weather.gc.ca/collections/climate-daily)):

```bash
python3 scripts/eval/backtest.py dataset.csv --grid
```
