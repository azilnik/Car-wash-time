"""Tests for scripts/carwash.py. Offline: no network, no notifications.

    python3 -m unittest discover -s scripts/tests -v
"""

import datetime as dt
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import carwash as c  # noqa: E402

if not os.environ.get("VERBOSE"):
    c.log = lambda msg: None

TODAY = dt.date(2026, 10, 16)  # a Friday
EDT = -4 * 3600


# ── Fixture builders ────────────────────────────────────────────────
def make_det(hours_mm, temps=None, codes=None, start=TODAY, models=("gem_seamless", "ecmwf_ifs025", "gfs_seamless"),
             offset=EDT):
    """Deterministic multi-model response. `hours_mm` is either a list of
    hourly mm (same for every model) or {model: list}."""
    if not isinstance(hours_mm, dict):
        hours_mm = {m: hours_mm for m in models}
    n = len(next(iter(hours_mm.values())))
    t0 = dt.datetime.combine(start, dt.time())
    hourly = {"time": [(t0 + dt.timedelta(hours=i)).isoformat(timespec="minutes") for i in range(n)]}
    for m, series in hours_mm.items():
        hourly[f"precipitation_{m}"] = series
        hourly[f"temperature_2m_{m}"] = temps if temps is not None else [10.0] * n
        hourly[f"weather_code_{m}"] = codes if codes is not None else [63 if (v or 0) > 0 else 1 for v in series]
    return {"utc_offset_seconds": offset, "hourly": hourly}


def make_ens(member_mm_by_model, start=TODAY):
    """{model: [series, series, ...]} → ensemble response."""
    first = next(iter(member_mm_by_model.values()))[0]
    t0 = dt.datetime.combine(start, dt.time())
    hourly = {"time": [(t0 + dt.timedelta(hours=i)).isoformat(timespec="minutes") for i in range(len(first))]}
    for model, members in member_mm_by_model.items():
        for k, series in enumerate(members):
            key = f"precipitation_{model}" if k == 0 else f"precipitation_member{k:02d}_{model}"
            hourly[key] = series
    return {"utc_offset_seconds": EDT, "hourly": hourly}


def days_pattern(pattern, wet_hour=14, mm=3.0):
    """'DDWD…' → hourly mm series, one char per day starting TODAY.
    W puts `mm` at wet_hour local; D is bone dry."""
    out = []
    for ch in pattern:
        day = [0.0] * 24
        if ch == "W":
            day[wet_hour] = mm
        elif ch != "D":
            raise ValueError(ch)
        out += day
    return out


def verdict(pattern, wash_day=TODAY, ens=None, **kw):
    fc = c.parse_forecast(make_det(days_pattern(pattern)), ens)
    return c.decide(fc, wash_day, **kw)


# ── Decision logic ──────────────────────────────────────────────────
class DecideTests(unittest.TestCase):
    def test_all_dry_is_good(self):
        v = verdict("DDDDDDDD")
        self.assertEqual(v.kind, "good")
        self.assertEqual(c.compose(v)[1], "Dry all week. Go for it.")

    def test_rain_today_is_skip(self):
        # The old script ignored today entirely and said "good" here.
        v = verdict("WDDDDDDD")
        self.assertEqual(v.kind, "no")
        self.assertTrue(c.compose(v)[1].startswith("Rain today"))

    def test_rain_before_wash_hour_today_does_not_count(self):
        fc = c.parse_forecast(make_det(days_pattern("WDDDDDDD", wet_hour=5)))
        self.assertEqual(c.decide(fc, TODAY, wash_hour=8).kind, "good")

    def test_rain_this_evening_counts(self):
        fc = c.parse_forecast(make_det(days_pattern("WDDDDDDD", wet_hour=22)))
        self.assertEqual(c.decide(fc, TODAY).kind, "no")

    def test_rain_tomorrow_is_skip(self):
        v = verdict("DWDDDDDD")
        self.assertEqual(v.kind, "no")
        body = c.compose(v)[1]
        self.assertIn("Rain tomorrow", body)
        self.assertIn("Next dry stretch: Sun onward (6 days)", body)

    def test_rain_day_2_or_3_is_maybe(self):
        for pattern, label in (("DDWDDDDD", "Sun"), ("DDDWDDDD", "Mon")):
            v = verdict(pattern)
            self.assertEqual(v.kind, "maybe", pattern)
            self.assertIn(f"then rain {label}", c.compose(v)[1])

    def test_rain_day_4_is_still_good(self):
        v = verdict("DDDDWDDD")
        self.assertEqual(v.kind, "good")
        self.assertEqual(c.compose(v)[1], "Dry today and the next 3 days. Go for it.")

    def test_long_dry_stretch_named(self):
        v = verdict("DDDDDDWD")
        self.assertEqual(c.compose(v)[1], "Dry for the next 5 days. Go for it.")

    def test_single_dry_day_hint(self):
        v = verdict("DWWDWWWW")
        self.assertIn("Next dry day: Mon.", c.compose(v)[1])

    def test_no_dry_day_no_hint(self):
        v = verdict("WWWWWWWW")
        self.assertNotIn("Next", c.compose(v)[1])

    def test_wash_day_tomorrow_shifts_window(self):
        # Evening/late-night planning: wash day is tomorrow, so today's rain
        # is irrelevant and labels are relative to the wash day.
        v = verdict("WDDDDDDD", wash_day=TODAY + dt.timedelta(days=1))
        self.assertEqual(v.kind, "good")
        v = verdict("WDWDDDDD", wash_day=TODAY + dt.timedelta(days=1))
        self.assertEqual(v.kind, "no")
        self.assertIn("Rain tomorrow", c.compose(v)[1])


class ThresholdTests(unittest.TestCase):
    def fc_with(self, mm, ens=None):
        return c.parse_forecast(make_det(days_pattern("DWDDDDDD", mm=mm)), ens)

    def test_trace_is_dry(self):
        # One hour of 0.1 mm used to flag the whole day via weather code 51.
        self.assertEqual(c.decide(self.fc_with(0.1), TODAY).kind, "good")

    def test_amount_over_wet_mm_is_wet(self):
        self.assertEqual(c.decide(self.fc_with(1.0), TODAY).kind, "no")

    def test_in_between_needs_ensemble_support(self):
        self.assertEqual(c.decide(self.fc_with(0.5), TODAY).kind, "good")
        n = 24 * 8
        wet = [0.0] * 24 + [0.0] * 14 + [2.0] + [0.0] * (n - 39)
        dry = [0.0] * n
        ens = make_ens({"gem_global_ensemble": [wet, wet, dry], "ecmwf_ifs025_ensemble": [wet, dry, dry, dry]})
        # mean of 2/3 and 1/4 = 0.458 < 0.5 → dry
        self.assertEqual(c.decide(self.fc_with(0.5, ens), TODAY).kind, "good")
        ens = make_ens({"gem_global_ensemble": [wet, wet, dry], "ecmwf_ifs025_ensemble": [wet, wet, dry, dry]})
        # mean of 2/3 and 2/4 = 0.583 → wet
        self.assertEqual(c.decide(self.fc_with(0.5, ens), TODAY).kind, "no")

    def test_ensemble_alone_cannot_override_bone_dry_models(self):
        n = 24 * 8
        wet = [0.0] * 38 + [5.0] + [0.0] * (n - 39)
        ens = make_ens({"gem_global_ensemble": [wet] * 5})
        self.assertEqual(c.decide(self.fc_with(0.0, ens), TODAY).kind, "good")

    def test_one_outlier_model_cannot_flip_the_call(self):
        dry = days_pattern("DDDDDDDD")
        wet = days_pattern("DWDDDDDD", mm=10)
        fc = c.parse_forecast(make_det({"gem_seamless": wet, "ecmwf_ifs025": dry, "gfs_seamless": dry}))
        self.assertEqual(c.decide(fc, TODAY).kind, "good")
        fc = c.parse_forecast(make_det({"gem_seamless": wet, "ecmwf_ifs025": wet, "gfs_seamless": dry}))
        self.assertEqual(c.decide(fc, TODAY).kind, "no")

    def test_models_disagreeing_on_timing_still_count(self):
        # Each model rains at a different hour; an hourly median would be 0.
        a = days_pattern("DWDDDDDD", wet_hour=9, mm=2)
        b = days_pattern("DWDDDDDD", wet_hour=13, mm=2)
        d = days_pattern("DWDDDDDD", wet_hour=17, mm=2)
        fc = c.parse_forecast(make_det({"gem_seamless": a, "ecmwf_ifs025": b, "gfs_seamless": d}))
        self.assertEqual(c.decide(fc, TODAY).kind, "no")


class FreezeTests(unittest.TestCase):
    def fc(self, temps):
        return c.parse_forecast(make_det(days_pattern("DDDDDDDD"), temps=temps))

    def test_cold_night_after_wash_freezes(self):
        temps = [5.0] * (24 * 8)
        temps[24 + 4] = -8.0  # 4 AM tomorrow
        v = c.decide(self.fc(temps), TODAY)
        self.assertEqual(v.kind, "freeze")
        self.assertEqual(c.compose(v)[1], "Tonight drops to -8°C; a fresh wash would freeze on the car.")

    def test_cold_morning_before_wash_does_not_count(self):
        temps = [5.0] * (24 * 8)
        temps[4] = -12.0  # 4 AM today, before the wash
        self.assertEqual(c.decide(self.fc(temps), TODAY).kind, "good")

    def test_threshold_is_configurable(self):
        temps = [5.0] * (24 * 8)
        temps[24 + 4] = -8.0
        self.assertEqual(c.decide(self.fc(temps), TODAY, min_wash_temp_c=-10).kind, "good")

    def test_rounding_never_shows_minus_zero(self):
        temps = [5.0] * (24 * 8)
        temps[24 + 4] = -0.4
        v = c.decide(self.fc(temps), TODAY, min_wash_temp_c=0)
        self.assertEqual(c.compose(v)[1], "Tonight drops to 0°C; a fresh wash would freeze on the car.")


class BadDataTests(unittest.TestCase):
    def test_nulls_in_window_are_unknown_not_dry(self):
        series = days_pattern("DDDDDDDD")
        series = [None] * 48 + series[48:]
        fc = c.parse_forecast(make_det(series))
        self.assertEqual(c.decide(fc, TODAY).kind, "unknown")

    def test_one_model_missing_is_fine(self):
        dry = days_pattern("DDDDDDDD")
        fc = c.parse_forecast(make_det({"gem_seamless": dry, "ecmwf_ifs025": dry, "gfs_seamless": [None] * len(dry)}))
        self.assertEqual(c.decide(fc, TODAY).kind, "good")

    def test_short_forecast_is_unknown(self):
        fc = c.parse_forecast(make_det(days_pattern("DD")))
        self.assertEqual(c.decide(fc, TODAY).kind, "unknown")

    def test_missing_hourly_raises(self):
        with self.assertRaises(c.DataError):
            c.parse_forecast({"utc_offset_seconds": 0})
        with self.assertRaises(c.DataError):
            c.parse_forecast({"hourly": {"time": []}})

    def test_unknown_has_no_message(self):
        with self.assertRaises(ValueError):
            c.compose(c.Verdict("unknown", TODAY, []))


class FuzzTests(unittest.TestCase):
    def test_random_forecasts_never_crash(self):
        import random
        rng = random.Random(1234)
        choices = [None, 0.0, 0.0, 0.0, 0.1, 0.4, 1.5, 12.0]
        for _ in range(300):
            n = rng.choice([24, 47, 100, 24 * 8, 24 * 8 + 5])
            models = {m: [rng.choice(choices) for _ in range(n)] for m in ("a", "b", "c")[: rng.randint(1, 3)]}
            temps = [rng.choice([None, -20.0, -3.0, 0.0, 5.0, 25.0]) for _ in range(n)]
            codes = [rng.choice([None, 0, 3, 45, 51, 63, 71, 95, 99]) for _ in range(n)]
            ens = None
            if rng.random() < 0.5:
                ens = make_ens({"gem_global_ensemble": [[rng.choice(choices) for _ in range(n)] for _ in range(4)]})
            fc = c.parse_forecast(make_det(models, temps=temps, codes=codes), ens)
            for wash_day in (TODAY, TODAY + dt.timedelta(days=1), TODAY + dt.timedelta(days=9)):
                v = c.decide(fc, wash_day, wash_hour=rng.choice([0, 6.5, 8, 23.5]))
                self.assertIn(v.kind, {"good", "maybe", "no", "freeze", "unknown"})
                if v.kind != "unknown":
                    title, body, tags = c.compose(v)
                    self.assertTrue(title and body and tags)
                    self.assertNotIn("None", body)


class CategoryTests(unittest.TestCase):
    def test_categories(self):
        self.assertEqual(c.category_for([1, 63], 10), "rain")
        self.assertEqual(c.category_for([73, 63], 0), "snow")
        self.assertEqual(c.category_for([67], 0), "freezing rain")
        self.assertEqual(c.category_for([95, 63], 20), "thunderstorms")
        self.assertEqual(c.category_for([99], 20), "hail")
        self.assertEqual(c.category_for([3], -4), "snow")
        self.assertEqual(c.category_for([3], 5), "rain")

    def test_snow_message(self):
        n = 24 * 8
        mm = days_pattern("DWDDDDDD")
        codes = [73 if v else 3 for v in mm]
        fc = c.parse_forecast(make_det(mm, temps=[-1.0] * n, codes=codes))
        v = c.decide(fc, TODAY, min_wash_temp_c=-100)
        self.assertTrue(c.compose(v)[1].startswith("Snow tomorrow"))


# ── Scheduling ─────────────────────────────────────────────────────
def at(day_offset, h, m=0):
    return dt.datetime.combine(TODAY + dt.timedelta(days=day_offset), dt.time(h, m))


class PlanTests(unittest.TestCase):
    def plan(self, now, last=""):
        return c.plan_run(now, 8.0, 8.0, 3.0, last)

    def test_prep_window_schedules_for_8am(self):
        for h in (0, 3, 7):
            p = self.plan(at(0, h, 30))
            self.assertEqual((p.action, p.wash_day, p.deliver_at_local), ("schedule", TODAY, at(0, 8)))

    def test_late_window_sends_now(self):
        p = self.plan(at(0, 9, 15))
        self.assertEqual((p.action, p.wash_day), ("send_late", TODAY))

    def test_after_late_window_skips(self):
        # The old script would happily send a "morning" verdict at 9 PM.
        self.assertEqual(self.plan(at(0, 11, 0)).action, "skip")
        self.assertEqual(self.plan(at(0, 21, 0)).action, "skip")

    def test_already_handled_skips(self):
        self.assertEqual(self.plan(at(0, 6), last=TODAY.isoformat()).action, "skip")
        self.assertEqual(self.plan(at(0, 9), last=TODAY.isoformat()).action, "skip")

    def test_late_evening_prep_for_next_day(self):
        p = c.plan_run(at(0, 23, 30), 8.0, 10.0, 3.0, TODAY.isoformat())
        self.assertEqual((p.action, p.wash_day), ("schedule", TODAY + dt.timedelta(days=1)))

    def test_custom_hour(self):
        p = c.plan_run(at(0, 6, 45), 6.5, 8.0, 3.0, "")
        self.assertEqual(p.action, "send_late")
        self.assertEqual(p.deliver_at_local, at(0, 6, 30))


class ConfigTests(unittest.TestCase):
    def test_defaults(self):
        cfg = c.load_config({"NTFY_TOPIC": "t", "LOCATION": "Toronto"})
        self.assertEqual(cfg.morning_hour, 8.0)

    def test_bad_values_fail_loudly(self):
        for bad in ("6:30", "abc", "24", "-1", "nan"):
            with self.assertRaises(c.ConfigError, msg=bad):
                c.load_config({"NTFY_TOPIC": "t", "LOCATION": "x", "MORNING_HOUR": bad})

    def test_requires_topic_and_location(self):
        with self.assertRaises(c.ConfigError):
            c.load_config({"LOCATION": "x"})
        with self.assertRaises(c.ConfigError):
            c.load_config({"NTFY_TOPIC": "t"})
        c.load_config({"NTFY_TOPIC": "t", "LATITUDE": "1", "LONGITUDE": "2"})


# ── End to end (fetch + notify stubbed) ────────────────────────────
class RunTests(unittest.TestCase):
    def setUp(self):
        self.sent = []
        self.fetches = 0
        self.cfg = c.load_config({"NTFY_TOPIC": "t", "LATITUDE": "43.65", "LONGITUDE": "-79.38"})
        self.pattern = "DDDDDDDD"

    def fetch(self, lat, lon, cfg):
        self.fetches += 1
        return c.parse_forecast(make_det(days_pattern(self.pattern)))

    def notify(self, topic, title, body, tags, deliver_at=None):
        self.sent.append((title, body, deliver_at))

    def run_at(self, local, state, cfg=None):
        utc = (local - dt.timedelta(seconds=EDT)).replace(tzinfo=dt.timezone.utc)
        return c.run(cfg or self.cfg, state, now_utc=utc, fetch=self.fetch, notify=self.notify)

    def test_schedules_once_for_exactly_8am(self):
        s = self.run_at(at(0, 3, 12), {})
        self.assertEqual(len(self.sent), 1)
        title, body, deliver_at = self.sent[0]
        self.assertEqual(title, "☀️ Good day for a wash")
        expected = (at(0, 8) - dt.timedelta(seconds=EDT)).replace(tzinfo=dt.timezone.utc).timestamp()
        self.assertEqual(deliver_at, int(expected))
        self.assertEqual(s["last_handled_date"], TODAY.isoformat())
        # Later firings the same morning do nothing, and don't even fetch.
        s2 = self.run_at(at(0, 6, 40), s)
        s3 = self.run_at(at(0, 9, 5), s2)
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(s3, s)
        self.assertEqual(self.fetches, 1)

    def test_dst_change_overnight_still_delivers_at_8(self):
        # 2026-11-01: Toronto falls back at 2 AM. A 1 AM EDT run must
        # schedule for 8 AM EST (13:00Z), not 8 AM EDT (12:00Z).
        def fetch(lat, lon, cfg):
            det = make_det(days_pattern("DDDDDDDD"), start=dt.date(2026, 11, 1))
            det["timezone"] = "America/Toronto"
            return c.parse_forecast(det)
        now = dt.datetime(2026, 11, 1, 5, 0, tzinfo=dt.timezone.utc)  # 1:00 AM EDT
        c.run(self.cfg, {}, now_utc=now, fetch=fetch, notify=self.notify)
        self.assertEqual(self.sent[0][2], int(dt.datetime(2026, 11, 1, 13, 0, tzinfo=dt.timezone.utc).timestamp()))

    def test_skip_outside_window_without_fetching(self):
        s = self.run_at(at(0, 3), {})
        n = self.fetches
        self.run_at(at(0, 14), s)
        self.run_at(at(0, 20), s)
        self.assertEqual(self.fetches, n)

    def test_late_send_is_immediate_and_labelled(self):
        self.run_at(at(0, 9, 30), {})
        title, body, deliver_at = self.sent[0]
        self.assertIsNone(deliver_at)
        self.assertIn("(Late: forecast checked 9:30 AM.)", body)

    def test_repeated_skip_is_quiet_but_good_repeats(self):
        self.pattern = "WWWWWWWW"
        s = self.run_at(at(0, 5), {})
        self.assertEqual(len(self.sent), 1)
        s = self.run_at(at(1, 5), s)
        self.assertEqual(len(self.sent), 1)  # still "no": quiet
        self.assertEqual(s["history"][-1]["notified"], False)
        self.pattern = "DDDDDDDD"
        s = self.run_at(at(2, 5), s)
        s = self.run_at(at(3, 5), s)
        self.assertEqual([t for t, _, _ in self.sent[1:]], ["☀️ Good day for a wash"] * 2)

    def test_force_and_dry_run_never_consume_the_slot(self):
        cfg = c.load_config({"NTFY_TOPIC": "t", "LATITUDE": "1", "LONGITUDE": "2", "FORCE_RUN": "true"})
        s = self.run_at(at(0, 14), {}, cfg)
        self.assertNotIn("last_handled_date", s)
        self.assertNotIn("last_notified_verdict", s)
        self.assertEqual(len(self.sent), 1)
        self.assertIsNone(self.sent[0][2])
        cfg = c.load_config({"NTFY_TOPIC": "t", "LATITUDE": "1", "LONGITUDE": "2", "DRY_RUN": "true"})
        s = self.run_at(at(0, 5), {}, cfg)
        self.assertEqual(len(self.sent), 1)
        self.assertNotIn("last_handled_date", s)

    def test_unknown_forecast_sends_nothing(self):
        def fetch(lat, lon, cfg):
            return c.parse_forecast(make_det([None] * 48 + [0.0] * 150))
        utc = (at(0, 5) - dt.timedelta(seconds=EDT)).replace(tzinfo=dt.timezone.utc)
        s = c.run(self.cfg, {}, now_utc=utc, fetch=fetch, notify=self.notify)
        self.assertEqual(self.sent, [])
        self.assertEqual(s["history"][-1]["verdict"], "unknown")

    def test_history_is_bounded(self):
        s = {}
        for d in range(c.HISTORY_LIMIT + 5):
            s = self.run_at(at(d, 5), s)
        self.assertEqual(len(s["history"]), c.HISTORY_LIMIT)

    def test_legacy_state_is_accepted(self):
        legacy = {"last_verdict": "good", "last_notified_verdict": "good",
                  "last_morning_slot_date": "2026-10-15", "location_query": "Toronto, Ontario"}
        s = self.run_at(at(0, 5), legacy)
        self.assertEqual(s["last_handled_date"], TODAY.isoformat())

    def test_state_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "state.json")
            self.assertEqual(c.load_state(path), {})
            with open(path, "w") as f:
                f.write("{not json")
            self.assertEqual(c.load_state(path), {})
            s = self.run_at(at(0, 5), {})
            c.save_state(s, path)
            self.assertEqual(c.load_state(path), json.loads(json.dumps(s)))


if __name__ == "__main__":
    unittest.main()
