import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "Model.js" as Model

// Headless tracker. One instance per session (the shell loads `service` kind
// plugins once, not per monitor), so this is the only thing that writes to the
// data files — the bar widgets are strictly readers.
//
// Every `sampleSeconds` (and on every focus change) it looks at the focused
// Wayland toplevel and adds the elapsed wall-clock time to that app's total for
// the current local day. Time is only counted while the session is not idle,
// and a single credit is capped at a few sample intervals so a suspend/resume
// or a long idle stretch can never dump a big block onto whatever was focused.
Item {
    id: root

    // Injected by omarchy-shell's service loader.
    property var shell: null
    property var manifest: null
    property string omarchyPath: Quickshell.env("OMARCHY_PATH")

    readonly property string home: Quickshell.env("HOME")
    readonly property string stateDir: home + "/.local/state/omarchy/wellbeing"

    // The service loader does not hand a service its widget settings, so read the
    // widget's shell.json layout entry off the live shell config directly. This
    // re-evaluates whenever the config is reloaded.
    readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "nihalebr.wellbeing"

    readonly property var widgetEntry: {
        var cfg = shell && shell.shellConfig ? shell.shellConfig : null;
        if (!cfg || !cfg.bar || !cfg.bar.layout)
            return ({});
        var sections = ["left", "center", "right"];
        for (var s = 0; s < sections.length; s++) {
            var list = cfg.bar.layout[sections[s]];
            if (!Array.isArray(list))
                continue;
            for (var i = 0; i < list.length; i++) {
                var e = list[i];
                if (e && String(e.id) === root.pluginId)
                    return e;
            }
        }
        return ({});
    }

    function setting(name, fallback) {
        if (widgetEntry && widgetEntry[name] !== undefined && widgetEntry[name] !== null)
            return widgetEntry[name];
        var defs = manifest && manifest.barWidget && manifest.barWidget.defaults ? manifest.barWidget.defaults : ({});
        if (defs[name] !== undefined && defs[name] !== null)
            return defs[name];
        return fallback;
    }

    function intSetting(name, fallback, min, max) {
        var n = parseInt(String(setting(name, fallback)), 10);
        if (!isFinite(n))
            n = fallback;
        return Math.max(min, Math.min(max, n));
    }

    readonly property int sampleSeconds: intSetting("sampleSeconds", 5, 2, 30)
    readonly property int idleTimeoutSeconds: intSetting("idleTimeoutSeconds", 180, 30, 1800)
    readonly property int historyDays: intSetting("historyDays", 14, 7, 400)

    // { "YYYY-MM-DD": dayRecord } — see Model.emptyDay for the shape. Only days
    // touched this session live here; the panel reads other days off disk.
    property var days: ({})
    readonly property string todayKey: Model.dateKey(clock.date)

    // Sampling cursor.
    property string currentAppId: ""
    property string currentTitle: ""
    property double lastSampleAt: 0
    property double secondsCarry: 0
    property bool lastActive: false
    property bool ready: false

    // Live summary, for the `status` IPC and quick debugging.
    property int todayTotalSeconds: 0
    property string topAppId: ""
    property string topAppName: ""
    readonly property bool tracking: ready && !idleMonitor.isIdle

    // Pending-write bookkeeping.
    property var dirty: ({})
    property bool writeAgain: false

    readonly property string writeScript: 'dir="$1"; shift; mkdir -p "$dir" || exit 1; ' + 'while [ "$#" -ge 2 ]; do f="$dir/$1.json"; ' + 'printf "%s" "$2" > "$f.part" && mv -f "$f.part" "$f"; shift 2; done'

    // ------------------------------------------------------------- day records

    function ensureDay(key) {
        if (!days[key]) {
            var next = days;
            next[key] = Model.emptyDay(key);
            days = next;
        }
        return days[key];
    }

    function markDirty(key) {
        var next = dirty;
        next[key] = true;
        dirty = next;
    }

    function creditElapsed(appId, title, seconds, whenDate) {
        if (!appId || !(seconds > 0))
            return;
        var key = Model.dateKey(whenDate);
        var day = ensureDay(key);
        Model.creditDay(day, appId, title, seconds, whenDate.getHours());
        stampWebAppName(day, appId);
        markDirty(key);
        refreshSummary();
    }

    function registerOpen(appId) {
        if (!appId)
            return;
        var day = ensureDay(todayKey);
        Model.registerOpen(day, appId);
        stampWebAppName(day, appId);
        markDirty(todayKey);
    }

    function refreshSummary() {
        var day = days[todayKey];
        todayTotalSeconds = day ? day.totalSeconds : 0;
        var top = day ? Model.topApps(day, 1) : [];
        topAppId = top.length > 0 ? top[0].appId : "";
        topAppName = top.length > 0 ? top[0].name : "";
    }

    // ------------------------------------------------------------- sampling

    // Shell-owned surfaces that are not "apps you use" — the screensaver in
    // particular can be focused for a stretch before the idle timeout fires.
    readonly property var ignoredApps: ({
            "org.omarchy.screensaver": true,
            "org.omarchy.lock": true,
            "quickshell": true
        })

    function normalizeAppId(id) {
        var s = id ? String(id) : "";
        return ignoredApps[s] ? "" : s;
    }

    // Drop any ignored-app data that predates the ignore list (or a build that
    // did not yet exclude it) when a day file is loaded. Hourly bins can't be
    // un-mixed per app, but an ignored app that slipped through is a few
    // seconds — not worth reconstructing the timeline over.
    function stripIgnored(day) {
        for (var id in day.apps) {
            if (ignoredApps[id])
                delete day.apps[id];
        }
        day.totalSeconds = Model.recomputeTotal(day);
        return day;
    }

    // ------------------------------------------------------------- web apps
    //
    // A browser web app (`browser --app=<url>`, which is how omarchy-launch-webapp
    // and Chrome's "install site" both work) shows up with an app_id like
    // "chrome-youtube.com__-Default" — Model.webAppHost pulls the host back out.
    // `omarchy-webapp-install` writes a .desktop file for each one naming it, so
    // map host -> that name and stamp it onto the day record; the readers show
    // `entry.name` in preference to the derived host.

    property var webAppNames: ({})
    // Seeded at startup so the first scan is the one the 1500ms timer kicks off,
    // not a duplicate fired from the first sample() before the timer.
    property double lastWebAppScanAt: Date.now()

    // host<TAB>name for each installed web app, read off its .desktop launcher.
    readonly property var webAppScanCommand: ["bash", "-c", ['shopt -s nullglob', 'for f in "$HOME"/.local/share/applications/*.desktop; do', '  [ -f "$f" ] || continue', '  name=$(sed -n "s/^Name=//p" "$f" | head -1)', '  ex=$(sed -n "s/^Exec=//p" "$f" | head -1)', '  case "$ex" in *omarchy-launch-webapp*|*--app=*) ;; *) continue ;; esac', '  url=$(printf "%s\\n" "$ex" | grep -oE "https?://[a-zA-Z0-9.:-]+" | head -1)', '  [ -n "$url" ] && [ -n "$name" ] || continue', '  host=${url#*://}; host=${host%%/*}; host=${host%%:*}', '  printf "%s\\t%s\\n" "$host" "$name"', 'done'].join("\n"), "wellbeing-webapp-scan"]

    function scanWebApps() {
        if (webAppScanProc.running)
            return;
        lastWebAppScanAt = Date.now();
        webAppScanProc.running = true;
    }

    // Called on every sample: if the focused window is a web app whose host we
    // have not resolved, kick a rescan (throttled) — covers apps installed after
    // the shell started.
    function noteWebApp(appId) {
        var host = Model.webAppHost(appId);
        if (!host || webAppNames[host] !== undefined)
            return;
        if (Date.now() - lastWebAppScanAt > 600000)
            scanWebApps();
    }

    function stampWebAppName(day, appId) {
        if (!day || !day.apps || !day.apps[appId])
            return;
        var host = Model.webAppHost(appId);
        var nm = host ? webAppNames[host] : "";
        if (nm && day.apps[appId].name !== nm)
            day.apps[appId].name = nm;
    }

    // Re-stamp every web-app row in today's record — used once the scan lands so
    // rows credited before it get their names without waiting to be re-focused.
    function restampToday() {
        var day = days[todayKey];
        if (!day || !day.apps)
            return;
        var changed = false;
        for (var id in day.apps) {
            var host = Model.webAppHost(id);
            var nm = host ? webAppNames[host] : "";
            if (nm && day.apps[id].name !== nm) {
                day.apps[id].name = nm;
                changed = true;
            }
        }
        if (changed) {
            markDirty(todayKey);
            refreshSummary();
        }
    }

    function sample() {
        var now = Date.now();
        var top = ToplevelManager.activeToplevel;
        var appId = normalizeAppId(top && top.appId ? top.appId : "");
        var title = top && top.title ? String(top.title) : "";
        var active = !idleMonitor.isIdle;

        if (!ready) {
            currentAppId = appId;
            currentTitle = title;
            lastSampleAt = now;
            lastActive = active;
            return;
        }

        if (lastSampleAt > 0 && lastActive && active && currentAppId !== "") {
            var dt = (now - lastSampleAt) / 1000;
            var maxDt = root.sampleSeconds * 2.5;
            // Below the floor is jitter; above the ceiling is a gap we can't account
            // for (missed timer, sleep, a long idle that just flipped) — drop it.
            if (dt > 0.2 && dt <= maxDt) {
                // Carry the sub-second remainder so the files hold whole numbers
                // without the rounding slowly losing time.
                secondsCarry += dt;
                var whole = Math.floor(secondsCarry);
                if (whole >= 1) {
                    secondsCarry -= whole;
                    creditElapsed(currentAppId, currentTitle, whole, new Date(lastSampleAt));
                }
            }
        }

        if (active && appId !== "" && appId !== currentAppId)
            registerOpen(appId);
        if (active && appId !== "")
            noteWebApp(appId);

        currentAppId = appId;
        currentTitle = title;
        lastSampleAt = now;
        lastActive = active;
    }

    // ------------------------------------------------------------- persistence

    function flush() {
        var keys = Object.keys(dirty);
        if (keys.length === 0)
            return;
        if (writeProc.running) {
            writeAgain = true;
            return;
        }

        var args = ["bash", "-c", root.writeScript, "wellbeing-write", root.stateDir];
        var wrote = 0;
        for (var i = 0; i < keys.length; i++) {
            var rec = days[keys[i]];
            if (!rec)
                continue;
            rec.updated = new Date().toISOString();
            args.push(keys[i]);
            args.push(JSON.stringify(rec));
            wrote++;
        }
        dirty = ({});
        if (wrote === 0)
            return;
        writeProc.command = args;
        writeProc.running = true;
    }

    function flushDetached() {
        var keys = Object.keys(dirty);
        if (keys.indexOf(todayKey) === -1 && days[todayKey])
            keys.push(todayKey);
        if (keys.length === 0)
            return;
        var args = ["bash", "-c", root.writeScript, "wellbeing-write", root.stateDir];
        var wrote = 0;
        for (var i = 0; i < keys.length; i++) {
            var rec = days[keys[i]];
            if (!rec)
                continue;
            rec.updated = new Date().toISOString();
            args.push(keys[i]);
            args.push(JSON.stringify(rec));
            wrote++;
        }
        if (wrote > 0)
            Quickshell.execDetached(args);
    }

    function resetDay(day) {
        var key = !day || day === "today" ? todayKey : (day === "yesterday" ? Model.shiftKey(todayKey, -1) : String(day));
        if (!/^\d{4}-\d{2}-\d{2}$/.test(key))
            return "bad-date";
        var next = days;
        delete next[key];
        days = next;
        var d = dirty;
        delete d[key];
        dirty = d;
        if (key === todayKey) {
            currentAppId = "";
            lastSampleAt = Date.now();
            refreshSummary();
        }
        Quickshell.execDetached(["bash", "-c", 'rm -f "$1/$2.json" "$1/$2.json.part"', "wellbeing-reset", root.stateDir, key]);
        return "ok";
    }

    function statusJson() {
        return JSON.stringify({
            ready: root.ready,
            tracking: root.tracking,
            idle: idleMonitor.isIdle,
            todayKey: root.todayKey,
            todayTotalSeconds: root.todayTotalSeconds,
            topApp: root.topAppName || (root.topAppId ? Model.friendlyName(root.topAppId) : ""),
            currentApp: root.currentAppId,
            sampleSeconds: root.sampleSeconds,
            idleTimeoutSeconds: root.idleTimeoutSeconds,
            stateDir: root.stateDir,
            trackedDays: Object.keys(root.days)
        }, null, 2);
    }

    // ------------------------------------------------------------- wiring

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    // Crossing midnight: settle up and flush the day that just ended, then let
    // the new day accumulate. creditElapsed already files each chunk under the
    // date of its own timestamp, so a sample straddling midnight splits cleanly.
    onTodayKeyChanged: {
        sample();
        flush();
        ensureDay(todayKey);
        refreshSummary();
    }

    IdleMonitor {
        id: idleMonitor
        enabled: true
        timeout: root.idleTimeoutSeconds
        // Deliberately NOT respecting idle inhibitors: a fullscreen video player
        // holds one, and "left a video running" should stop counting, not log
        // hours. Real input is the signal we want here.
        respectInhibitors: false
        onIsIdleChanged: {
            // Settle the chunk up to the transition, then persist — going idle is a
            // natural save point, and coming back must not backfill the gap.
            root.sample();
            if (isIdle)
                root.flush();
        }
    }

    Connections {
        target: ToplevelManager
        // Focus changes are where per-app time and the "opens" count are decided,
        // so account for them the instant they happen rather than on the next tick.
        function onActiveToplevelChanged() {
            if (root.ready)
                root.sample();
        }
    }

    Timer {
        id: sampleTimer
        interval: root.sampleSeconds * 1000
        repeat: true
        running: true
        onTriggered: root.sample()
    }

    Timer {
        id: flushTimer
        interval: 15000
        repeat: true
        running: true
        onTriggered: root.flush()
    }

    // Load today's file (a shell restart mid-day must not lose the morning).
    // Nothing is credited until this resolves, so the parsed record is a safe
    // straight assignment rather than a merge.
    FileView {
        id: todayLoader
        path: root.stateDir + "/" + root.todayKey + ".json"
        watchChanges: false
        printErrors: false
        onLoaded: {
            var next = root.days;
            next[root.todayKey] = root.stripIgnored(Model.parseDay(text(), root.todayKey));
            root.days = next;
            root.ready = true;
            root.markDirty(root.todayKey);
            root.restampToday();
            root.refreshSummary();
        }
        onLoadFailed: {
            root.ensureDay(root.todayKey);
            root.ready = true;
            root.refreshSummary();
        }
    }

    // Belt and braces: if the FileView never reports back, start tracking anyway.
    Timer {
        interval: 4000
        running: !root.ready
        repeat: false
        onTriggered: {
            if (root.ready)
                return;
            root.ensureDay(root.todayKey);
            root.ready = true;
            root.refreshSummary();
        }
    }

    Process {
        id: writeProc
        running: false
        onExited: function (exitCode) {
            if (exitCode !== 0)
                console.warn("wellbeing: write exited", exitCode);
            if (root.writeAgain) {
                root.writeAgain = false;
                root.flush();
            }
        }
    }

    // Prune old day files once, a beat after startup.
    Process {
        id: pruneProc
        running: false
        command: ["bash", "-c", 'dir="$1"; keep="$2"; [ -d "$dir" ] || exit 0; ' + 'find "$dir" -maxdepth 1 -type f -name "*.json" -mtime "+$keep" -delete 2>/dev/null; ' + 'find "$dir" -maxdepth 1 -type f -name "*.part" -mmin "+60" -delete 2>/dev/null; exit 0', "wellbeing-prune", root.stateDir, String(root.historyDays)]
    }

    Timer {
        interval: 8000
        running: true
        repeat: false
        onTriggered: pruneProc.running = true
    }

    // host<TAB>name for every installed web app, from the .desktop launchers.
    Process {
        id: webAppScanProc
        running: false
        command: root.webAppScanCommand
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var map = ({});
                var lines = String(text).split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var tab = lines[i].indexOf("\t");
                    if (tab <= 0)
                        continue;
                    var host = lines[i].slice(0, tab).trim().toLowerCase();
                    var name = lines[i].slice(tab + 1).trim();
                    if (host && name)
                        map[host] = name;
                }
                root.webAppNames = map;
                root.restampToday();
            }
        }
    }

    Timer {
        interval: 1500
        running: true
        repeat: false
        onTriggered: root.scanWebApps()
    }

    IpcHandler {
        target: "nihalebr.wellbeing"

        function status(): string {
            return root.statusJson();
        }
        function flush(): string {
            root.flush();
            return "ok";
        }
        function reset(day: string): string {
            return root.resetDay(day);
        }
        function dir(): string {
            return root.stateDir;
        }
    }

    Component.onCompleted: console.log("wellbeing: service ready, state dir", root.stateDir)
    Component.onDestruction: {
        root.sample();
        root.flushDetached();
    }
}
