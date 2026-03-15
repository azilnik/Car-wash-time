// ── Constants ──────────────────────────────────────────────────────
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

// ── Settings helpers ───────────────────────────────────────────────
function loadSettings() {
    const raw = localStorage.getItem("carwash-settings");
    return raw ? JSON.parse(raw) : null;
}

function saveSettings(settings) {
    localStorage.setItem("carwash-settings", JSON.stringify(settings));
}

function readFormSettings() {
    return {
        latitude: parseFloat(document.getElementById("latitude").value),
        longitude: parseFloat(document.getElementById("longitude").value),
        ntfyTopic: document.getElementById("ntfy-topic").value.trim(),
        dryDays: parseInt(document.getElementById("dry-days").value, 10),
    };
}

function populateForm(settings) {
    if (!settings) return;
    document.getElementById("latitude").value = settings.latitude || "";
    document.getElementById("longitude").value = settings.longitude || "";
    document.getElementById("ntfy-topic").value = settings.ntfyTopic || "";
    document.getElementById("dry-days").value = settings.dryDays || 3;
}

// ── Logging ────────────────────────────────────────────────────────
function log(message) {
    const el = document.getElementById("log-output");
    const ts = new Date().toLocaleTimeString();
    const entry = document.createElement("div");
    entry.className = "log-entry";
    entry.textContent = `[${ts}] ${message}`;

    // Remove placeholder if present
    const placeholder = el.querySelector(".placeholder-text");
    if (placeholder) placeholder.remove();

    el.prepend(entry);
}

// ── Weather fetching ───────────────────────────────────────────────
async function fetchForecast(lat, lon) {
    const params = new URLSearchParams({
        latitude: lat,
        longitude: lon,
        daily: "weather_code,precipitation_sum,precipitation_probability_max,temperature_2m_max,temperature_2m_min",
        timezone: "auto",
        forecast_days: 7,
    });

    const res = await fetch(`${OPEN_METEO_URL}?${params}`);
    if (!res.ok) throw new Error(`Weather API returned ${res.status}`);
    return res.json();
}

// ── Precipitation analysis ─────────────────────────────────────────
function analyzeForecast(data, dryDays) {
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

    // Check the next N days (skip today = index 0, look at 1..dryDays)
    const windowStart = 1;
    const windowEnd = Math.min(windowStart + dryDays, results.length);
    const window = results.slice(windowStart, windowEnd);
    const allDry = window.every((d) => !d.isPrecipitation);

    return { days: results, allDry, checkedDays: window };
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

function renderForecast(analysis, dryDays) {
    const grid = document.getElementById("forecast-grid");
    const status = document.getElementById("forecast-status");
    grid.innerHTML = "";

    analysis.days.forEach((day, i) => {
        const card = document.createElement("div");
        const inWindow = i >= 1 && i <= dryDays;
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

    status.classList.remove("hidden", "status-go", "status-wait");
    if (analysis.allDry) {
        status.className = "status-banner status-go";
        status.textContent = "It's Car Wash Time! No precipitation expected in the next " + dryDays + " days.";
    } else {
        status.className = "status-banner status-wait";
        status.textContent = "Hold off \u2014 precipitation is expected within the next " + dryDays + " days.";
    }
}

// ── ntfy.sh notifications ──────────────────────────────────────────
async function sendNtfyAlert(topic, title, message, tags) {
    const res = await fetch(`${NTFY_URL}/${encodeURIComponent(topic)}`, {
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
    const settings = loadSettings();
    if (!settings || !settings.latitude || !settings.longitude) {
        log("Please configure your location first.");
        return;
    }

    log("Fetching forecast...");
    try {
        const data = await fetchForecast(settings.latitude, settings.longitude);
        const analysis = analyzeForecast(data, settings.dryDays || 3);
        renderForecast(analysis, settings.dryDays || 3);

        if (analysis.allDry) {
            log("No precipitation in the next " + (settings.dryDays || 3) + " days!");
            if (settings.ntfyTopic) {
                log("Sending notification to ntfy.sh/" + settings.ntfyTopic + "...");
                const dryDaysList = analysis.checkedDays
                    .map((d) => `${dayName(d.date)}: ${weatherDescriptions[d.weatherCode] || "Clear"} (${d.precipProb}% chance)`)
                    .join("\n");
                await sendNtfyAlert(
                    settings.ntfyTopic,
                    "Time for a Car Wash!",
                    `No rain or snow expected in the next ${settings.dryDays || 3} days.\n\n${dryDaysList}`,
                    "car,white_check_mark"
                );
                log("Notification sent!");
            } else {
                log("No ntfy topic configured \u2014 skipping notification.");
            }
        } else {
            log("Precipitation expected \u2014 not a good time for a car wash.");
        }
    } catch (err) {
        log("Error: " + err.message);
    }
}

// ── Event listeners ────────────────────────────────────────────────
document.addEventListener("DOMContentLoaded", () => {
    populateForm(loadSettings());

    document.getElementById("save-settings").addEventListener("click", () => {
        const settings = readFormSettings();
        if (isNaN(settings.latitude) || isNaN(settings.longitude)) {
            log("Please enter valid latitude and longitude.");
            return;
        }
        saveSettings(settings);
        log("Settings saved.");
    });

    document.getElementById("detect-location").addEventListener("click", () => {
        if (!navigator.geolocation) {
            log("Geolocation is not supported by your browser.");
            return;
        }
        log("Detecting location...");
        navigator.geolocation.getCurrentPosition(
            (pos) => {
                document.getElementById("latitude").value = pos.coords.latitude.toFixed(4);
                document.getElementById("longitude").value = pos.coords.longitude.toFixed(4);
                log(`Location detected: ${pos.coords.latitude.toFixed(4)}, ${pos.coords.longitude.toFixed(4)}`);
            },
            (err) => log("Location error: " + err.message)
        );
    });

    document.getElementById("check-now").addEventListener("click", () => {
        const settings = readFormSettings();
        if (isNaN(settings.latitude) || isNaN(settings.longitude)) {
            log("Please enter valid latitude and longitude.");
            return;
        }
        saveSettings(settings);
        runCheck();
    });

    document.getElementById("send-test").addEventListener("click", async () => {
        const topic = document.getElementById("ntfy-topic").value.trim();
        if (!topic) {
            log("Please enter a ntfy topic first.");
            return;
        }
        log("Sending test notification...");
        try {
            await sendNtfyAlert(topic, "Test from Car Wash Time", "If you see this, notifications are working!", "white_check_mark");
            log("Test notification sent to ntfy.sh/" + topic);
        } catch (err) {
            log("Error sending test: " + err.message);
        }
    });
});
