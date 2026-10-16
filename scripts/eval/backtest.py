#!/usr/bin/env python3
"""Backtest the wet-day rule against what actually fell.

Input is a per-day dataset of archived forecasts joined with Environment
Canada observations (see docs/accuracy.md for how it was built):

    python3 scripts/eval/backtest.py dataset.csv [--grid]

Two levels are scored:
  day     — is each forecast day (lead 0-3) called wet/dry correctly?
  verdict — for each date as wash day, the good/maybe/skip call made that
            morning (lead 0 for today, lead k for day k) vs the call the
            observations would have produced. "Bust" = we said good and
            it rained within the window; "missed" = we said skip and the
            whole window stayed dry.

The rule mirrors carwash.assess_span: median of per-model day totals,
wet at >= wet_mm, dry below floor_mm, and in between wet only when the
probability signal agrees.
"""

import argparse
import csv
import os
import statistics
import sys
from collections import defaultdict
from datetime import date, timedelta

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from carwash import DEFAULT_THRESHOLDS as TH  # noqa: E402

OBS_WET_MM = 0.5
# Archived ensembles aren't available, so the backtest stands in
# best_match's max hourly precipitation_probability (share of members
# with >0.1 mm in an hour). A day's chance of *any* measurable rain is at
# least its peak hourly chance, which is why the live ensemble threshold
# (P(day >= 0.2 mm) >= 0.3) sits a little above this proxy's 0.2.
PROXY_PROB = 0.2


def load(path, models, prob_model):
    fc = defaultdict(dict)      # (date, lead) -> {model: mm}
    prob = {}                   # (date, lead) -> 0-1
    obs = {}
    old = {}                    # (date, lead) -> old check.sh rule (best_match)
    with open(path) as f:
        for r in csv.DictReader(f):
            d, lead = date.fromisoformat(r["date"]), int(r["lead_days"])
            if r["obs_total_precip_mm"] != "":
                obs[d] = float(r["obs_total_precip_mm"]) >= OBS_WET_MM
            key = f'{r["source"]}:{r["model"]}'
            if key in models and r["fc_precip_sum"] != "" and int(r["fc_hours"] or 0) >= 18:
                fc[(d, lead)][key] = float(r["fc_precip_sum"])
            if key == prob_model and r["fc_prob_max"] != "":
                prob[(d, lead)] = float(r["fc_prob_max"]) / 100
            if key == "openmeteo_prev:best_match" and r["rule_wet_checksh"] != "":
                old[(d, lead)] = r["rule_wet_checksh"] == "1"
    return fc, prob, obs, old


def rule(mm_by_model, p, wet_mm, floor_mm, wet_prob, need):
    if len(mm_by_model) < need:
        return None
    mm = statistics.median(mm_by_model.values())
    if mm < floor_mm:
        return False
    if mm >= wet_mm:
        return True
    return p is not None and p >= wet_prob


def verdict(days):
    """days: wet flags for wash day + 3 → good/maybe/no (None if unknown)."""
    if any(x is None for x in days):
        return None
    if days[0] or days[1]:
        return "no"
    return "maybe" if any(days[2:]) else "good"


def score(pred_fn, obs, dates):
    day = defaultdict(lambda: [0, 0, 0, 0])  # lead -> TP FP FN TN
    v = defaultdict(int)
    for d in dates:
        flags = []
        for k in range(4):
            p, o = pred_fn(d + timedelta(days=k), k), obs.get(d + timedelta(days=k))
            flags.append(p)
            if p is None or o is None:
                continue
            day[k][0 if (p and o) else 1 if (p and not o) else 2 if (o and not p) else 3] += 1
        pv = verdict(flags)
        ov = verdict([obs.get(d + timedelta(days=k)) for k in range(4)])
        if pv is None or ov is None:
            continue
        v["n"] += 1
        v[f"said_{pv}"] += 1
        v["exact"] += pv == ov
        if pv == "good":
            v["bust"] += ov != "good"
            v["bust_hard"] += ov == "no"
        if pv == "no":
            v["missed"] += ov == "good"
        v["obs_good"] += ov == "good"
        v["caught_good"] += pv == "good" and ov == "good"
    return day, v


def fmt(day, v):
    out = []
    for k in range(4):
        tp, fp, fn, tn = day[k]
        n = tp + fp + fn + tn
        if n:
            out.append(f"  lead {k}: n={n:3d} acc={(tp+tn)/n:.2f} "
                       f"rain-missed={fn/max(tp+fn,1):.2f} dry-called-wet={fp/max(fp+tn,1):.2f}")
    n = v["n"] or 1
    out.append(f"  verdicts n={v['n']}: exact={v['exact']/n:.2f}  said good {v['said_good']}x, "
               f"busted {v['bust']} ({v['bust']/max(v['said_good'],1):.0%}; rain today/tomorrow {v['bust_hard']})  "
               f"said skip {v['said_no']}x, window was fully dry {v['missed']}  "
               f"good days caught {v['caught_good']}/{v['obs_good']}")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset")
    ap.add_argument("--grid", action="store_true", help="search thresholds")
    a = ap.parse_args()

    configs = {
        "full year: best_match + gem_seamless (Previous Runs API)": (
            ["openmeteo_prev:best_match", "openmeteo_prev:gem_seamless"], "openmeteo_prev:best_match", 2),
        "92 days: GEM + ECMWF + GFS median (per-run archive)": (
            ["s3_run:cmc_gem_gdps_15km", "s3_run:ecmwf_ifs025", "s3_run:ncep_gfs013"], "openmeteo_prev:best_match", 2),
    }
    for name, (models, pm, need) in configs.items():
        fc, prob, obs, old = load(a.dataset, models, pm)
        dates = sorted({d for (d, k) in fc if k == 0})
        print(f"\n=== {name} ===")
        print("old check.sh rule as shipped (best_match, today ignored):")
        print(fmt(*score(lambda d, k: False if k == 0 else old.get((d, k)), obs, dates)))
        print(f"new rule (median >= {TH.wet_mm} mm wet, < {TH.floor_mm} mm dry, prob >= {PROXY_PROB} in between):")
        print(fmt(*score(lambda d, k: rule(fc.get((d, k), {}), prob.get((d, k)), TH.wet_mm, TH.floor_mm, PROXY_PROB, need)
                         if (d, k) in fc else None, obs, dates)))
        if a.grid:
            rows = []
            for wet_mm in (0.5, 0.8, 1.0, 1.5, 2.0, 3.0):
                for floor in (0.1, 0.2, 0.3, 0.5):
                    for wp in (0.3, 0.5, 0.7, 0.9, 1.01):
                        if floor > wet_mm:
                            continue
                        _, v = score(lambda d, k: rule(fc.get((d, k), {}), prob.get((d, k)), wet_mm, floor, wp, need)
                                     if (d, k) in fc else None, obs, dates)
                        if v["n"]:
                            rows.append((v["exact"] / v["n"], v["bust"] / max(v["said_good"], 1),
                                         v["caught_good"] / max(v["obs_good"], 1), wet_mm, floor, wp))
            rows.sort(reverse=True)
            print("  top by exact verdict match: exact, bust-rate, good-days-caught, wet_mm, floor, prob")
            for r in rows[:12]:
                print("   ", " ".join(f"{x:.2f}" for x in r))


if __name__ == "__main__":
    sys.exit(main())
