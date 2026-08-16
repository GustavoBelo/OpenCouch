import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami

Kirigami.ScrollablePage {
    id: page
    title: "Open Couch"

    signal reconfigureRequested()
    signal helpRequested()

    property int logPanelHeight: Kirigami.Units.gridUnit * 10
    readonly property int logPanelMinHeight: Kirigami.Units.gridUnit * 4
    property int logPanelMaxHeight: Math.max(logPanelMinHeight, page.height - Kirigami.Units.gridUnit * 10)
    property real logResizeStartY: 0
    property int logResizeStartHeight: 0
    property string viewingHistoryId: ""
    property string viewingHistoryName: ""
    property string liveLogCache: ""

    actions: [
        Kirigami.Action {
            text: qsTrId("dashboard.help")
            icon.name: "help-about"
            onTriggered: page.helpRequested()
        },
        Kirigami.Action {
            text: qsTrId("app.settings")
            icon.name: "configure"
            onTriggered: page.reconfigureRequested()
        }
    ]

    Component.onCompleted: {
        backend.refreshStatus();

        let rawContent = backend.readLog();
        if (rawContent !== undefined && rawContent !== "") {
            let lines = rawContent.split('\n');
            let formattedLines = [];
            for (let i = 0; i < lines.length; i++) {
                if (i === lines.length - 1 && lines[i] === "") continue;
                formattedLines.push(logArea.getFormattedLine(lines[i]));
            }
            logArea.text = formattedLines.join("<br/>");
            logArea.cursorPosition = logArea.length;
        }

        if (backend.watcherEnabled()) {
            backend.startWatcher();
        }
        
        if (!backend.engineAvailable()) {
            banner.type = Kirigami.MessageType.Warning;
            banner.text = qsTrId("engine.missing")
            banner.visible = true;
        }
    }

    Timer {
        id: statusFeedbackTimer
        interval: 2500
        onTriggered: banner.visible = false
    }

    Connections {
        target: backend
        function onLogLine(line) {
            logArea.append(line);
        }
        function onActionFinished(success, message) {
            banner.type = success ? Kirigami.MessageType.Positive : Kirigami.MessageType.Error;
            banner.text = message;
            banner.visible = true;
            backend.refreshStatus();
        }
        function onStatusUpdated(text) {
            statusArea.text = text;
        }
    }

    ColumnLayout {
        width: page.width
        spacing: Kirigami.Units.largeSpacing

        Kirigami.InlineMessage {
            id: banner
            Layout.fillWidth: true
            visible: false
            showCloseButton: true
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Kirigami.Units.gridUnit * 4
            visible: backend.running
            radius: Kirigami.Units.smallSpacing
            color: Kirigami.Theme.positiveBackgroundColor
            border.color: Kirigami.Theme.positiveTextColor
            border.width: 1

            RowLayout {
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing
                spacing: Kirigami.Units.largeSpacing

                Kirigami.Icon {
                    source: "video-display"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.large
                    Layout.preferredHeight: Kirigami.Units.iconSizes.large
                    Layout.alignment: Qt.AlignVCenter
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 2

                    Kirigami.Heading {
                        level: 3
                        text: qsTrId("status.couch")
                        color: Kirigami.Theme.positiveTextColor
                    }

                    Controls.Label {
                        text: qsTrId("dashboard.couch_active")
                        opacity: 0.85
                        font.pixelSize: Math.max(9, Kirigami.Theme.defaultFont.pixelSize - 1)
                        color: Kirigami.Theme.positiveTextColor
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.largeSpacing

            Controls.Button {
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 3
                text: qsTrId("dashboard.enter_couch")
                icon.name: "media-playback-start"
                highlighted: !backend.running
                enabled: !backend.running
                onClicked: {
                    if(!backend.engineAvailable()) {
                        permissionPopup.open();
                        return;
                    }
                    banner.visible = false;
                    backend.play();
                }
            }

            Controls.Button {
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 3
                text: qsTrId("dashboard.return_desktop")
                icon.name: "go-home"
                enabled: backend.running
                highlighted: backend.running
                onClicked: {
                    banner.visible = false;
                    backend.restore();
                }
            }
        }

        Kirigami.Heading {
            text: qsTrId("dashboard.display_status")
            level: 3
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        Controls.Label {
            id: statusArea
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: qsTrId("common.loading")
            opacity: 0.85
        }

        Controls.Button {
            text: qsTrId("dashboard.refresh_status")
            icon.name: "view-refresh"
            onClicked: {
                backend.refreshStatus();
                banner.type = Kirigami.MessageType.Positive;
                banner.text = qsTrId("dashboard.status_updated");
                banner.visible = true;
                statusFeedbackTimer.restart();
            }
        }

        Kirigami.Heading {
            text: qsTrId("common.log")
            level: 3
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Controls.Button {
                text: qsTrId("dashboard.copy_log")
                icon.name: "edit-copy"
                enabled: page.viewingHistoryId === ""
                onClicked: {
                    backend.copyLogToClipboard();
                    banner.type = Kirigami.MessageType.Positive;
                    banner.text = qsTrId("dashboard.log_copied");
                    banner.visible = true;
                }
            }

            Controls.Button {
                text: qsTrId("dashboard.log_history")
                icon.name: "document-open-recent"
                onClicked: historyDialog.open()
            }

            Controls.ToolButton {
                id: logOverflowButton
                icon.name: "overflow-menu"
                enabled: page.viewingHistoryId === ""
                onClicked: logOptionsMenu.popup(logOverflowButton)
                
                Controls.Menu {
                    id: logOptionsMenu

                    Controls.MenuItem {
                        text: qsTrId("dashboard.download_log")
                        icon.name: "document-save"
                        onTriggered: {
                            const path = backend.exportLogToHome();
                            if (path.length > 0) {
                                banner.type = Kirigami.MessageType.Positive;
                                banner.text = qsTrId("dashboard.log_saved").arg(path);
                            } else {
                                banner.type = Kirigami.MessageType.Error;
                                banner.text = qsTrId("dashboard.log_save_failed");
                            }
                            banner.visible = true;
                        }
                    }

                    Controls.MenuItem {
                        text: qsTrId("dashboard.clear_log")
                        icon.name: "edit-clear"
                        onTriggered: {
                            logArea.clear();
                            backend.clearLog();
                            banner.type = Kirigami.MessageType.Positive;
                            banner.text = qsTrId("dashboard.log_cleared");
                            banner.visible = true;
                        }
                    }
                }
            }

            Item { Layout.fillWidth: true }
        }

        Kirigami.InlineMessage {
            id: historyModeBanner
            Layout.fillWidth: true
            Layout.bottomMargin: Kirigami.Units.smallSpacing
            visible: page.viewingHistoryId !== ""
            type: Kirigami.MessageType.Warning
            text: qsTrId("dashboard.viewing_history").arg(page.viewingHistoryName)
            actions: [
                Kirigami.Action {
                    text: qsTrId("dashboard.back_to_live_log")
                    icon.name: "media-skip-backward"
                    onTriggered: {
                        page.viewingHistoryId = "";
                        page.viewingHistoryName = "";
                        logArea.text = page.liveLogCache;
                        logArea.cursorPosition = logArea.length;
                    }
                }
            ]
        }

        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: page.logPanelHeight

            Controls.ScrollView {
                id: logScroll
                anchors.fill: parent
                clip: true
                Controls.ScrollBar.vertical.policy: Controls.ScrollBar.AsNeeded

                Controls.TextArea {
                    id: logArea
                    width: logScroll.availableWidth
                    readOnly: true
                    wrapMode: Controls.TextArea.Wrap
                    textFormat: TextEdit.RichText

                    function escapeHtml(value) {
                        return value
                            .replace(/&/g, "&amp;")
                            .replace(/</g, "&lt;")
                            .replace(/>/g, "&gt;")
                            .replace(/"/g, "&quot;");
                    }

                    function getFormattedLine(line) {
                        const safeLine = escapeHtml(line);
                        return /(ERRO|ERROR|error)/.test(line)
                            ? "<font color=\"#ef5350\">" + safeLine + "</font>"
                            : safeLine;
                    }

                    function clear() {
                        text = "";
                        page.liveLogCache = "";
                    }

                    function append(line) {
                        const formatted = getFormattedLine(line);

                        if (page.viewingHistoryId === "") {
                            text += (text.length > 0 ? "<br/>" : "") + formatted;
                            cursorPosition = length;
                        } else {
                            page.liveLogCache += (page.liveLogCache.length > 0 ? "<br/>" : "") + formatted;
                        }
                    }
                }

                WheelHandler {
                    target: parent
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    onWheel: (event) => {
                        event.accepted = true
                        const bar = logScroll.ScrollBar.vertical
                        if (bar.size >= 1) return
                        const step = event.angleDelta.y / 120 * Kirigami.Units.gridUnit * 3
                        bar.position = Math.max(0, Math.min(1 - bar.size, bar.position - step / logArea.implicitHeight))
                    }
                }
            }
        }

        MouseArea {
            id: logResizeHandle
            Layout.fillWidth: true
            Layout.preferredHeight: Kirigami.Units.smallSpacing * 2
            Layout.topMargin: Kirigami.Units.smallSpacing
            cursorShape: Qt.SizeVerCursor
            hoverEnabled: true
            preventStealing: true

            Rectangle {
                anchors.fill: parent
                color: logResizeHandle.containsMouse || logResizeHandle.pressed ? Kirigami.Theme.highlightColor : "transparent"
                opacity: logResizeHandle.pressed ? 0.7 : (logResizeHandle.containsMouse ? 0.4 : 0.2)
            }

            Controls.ToolTip.visible: logResizeHandle.containsMouse && !logResizeHandle.pressed
            Controls.ToolTip.text: qsTrId("dashboard.log_resize_hint")

            onPressed: (mouse) => {
                const p = logResizeHandle.mapToGlobal(mouse.x, mouse.y);
                page.logResizeStartY = p.y;
                page.logResizeStartHeight = page.logPanelHeight;
            }
            onPositionChanged: (mouse) => {
                if (!pressed) return;

                const p = logResizeHandle.mapToGlobal(mouse.x, mouse.y);
                const newHeight = page.logResizeStartHeight + (p.y - page.logResizeStartY);
                const originalSize = Kirigami.Units.gridUnit * 10;
                
                page.logPanelHeight = Math.max(originalSize, Math.min(page.logPanelMaxHeight, newHeight));
            }
            
            onDoubleClicked: {
                page.logPanelHeight = Kirigami.Units.gridUnit * 10;
            }
        }

        Kirigami.Separator {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.largeSpacing
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing 

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing

                Kirigami.Icon {
                    source: "help-donate"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                    Layout.alignment: Qt.AlignTop 
                }

                Controls.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: qsTrId("support.description")
                    opacity: 0.8
                }
            }

            Controls.Button {
                text: qsTrId("support.buy_coffee")
                icon.name: "help-donate"
                Layout.alignment: Qt.AlignRight
                onClicked: Qt.openUrlExternally("https://www.buymeacoffee.com/gustavobelo")
            }
        }

        Controls.Label {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignRight
            text: qsTrId("common.version").arg(appInfo.formattedVersion())
            opacity: 0.7
        }
    }

        Controls.Popup {
            id: permissionPopup
            parent: Controls.Overlay.overlay
            modal: true
            focus: true
            dim: true
            closePolicy: Controls.Popup.CloseOnEscape | Controls.Popup.CloseOnPressOutside
            anchors.centerIn: parent
            implicitWidth: Math.min(parent ? parent.width * 0.9 : 500, Kirigami.Units.gridUnit * 35)
            implicitHeight: Math.min(parent ? parent.height * 0.9 : 600, permLayout.implicitHeight + padding * 2)
            padding: Kirigami.Units.largeSpacing

            background: Rectangle {
                radius: Kirigami.Units.largeSpacing
                color: Kirigami.Theme.backgroundColor
                border.color: Kirigami.Theme.focusColor
                border.width: 1
                opacity: 0.95
            }

            contentItem: ColumnLayout {
                id: permLayout
                spacing: Kirigami.Units.largeSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Kirigami.Icon {
                        source: "dialog-warning"
                        Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                        Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                        Kirigami.Theme.colorSet: Kirigami.Theme.Button
                        Kirigami.Theme.inherit: false
                    }

                    Kirigami.Heading {
                        text: qsTrId("dashboard.permission_popup_title")
                        level: 2
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                    }
                }

                Kirigami.Separator {
                    Layout.fillWidth: true
                }

                Controls.ScrollView {
                    id: permScrollView
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff

                    ColumnLayout {
                        width: permScrollView.availableWidth
                        spacing: Kirigami.Units.largeSpacing

                        Controls.Label {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            text: qsTrId("onboarding.requirement_description")
                            font.pointSize: Kirigami.Theme.defaultFont.pointSize + 1
                            opacity: 0.9
                        }

                        Controls.Label {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            text: qsTrId("onboarding.install_description")
                            opacity: 0.85
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: permInstallRow.implicitHeight + Kirigami.Units.smallSpacing * 2
                            color: Kirigami.Theme.alternateBackgroundColor
                            radius: Kirigami.Units.smallSpacing
                            border.color: Kirigami.Theme.focusColor
                            border.width: 1
                            opacity: 0.9

                            RowLayout {
                                id: permInstallRow
                                anchors.fill: parent
                                anchors.margins: Kirigami.Units.smallSpacing
                                spacing: Kirigami.Units.smallSpacing

                                Controls.TextArea {
                                    id: permCmdField
                                    Layout.fillWidth: true
                                    text: "bash <(curl -fsSL " + appInfo.installScriptUrl + ")"
                                    font.family: "monospace"
                                    readOnly: true
                                    wrapMode: Text.WrapAnywhere
                                    selectByMouse: true
                                    background: null
                                    color: Kirigami.Theme.textColor
                                    topPadding: 0
                                    bottomPadding: 0
                                }

                                Controls.ToolButton {
                                    icon.name: "edit-copy"
                                    Layout.alignment: Qt.AlignTop
                                    Controls.ToolTip.text: qsTrId("common.copy_command")
                                    Controls.ToolTip.visible: hovered
                                    onClicked: {
                                        permCmdField.selectAll();
                                        permCmdField.copy();
                                        permCmdField.deselect();
                                        icon.name = "dialog-ok";
                                        permCopyTimer.start();
                                    }

                                    Timer {
                                        id: permCopyTimer
                                        interval: 2000
                                        onTriggered: parent.icon.name = "edit-copy"
                                    }
                                }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: permWarnLabel.implicitHeight + Kirigami.Units.smallSpacing * 2
                            color: Kirigami.Theme.neutralBackgroundColor
                            border.color: Kirigami.Theme.neutralTextColor
                            border.width: 1
                            radius: Kirigami.Units.smallSpacing
                            opacity: 0.9

                            Controls.Label {
                                id: permWarnLabel
                                anchors {
                                    left: parent.left
                                    right: parent.right
                                    top: parent.top
                                    margins: Kirigami.Units.smallSpacing
                                }
                                wrapMode: Text.Wrap
                                text: qsTrId("dashboard.permission_reopen_warning")
                                opacity: 0.9
                            }
                        }
                    }
                }

                Kirigami.Separator {
                    Layout.fillWidth: true
                }

                RowLayout {
                    Layout.fillWidth: true

                    Item { Layout.fillWidth: true }

                    Controls.Button {
                        text: qsTrId("common.got_it")
                        icon.name: "dialog-ok"
                        highlighted: true
                        onClicked: permissionPopup.close()

                        Component.onCompleted: forceActiveFocus()
                    }
                }
            }
        }

    Controls.Dialog {
        id: historyDialog
        parent: Controls.Overlay.overlay
        title: qsTrId("dashboard.history_title")
        modal: true
        standardButtons: Controls.Dialog.Close
        implicitWidth: Math.min(620, page.width > 0 ? page.width - Kirigami.Units.gridUnit * 4 : 600)

        property var entries: []
        property string selectedId: ""

        onAboutToShow: {
            entries = backend.logHistory();
            selectedId = entries.length > 0 ? entries[0].id : "";
        }

        function formatTimestamp(raw) {
            if (raw.length < 15) {
                return raw;
            }
            return raw.slice(0, 4) + "-" + raw.slice(4, 6) + "-" + raw.slice(6, 8)
                + " " + raw.slice(9, 11) + ":" + raw.slice(11, 13) + ":" + raw.slice(13, 15);
        }

        function formatSize(bytes) {
            if (bytes < 1024) {
                return bytes + " B";
            }
            if (bytes < 1048576) {
                return (bytes / 1024).toFixed(1) + " KB";
            }
            return (bytes / 1048576).toFixed(1) + " MB";
        }

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.largeSpacing

            Controls.Label {
                Layout.fillWidth: true
                visible: historyDialog.entries.length === 0
                wrapMode: Text.WordWrap
                opacity: 0.8
                text: qsTrId("dashboard.history_empty")
            }

            ListView {
                id: historyList
                Layout.fillWidth: true
                
                Layout.preferredHeight: Math.min(contentHeight, maxListHeight)
                readonly property int maxListHeight: Math.min(360, page.height > 0 ? page.height - Kirigami.Units.gridUnit * 16 : 240)
                
                visible: historyDialog.entries.length > 0
                clip: true
                spacing: Kirigami.Units.smallSpacing
                model: historyDialog.entries
                currentIndex: -1

                delegate: Controls.ItemDelegate {
                    width: ListView.view.width
                    highlighted: modelData.id === historyDialog.selectedId
                    onClicked: {
                        historyDialog.selectedId = modelData.id;
                        historyList.currentIndex = index;
                    }

                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Icon {
                            source: "text-x-log"
                            Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                            Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            Controls.Label {
                                Layout.fillWidth: true
                                text: historyDialog.formatTimestamp(modelData.timestamp)
                            }

                            Controls.Label {
                                Layout.fillWidth: true
                                text: historyDialog.formatSize(modelData.size)
                                opacity: 0.7
                                font.pixelSize: Math.max(9, Kirigami.Theme.defaultFont.pixelSize - 1)
                            }
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Controls.Button {
                    text: qsTrId("dashboard.view")
                    icon.name: "document-preview"
                    enabled: historyDialog.selectedId.length > 0
                    onClicked: {
                        let selectedEntry = historyDialog.entries.find(e => e.id === historyDialog.selectedId);
                        let timestampStr = selectedEntry ? historyDialog.formatTimestamp(selectedEntry.timestamp) : historyDialog.selectedId;

                        let rawContent = backend.readHistoryLog(historyDialog.selectedId);
                        
                        if (rawContent !== undefined && rawContent !== "") {
                            if (page.viewingHistoryId === "") {
                                page.liveLogCache = logArea.text;
                            }
                            
                            page.viewingHistoryId = historyDialog.selectedId;
                            page.viewingHistoryName = timestampStr;

                            let lines = rawContent.split('\n');
                            let formattedLines = [];
                            for (let i = 0; i < lines.length; i++) {
                                if (i === lines.length - 1 && lines[i] === "") continue;
                                formattedLines.push(logArea.getFormattedLine(lines[i]));
                            }
                            
                            logArea.text = formattedLines.join("<br/>");
                            historyDialog.close();
                        } else {
                            banner.type = Kirigami.MessageType.Error;
                            banner.text = qsTrId("dashboard.read_log_failed");
                            banner.visible = true;
                        }
                    }
                }

                Controls.Button {
                    text: qsTrId("dashboard.history_copy")
                    icon.name: "edit-copy"
                    enabled: historyDialog.selectedId.length > 0
                    onClicked: {
                        const ok = backend.copyHistoryLogToClipboard(historyDialog.selectedId);
                        historyDialog.close();
                        banner.type = ok ? Kirigami.MessageType.Positive : Kirigami.MessageType.Error;
                        banner.text = ok ? qsTrId("dashboard.log_copied") : qsTrId("dashboard.history_action_failed");
                        banner.visible = true;
                    }
                }

                Controls.Button {
                    text: qsTrId("dashboard.history_download")
                    icon.name: "document-save"
                    enabled: historyDialog.selectedId.length > 0
                    onClicked: {
                        const path = backend.exportHistoryLog(historyDialog.selectedId);
                        historyDialog.close();
                        if (path.length > 0) {
                            banner.type = Kirigami.MessageType.Positive;
                            banner.text = qsTrId("dashboard.log_saved").arg(path);
                        } else {
                            banner.type = Kirigami.MessageType.Error;
                            banner.text = qsTrId("dashboard.history_action_failed");
                        }
                        banner.visible = true;
                    }
                }

                Item {
                    Layout.fillWidth: true
                }
            }
        }
    }
}
