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
    // Resolve the data dir exactly as the bar widget and bin/omarchy-wellbeing
    // do (honour an absolute XDG_STATE_HOME, ignore a relative one per the XDG
    // spec) so all three always agree on where the data lives.
    readonly property string stateDir: Model.stateDirFrom(home, Quickshell.env("XDG_STATE_HOME"))

    // Private per-user scratch dir for the shutdown payload (see flushDetached).
    // Absolute or nothing — a relative value is not a dir we can trust.
    readonly property string runtimeDir: {
        var r = Quickshell.env("XDG_RUNTIME_DIR");
        return r && r.length > 0 && r[0] === "/" ? r : "";
    }

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
    // Keys handed to the running writeProc; cleared from `dirty` only once it
    // exits 0 (see writeProc.onExited), so a partial or failed write leaves the
    // records queued for the next attempt instead of dropping them.
    property var writingKeys: []
    property bool lastWriteFailed: false

    // Set once today's file has been read back this session (todayLoader
    // onLoaded/onLoadFailed). Until then the writers hold today's record back
    // rather than risk a near-empty in-memory record overwriting a file whose
    // contents this session has never seen. Reset on the midnight rollover.
    property bool todayLoaded: false
    property bool warnedHeldToday: false

    // maintenanceProc reports back through these, and only once it has actually
    // exited — a slow sweep can never expose an unswept file to todayLoader:
    //   dirReady    - the dir is one we own at 0700 and has been swept of
    //                 anything a bare read must not follow. Gates the readers,
    //                 and the writers (flush/flushDetached), so nothing touches
    //                 the dir until it has been verified.
    //   dirRejected - the dir is a symlink or is not ours. The writers skip it
    //                 and the readers stay inert.
    property bool dirReady: false
    property bool dirRejected: false

    // The day files hold app_ids and, as a display hint, the last window title
    // seen per app, so the writer is deliberately careful with them:
    //   - refuses a state dir that is a symlink or that this user does not own,
    //     and forces it to 0700
    //   - writes each file through an unpredictable mktemp name at mode 0600 and
    //     publishes it with `mv -fT` — a plain rename that replaces a symlink at
    //     the target and never descends into one that points at a directory; a
    //     failed publish returns failure so the caller keeps the record queued
    //   - never puts a record on argv or in the environment: live writes stream
    //     in on stdin (exactly `mode` lines); the shutdown flush drops them in
    //     a `wellbeing-shutdown-*.ndjson` temp file under $XDG_RUNTIME_DIR — a
    //     private 0700 tmpfs dir that cannot be swapped for a symlink — which a
    //     detached reader drains (`mode` = `file:<path>`), reads whole (dd
    //     status checked, size checked against the cap) and unlinks only on
    //     full success. `mode` = `replay` (runs before the readers open today,
    //     $3 = $XDG_RUNTIME_DIR) re-drains any payload a previous run could not
    //     persist, replacing a day file only when the payload record is newer
    //     (by `updated`) so it can neither lose the deferred tail nor clobber a
    //     day a later session already advanced.
    readonly property string writeScript: ['set -u', 'export LC_ALL=C', 'dir=$1; mode=${2:-}; rtdir=${3:-}', 'umask 077', '[ -n "$dir" ] || exit 64', 'if [ -L "$dir" ]; then echo "state dir $dir is a symlink; refusing to write, day data will not be saved" >&2; exit 65; fi', 'mkdir -p "$dir" || exit 66', '{ [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ]; } || { echo "state dir $dir is not a directory this user owns; refusing to write" >&2; exit 67; }', 'chmod 700 "$dir" 2>/dev/null || true', 'CAP=16777216', 'write_one() {', '  line=$1; key=${line%% *}; json=${line#* }', '  [ "$json" = "$line" ] && return 0', '  case $key in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 0 ;; esac', '  tmp=$(mktemp "$dir/.$key.json.XXXXXX") || return 1', '  if printf "%s\\n" "$json" > "$tmp"; then', '    chmod 600 "$tmp" 2>/dev/null || true', '    if [ -d "$dir/$key.json" ] && [ ! -L "$dir/$key.json" ]; then rmdir "$dir/$key.json" 2>/dev/null || rm -rf -- "$dir/$key.json" 2>/dev/null || true; fi', '    mv -fT "$tmp" "$dir/$key.json" || { rm -f "$tmp"; return 1; }', '  else', '    rm -f "$tmp"; return 1', '  fi', '}', 'field_updated() { sed -n "s/.*\\"updated\\":\\"\\([^\\"]*\\)\\".*/\\1/p" | head -n 1; }', 'write_newer() {', '  line=$1; key=${line%% *}; json=${line#* }', '  [ "$json" = "$line" ] && return 0', '  case $key in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 0 ;; esac', '  cur="$dir/$key.json"', '  if [ -f "$cur" ] && [ ! -L "$cur" ]; then', '    du=$(head -c "$CAP" "$cur" 2>/dev/null | field_updated)', '    nu=$(printf "%s" "$json" | field_updated)', '    if [ -n "$du" ] && [ -n "$nu" ] && [[ ! "$nu" > "$du" ]]; then return 0; fi', '  fi', '  write_one "$line"', '}', 'drain_payload() {', '  wf=$1; p=$2; prc=0', '  { [ -f "$p" ] && [ ! -L "$p" ]; } || return 0', '  psz=$(wc -c < "$p" 2>/dev/null) || return 1', '  { [ -n "$psz" ] && [ "$psz" -ge 2 ] && [ "$psz" -le "$CAP" ]; } || return 1', '  chmod 600 "$p" 2>/dev/null || true', '  cont=$(timeout 10 dd if="$p" iflag=nofollow,count_bytes count="$CAP" bs=65536 2>/dev/null) || return 1', '  [ -n "$cont" ] || return 1', '  while IFS= read -r pl; do [ -n "$pl" ] && { "$wf" "$pl" || prc=1; }; done <<< "$cont"', '  [ "$prc" -eq 0 ] && rm -f "$p"', '  return "$prc"', '}', 'case $mode in', '  file:*)', '    f=${mode#file:}', '    case ${f##*/} in wellbeing-shutdown-*.ndjson) ;; *) exit 0 ;; esac', '    drain_payload write_one "$f"; exit $?', '    ;;', '  replay)', '    { [ -n "$rtdir" ] && [ -d "$rtdir" ] && [ ! -L "$rtdir" ]; } || exit 0', '    shopt -s nullglob', '    rc=0', '    for pf in "$rtdir"/wellbeing-shutdown-*.ndjson; do drain_payload write_newer "$pf" || rc=1; done', '    exit "$rc"', '    ;;', '  ""|*[!0-9]*)', '    ;;', '  *)', '    i=0; rc=0', '    while [ "$i" -lt "$mode" ]; do', '      IFS= read -r -t 10 line || break', '      i=$((i + 1))', '      if [ -n "$line" ]; then write_one "$line" || rc=1; fi', '    done', '    [ "$i" -eq "$mode" ] || rc=1', '    exit "$rc"', '    ;;', 'esac'].join("\n")

    // Runs once at startup, before any day file is read. Guarantees the state
    // dir is one we own at 0700, then removes anything a reader (the FileViews
    // here and in the bar widget, `jq` in bin/omarchy-wellbeing) should never be
    // pointed at: non-regular files (a planted symlink or fifo), a directory
    // sitting where a day file belongs (which would wedge that day's writes,
    // since `mv -fT` can't replace a directory), oversized files, history past
    // the retention window, and stale temp files from an interrupted write.
    // Also normalises any legacy day file to 0600.
    readonly property string maintenanceScript: ['set -u', 'dir=$1; keep=${2:-14}', 'umask 077', '[ -n "$dir" ] || exit 0', 'if [ -L "$dir" ]; then echo "state dir $dir is a symlink; wellbeing will not read or write it" >&2; exit 3; fi', 'mkdir -p "$dir" 2>/dev/null || { echo "cannot create state dir $dir" >&2; exit 3; }', '{ [ -d "$dir" ] && [ -O "$dir" ]; } || { echo "state dir $dir is not a directory this user owns" >&2; exit 3; }', 'chmod 700 "$dir" 2>/dev/null || true', 'find "$dir" -maxdepth 1 -mindepth 1 ! -type d ! -type f -delete 2>/dev/null || true', 'find "$dir" -maxdepth 1 -mindepth 1 -type d -name "????-??-??.json" -exec rm -rf -- {} + 2>/dev/null || true', 'find "$dir" -maxdepth 1 -type f -size +8M -delete 2>/dev/null || true', 'find "$dir" -maxdepth 1 -type f -name "*.json" -mtime "+$keep" -delete 2>/dev/null || true', 'find "$dir" -maxdepth 1 -type f \\( -name ".*.json.*" -o -name "*.part" -o -name ".shutdown-*" \\) -mmin +60 -delete 2>/dev/null || true', 'find "$dir" -maxdepth 1 -type f -name "*.json" -exec chmod 600 {} + 2>/dev/null || true', 'exit 0'].join("\n")

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

    // Collect the dirty day records as "<YYYY-MM-DD> <compact-json>" lines. The
    // key is safe on argv/stdin; the record body never is.
    function pendingLines(keys) {
        var lines = [];
        for (var i = 0; i < keys.length; i++) {
            var rec = days[keys[i]];
            if (!rec)
                continue;
            rec.updated = new Date().toISOString();
            lines.push(keys[i] + " " + JSON.stringify(rec));
        }
        return lines;
    }

    function flush() {
        var all = Object.keys(dirty);
        if (all.length === 0)
            return;
        if (dirRejected) {
            // maintenanceProc logged why the dir is unusable; drop the pending
            // writes rather than respawn a doomed writer every 15s.
            dirty = ({});
            return;
        }
        // Wait for maintenanceProc to harden and sweep the dir before writing;
        // whatever queues up in the meantime drains from onDirReadyChanged.
        if (!dirReady)
            return;

        // Hold today's record back until its file has been read this session —
        // a slow start must not let a near-empty in-memory record overwrite the
        // morning still sitting on disk. Other days are always safe to write.
        var keys = all;
        if (!todayLoaded) {
            keys = [];
            for (var k = 0; k < all.length; k++)
                if (all[k] !== todayKey)
                    keys.push(all[k]);
            if (!warnedHeldToday && keys.length !== all.length) {
                warnedHeldToday = true;
                console.warn("wellbeing: today's file has not loaded yet — holding its writes back so a slow start can't overwrite it");
            }
            if (keys.length === 0)
                return;
        }

        if (writeProc.running) {
            writeAgain = true;
            return;
        }

        var lines = pendingLines(keys);
        if (lines.length === 0) {
            var d = dirty;
            for (var m = 0; m < keys.length; m++)
                delete d[keys[m]];
            dirty = d;
            return;
        }

        // Records stream in on stdin; only the state dir and the line count ride
        // on argv. `dirty` is cleared for these keys only once writeProc exits 0
        // (see onExited), so a partial or failed write keeps them queued.
        writeProc.command = ["bash", "-c", root.writeScript, "wellbeing-write", root.stateDir, String(lines.length)];
        writingKeys = keys.slice();
        writeProc.running = true;
        for (var j = 0; j < lines.length; j++)
            writeProc.write(lines[j] + "\n");
    }

    function flushDetached() {
        // Only touch the dir once maintenanceProc has confirmed it is ours, not
        // a symlink, and swept it — the shutdown payload carries window titles
        // and app ids and must not be written through an unverified path.
        if (!dirReady)
            return;
        var keys = [];
        var dk = Object.keys(dirty);
        for (var i = 0; i < dk.length; i++)
            if (dk[i] !== todayKey)
                keys.push(dk[i]);
        // Force-add today (it is usually not "dirty" in the strict sense), but
        // only once its file has been loaded this session.
        if (todayLoaded && days[todayKey])
            keys.push(todayKey);
        if (keys.length === 0)
            return;
        var lines = pendingLines(keys);
        if (lines.length === 0)
            return;
        // Shutdown path: there is no stdin pipe to a detached process, and
        // window titles must not ride on argv/env (visible in /proc, and capped
        // at MAX_ARG_STRLEN anyway). Drop the records in a temp file now
        // (synchronously) for a detached reader to drain. The file goes under
        // $XDG_RUNTIME_DIR — a private 0700 tmpfs dir that, unlike stateDir,
        // cannot have been swapped for a symlink since startup — so FileView's
        // symlink-following write can't be redirected. If the reader can't
        // persist every record it leaves the file for the next start's replay.
        if (!runtimeDir)
            return; // no private scratch dir; the last flush() (<=15s ago) stands
        var tmp = runtimeDir + "/wellbeing-shutdown-" + Date.now() + "-" + Math.floor(Math.random() * 1e9) + ".ndjson";
        shutdownPayloadFile.path = tmp;
        shutdownPayloadFile.setText(lines.join("\n") + "\n");
        if (shutdownPayloadFile.waitForJob)
            shutdownPayloadFile.waitForJob();
        Quickshell.execDetached(["bash", "-c", root.writeScript, "wellbeing-write", root.stateDir, "file:" + tmp]);
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
        // `key` is validated as YYYY-MM-DD above; re-check it here too. Replaces
        // the earlier `cd -P` guard: `cd -P` follows a symlinked stateDir into
        // its target and would delete there, whereas GNU `find` with a bare
        // (non-slashed) start path does not descend a symlinked directory at
        // all — and it opens the directory once, so a post-check swap of the
        // path cannot redirect the delete either.
        if (!dirRejected)
            Quickshell.execDetached(["bash", "-c", 'd=$1; k=$2; case $k in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) exit 0 ;; esac; [ ! -L "$d" ] && [ -d "$d" ] && [ -O "$d" ] || exit 0; exec find "$d" -maxdepth 1 -type f \\( -name "$k.json" -o -name "$k.json.part" -o -name ".$k.json.*" \\) -delete', "wellbeing-reset", root.stateDir, key]);
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
        // The new day's file has not been read yet — hold its writes back again
        // until todayLoader reports on the new key.
        todayLoaded = false;
        warnedHeldToday = false;
        sample();
        flush();
        ensureDay(todayKey);
        refreshSummary();
    }

    // Once the dir is confirmed good, drain anything that piled up while we waited.
    onDirReadyChanged: {
        if (dirReady && Object.keys(dirty).length > 0)
            flush();
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
    // The path stays empty — so the FileView never touches disk — until
    // maintenanceProc has exited cleanly, having hardened the dir and swept out
    // anything a bare read should not follow. No timeout shortcut: a slow sweep
    // must finish first. The belt-and-braces timer below may start crediting
    // before this resolves; onLoaded folds that in rather than discarding it.
    FileView {
        id: todayLoader
        path: root.dirReady ? (root.stateDir + "/" + root.todayKey + ".json") : ""
        watchChanges: false
        printErrors: false
        onLoaded: {
            var disk = root.stripIgnored(Model.parseDay(text(), root.todayKey));
            var mem = root.days[root.todayKey];
            // If the fallback timer credited into an in-memory record before
            // this read landed, flush() has been holding today back, so the
            // file is still the untouched earlier state and the two fold
            // together cleanly. Guarded on !todayLoaded so a second load for
            // the same day (disk already holds the merged data) just assigns.
            var next = root.days;
            next[root.todayKey] = (!root.todayLoaded && mem && (mem.totalSeconds > 0 || mem.switches > 0))
                ? Model.mergeDay(disk, mem)
                : disk;
            root.days = next;
            root.ready = true;
            root.todayLoaded = true;
            root.markDirty(root.todayKey);
            root.restampToday();
            root.refreshSummary();
            root.flush();
        }
        onLoadFailed: {
            root.ensureDay(root.todayKey);
            root.ready = true;
            root.todayLoaded = true;
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
        stdinEnabled: true
        // Surface the writer's own diagnostics (a refused state dir, a failed
        // rename) instead of just an exit code in the journal.
        stderr: StdioCollector {
            onStreamFinished: {
                var msg = String(text).trim();
                if (msg)
                    console.warn("wellbeing:", msg);
            }
        }
        onExited: function (exitCode) {
            if (exitCode === 0) {
                // Confirmed on disk — now it is safe to forget these keys.
                var d = root.dirty;
                for (var i = 0; i < root.writingKeys.length; i++)
                    delete d[root.writingKeys[i]];
                root.dirty = d;
                if (root.lastWriteFailed) {
                    root.lastWriteFailed = false;
                    console.log("wellbeing: writes recovered");
                }
            } else if (!root.lastWriteFailed) {
                root.lastWriteFailed = true;
                console.warn("wellbeing: write exited", exitCode, "— day data was not saved; keeping it queued to retry");
            }
            root.writingKeys = [];
            if (root.writeAgain) {
                root.writeAgain = false;
                root.flush();
            }
        }
    }

    // Writes the shutdown payload temp file synchronously (see flushDetached).
    FileView {
        id: shutdownPayloadFile
        blockWrites: true
        atomicWrites: true
        printErrors: false
    }

    // Harden the state dir and clear anything a reader should never follow,
    // before the first day file is loaded.
    Process {
        id: maintenanceProc
        running: false
        command: ["bash", "-c", root.maintenanceScript, "wellbeing-maint", root.stateDir, String(root.historyDays)]
        stderr: StdioCollector {
            onStreamFinished: {
                var msg = String(text).trim();
                if (msg)
                    console.warn("wellbeing:", msg);
            }
        }
        onExited: function (exitCode) {
            // exit 0: dir owned + swept. exit 3: symlink / not ours, stay off
            // it. Anything else: not swept and not proven bad — readers stay
            // inert, the self-hardening writer carries on.
            if (exitCode === 3) {
                root.dirRejected = true;
                return;
            }
            if (exitCode !== 0)
                return;
            // Re-drain any shutdown payload a previous run could not persist,
            // and only then open the readers — a recovered day must land on
            // disk before todayLoader reads it, or this session's stale copy
            // would overwrite it straight back.
            if (root.runtimeDir)
                replayProc.running = true;
            else
                root.dirReady = true;
        }
    }

    // Gating step between maintenanceProc and the readers: drains a leftover
    // shutdown payload (if any) into the state dir. A failure here just means
    // the payload waits for the next start, so the readers open regardless.
    Process {
        id: replayProc
        running: false
        command: ["bash", "-c", root.writeScript, "wellbeing-replay", root.stateDir, "replay", root.runtimeDir]
        stderr: StdioCollector {
            onStreamFinished: {
                var msg = String(text).trim();
                if (msg)
                    console.warn("wellbeing:", msg);
            }
        }
        onExited: function (exitCode) {
            root.dirReady = true;
        }
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

    Component.onCompleted: {
        console.log("wellbeing: service ready, state dir", root.stateDir);
        maintenanceProc.running = true;
    }
    Component.onDestruction: {
        root.sample();
        root.flushDetached();
    }
}
