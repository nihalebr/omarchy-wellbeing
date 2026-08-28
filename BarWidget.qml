import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar icon + screen-time popup. This is a pure reader: the Service does all the
// tracking and writing, and every widget instance (one per monitor) just reads
// the day files off disk. Opening the popup nudges the Service to flush first
// so the numbers on screen are current.
BarWidget {
    id: root
    moduleName: "nihalebr.wellbeing"

    readonly property string home: Quickshell.env("HOME")
    readonly property string stateDir: home + "/.local/state/omarchy/wellbeing"

    readonly property bool showLabel: String(setting("showLabel", "Off")) === "On"
    readonly property int goalMinutes: {
        var n = parseInt(String(setting("dailyGoalMinutes", 0)), 10);
        return isFinite(n) && n > 0 ? n : 0;
    }
    readonly property int historyDays: {
        var n = parseInt(String(setting("historyDays", 14)), 10);
        return isFinite(n) ? Math.max(7, n) : 14;
    }

    // Nerd Font glyphs as escapes — a literal PUA character is too easy to lose.
    readonly property string barGlyph: ""       // nf-fa-hourglass-half
    readonly property string chevronLeft: ""    // nf-fa-chevron-left
    readonly property string chevronRight: ""   // nf-fa-chevron-right

    readonly property string todayKey: Model.dateKey(clock.date)

    property var todayData: Model.emptyDay(todayKey)
    property string selectedKey: todayKey
    property var dayData: Model.emptyDay(todayKey)
    property var history: ({})
    property bool popupOpen: false

    readonly property int todayTotal: todayData ? todayData.totalSeconds : 0
    readonly property bool overGoal: goalMinutes > 0 && todayTotal >= goalMinutes * 60
    readonly property var todayTop: Model.topApps(todayData, 1)

    readonly property color fg: bar ? bar.foreground : Color.foreground
    readonly property color dim: Qt.darker(fg, 1.45)
    readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.12)
    readonly property color accent: Color.accent
    readonly property color urgent: bar ? bar.urgent : Color.urgent
    readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

    readonly property string tooltipSummary: {
        var base = "Screen time today: " + Model.formatDuration(todayTotal, false);
        if (todayTop.length > 0)
            base += "  ·  " + todayTop[0].name + " " + Model.formatDuration(todayTop[0].seconds, false);
        if (goalMinutes > 0)
            base += "\nGoal " + Model.formatDuration(goalMinutes * 60, true) + (overGoal ? " — reached" : "");
        return base;
    }

    readonly property bool opened: popupOpen

    function close() {
        popupOpen = false;
    }
    function closePopup() {
        popupOpen = false;
    }

    function openPopup() {
        if (popupOpen)
            return;
        popupOpen = true;
        selectedKey = todayKey;
        refreshNow();
    }

    function toggle() {
        if (popupOpen)
            close();
        else
            openPopup();
    }

    function service() {
        return bar && bar.shell && bar.shell.serviceFor ? bar.shell.serviceFor("nihalebr.wellbeing") : null;
    }

    function refreshNow() {
        var svc = service();
        if (svc && svc.flush)
            svc.flush();
        Qt.callLater(function () {
            todayFile.reload();
            dayFile.reload();
            historyProc.running = false;
            historyProc.running = true;
        });
    }

    function step(delta) {
        var next = Model.shiftKey(selectedKey, delta);
        if (Model.daysBetween(next, todayKey) < 0)
            // never past today
            return;
        if (Model.daysBetween(next, todayKey) > historyDays + 1)
            return;
        selectedKey = next;
    }

    function appCount(day) {
        if (!day || !day.apps)
            return 0;
        var n = 0;
        for (var id in day.apps)
            if ((day.apps[id].seconds || 0) > 0)
                n++;
        return n;
    }

    function appRows() {
        return Model.topApps(root.dayData, 8);
    }
    function appOverflow() {
        return Math.max(0, appCount(root.dayData) - 8);
    }

    visible: true
    implicitWidth: pill.implicitWidth
    implicitHeight: pill.implicitHeight

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    onSelectedKeyChanged: Qt.callLater(dayFile.reload)

    // ---- data files -----------------------------------------------------

    FileView {
        id: todayFile
        path: root.stateDir + "/" + root.todayKey + ".json"
        watchChanges: true
        printErrors: false
        onLoaded: root.todayData = Model.parseDay(text(), root.todayKey)
        onLoadFailed: root.todayData = Model.emptyDay(root.todayKey)
        onFileChanged: reload()
    }

    // The service replaces the day file with an atomic rename, which can break
    // an inode-based watch after the first write. This keeps the bar label and
    // tooltip current regardless of whether the watch is following. The popup
    // has its own explicit reload on open, so this stays gentle.
    Timer {
        interval: 30000
        repeat: true
        running: true
        triggeredOnStart: false
        onTriggered: {
            todayFile.reload();
            if (root.selectedKey !== root.todayKey)
                dayFile.reload();
        }
    }

    FileView {
        id: dayFile
        path: root.stateDir + "/" + root.selectedKey + ".json"
        watchChanges: true
        printErrors: false
        onLoaded: root.dayData = Model.parseDay(text(), root.selectedKey)
        onLoadFailed: root.dayData = Model.emptyDay(root.selectedKey)
        onFileChanged: reload()
    }

    Process {
        id: historyProc
        // Reader: skip a state dir or day file that is a symlink, and cap how
        // much of each file is read, so this can never be pointed at an
        // unrelated or unbounded file. The service hardens the dir to 0700 and
        // sweeps out non-regular files at startup; this is the belt to that.
        command: ["bash", "-c", 'dir="$1"; { [ -d "$dir" ] && [ ! -L "$dir" ]; } || exit 0; ' + 'ls -1 "$dir"/*.json 2>/dev/null | sort | tail -n 60 | while read -r f; do ' + '{ [ -f "$f" ] && [ ! -L "$f" ]; } || continue; ' + 'b=$(basename "$f" .json); printf "===%s===\\n" "$b"; head -c 2000000 "$f"; printf "\\n"; done', "wellbeing-history", root.stateDir]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.history = Model.parseHistoryDump(text)
        }
    }

    // Keep the open popup ticking without hammering the disk.
    Timer {
        interval: 12000
        repeat: true
        running: root.popupOpen
        onTriggered: root.refreshNow()
    }

    // Lets a Hyprland keybinding summon the breakdown:
    //   omarchy-shell nihalebr.wellbeing.ui toggle
    IpcHandler {
        target: "nihalebr.wellbeing.ui"
        function toggle(): void {
            root.broadcast("toggle");
        }
        function open(): void {
            root.broadcast("openPopup");
        }
        function close(): void {
            root.broadcast("closePopup");
        }
        function status(): string {
            return JSON.stringify({
                open: root.popupOpen,
                selectedDay: root.selectedKey,
                todayScreenTime: Model.formatDuration(root.todayTotal, false),
                topApp: root.todayTop.length > 0 ? root.todayTop[0].name : ""
            });
        }
    }

    // ---- bar pill -------------------------------------------------------

    WidgetButton {
        id: pill
        anchors.fill: parent
        bar: root.bar
        horizontalMargin: 9
        fontSize: Style.font.body
        active: root.overGoal
        tooltipText: root.tooltipSummary
        text: root.vertical ? root.barGlyph : (root.showLabel ? root.barGlyph + "  " + Model.formatDuration(root.todayTotal, true) : root.barGlyph)
        hasVisualContent: text !== ""

        onPressed: function (button) {
            if (button === Qt.MiddleButton && root.popupOpen) {
                root.selectedKey = root.todayKey;
                root.refreshNow();
            } else {
                root.toggle();
            }
        }
    }

    // ---- popup ---------------------------------------------------------
    //
    // A layer-shell KeyboardPanel rather than an xdg PopupCard: xdg popups only
    // map in response to pointer/keyboard input, so a hotkey summon
    // (nihalebr.wellbeing.ui toggle) would open nothing. The layer-shell panel
    // maps on demand and still dismisses on an outside click.

    KeyboardPanel {
        id: popup
        anchorItem: pill
        bar: root.bar
        owner: root
        open: root.popupOpen
        centerOnBar: false
        focusTarget: keyCatcher
        contentWidth: popup.fittedContentWidth(Style.space(380))
        // Cap high enough that the whole breakdown fits without scrolling on a
        // normal display; fittedContentHeight still clamps to the screen, so a
        // short screen falls back to the Flickable.
        contentHeight: popup.fittedContentHeight(column.implicitHeight, Style.space(960))

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: root.close()
            onMoveRequested: function (dx, dy) {
                if (dx !== 0)
                    root.step(dx);
            }
            onActivateRequested: root.selectedKey = root.todayKey
            onTextKey: function (t) {
                if (t === "t" || t === "T")
                    root.selectedKey = root.todayKey;
            }

            Flickable {
                id: scroll
                anchors.fill: parent
                contentWidth: width
                contentHeight: column.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height
                ScrollBar.vertical: ScrollBar {
                    policy: ScrollBar.AsNeeded
                }

                Column {
                    id: column
                    width: scroll.width
                    spacing: Style.space(14)

                    // ---- day navigator
                    Item {
                        width: parent.width
                        height: navLabel.implicitHeight + Style.space(6)

                        Text {
                            id: navLabel
                            anchors.centerIn: parent
                            text: Model.dayLabel(root.selectedKey, root.todayKey).toUpperCase()
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            font.letterSpacing: 1
                        }

                        NavArrow {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            glyph: root.chevronLeft
                            hint: "Previous day"
                            onActivated: root.step(-1)
                        }

                        NavArrow {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            glyph: root.chevronRight
                            hint: "Next day"
                            enabled: Model.daysBetween(root.selectedKey, root.todayKey) > 0
                            onActivated: root.step(1)
                        }
                    }

                    // ---- hero: the day's total
                    RowLayout {
                        width: parent.width
                        spacing: Style.space(12)

                        ColumnLayout {
                            spacing: Style.space(2)
                            Layout.fillWidth: true

                            Text {
                                text: Model.formatDuration(root.dayData ? root.dayData.totalSeconds : 0, false)
                                color: root.fg
                                font.family: root.fontFamily
                                font.pixelSize: 44
                                font.bold: true
                            }
                            Text {
                                text: "SCREEN TIME"
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                font.letterSpacing: 1.5
                                font.bold: true
                            }
                        }

                        ColumnLayout {
                            spacing: Style.space(3)
                            Layout.alignment: Qt.AlignRight | Qt.AlignVCenter

                            Text {
                                Layout.alignment: Qt.AlignRight
                                text: root.appCount(root.dayData) + (root.appCount(root.dayData) === 1 ? " app" : " apps")
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                            }
                            Text {
                                Layout.alignment: Qt.AlignRight
                                text: (root.dayData ? root.dayData.switches : 0) + " switches"
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                            }
                        }
                    }

                    // ---- goal bar
                    Column {
                        visible: root.goalMinutes > 0
                        width: parent.width
                        spacing: Style.space(5)

                        Item {
                            width: parent.width
                            height: goalLabel.implicitHeight

                            Text {
                                id: goalLabel
                                anchors.left: parent.left
                                text: "DAILY GOAL"
                                color: root.dim
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                font.letterSpacing: 1
                                font.bold: true
                            }
                            Text {
                                anchors.right: parent.right
                                readonly property int daySeconds: root.dayData ? root.dayData.totalSeconds : 0
                                text: Model.formatDuration(daySeconds, true) + " / " + Model.formatDuration(root.goalMinutes * 60, true)
                                color: daySeconds >= root.goalMinutes * 60 ? root.urgent : root.fg
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                            }
                        }

                        Rectangle {
                            width: parent.width
                            height: Style.space(6)
                            radius: Style.cornerRadius > 0 ? height / 2 : 0
                            color: root.faint

                            Rectangle {
                                readonly property real frac: {
                                    var s = root.dayData ? root.dayData.totalSeconds : 0;
                                    return Math.max(0, Math.min(1, s / (root.goalMinutes * 60)));
                                }
                                width: Math.round(parent.width * frac)
                                height: parent.height
                                radius: parent.radius
                                color: frac >= 1 ? root.urgent : Style.selectedStateColor(root.fg, root.accent)
                                Behavior on width {
                                    NumberAnimation {
                                        duration: 200
                                        easing.type: Easing.OutCubic
                                    }
                                }
                            }
                        }
                    }

                    // ---- last 7 days
                    Column {
                        width: parent.width
                        spacing: Style.space(6)

                        Text {
                            text: "LAST 7 DAYS"
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            font.letterSpacing: 1
                            font.bold: true
                        }

                        Row {
                            id: weekRow
                            width: parent.width
                            height: Style.space(66)
                            spacing: Style.space(6)

                            readonly property var keys: Model.recentKeys(root.todayKey, 7)
                            readonly property real weekMax: {
                                var m = 1;
                                for (var i = 0; i < keys.length; i++)
                                    m = Math.max(m, root.history[keys[i]] || 0);
                                return m;
                            }
                            readonly property real colW: (width - spacing * 6) / 7

                            Repeater {
                                model: weekRow.keys

                                Item {
                                    id: dayCell
                                    required property var modelData
                                    readonly property int seconds: root.history[modelData] || 0
                                    readonly property bool selected: modelData === root.selectedKey
                                    width: weekRow.colW
                                    height: weekRow.height

                                    Item {
                                        id: barBox
                                        anchors.top: parent.top
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.bottom: dowLabel.top
                                        anchors.bottomMargin: Style.space(4)

                                        Rectangle {
                                            anchors.bottom: parent.bottom
                                            width: parent.width
                                            height: dayCell.seconds > 0 ? Math.max(Style.space(6), Math.round(barBox.height * dayCell.seconds / weekRow.weekMax)) : Style.space(3)
                                            radius: Math.min(Style.cornerRadius, width / 2)
                                            color: dayCell.selected ? Style.selectedStateColor(root.fg, root.accent) : (dayCell.seconds > 0 ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.32) : root.faint)
                                            Behavior on height {
                                                NumberAnimation {
                                                    duration: 180
                                                    easing.type: Easing.OutCubic
                                                }
                                            }
                                        }
                                    }

                                    Text {
                                        id: dowLabel
                                        anchors.bottom: parent.bottom
                                        width: parent.width
                                        horizontalAlignment: Text.AlignHCenter
                                        text: Model.weekdayInitial(dayCell.modelData)
                                        color: dayCell.selected ? root.fg : root.dim
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.caption
                                        font.bold: dayCell.selected
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.selectedKey = dayCell.modelData
                                        onEntered: if (root.bar)
                                            root.bar.showTooltip(root, Model.dayLabel(dayCell.modelData, root.todayKey) + ": " + Model.formatDuration(dayCell.seconds, false))
                                        onExited: if (root.bar)
                                            root.bar.hideTooltip(root)
                                    }
                                }
                            }
                        }
                    }

                    // ---- hourly timeline
                    Column {
                        width: parent.width
                        spacing: Style.space(5)
                        visible: Model.peakBin(root.dayData) > 0

                        Text {
                            text: "BY HOUR"
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            font.letterSpacing: 1
                            font.bold: true
                        }

                        Row {
                            id: hourRow
                            width: parent.width
                            height: Style.space(46)
                            readonly property real peak: Math.max(1, Model.peakBin(root.dayData))
                            readonly property real slotW: width / 24

                            Repeater {
                                model: 24

                                Item {
                                    id: hourCell
                                    required property int index
                                    readonly property int seconds: root.dayData && root.dayData.bins ? (root.dayData.bins[index] || 0) : 0
                                    readonly property bool isNow: root.selectedKey === root.todayKey && index === clock.date.getHours()
                                    width: hourRow.slotW
                                    height: hourRow.height

                                    Rectangle {
                                        anchors.bottom: parent.bottom
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        width: Math.max(2, hourCell.width - Style.space(3))
                                        height: hourCell.seconds > 0 ? Math.max(Style.space(3), Math.round(hourCell.height * hourCell.seconds / hourRow.peak)) : Style.space(2)
                                        radius: Math.min(2, Style.cornerRadius)
                                        color: hourCell.seconds > 0 ? (hourCell.isNow ? Style.selectedStateColor(root.fg, root.accent) : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.4)) : root.faint
                                    }
                                }
                            }
                        }

                        Item {
                            width: parent.width
                            height: Style.font.caption + Style.space(2)

                            Repeater {
                                model: [0, 6, 12, 18]
                                Text {
                                    required property var modelData
                                    x: Math.round(modelData / 24 * parent.width)
                                    text: Model.formatClockHour(modelData)
                                    color: root.dim
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                }
                            }
                        }
                    }

                    PanelSeparator {
                        foreground: root.fg
                    }

                    // ---- most used
                    Text {
                        text: "MOST USED"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.letterSpacing: 1
                        font.bold: true
                    }

                    Text {
                        visible: root.appRows().length === 0
                        width: parent.width
                        text: Model.daysBetween(root.selectedKey, root.todayKey) === 0 ? "No app activity recorded yet today." : "No app activity recorded for this day."
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                    }

                    Column {
                        width: parent.width
                        spacing: Style.space(9)

                        Repeater {
                            model: root.appRows()

                            Item {
                                required property var modelData
                                width: parent.width
                                implicitHeight: rowName.implicitHeight + Style.space(9)

                                Text {
                                    id: rowGlyph
                                    anchors.left: parent.left
                                    anchors.verticalCenter: rowName.verticalCenter
                                    width: Style.space(20)
                                    text: modelData.glyph
                                    color: root.fg
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.icon
                                }

                                Text {
                                    id: rowName
                                    anchors.left: rowGlyph.right
                                    anchors.leftMargin: Style.space(6)
                                    anchors.right: rowTime.left
                                    anchors.rightMargin: Style.space(8)
                                    anchors.top: parent.top
                                    text: modelData.name
                                    elide: Text.ElideRight
                                    color: root.fg
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.body
                                }

                                Text {
                                    id: rowTime
                                    anchors.right: parent.right
                                    anchors.verticalCenter: rowName.verticalCenter
                                    text: Model.formatDuration(modelData.seconds, false)
                                    color: root.fg
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.body
                                }

                                Rectangle {
                                    anchors.left: rowName.left
                                    anchors.right: parent.right
                                    anchors.top: rowName.bottom
                                    anchors.topMargin: Style.space(4)
                                    height: Style.space(4)
                                    radius: Style.cornerRadius > 0 ? height / 2 : 0
                                    color: root.faint

                                    Rectangle {
                                        width: Math.max(Style.space(4), Math.round(parent.width * modelData.fraction))
                                        height: parent.height
                                        radius: parent.radius
                                        color: Style.selectedStateColor(root.fg, root.accent)
                                    }
                                }
                            }
                        }
                    }

                    Text {
                        visible: root.appRows().length > 0 && root.appOverflow() > 0
                        text: "+ " + root.appOverflow() + " more"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                    }

                    // ---- footer
                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        readonly property var svc: root.service()
                        text: {
                            if (svc && svc.tracking === false && Model.daysBetween(root.selectedKey, root.todayKey) === 0)
                                return "Tracking paused — you're idle";
                            var upd = root.dayData ? root.dayData.updated : "";
                            if (!upd)
                                return "";
                            var d = new Date(upd);
                            return isNaN(d.getTime()) ? "" : "Updated " + Qt.formatDateTime(d, "HH:mm");
                        }
                        visible: text !== ""
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                    }
                }
            }
        }
    }

    // Small chevron button for the day navigator.
    component NavArrow: Item {
        id: nav
        property string glyph: ""
        property string hint: ""
        signal activated

        implicitWidth: Style.space(26)
        implicitHeight: Style.space(24)
        opacity: enabled ? 1 : 0.3

        Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: navMouse.containsMouse && nav.enabled ? Style.hoverFillFor(root.fg, root.accent) : "transparent"
        }

        Text {
            anchors.centerIn: parent
            text: nav.glyph
            color: navMouse.containsMouse && nav.enabled ? Style.hoverStateColor(root.fg, root.accent) : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
        }

        MouseArea {
            id: navMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: nav.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: nav.activated()
            onEntered: if (nav.hint !== "" && root.bar)
                root.bar.showTooltip(root, nav.hint)
            onExited: if (root.bar)
                root.bar.hideTooltip(root)
        }
    }
}
