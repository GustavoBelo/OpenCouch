import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import io.github.gustavobelo.opencouch

Item {
    id: page

    signal settingsRequested()

    property var status: ({})
    property string viewingHistory: ""
    readonly property bool ready: status.ready === true
    readonly property string displayName: status.tv_description || status.tv_name || ""

    function reload() {
        page.status = backend.consoleStatus();
        // The engine leaves word when a console session could not start: the
        // desktop it fell back to came up with no notification server yet, so
        // this window is the first thing able to say what happened.
        if (page.status.failure) {
            banner.show(page.status.failure, true);
            banner.raisedBy = "alert";
            // And the account of it is one click away, behind a section the
            // user has no reason to suspect is there. A failure is the one time
            // the log is the point of the window, so it opens itself.
            logSection.expanded = true;
        }
        // The wrapper is hosting only the desktop -- after too many failed
        // logins, or because the user asked it to. Reason string from the
        // engine, same as a failure; the log and the buttons below say the
        // rest. else-if, so a one-shot failure this same poll is not clobbered.
        else if (page.status.safe_mode) {
            banner.show(page.status.safe_mode, true);
            banner.raisedBy = "alert";
            logSection.expanded = true;
        }
        // Safe mode lifts on its own once the streak ages out; the banner it
        // raised has to come down with it rather than sit there as a stale
        // alarm while the rest of the page has flipped to ready.
        else if (banner.raisedBy === "alert") {
            banner.visible = false;
            banner.raisedBy = "";
        }
    }

    function loadLog() {
        page.viewingHistory = "";
        const raw = backend.readLog();
        logView.text = (raw === undefined || raw === "") ? "" : raw.trim();
        logView.cursorPosition = logView.length;
        historySelect.entries = backend.logHistory();
    }

    Component.onCompleted: {
        // Deliberately no clearLog() here. This used to empty the log every
        // time the window opened, which destroyed the one account of why the
        // console did not start last time -- read, by definition, on the next
        // desktop that comes up. Clearing is the button that says so.
        page.reload();
        page.loadLog();
        countdown.sync();

        if (!backend.engineAvailable()) {
            banner.show(qsTrId("engine.missing"), true);
        } else if (backend.engineNeedsUpdate()) {
            banner.show(qsTrId("engine.outdated"), true);
        }
    }

    Connections {
        target: backend
        function onLogLine(line) {
            logView.append(line);
            logView.cursorPosition = logView.length;
        }
        function onActionFinished(success, message) {
            banner.show(message, !success);
            page.reload();
        }
        // The settings page is pushed over this one rather than replacing it,
        // so nothing here is rebuilt when the user comes back. Without this the
        // dashboard went on showing the display that was chosen when it was
        // built, and Refresh was the only way to find out otherwise.
        function onConfigChanged() {
            page.reload();
        }
        function onPendingEntryChanged() {
            countdown.sync();
        }
    }

    Controls.ScrollView {
        id: scroll
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true

        ColumnLayout {
            width: scroll.availableWidth
            spacing: Metrics.sectionGap

            Item { Layout.preferredHeight: Metrics.xs }

            // Banner ------------------------------------------------------
            Card {
                id: banner
                Layout.fillWidth: true
                Layout.leftMargin: Metrics.pagePadding
                Layout.rightMargin: Metrics.pagePadding
                visible: false
                accented: false
                color: bannerBad ? Colors.urgentWash : Colors.accentWash
                border.color: bannerBad ? Colors.urgentEdge : Colors.accentEdge
                implicitHeight: bannerRow.implicitHeight + Metrics.x5

                property bool bannerBad: false
                // Set by reload() to "alert" when the banner is showing a
                // failure or safe-mode reason, so reload() can take it back down
                // once that reason is gone -- other callers leave it empty and
                // own their banner until the user dismisses it.
                property string raisedBy: ""
                function show(message, bad) {
                    bannerText.text = message;
                    bannerBad = bad;
                    raisedBy = "";
                    visible = true;
                }

                RowLayout {
                    id: bannerRow
                    anchors.fill: parent
                    anchors.margins: Metrics.xl
                    spacing: Metrics.xl

                    Icon {
                        Layout.alignment: Qt.AlignTop
                        name: banner.bannerBad ? "warn" : "check"
                        size: Metrics.icon
                        color: banner.bannerBad ? Colors.urgent : Colors.accent
                    }

                    Text {
                        id: bannerText
                        Layout.fillWidth: true
                        color: Colors.foreground
                        font.pixelSize: Metrics.body
                        wrapMode: Text.Wrap
                    }

                    AppButton {
                        visible: !backend.engineAvailable()
                        text: qsTrId("dashboard.copy_install_command")
                        icon: "copy"
                        onClicked: {
                            installCommand.text = "curl -fsSL " + appInfo.installScriptUrl + " | bash";
                            installCommand.selectAll();
                            installCommand.copy();
                            installCommand.deselect();
                            banner.show(qsTrId("dashboard.install_command_copied"), false);
                        }
                    }

                    // Off-screen, purely to own the clipboard copy: the command
                    // is shown as a message rather than run, because fetching
                    // and executing a script on the user's behalf is not
                    // something a window should decide.
                    TextEdit {
                        id: installCommand
                        visible: false
                    }

                    IconAction {
                        icon: "close"
                        onTriggered: banner.visible = false
                    }
                }
            }

            // Hero --------------------------------------------------------
            Card {
                Layout.fillWidth: true
                Layout.leftMargin: Metrics.pagePadding
                Layout.rightMargin: Metrics.pagePadding
                accented: page.ready
                implicitHeight: heroColumn.implicitHeight + Metrics.cardPadding * 2

                ColumnLayout {
                    id: heroColumn
                    anchors.fill: parent
                    anchors.margins: Metrics.cardPadding
                    spacing: Metrics.sm

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Metrics.xxl

                        Icon {
                            name: page.ready ? "display" : "warn"
                            size: Metrics.iconLarge
                            color: page.ready ? Colors.accent : Colors.muted
                        }

                        Text {
                            Layout.fillWidth: true
                            text: page.ready ? qsTrId("dashboard.console_ready")
                                             : qsTrId("dashboard.console_not_ready")
                            color: page.ready ? Colors.accent : Colors.foreground
                            font.pixelSize: Metrics.display
                            font.bold: true
                            wrapMode: Text.Wrap
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        Layout.topMargin: Metrics.xxs
                        text: page.ready ? qsTrId("dashboard.console_ready_body").arg(page.displayName)
                                         : qsTrId("dashboard.console_not_ready_body")
                        color: Colors.muted
                        font.pixelSize: Metrics.body
                        wrapMode: Text.Wrap
                    }
                }
            }

            // The action --------------------------------------------------
            AppButton {
                Layout.fillWidth: true
                Layout.leftMargin: Metrics.pagePadding
                Layout.rightMargin: Metrics.pagePadding
                large: true
                primary: true
                icon: "enter"
                text: qsTrId("dashboard.enter_console")
                enabled: page.ready && !backend.running
                onClicked: countdown.arm()
            }

            // Safe mode / disabled --------------------------------------------
            //
            // The wrapper is hosting only the desktop. In safe mode it lifts on
            // its own after one login that lasts; these are the shortcuts --
            // offer the console again now, or make the hold stick so a machine
            // that was looping stops trying. When disabled, only the first one
            // applies. No root: a marker file in the user's own config directory.
            RowLayout {
                id: holdActions
                Layout.fillWidth: true
                Layout.leftMargin: Metrics.pagePadding
                Layout.rightMargin: Metrics.pagePadding
                visible: !!page.status.safe_mode || page.status.disabled === true
                spacing: Metrics.md

                function apply(enable) {
                    if (backend.setConsoleEnabled(enable)) {
                        page.reload();
                        page.loadLog();
                    }
                }

                AppButton {
                    Layout.fillWidth: true
                    icon: "enter"
                    text: qsTrId("dashboard.console_enable")
                    onClicked: holdActions.apply(true)
                }
                AppButton {
                    Layout.fillWidth: true
                    visible: page.status.disabled !== true
                    icon: "close"
                    text: qsTrId("dashboard.console_disable")
                    onClicked: holdActions.apply(false)
                }
            }

            AppButton {
                Layout.alignment: Qt.AlignHCenter
                visible: !page.ready
                text: qsTrId("app.settings")
                icon: "settings"
                onClicked: page.settingsRequested()
            }

            // Requirements ------------------------------------------------
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Metrics.pagePadding
                Layout.rightMargin: Metrics.pagePadding
                spacing: Metrics.rowGap

                SectionLabel { label: qsTrId("dashboard.console_status") }

                Repeater {
                    model: page.status.requirements || []
                    StatusDot {
                        Layout.fillWidth: true
                        ok: modelData.ok
                        text: modelData.ok ? modelData.have : modelData.want
                    }
                }

                AppButton {
                    Layout.topMargin: Metrics.xs
                    text: qsTrId("dashboard.refresh_status")
                    icon: "refresh"
                    onClicked: {
                        page.reload();
                        page.loadLog();
                        historySelect.currentIndex = -1;
                    }
                }
            }

            // Log ---------------------------------------------------------
            ColumnLayout {
                id: logSection
                Layout.fillWidth: true
                Layout.leftMargin: Metrics.pagePadding
                Layout.rightMargin: Metrics.pagePadding
                spacing: Metrics.rowGap

                property bool expanded: false

                MouseArea {
                    id: logHeader
                    Layout.fillWidth: true
                    implicitHeight: logHeaderRow.implicitHeight
                    cursorShape: Qt.PointingHandCursor
                    onClicked: logSection.expanded = !logSection.expanded

                    RowLayout {
                        id: logHeaderRow
                        anchors.fill: parent
                        spacing: Metrics.lg

                        Icon {
                            name: "log"
                            size: Metrics.iconSmall
                            color: Colors.muted
                        }

                        SectionLabel {
                            Layout.fillWidth: true
                            label: qsTrId("dashboard.logs")
                        }

                        Icon {
                            name: "chevron"
                            size: Metrics.icon
                            color: logHeader.containsMouse ? Colors.foreground : Colors.muted
                            rotation: logSection.expanded ? 180 : 0
                            Behavior on rotation { NumberAnimation { duration: Metrics.moveDuration; easing.type: Easing.OutCubic } }
                        }
                    }
                }

                Card {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Metrics.logHeight
                    visible: logSection.expanded

                    Controls.ScrollView {
                        anchors.fill: parent
                        anchors.margins: Metrics.lg
                        clip: true

                        Controls.TextArea {
                            id: logView
                            readOnly: true
                            wrapMode: Text.Wrap
                            color: Colors.muted
                            font.family: Metrics.monoFamily
                            font.pixelSize: Metrics.caption
                            background: null
                            selectByMouse: true
                        }
                    }
                }

                // Past runs. The engine keeps one file per session, and the
                // one worth reading is almost always the session that just
                // failed -- so this sits with the log rather than behind a
                // separate browser.
                RowLayout {
                    Layout.fillWidth: true
                    visible: logSection.expanded && historySelect.count > 0
                    spacing: Metrics.md

                    Text {
                        text: qsTrId("dashboard.log_history")
                        color: Colors.muted
                        font.pixelSize: Metrics.caption
                    }

                    Select {
                        id: historySelect
                        Layout.fillWidth: true
                        property var entries: []
                        textRole: "name"
                        model: entries
                        onActivated: {
                            const entry = entries[currentIndex];
                            if (!entry) return;
                            logView.text = backend.readHistoryLog(entry.id);
                            page.viewingHistory = entry.id;
                        }
                    }

                    AppButton {
                        visible: page.viewingHistory !== ""
                        text: qsTrId("dashboard.back_to_live_log")
                        icon: "refresh"
                        onClicked: { page.loadLog(); historySelect.currentIndex = -1; }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    visible: logSection.expanded
                    spacing: Metrics.md

                    AppButton {
                        text: qsTrId("dashboard.copy_logs")
                        icon: "copy"
                        onClicked: page.viewingHistory === "" ? backend.copyLogToClipboard()
                                                            : backend.copyHistoryLogToClipboard(page.viewingHistory)
                    }
                    AppButton {
                        text: qsTrId("dashboard.download_logs")
                        icon: "save"
                        onClicked: {
                            const path = page.viewingHistory === "" ? backend.exportLogToHome()
                                                                    : backend.exportHistoryLog(page.viewingHistory);
                            if (path !== "") {
                                banner.show(qsTrId("dashboard.log_saved").arg(path), false);
                            }
                        }
                    }
                    AppButton {
                        text: qsTrId("dashboard.clear_logs")
                        icon: "clear"
                        onClicked: { backend.clearLog(); page.loadLog(); }
                    }
                    Item { Layout.fillWidth: true }
                }
            }

            // Support ------------------------------------------------------
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Metrics.pagePadding
                Layout.rightMargin: Metrics.pagePadding
                Layout.topMargin: Metrics.x4
                spacing: Metrics.lg

                Rectangle {
                    Layout.fillWidth: true
                    Layout.bottomMargin: Metrics.sm
                    height: 1
                    color: Colors.hairline
                }

                Text {
                    Layout.fillWidth: true
                    text: qsTrId("support.description")
                    color: Colors.muted
                    font.pixelSize: Metrics.caption
                    wrapMode: Text.Wrap
                }

                AppButton {
                    Layout.alignment: Qt.AlignLeft
                    text: qsTrId("support.buy_coffee")
                    icon: "heart"
                    onClicked: Qt.openUrlExternally("https://www.buymeacoffee.com/gustavobelo")
                }
            }

            Item { Layout.preferredHeight: Metrics.x4 }
        }
    }

    // The countdown ---------------------------------------------------------
    //
    // Full screen, because it is the most consequential moment in the app: the
    // desktop session is about to end and everything open in it goes too. A
    // dialog that can be missed is not a warning.
    Rectangle {
        id: countdown
        anchors.fill: parent
        color: Colors.scrim
        visible: opacity > 0
        opacity: 0
        z: 10

        property int remaining: 10
        // An entry announced by the engine -- a controller switched on -- is
        // counted down by the wrapper, and it is the wrapper that will stop the
        // compositor. This window only shows the same clock and offers the same
        // way out, so it must not enter anything itself when it reaches zero.
        property bool external: false
        property string trigger: ""

        function arm() {
            if (!backend.engineAvailable()) {
                banner.show(qsTrId("engine.missing"), true);
                return;
            }
            banner.visible = false;
            external = false;
            trigger = "";
            remaining = 10;
            opacity = 1;
            ticker.restart();
        }

        // Armed from the announcement the wrapper left, seconds remaining and
        // all: the window may have been opened halfway through one.
        function sync() {
            const pending = backend.pendingEntry();
            if (pending && pending.seconds > 0) {
                banner.visible = false;
                external = true;
                trigger = pending.trigger || "";
                remaining = pending.seconds;
                opacity = 1;
                ticker.restart();
            } else if (external) {
                stand_down();
            }
        }

        function stand_down() {
            ticker.stop();
            opacity = 0;
            external = false;
        }

        Behavior on opacity { NumberAnimation { duration: Metrics.moveDuration; easing.type: Easing.OutCubic } }

        MouseArea { anchors.fill: parent }

        ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(parent.width - Metrics.pagePadding * 2, Metrics.countdownWidth)
            spacing: Metrics.x4

            SectionLabel {
                Layout.alignment: Qt.AlignHCenter
                label: qsTrId("dashboard.countdown_title")
            }

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: countdown.remaining
                color: Colors.accent
                font.pixelSize: Metrics.numeral
                font.bold: true
            }

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                visible: countdown.trigger === "controller"
                text: qsTrId("dashboard.countdown_trigger_controller")
                color: Colors.muted
                font.pixelSize: Metrics.body
                wrapMode: Text.Wrap
            }

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: qsTrId("dashboard.countdown_body").arg(page.displayName)
                color: Colors.foreground
                font.pixelSize: Metrics.body
                wrapMode: Text.Wrap
            }

            AppButton {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: Metrics.md
                large: true
                icon: "close"
                text: qsTrId("common.cancel")
                onClicked: {
                    // The engine is counting down too, and the file it polls
                    // for is the only thing that reaches it.
                    if (countdown.external) {
                        backend.cancelEntry();
                    }
                    countdown.stand_down();
                }
            }
        }

        Timer {
            id: ticker
            interval: 1000
            repeat: true
            onTriggered: {
                countdown.remaining -= 1;
                if (countdown.remaining > 0) {
                    return;
                }
                const ours = !countdown.external;
                countdown.stand_down();
                if (ours) {
                    backend.enterConsole();
                }
            }
        }
    }
}
