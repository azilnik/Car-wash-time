// ── Config (hardcoded) ─────────────────────────────────────────────
const LATITUDE = 43.7232;
const LONGITUDE = -79.4331;
const NTFY_TOPIC = "zilnik-carwash-uTPEjc0f2q8uuKbP";
const DRY_DAYS = 3;

const OPEN_METEO_URL = "https://api.open-meteo.com/v1/forecast";
const NTFY_URL = "https://ntfy.sh";

// WMO weather codes that indicate precipitation
// https://open-meteo.com/en/docs#weathervariables
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
        daily: "weather_code,precipitation_sum,precipitation_probability_max,temperature_2m_max,temperature_2m_min",
        timezone: "auto",
        forecast_days: 7,
    });

    const res = await fetch(`${OPEN_METEO_URL}?${params}`);
    if (!res.ok) throw new Error(`Weather API returned ${res.status}`);
    return res.json();
}

// ── Precipitation analysis ─────────────────────────────────────────
function analyzeForecast(data) {
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
            isPrecipitation: isPrecip,
        });
    }

    const windowEnd = Math.min(DRY_DAYS + 1, results.length);
    const window = results.slice(1, windowEnd);

    const tomorrowWet = window.length > 0 && window[0].isPrecipitation;
    const anyWet = window.some((d) => d.isPrecipitation);

    let verdict;
    if (tomorrowWet) {
        verdict = "no";
    } else if (anyWet) {
        verdict = "maybe";
    } else {
        verdict = "good";
    }

    return { days: results, verdict, checkedDays: window };
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
            <div class="day-precip">Precip: ${day.precipSum.toFixed(1)} mm (${day.precipProb}%)</div>
            ${day.isPrecipitation ? '<span class="badge badge-wet">Wet</span>' : '<span class="badge badge-dry">Dry</span>'}
        `;
        grid.appendChild(card);
    });

    status.classList.remove("hidden", "status-go", "status-maybe", "status-wait");
    if (analysis.verdict === "good") {
        status.className = "status-banner status-go";
        status.textContent = "Good day for a car wash! No precipitation for 3 days.";
    } else if (analysis.verdict === "maybe") {
        status.className = "status-banner status-maybe";
        status.textContent = "Maybe worth a wash \u2014 possible rain or snow in 3 days.";
    } else {
        status.className = "status-banner status-wait";
        status.textContent = "No wash \u2014 precipitation expected tomorrow.";
    }
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
    log("Fetching forecast...");
    try {
        const data = await fetchForecast();
        const analysis = analyzeForecast(data);
        renderForecast(analysis);

        const forecastList = analysis.checkedDays
            .map((d) => `${dayName(d.date)}: ${weatherDescriptions[d.weatherCode] || "Clear"} (${d.precipProb}% chance)`)
            .join("\n");

        const notifications = {
            good: {
                title: "Good day for a car wash!",
                body: `No precipitation for 3 days.\n\n${forecastList}`,
                tags: "car,white_check_mark",
                logMsg: "All clear for 3 days!",
            },
            maybe: {
                title: "Maybe worth a wash",
                body: `Possible rain or snow in 3 days.\n\n${forecastList}`,
                tags: "car,thinking",
                logMsg: "Precipitation possible in 2-3 days, but tomorrow is clear.",
            },
            no: {
                title: "No wash today",
                body: `Precipitation expected tomorrow.\n\n${forecastList}`,
                tags: "car,x",
                logMsg: "Precipitation expected tomorrow \u2014 skip the wash.",
            },
        };

        const n = notifications[analysis.verdict];
        log(n.logMsg);
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
            await sendNtfyAlert("Test from Car Wash Time", "If you see this, notifications are working!", "white_check_mark");
            log("Test notification sent!");
        } catch (err) {
            log("Error sending test: " + err.message);
        }
    });
});
