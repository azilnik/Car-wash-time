# AI-Powered Car Wash Recommendations — PRD & Technical Plan

## Context

**Problem:** The current car wash notification system uses simple if/else logic checking 3-day precipitation only. It always sends notifications twice daily regardless of whether the information is useful, and the messages are robotic (`code=80 precip=0.0mm prob=0%`).

**Goal:** Transform this into an AI-powered system that considers many more signals, only pings when it matters, and sends natural, human-readable messages — while staying fully serverless on GitHub Actions + ntfy.sh at zero/minimal cost.

---

## PRD: Product Requirements

### 1. AI-Powered Wash Recommendations

The system should analyze a rich set of signals to produce a nuanced recommendation:

| Signal | Source | Why It Matters |
|--------|--------|----------------|
| 7-day forecast ahead | Open-Meteo daily forecast | Find the best wash window in the week, not just "is tomorrow wet" |
| Past 7 days weather | Open-Meteo historical API | If it's rained all week, car is already dirty — washing now may not be worth it if more rain is coming |
| Hourly forecast (next 48h) | Open-Meteo hourly | Morning vs afternoon rain matters for "wash before work" |
| Temperature & wind | Open-Meteo daily | Below freezing = don't wash (ice). High wind = dust/debris |
| UV index | Open-Meteo daily | High UV can damage unwashed cars (baked-on dirt) |
| Air quality / particulate | Open-Meteo Air Quality API | High pollution = car gets dirty faster |
| Season awareness | Date-derived | Spring: pollen. Winter: road salt. Fall: leaves/sap. Summer: dust/bugs |
| Day of week | Date-derived | Weekend = more time for a wash. Friday = "fresh for the weekend" |
| Days since last wash suggestion | State file in repo | Don't nag, but also don't go silent for 2 weeks |

### 2. Smart Notification Gating

The system should **decide whether to notify at all**. Criteria:

- **Notify** when: a genuinely good wash window opens, conditions shift meaningfully, it's been 5+ days since last notification, or there's a time-sensitive opportunity ("rain stopping at noon, dry rest of week")
- **Stay silent** when: conditions unchanged from last check, forecast is ambiguous with no clear action, a notification was sent recently with same verdict
- **State tracking**: Store last notification timestamp, last verdict, and last weather summary hash in a JSON file committed to the repo

### 3. Dynamic Human-Readable Notifications

Replace template strings with AI-generated natural language. Examples:

- "Clear skies through Friday — perfect wash window. Spring pollen's been building up for 5 days."
- "Hold off. Freezing rain tonight, then snow Tuesday. Your car's gonna get salty anyway."
- "Quick wash today? Dry until Wednesday, then a wet stretch moves in. Get it while you can."
- "Not worth it this week. Rain every other day. Maybe next Monday."

Notifications should feel like a text from a friend, not a weather bot.

### 4. Constraints

- Serverless: GitHub Actions only
- Notifications: ntfy.sh
- Cost: Free or near-free (< $1/month)
- No databases — state via repo file commits

---

## Technical Plan

### Architecture Overview

```
GitHub Actions (cron)
  → Bash: fetch weather data (Open-Meteo forecast + historical + air quality)
  → Bash: read state file (last notification info)
  → Bash: call Claude API with structured prompt containing all signals
  → Claude returns JSON: { should_notify, title, message, tags, reasoning }
  → Bash: if should_notify → POST to ntfy.sh
  → Bash: update state file & commit
```

### AI Provider Decision: **Claude API (Haiku)**

**Why Claude Haiku:**
- Extremely low cost (~$0.25/million input tokens, $1.25/million output tokens)
- At 2 checks/day with ~1500 tokens input, ~200 tokens output = **~$0.003/month**
- Excellent at natural language generation and structured reasoning
- Can output JSON reliably
- The user is already in the Anthropic ecosystem

**Alternative considered:** Google Gemini free tier (1500 req/day) — viable but less reliable JSON output and the free tier could change. Claude Haiku is practically free and more predictable.

**API Key:** Stored as GitHub Actions secret `ANTHROPIC_API_KEY`

### Files to Create/Modify

#### 1. `.github/workflows/carwash-check.yml` — **Major rewrite**

Replace the simple bash script with an enhanced workflow:

```
Steps:
1. Checkout repo (needed to read/write state file)
2. Fetch all weather data (parallel curls)
3. Read state file (data/state.json)
4. Build AI prompt with all signals
5. Call Claude API
6. Parse response
7. If should_notify → send ntfy notification
8. Update state file
9. Commit & push state file changes
```

**Weather data fetched (all from Open-Meteo, all free, no API key):**

```bash
# 7-day daily forecast (expanded fields)
https://api.open-meteo.com/v1/forecast?latitude=...&longitude=...
  &daily=weather_code,temperature_2m_max,temperature_2m_min,
         precipitation_sum,precipitation_probability_max,
         wind_speed_10m_max,uv_index_max
  &timezone=auto&forecast_days=7

# 48-hour hourly forecast
https://api.open-meteo.com/v1/forecast?latitude=...&longitude=...
  &hourly=precipitation,precipitation_probability,temperature_2m,
          weather_code
  &timezone=auto&forecast_hours=48

# Past 7 days historical
https://api.open-meteo.com/v1/forecast?latitude=...&longitude=...
  &daily=weather_code,precipitation_sum,temperature_2m_max
  &timezone=auto&past_days=7&forecast_days=0

# Air quality
https://air-quality-api.open-meteo.com/v1/air-quality?latitude=...&longitude=...
  &current=pm2_5,pm10,us_aqi
  &hourly=pm2_5,pm10
  &forecast_days=2
```

**Claude API call structure:**

```bash
curl -s https://api.anthropic.com/v1/messages \
  -H "x-api-key: ${ANTHROPIC_API_KEY}" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 400,
    "messages": [{"role": "user", "content": "...prompt..."}]
  }'
```

**Prompt template (sent to Claude):**

```
You are a car wash advisor for someone in {city}. Based on the data below,
decide whether to send them a notification and what to say.

WEATHER FORECAST (next 7 days):
{daily_forecast_json}

HOURLY FORECAST (next 48h):
{hourly_summary}

PAST WEEK WEATHER:
{historical_json}

AIR QUALITY:
Current AQI: {aqi}, PM2.5: {pm25}

CONTEXT:
- Today: {day_of_week}, {date}
- Season: {season}
- Days since last notification: {days_since}
- Last notification verdict: {last_verdict}
- Last notification message: {last_message}
- Time of day: {morning_or_evening}

RULES:
- Only recommend notifying if there's actionable info they don't already have
- Consider: Is there a good wash window? Has weather shifted? Is it time-sensitive?
- Think about seasonal factors (spring pollen, winter salt, fall debris, summer dust/bugs)
- If it's been 5+ days with no notification, lean toward sending one even if just a status update
- Weekend proximity matters (Friday/Saturday = good wash days)
- Don't notify if you'd say the same thing as last time

Respond with ONLY this JSON (no markdown, no explanation):
{
  "should_notify": true/false,
  "title": "short title for notification",
  "message": "2-4 sentence natural message. Conversational, like a friend texting.",
  "tags": "car,emoji_tag",
  "reasoning": "one line explaining your decision (for logging)"
}
```

#### 2. `data/state.json` — **New file** (committed to repo)

```json
{
  "last_notification_at": "2025-03-26T11:00:00Z",
  "last_verdict": "good",
  "last_message_hash": "a1b2c3",
  "last_message": "Clear skies through Thursday...",
  "consecutive_skips": 0
}
```

**State update flow:**
- After each run, the workflow updates `data/state.json`
- If a notification was sent: update all fields, reset `consecutive_skips` to 0
- If notification was skipped: increment `consecutive_skips`
- Commit with `[bot] update state` message using `git commit --allow-empty-message` with GitHub Actions bot credentials

#### 3. `app.js` — **Moderate update**

- Update `fetchForecast()` to request expanded fields (wind, UV)
- Update `analyzeForecast()` to pass data to a new `generateAISummary()` function for the frontend
- For the frontend, keep the rule-based verdict (no API call from browser — no key exposure) but improve the display
- Add display of wind speed, UV index, air quality on forecast cards
- Update notification format in the frontend test button

#### 4. `index.html` / `style.css` — **Minor updates**

- Add new data fields to forecast cards (wind, UV, AQI)
- Update status banner text to be more conversational

#### 5. `.github/workflows/carwash-check.yml` — **Permissions update**

Add `contents: write` permission so the workflow can commit state file changes:

```yaml
permissions:
  contents: write
```

### Notification Flow

```
6:00 AM EST / 9:30 PM EST (cron triggers)
  │
  ├─ Fetch: 7-day forecast, 48h hourly, past 7 days, air quality
  ├─ Read: data/state.json
  ├─ Build prompt with all signals + state context
  ├─ Call Claude Haiku API
  │
  ├─ Claude responds: { should_notify: true/false, title, message, tags }
  │
  ├─ IF should_notify:
  │   ├─ POST to ntfy.sh with title/message/tags
  │   └─ Update state.json (timestamp, verdict, message hash)
  │
  ├─ IF NOT should_notify:
  │   └─ Update state.json (increment consecutive_skips)
  │
  └─ Commit & push state.json
```

### ntfy Notification Format (examples)

**Title:** "Wash window opening up" / "Skip it this week" / "Quick wash today?"
**Tags:** `car,sparkles` / `car,umbrella` / `car,sun_with_face` / `car,thinking`
**Body:**
```
Clear skies through Friday and temps in the low 20s — perfect
wash weather. Spring pollen count is high this week, so your car
could use it. Saturday morning looks ideal if you want to wait
for the weekend.
```

### Cost Analysis

| Item | Monthly Cost |
|------|-------------|
| Claude Haiku API (~60 calls/month, ~1500 tok in, ~300 tok out) | ~$0.003 |
| Open-Meteo API | Free |
| ntfy.sh | Free |
| GitHub Actions (~60 runs × 30s) | Free (within 2000 min/month) |
| **Total** | **< $0.01/month** |

### GitHub Secrets Required

| Secret | Value |
|--------|-------|
| `ANTHROPIC_API_KEY` | Anthropic API key for Claude Haiku |

(ntfy topic and coordinates stay as env vars — they're not sensitive)

### Implementation Steps

1. **Add `data/state.json`** — Create initial state file
2. **Rewrite `.github/workflows/carwash-check.yml`** — Full replacement with:
   - Repo checkout step
   - Expanded weather data fetching (4 API calls)
   - State file reading
   - Season/context calculation
   - Claude API prompt construction & call
   - Response parsing (jq)
   - Conditional ntfy notification
   - State file update
   - Git commit & push
3. **Update `app.js`** — Expanded forecast fields, improved UI messaging
4. **Update `index.html`** — Add new data display elements
5. **Update `style.css`** — Style new forecast card fields
6. **Update `README.md`** — Document new AI-powered features and setup (ANTHROPIC_API_KEY secret)

### Key Implementation Details

**Season detection (bash):**
```bash
MONTH=$(date +%m)
case $MONTH in
  03|04|05) SEASON="spring (pollen, rain, mud)" ;;
  06|07|08) SEASON="summer (dust, bugs, UV damage)" ;;
  09|10|11) SEASON="fall (leaves, sap, early frost)" ;;
  12|01|02) SEASON="winter (road salt, slush, freezing)" ;;
esac
```

**State file git commit (in workflow):**
```bash
git config user.name "car-wash-bot"
git config user.email "bot@carwashtime"
git add data/state.json
git diff --staged --quiet || git commit -m "[bot] update wash state" && git push
```

**Fallback if Claude API fails:**
- Fall back to the existing simple 3-tier logic
- Always notify on fallback (don't silently fail)
- Log the error in the workflow

**Message hash for dedup:**
```bash
echo "$VERDICT|$FORECAST_HASH" | md5sum | cut -c1-8
```

### Verification Plan

1. **Manual trigger**: Run workflow via `workflow_dispatch` and verify:
   - All 4 weather API calls succeed
   - Claude API returns valid JSON
   - Notification arrives on phone via ntfy
   - State file is updated and committed
2. **Test notification gating**: Run twice in quick succession — second run should skip notification (same conditions, recent notification)
3. **Test fallback**: Temporarily use invalid API key — should fall back to simple logic
4. **Frontend**: Load GitHub Pages site, verify expanded forecast cards show wind/UV data
5. **Cost monitoring**: Check Anthropic dashboard after a week to verify costs match estimates

### Critical Files

| File | Action |
|------|--------|
| `.github/workflows/carwash-check.yml` | Major rewrite |
| `data/state.json` | New file |
| `app.js` | Moderate update (expanded fields, UI) |
| `index.html` | Minor update (new card fields) |
| `style.css` | Minor update (new card styles) |
