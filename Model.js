// Pure helpers for the Digital Wellbeing plugin. No QML, no Qt, no state — the
// Service owns the data files and the sampling loop, the BarWidget owns the
// rendering, and everything they both need to agree on (the on-disk shape, the
// app-name and icon maps, duration formatting, the top-apps sort) lives here.

var DAY_MS = 86400000

// ---------------------------------------------------------------- day records
//
// One JSON file per local day at
//   ~/.local/state/omarchy/wellbeing/YYYY-MM-DD.json
// with this shape. `apps` is keyed by Wayland app_id; `bins` is 24 buckets of
// active seconds, one per hour, for the timeline strip.

function emptyDay(dateKey) {
  var bins = []
  for (var i = 0; i < 24; i++) bins.push(0)
  return {
    date: String(dateKey || ""),
    updated: "",
    totalSeconds: 0,
    switches: 0,
    apps: ({}),
    bins: bins
  }
}

// Coerce whatever is on disk (or an empty string on first run) into a valid
// record. A corrupt or partial file must never crash the shell, so every field
// is rebuilt defensively rather than trusted.
function parseDay(raw, dateKey) {
  var day = emptyDay(dateKey)
  var data = null
  try {
    data = JSON.parse(String(raw || ""))
  } catch (e) {
    return day
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) return day

  if (typeof data.date === "string" && data.date) day.date = data.date
  if (typeof data.updated === "string") day.updated = data.updated
  day.switches = safeInt(data.switches, 0)

  if (data.apps && typeof data.apps === "object") {
    for (var id in data.apps) {
      var entry = data.apps[id]
      if (!entry || typeof entry !== "object") continue
      var seconds = Math.max(0, safeInt(entry.seconds, 0))
      if (seconds <= 0 && !entry.opens) continue
      day.apps[id] = {
        seconds: seconds,
        opens: Math.max(0, safeInt(entry.opens, 0)),
        lastTitle: typeof entry.lastTitle === "string" ? entry.lastTitle : "",
        // A display name the Service resolved for a web app (see webAppHost).
        // Rebuilt defensively like every other field, and must survive the
        // round-trip or the panel — which always reads from disk — loses it.
        name: typeof entry.name === "string" ? entry.name : ""
      }
    }
  }

  if (Array.isArray(data.bins)) {
    for (var h = 0; h < 24; h++) day.bins[h] = Math.max(0, safeInt(data.bins[h], 0))
  }

  day.totalSeconds = recomputeTotal(day)
  return day
}

function recomputeTotal(day) {
  var total = 0
  for (var id in day.apps) total += Math.max(0, day.apps[id].seconds || 0)
  return total
}

// Add `seconds` of use of `appId` at local hour `hour` to a day record, in
// place. Called once per sample tick by the Service.
function creditDay(day, appId, title, seconds, hour) {
  if (!appId || !(seconds > 0)) return day
  var entry = day.apps[appId]
  if (!entry) {
    entry = { seconds: 0, opens: 0, lastTitle: "", name: "" }
    day.apps[appId] = entry
  }
  entry.seconds += seconds
  if (title) entry.lastTitle = title
  day.totalSeconds += seconds
  var h = safeInt(hour, 0)
  if (h >= 0 && h < 24) day.bins[h] += seconds
  return day
}

function registerOpen(day, appId) {
  if (!appId) return day
  var entry = day.apps[appId]
  if (!entry) {
    entry = { seconds: 0, opens: 0, lastTitle: "", name: "" }
    day.apps[appId] = entry
  }
  entry.opens += 1
  day.switches += 1
  return day
}

function safeInt(value, fallback) {
  var n = parseInt(value, 10)
  return isFinite(n) ? n : fallback
}

// ---------------------------------------------------------------- date keys

function dateKey(date) {
  var d = date instanceof Date ? date : new Date()
  var m = d.getMonth() + 1
  var day = d.getDate()
  return d.getFullYear() + "-" + (m < 10 ? "0" + m : m) + "-" + (day < 10 ? "0" + day : day)
}

function keyToDate(key) {
  var parts = String(key || "").split("-")
  if (parts.length !== 3) return new Date()
  return new Date(safeInt(parts[0], 1970), safeInt(parts[1], 1) - 1, safeInt(parts[2], 1))
}

function shiftKey(key, deltaDays) {
  var d = keyToDate(key)
  d.setDate(d.getDate() + deltaDays)
  return dateKey(d)
}

function daysBetween(fromKey, toKey) {
  return Math.round((keyToDate(toKey).getTime() - keyToDate(fromKey).getTime()) / DAY_MS)
}

// "Today" / "Yesterday" / "Wed, 27 Aug" — the panel header label.
function dayLabel(key, todayKey) {
  var diff = daysBetween(key, todayKey)
  if (diff === 0) return "Today"
  if (diff === 1) return "Yesterday"
  var d = keyToDate(key)
  var weekday = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.getDay()]
  var month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][d.getMonth()]
  return weekday + ", " + d.getDate() + " " + month
}

function weekdayInitial(key) {
  return ["S", "M", "T", "W", "T", "F", "S"][keyToDate(key).getDay()]
}

// ---------------------------------------------------------------- formatting

// 4210 -> "1h 10m", 540 -> "9m", 20 -> "20s". `compact` drops the minutes on a
// whole-hour value ("2h" rather than "2h 0m") for the big hero read-out.
function formatDuration(seconds, compact) {
  var s = Math.max(0, Math.round(seconds || 0))
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  if (h > 0) {
    if (compact && m === 0) return h + "h"
    return h + "h " + m + "m"
  }
  if (m > 0) return m + "m"
  return s + "s"
}

function formatClockHour(hour) {
  var h = ((safeInt(hour, 0) % 24) + 24) % 24
  if (h === 0) return "12a"
  if (h === 12) return "12p"
  if (h < 12) return h + "a"
  return (h - 12) + "p"
}

// ---------------------------------------------------------------- top apps

// Sorted, display-ready rows for the "most used" list and the bar tooltip.
// `fraction` is relative to the busiest app so the row meters share a scale.
function topApps(day, limit) {
  var rows = []
  var apps = day && day.apps ? day.apps : {}
  for (var id in apps) {
    var seconds = Math.max(0, apps[id].seconds || 0)
    if (seconds <= 0) continue
    rows.push({
      appId: id,
      name: apps[id].name || friendlyName(id),
      glyph: iconGlyph(id),
      seconds: seconds,
      opens: Math.max(0, apps[id].opens || 0),
      lastTitle: apps[id].lastTitle || ""
    })
  }
  rows.sort(function(a, b) { return b.seconds - a.seconds || a.name.localeCompare(b.name) })
  var max = rows.length > 0 ? rows[0].seconds : 0
  for (var i = 0; i < rows.length; i++) rows[i].fraction = max > 0 ? rows[i].seconds / max : 0
  if (limit > 0 && rows.length > limit) rows = rows.slice(0, limit)
  return rows
}

function peakBin(day) {
  var max = 0
  var bins = day && Array.isArray(day.bins) ? day.bins : []
  for (var i = 0; i < bins.length; i++) if (bins[i] > max) max = bins[i]
  return max
}

// ---------------------------------------------------------------- app names

// app_id -> display name. Covers what people actually run on Omarchy; anything
// missing falls through to prettifyId(), which is good enough for the long
// tail without a per-app entry.
var NAME_MAP = {
  "firefox": "Firefox", "firefox-esr": "Firefox", "org.mozilla.firefox": "Firefox",
  "librewolf": "LibreWolf", "io.gitlab.librewolf-community": "LibreWolf",
  "zen": "Zen Browser", "app.zen_browser.zen": "Zen Browser",
  "google-chrome": "Chrome", "google-chrome-stable": "Chrome", "chrome": "Chrome",
  "chromium": "Chromium", "chromium-browser": "Chromium", "org.chromium.Chromium": "Chromium",
  "brave-browser": "Brave", "brave": "Brave", "com.brave.Browser": "Brave",
  "microsoft-edge": "Edge", "vivaldi-stable": "Vivaldi",
  "code": "VS Code", "code-oss": "Code - OSS", "code-url-handler": "VS Code",
  "vscodium": "VSCodium", "codium": "VSCodium", "cursor": "Cursor",
  "dev.zed.Zed": "Zed", "zed": "Zed",
  "jetbrains-idea": "IntelliJ IDEA", "jetbrains-idea-ce": "IntelliJ IDEA",
  "jetbrains-pycharm": "PyCharm", "jetbrains-webstorm": "WebStorm", "jetbrains-goland": "GoLand",
  "sublime_text": "Sublime Text",
  "Alacritty": "Alacritty", "org.alacritty.Alacritty": "Alacritty",
  "kitty": "Kitty", "org.kitty.kitty": "Kitty",
  "foot": "Foot", "footclient": "Foot",
  "com.mitchellh.ghostty": "Ghostty", "ghostty": "Ghostty",
  "org.wezfurlong.wezterm": "WezTerm", "wezterm": "WezTerm",
  "org.gnome.Console": "Console", "org.gnome.Terminal": "Terminal", "xterm": "XTerm",
  "obsidian": "Obsidian", "md.obsidian.Obsidian": "Obsidian",
  "logseq": "Logseq", "com.logseq.Logseq": "Logseq",
  "slack": "Slack", "com.slack.Slack": "Slack",
  "discord": "Discord", "WebCord": "WebCord", "vesktop": "Vesktop", "legcord": "Legcord",
  "dev.vencord.Vesktop": "Vesktop",
  "org.telegram.desktop": "Telegram", "telegram-desktop": "Telegram",
  "Signal": "Signal", "signal": "Signal", "org.signal.Signal": "Signal",
  "whatsapp-for-linux": "WhatsApp", "io.github.mimbrero.WhatsAppDesktop": "WhatsApp",
  "element": "Element", "im.riot.Riot": "Element",
  "thunderbird": "Thunderbird", "org.mozilla.Thunderbird": "Thunderbird",
  "spotify": "Spotify", "com.spotify.Client": "Spotify",
  "mpv": "mpv", "io.mpv.Mpv": "mpv",
  "vlc": "VLC", "org.videolan.VLC": "VLC",
  "org.gnome.Nautilus": "Files", "nautilus": "Files", "org.kde.dolphin": "Dolphin",
  "thunar": "Files", "pcmanfm": "Files", "nemo": "Files",
  "steam": "Steam", "Steam": "Steam", "steam_app": "Steam",
  "lutris": "Lutris", "net.lutris.Lutris": "Lutris", "heroic": "Heroic",
  "org.gimp.GIMP": "GIMP", "gimp": "GIMP",
  "org.inkscape.Inkscape": "Inkscape", "inkscape": "Inkscape",
  "blender": "Blender", "org.blender.Blender": "Blender",
  "figma-linux": "Figma", "Figma": "Figma",
  "1Password": "1Password", "1password": "1Password",
  "org.keepassxc.KeePassXC": "KeePassXC", "com.bitwarden.desktop": "Bitwarden",
  "org.pwmt.zathura": "Zathura", "zathura": "Zathura",
  "org.gnome.Evince": "Evince", "evince": "Evince", "com.github.johnfactotum.Foliate": "Foliate",
  "libreoffice-writer": "LibreOffice Writer", "libreoffice-calc": "LibreOffice Calc",
  "libreoffice-impress": "LibreOffice Impress", "libreoffice-startcenter": "LibreOffice",
  "Zoom": "Zoom", "us.zoom.Zoom": "Zoom", "zoom": "Zoom",
  "com.obsproject.Studio": "OBS Studio",
  "DBeaver": "DBeaver", "io.dbeaver.DBeaverCommunity": "DBeaver",
  "org.gnome.Calculator": "Calculator", "org.gnome.Settings": "Settings",
  "com.github.tchx84.Flatseal": "Flatseal", "btop": "btop", "htop": "htop",
  "org.omarchy.agent": "AI Agent", "Omarchy": "Omarchy"
}

function friendlyName(appId) {
  var id = String(appId || "").trim()
  if (!id) return "Desktop"
  if (NAME_MAP[id]) return NAME_MAP[id]
  var lower = id.toLowerCase()
  if (NAME_MAP[lower]) return NAME_MAP[lower]
  var host = webAppHost(id)
  if (host) return WEBAPP_NAME_MAP[host] || prettifyHost(host)
  return prettifyId(id)
}

// ------------------------------------------------------------- web apps
//
// A browser launched with `--app=<url>` (what `omarchy-launch-webapp` and
// Chrome's "install this site" both do) gives its window a synthetic app_id:
// a browser prefix, the URL with the scheme dropped and every non-host
// character flattened to "_", then the profile. e.g.
//   chrome-youtube.com__-Default
//   chrome-app.hey.com__calendar_weeks_-Default
// Only the host up to the first "_" is stable enough to read; the Service
// resolves it to the name from the app's .desktop file when there is one, and
// this is the fallback for everything else.

var WEBAPP_PREFIX_RE = /^(?:chrome|chromium|brave|brave-browser|msedge|microsoft-edge|vivaldi|vivaldi-stable|opera|helium)-(.+)$/i

function webAppHost(appId) {
  var m = WEBAPP_PREFIX_RE.exec(String(appId || "").trim())
  if (!m) return ""
  var rest = m[1].replace(/-(?:Default|Profile[ _]?\d+)$/i, "")
  var host = rest.split("_")[0].replace(/\.+$/, "").toLowerCase()
  // A real host has a dot and a letter TLD. Without one this is just an app_id
  // that happens to start with "opera" / "chromium" / etc.
  return /^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$/.test(host) ? host : ""
}

// Curated names for common web apps, and for host families where the bare host
// would collide — every "*.google.com" app otherwise reads the same.
var WEBAPP_NAME_MAP = {
  "youtube.com": "YouTube", "www.youtube.com": "YouTube", "music.youtube.com": "YouTube Music",
  "x.com": "X", "twitter.com": "X", "mobile.twitter.com": "X",
  "mail.google.com": "Gmail",
  "calendar.google.com": "Google Calendar",
  "maps.google.com": "Google Maps",
  "photos.google.com": "Google Photos",
  "contacts.google.com": "Google Contacts",
  "messages.google.com": "Google Messages",
  "drive.google.com": "Google Drive",
  "docs.google.com": "Google Docs",
  "sheets.google.com": "Google Sheets",
  "meet.google.com": "Google Meet",
  "chat.google.com": "Google Chat",
  "keep.google.com": "Google Keep",
  "gemini.google.com": "Gemini",
  "web.whatsapp.com": "WhatsApp",
  "discord.com": "Discord",
  "app.slack.com": "Slack",
  "web.telegram.org": "Telegram",
  "teams.microsoft.com": "Microsoft Teams",
  "outlook.office.com": "Outlook", "outlook.office365.com": "Outlook", "outlook.live.com": "Outlook",
  "github.com": "GitHub", "gitlab.com": "GitLab",
  "reddit.com": "Reddit", "www.reddit.com": "Reddit",
  "notion.so": "Notion", "www.notion.so": "Notion",
  "linear.app": "Linear",
  "figma.com": "Figma", "www.figma.com": "Figma",
  "chat.openai.com": "ChatGPT", "chatgpt.com": "ChatGPT",
  "claude.ai": "Claude",
  "open.spotify.com": "Spotify",
  "music.apple.com": "Apple Music",
  "netflix.com": "Netflix", "www.netflix.com": "Netflix",
  "app.hey.com": "HEY",
  "login.tailscale.com": "Tailscale",
  "console.aws.amazon.com": "AWS Console"
}

// Bare host -> a readable label, when nothing better is known.
// "app.hey.com" -> "Hey", "maps.google.com" -> "Maps Google".
function prettifyHost(host) {
  var labels = String(host || "").toLowerCase().replace(/^www\./, "").split(".")
  // Drop the public suffix ("com", and a second-level one like "co.uk").
  if (labels.length > 2 && /^(co|com|org|net|gov|ac|edu)$/.test(labels[labels.length - 2]))
    labels = labels.slice(0, -2)
  else if (labels.length > 1)
    labels = labels.slice(0, -1)
  // A generic front label ("app.", "web.", "login.") carries no meaning.
  if (labels.length > 1 && /^(app|web|my|go|get|portal|login|account|accounts|auth|dashboard|console|secure)$/.test(labels[0]))
    labels = labels.slice(1)
  var core = labels.join(" ").replace(/[_-]+/g, " ").trim()
  return core.split(/\s+/).map(function(word) {
    if (!word) return word
    if (word.length <= 3 && word === word.toUpperCase()) return word
    return word.charAt(0).toUpperCase() + word.slice(1)
  }).join(" ") || String(host || "")
}

// Reverse-DNS-ish ids get their meaningful segment lifted out
// ("org.telegram.desktop" -> "Telegram"), everything else is split on
// separators and title-cased.
function prettifyId(id) {
  var parts = id.split(".")
  var core = id
  if (parts.length >= 2) {
    var last = parts[parts.length - 1]
    var generic = ["desktop", "client", "app", "gtk", "qt", "bin", "stable", "devel"]
    core = generic.indexOf(last.toLowerCase()) !== -1 && parts.length >= 3 ? parts[parts.length - 2] : last
  }
  core = core.replace(/[_-]+/g, " ").replace(/([a-z])([A-Z])/g, "$1 $2").trim()
  return core.split(/\s+/).map(function(word) {
    if (word.length <= 3 && word === word.toUpperCase()) return word
    return word.charAt(0).toUpperCase() + word.slice(1)
  }).join(" ") || id
}

// ---------------------------------------------------------------- app icons
//
// Glyphs are given as numeric Nerd Font code points and materialised through
// String.fromCharCode, so the source stays plain ASCII — a literal Private Use
// Area character is far too easy to lose or mangle in transit. Every code
// point below is a Basic-Plane glyph present in the JetBrainsMono Nerd Font
// the bar ships. A few exact brand matches, then keyword categories, then a
// generic window glyph.

function nf(codePoint) {
  return String.fromCharCode(codePoint)
}

var GENERIC_APP_GLYPH = 0xf2d0        // nf-fa-window_maximize

var ICON_MAP = {
  "firefox": 0xf269, "firefox-esr": 0xf269, "org.mozilla.firefox": 0xf269, "librewolf": 0xf269,
  "io.gitlab.librewolf-community": 0xf269, "zen": 0xf269, "app.zen_browser.zen": 0xf269,
  "google-chrome": 0xf268, "google-chrome-stable": 0xf268, "chrome": 0xf268,
  "chromium": 0xf268, "chromium-browser": 0xf268, "org.chromium.Chromium": 0xf268,
  "brave-browser": 0xf0ac, "brave": 0xf0ac, "com.brave.Browser": 0xf0ac,
  "code": 0xe70c, "code-oss": 0xe70c, "code-url-handler": 0xe70c, "vscodium": 0xe70c, "codium": 0xe70c,
  "cursor": 0xf121, "dev.zed.Zed": 0xf121, "zed": 0xf121,
  "spotify": 0xf1bc, "com.spotify.Client": 0xf1bc,
  "discord": 0xf086, "vesktop": 0xf086, "dev.vencord.Vesktop": 0xf086, "WebCord": 0xf086, "legcord": 0xf086,
  "slack": 0xf198, "com.slack.Slack": 0xf198,
  "org.telegram.desktop": 0xf1d8, "telegram-desktop": 0xf1d8,
  "steam": 0xf1b6, "Steam": 0xf1b6,
  "thunderbird": 0xf0e0, "org.mozilla.Thunderbird": 0xf0e0,
  "org.gimp.GIMP": 0xf1fc, "gimp": 0xf1fc,
  "org.omarchy.agent": 0xf120
}

var ICON_CATEGORIES = [
  [/(firefox|chrom|brave|browser|vivaldi|epiphany|librewolf|zen|edge|safari|webkit)/i, 0xf0ac],
  [/(alacritty|kitty|foot|ghostty|wezterm|terminal|console|xterm|tmux|tilix|konsole)/i, 0xf120],
  [/(vscode|codium|cursor|\bzed\b|sublime|jetbrains|idea|pycharm|webstorm|goland|nvim|neovim|\bvim\b|emacs|lapce|\bcode\b)/i, 0xf121],
  [/(discord|slack|telegram|signal|whatsapp|element|riot|matrix|mattermost)/i, 0xf086],
  [/(thunderbird|geary|evolution|outlook|protonmail|\bmail\b)/i, 0xf0e0],
  [/(spotify|music|rhythmbox|audacious|tidal|deezer|clementine|strawberry|lollypop)/i, 0xf001],
  [/(mpv|vlc|video|celluloid|totem|youtube|netflix|plex|jellyfin|\bobs\b|kdenlive)/i, 0xf008],
  [/(nautilus|dolphin|thunar|nemo|files|pcmanfm|ranger|nnn|yazi|caja)/i, 0xf07b],
  [/(steam|lutris|heroic|\bgame\b|minecraft|gamescope|retroarch)/i, 0xf11b],
  [/(gimp|inkscape|blender|krita|figma|darktable|\bphoto\b|pinta|gwenview)/i, 0xf1fc],
  [/(obsidian|logseq|notion|zotero|okular|zathura|evince|foliate|calibre|\bpdf\b|libreoffice|onlyoffice|document|writer)/i, 0xf02d]
]

var GLOBE_GLYPH = 0xf0ac              // nf-fa-globe — a web app we can't categorise

function iconGlyph(appId) {
  var id = String(appId || "").trim()
  if (!id) return nf(GENERIC_APP_GLYPH)
  if (ICON_MAP[id] !== undefined) return nf(ICON_MAP[id])
  var lower = id.toLowerCase()
  if (ICON_MAP[lower] !== undefined) return nf(ICON_MAP[lower])
  var name = friendlyName(id)
  var host = webAppHost(id)
  // For a web app the raw id ("chrome-…") would trip the browser category, so
  // match on the host and resolved name instead — and fall back to a globe,
  // not the generic window glyph.
  var probe = host ? host + " " + name : id
  for (var i = 0; i < ICON_CATEGORIES.length; i++) {
    if (ICON_CATEGORIES[i][0].test(probe) || ICON_CATEGORIES[i][0].test(name)) return nf(ICON_CATEGORIES[i][1])
  }
  return nf(host ? GLOBE_GLYPH : GENERIC_APP_GLYPH)
}

// ---------------------------------------------------------------- history

// Parse the BarWidget history dump — "===YYYY-MM-DD===\n<json>\n" blocks —
// into { dateKey: totalSeconds }. Used for the 7-day strip.
function parseHistoryDump(raw) {
  var out = ({})
  var text = String(raw || "")
  var re = /===(\d{4}-\d{2}-\d{2})===\n([\s\S]*?)(?=\n===\d{4}-\d{2}-\d{2}===|\s*$)/g
  var match
  while ((match = re.exec(text)) !== null) {
    var key = match[1]
    var day = parseDay(match[2], key)
    out[key] = day.totalSeconds
  }
  return out
}

// The last `count` day keys ending at todayKey, oldest first — the x-axis of
// the week strip regardless of which days actually have a file.
function recentKeys(todayKey, count) {
  var keys = []
  for (var i = count - 1; i >= 0; i--) keys.push(shiftKey(todayKey, -i))
  return keys
}
