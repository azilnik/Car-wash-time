// ── Config (hardcoded) ─────────────────────────────────────────────
const LATITUDE = 43.7232;
const LONGITUDE = -79.4331;
const NTFY_TOPIC = "zilnik-carwash-uTPEjc0f2q8uuKbP";
const DRY_DAYS = 3;

const OPEN_METEO_URL = "https://api.open-meteo.com/v1/forecast";
const AIR_QUALITY_URL = "https://air-quality-api.open-meteo.com/v1/air-quality";
const NTFY_URL = "https://ntfy.sh";

// WMO weather codes that indicate precipitation
const PRECIPITATION_CODES = new Set([
    51, 53, 55,       // drizzle (light, moderate, dense)
    56, 57,           // freezing drizzle
    61, 63, 65,       // rain (slight, moderate, heavy)
    66, 67,           // freezing rain
    71, 73, 75,       // snowfall (slight, moderate, heavy)
    77,               // snow grains
    80, 81, 82,       // rain showers
    85, 86,           // snow showers
    95,               // thunderstorm
    96, 99,           // thunderstorm with hail
]);

// ── Logging ────────────────────────────────────────────────────────
function log(message) {
    const el = document.getElementById("log-output");
    const ts = new Date().toLocaleTimeString();
    const entry = document.createElement("div");
    entry.className = "log-entry";
    entry.textContent = `[${ts}] ${message}`;

    const placeholder = el.querySelector(".placeholder-text");
    if (placeholder) placeholder.remove();

    el.prepend(entry);
}

// ── Weather fetching ───────────────────────────────────────────────
async function fetchForecast() {
    const params = new URLSearchParams({
        latitude: LATITUDE,
        longitude: LONGITUDE,
        daily: "weather_code,precipitation_sum,precipitation_probability_max,temperature_2m_max,temperature_2m_min,wind_speed_10m_max,uv_index_max",
        timezone: "auto",
        forecast_days: 7,
    });

    const res = await fetch(`${OPEN_METEO_URL}?${params}`);
    if (!res.ok) throw new Error(`Weather API returned ${res.status}`);
    return res.json();
}

async function fetchAirQuality() {
    try {
        const params = new URLSearchParams({
            latitude: LATITUDE,
            longitude: LONGITUDE,
            current: "us_aqi,pm2_5,pm10",
            forecast_days: 1,
        });
        const res = await fetch(`${AIR_QUALITY_URL}?${params}`);
        if (!res.ok) return null;
        return res.json();
    } catch {
        return null;
    }
}

// ── Season detection ──────────────────────────────────────────────
function getSeason() {
    const month = new Date().getMonth() + 1;
    if (month >= 3 && month <= 5) return { name: "Spring", note: "Pollen season — cars get coated fast" };
    if (month >= 6 && month <= 8) return { name: "Summer", note: "Dust, bugs, and UV bake dirt onto paint" };
    if (month >= 9 && month <= 11) return { name: "Fall", note: "Tree sap, leaves, and early frost" };
    return { name: "Winter", note: "Road salt is the main enemy" };
}

// ── Precipitation analysis ─────────────────────────────────────────
function analyzeForecast(data, airQuality) {
    const daily = data.daily;
    const results = [];

    for (let i = 0; i < daily.time.length; i++) {
        const hasPrecipCode = PRECIPITATION_CODES.has(daily.weather_code[i]);
        const hasPrecipAmount = daily.precipitation_sum[i] > 0;
        const highProbability = daily.precipitation_probability_max[i] > 30;
        const isPrecip = hasPrecipCode || hasPrecipAmount || highProbability;

        results.push({
            date: daily.time[i],
            weatherCode: daily.weather_code[i],
            precipSum: daily.precipitation_sum[i],
            precipProb: daily.precipitation_probability_max[i],
            tempMax: daily.temperature_2m_max[i],
            tempMin: daily.temperature_2m_min[i],
            windMax: daily.wind_speed_10m_max[i],
            uvMax: daily.uv_index_max[i],
            isPrecipitation: isPrecip,
        });
    }

    const windowEnd = Math.min(DRY_DAYS + 1, results.length);
    const window = results.slice(1, windowEnd);

    const tomorrowWet = window.length > 0 && window[0].isPrecipitation;
    const anyWet = window.some((d) => d.isPrecipitation);

    // Find best wash window in 7-day forecast
    let bestWindow = null;
    for (let i = 1; i < results.length; i++) {
        if (!results[i].isPrecipitation) {
            let dryStreak = 1;
            for (let j = i + 1; j < results.length && !results[j].isPrecipitation; j++) {
                dryStreak++;
            }
            if (!bestWindow || dryStreak > bestWindow.streak) {
                bestWindow = { day: results[i].date, streak: dryStreak, index: i };
            }
        }
    }

    let verdict;
    if (tomorrowWet) {
        verdict = "no";
    } else if (anyWet) {
        verdict = "maybe";
    } else {
        verdict = "good";
    }

    const season = getSeason();

    return { days: results, verdict, checkedDays: window, bestWindow, season, airQuality };
}

// ── Verdict message generation ────────────────────────────────────
function getVerdictMessage(analysis) {
    const { verdict, bestWindow, season, checkedDays } = analysis;
    const dayOfWeek = new Date().getDay();
    const isWeekend = dayOfWeek === 0 || dayOfWeek === 6;
    const isFriday = dayOfWeek === 5;

    if (verdict === "good") {
        let msg = "Clear skies ahead — great time to wash.";
        if (bestWindow && bestWindow.streak >= 4) {
            msg = `${bestWindow.streak}-day dry stretch ahead. Perfect wash window.`;
        }
        if (isFriday) msg += " Fresh ride for the weekend!";
        if (season.name === "Spring") msg += " Pollen's been building up.";
        if (season.name === "Winter") msg += " Rinse off that road salt.";
        return msg;
    } else if (verdict === "maybe") {
        const wetDay = checkedDays.find(d => d.isPrecipitation);
        const wetDayName = wetDay ? dayName(wetDay.date) : "later this week";
        let msg = `Rain possible ${wetDayName}, but today's dry.`;
        if (bestWindow) {
            msg += ` Best window: ${dayName(bestWindow.day)}.`;
        }
        return msg;
    } else {
        const precip = checkedDays[0];
        const desc = weatherDescriptions[precip?.weatherCode] || "precipitation";
        let msg = `${desc} expected tomorrow — skip the wash.`;
        if (bestWindow) {
            msg += ` Try ${dayName(bestWindow.day)} instead.`;
        }
        return msg;
    }
}

// ── UI rendering ───────────────────────────────────────────────────
const weatherDescriptions = {
    0: "Clear sky", 1: "Mainly clear", 2: "Partly cloudy", 3: "Overcast",
    45: "Foggy", 48: "Rime fog",
    51: "Light drizzle", 53: "Drizzle", 55: "Dense drizzle",
    56: "Light freezing drizzle", 57: "Freezing drizzle",
    61: "Light rain", 63: "Rain", 65: "Heavy rain",
    66: "Light freezing rain", 67: "Freezing rain",
    71: "Light snow", 73: "Snow", 75: "Heavy snow", 77: "Snow grains",
    80: "Light showers", 81: "Showers", 82: "Heavy showers",
    85: "Light snow showers", 86: "Snow showers",
    95: "Thunderstorm", 96: "Thunderstorm + hail", 99: "Severe thunderstorm",
};

const weatherIcons = {
    0: "\u2600\uFE0F", 1: "\uD83C\uDF24\uFE0F", 2: "\u26C5", 3: "\u2601\uFE0F",
    45: "\uD83C\uDF2B\uFE0F", 48: "\uD83C\uDF2B\uFE0F",
    51: "\uD83C\uDF26\uFE0F", 53: "\uD83C\uDF27\uFE0F", 55: "\uD83C\uDF27\uFE0F",
    56: "\u2744\uFE0F\uD83C\uDF27\uFE0F", 57: "\u2744\uFE0F\uD83C\uDF27\uFE0F",
    61: "\uD83C\uDF26\uFE0F", 63: "\uD83C\uDF27\uFE0F", 65: "\uD83C\uDF27\uFE0F",
    66: "\u2744\uFE0F\uD83C\uDF27\uFE0F", 67: "\u2744\uFE0F\uD83C\uDF27\uFE0F",
    71: "\uD83C\uDF28\uFE0F", 73: "\uD83C\uDF28\uFE0F", 75: "\uD83C\uDF28\uFE0F", 77: "\uD83C\uDF28\uFE0F",
    80: "\uD83C\uDF26\uFE0F", 81: "\uD83C\uDF27\uFE0F", 82: "\uD83C\uDF27\uFE0F",
    85: "\uD83C\uDF28\uFE0F", 86: "\uD83C\uDF28\uFE0F",
    95: "\u26C8\uFE0F", 96: "\u26C8\uFE0F", 99: "\u26C8\uFE0F",
};

function dayName(dateStr) {
    const d = new Date(dateStr + "T00:00:00");
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    const diff = (d - today) / 86400000;
    if (diff < 1) return "Today";
    if (diff < 2) return "Tomorrow";
    return d.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
}

function renderForecast(analysis) {
    const grid = document.getElementById("forecast-grid");
    const status = document.getElementById("forecast-status");
    grid.innerHTML = "";

    analysis.days.forEach((day, i) => {
        const card = document.createElement("div");
        const inWindow = i >= 1 && i <= DRY_DAYS;
        card.className = `forecast-day${day.isPrecipitation ? " wet" : " dry"}${inWindow ? " in-window" : ""}`;
        card.innerHTML = `
            <div class="day-name">${dayName(day.date)}</div>
            <div class="day-icon">${weatherIcons[day.weatherCode] || "\u2753"}</div>
            <div class="day-desc">${weatherDescriptions[day.weatherCode] || "Unknown"}</div>
            <div class="day-temp">${Math.round(day.tempMax)}\u00B0 / ${Math.round(day.tempMin)}\u00B0</div>
            <div class="day-details">
                <span title="Precipitation">${day.precipSum.toFixed(1)}mm (${day.precipProb}%)</span>
                <span title="Wind">${Math.round(day.windMax)} km/h</span>
                <span title="UV Index">UV ${day.uvMax.toFixed(0)}</span>
            </div>
            ${day.isPrecipitation ? '<span class="badge badge-wet">Wet</span>' : '<span class="badge badge-dry">Dry</span>'}
        `;
        grid.appendChild(card);
    });

    // Render air quality if available
    const aqiEl = document.getElementById("aqi-display");
    if (aqiEl && analysis.airQuality?.current) {
        const aqi = analysis.airQuality.current;
        const aqiLevel = aqi.us_aqi <= 50 ? "Good" : aqi.us_aqi <= 100 ? "Moderate" : "Unhealthy";
        aqiEl.innerHTML = `AQI: ${aqi.us_aqi} (${aqiLevel}) &middot; PM2.5: ${aqi.pm2_5}`;
        aqiEl.className = `aqi-display aqi-${aqiLevel.toLowerCase()}`;
    }

    // Render season info
    const seasonEl = document.getElementById("season-display");
    if (seasonEl) {
        seasonEl.textContent = `${analysis.season.name} \u2014 ${analysis.season.note}`;
    }

    // Render verdict with natural language
    const verdictMsg = getVerdictMessage(analysis);
    status.classList.remove("hidden", "status-go", "status-maybe", "status-wait");
    if (analysis.verdict === "good") {
        status.className = "status-banner status-go";
    } else if (analysis.verdict === "maybe") {
        status.className = "status-banner status-maybe";
    } else {
        status.className = "status-banner status-wait";
    }
    status.textContent = verdictMsg;
}

// ── ntfy.sh notifications ──────────────────────────────────────────
async function sendNtfyAlert(title, message, tags) {
    const res = await fetch(`${NTFY_URL}/${encodeURIComponent(NTFY_TOPIC)}`, {
        method: "POST",
        headers: {
            Title: title,
            Tags: tags || "car,droplet",
        },
        body: message,
    });
    if (!res.ok) throw new Error(`ntfy returned ${res.status}`);
    return res;
}

// ── Main check logic ───────────────────────────────────────────────
async function runCheck() {
    log("Fetching forecast and air quality...");
    try {
        const [data, airQuality] = await Promise.all([
            fetchForecast(),
            fetchAirQuality(),
        ]);
        const analysis = analyzeForecast(data, airQuality);
        renderForecast(analysis);

        const verdictMsg = getVerdictMessage(analysis);
        log(verdictMsg);
    } catch (err) {
        log("Error: " + err.message);
    }
}

// ── Event listeners ────────────────────────────────────────────────
document.addEventListener("DOMContentLoaded", () => {
    runCheck();

    document.getElementById("check-now").addEventListener("click", runCheck);

    document.getElementById("send-test").addEventListener("click", async () => {
        log("Sending test notification...");
        try {
            await sendNtfyAlert(
                "Car Wash Time \u2014 Test",
                "If you see this, your AI-powered car wash notifications are working!",
                "car,white_check_mark"
            );
            log("Test notification sent!");
        } catch (err) {
            log("Error sending test: " + err.message);
        }
    });
});
