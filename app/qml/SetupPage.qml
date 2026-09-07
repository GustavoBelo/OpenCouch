import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import io.github.gustavobelo.opencouch

Item {
    id: page

    property var status: ({})
    property var displays: []
    // Read once per reload rather than bound: neither answer comes from a
    // property with a change signal, so a binding would be evaluated when the
    // page was built and never again.
    property bool autostart: false
    property bool startMinimized: false
    property bool backgroundOnClose: true

    function reload() {
        page.status = backend.consoleStatus();
        page.displays = backend.listDisplays();
        page.autostart = backend.autostartEnabled();
        page.startMinimized = backend.startMinimized();
        page.backgroundOnClose = backend.backgroundOnClose();
        // Assigned, not bound. Activating a ComboBox writes currentIndex, and
        // that write replaces whatever binding was there -- so after the first
        // choice the control would stop following the engine.
        bootSelect.currentIndex = page.bootIndex();
    }

    function bootIndex() {
        const boot = page.status.boot || "desktop";
        return boot === "console" ? 1 : (boot === "last" ? 2 : 0);
    }

    // The connector is what gamescope takes; the description is what a person
    // recognises. Both are shown, because a machine with two HDMI ports gives
    // no other way to tell which one the cable is in.
    function displayLabel(display) {
        if (!display) return "";
        return display.description === display.connector
            ? display.connector
            : display.description + "  ·  " + display.connector;
    }

    function chosenIndex() {
        for (var i = 0; i < page.displays.length; i++) {
            if (page.displays[i].connector === page.status.tv_name) return i;
        }
        return -1;
    }

    Component.onCompleted: page.reload()

    // Every setting here is one engine call. Rather than each of them
    // remembering to refresh afterwards, the page listens for the engine
    // having been told something.
    Connections {
        target: backend
        function onConfigChanged() { page.reload(); }
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

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: Metrics.pagePadding
                Layout.rightMargin: Metrics.pagePadding
                text: qsTrId("settings.console_description")
                color: Colors.muted
                font.pixelSize: Metrics.body
                wrapMode: Text.Wrap
            }

            // Requirements ------------------------------------------------
            Card {
                Layout.fillWidth: true
                Layout.leftMargin: Metrics.pagePadding
                Layout.rightMargin: Metrics.pagePadding
                implicitHeight: reqColumn.implicitHeight + Metrics.cardPadding * 2

                ColumnLayout {
                    id: reqColumn
                    anchors.fill: parent
                    anchors.margins: Metrics.cardPadding
                    spacing: Metrics.rowGap

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Metrics.lg

                        Icon {
                            name: page.status.ready === true ? "check" : "warn"
                            size: Metrics.icon
                            color: page.status.ready === true ? Colors.accent : Colors.urgent
                        }

                        Text {
                            Layout.fillWidth: true
                            text: page.status.ready === true ? qsTrId("settings.ready")
                                                             : qsTrId("settings.not_ready")
                            color: Colors.foreground
                            font.pixelSize: Metrics.title
                            font.bold: true
                            wrapMode: Text.Wrap
                        }

                        AppButton {
                            text: qsTrId("settings.recheck")
                            icon: "refresh"
                            onClicked: page.reload()
                        }
                    }

                    Repeater {
                        model: page.status.requirements || []
                        StatusDot {
                            Layout.fillWidth: true
                            Layout.leftMargin: Metrics.xs
                            ok: modelData.ok
                            text: modelData.ok ? modelData.have : modelData.want
                        }
                    }
                }
            }

            // Hosting session ---------------------------------------------
            Card {
                Layout.fillWidth: true
                Layout.leftMargin: Metrics.pagePadding
                Layout.rightMargin: Metrics.pagePadding
                implicitHeight: hostColumn.implicitHeight + Metrics.cardPadding * 2

                ColumnLayout {
                    id: hostColumn
                    anchors.fill: parent
                    anchors.margins: Metrics.cardPadding
                    spacing: Metrics.labelGap

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Metrics.lg
                        Icon { name: "session"; size: Metrics.icon; color: Colors.foreground }
                        SectionLabel { Layout.fillWidth: true; label: qsTrId("settings.hosting_session") }
                    }

                    // Whether this needs root depends on the machine -- a package
                    // installs the entry for every account, greetd and a bare tty
                    // read the user's own directory, and only the common display
                    // managers need it in /usr. So the card reports the state
                    // rather than warning about root unconditionally.
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: Metrics.xs
                        visible: page.status.hosting_installed === true
                        spacing: Metrics.md

                        Icon { name: "check"; size: Metrics.iconSmall; color: Colors.accent }

                        Text {
                            Layout.fillWidth: true
                            text: qsTrId("settings.hosting_installed")
                            color: Colors.muted
                            font.pixelSize: Metrics.body
                            wrapMode: Text.Wrap
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        Layout.topMargin: Metrics.xs
                        visible: page.status.hosting_installed !== true
                        text: qsTrId("settings.hosting_description")
                        color: Colors.muted
                        font.pixelSize: Metrics.body
                        wrapMode: Text.Wrap
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: Metrics.md
                        spacing: Metrics.md

                        AppButton {
                            text: page.status.hosting_installed === true
                                  ? qsTrId("settings.recheck_setup") : qsTrId("settings.run_setup")
                            icon: "session"
                            onClicked: {
                                const instructions = backend.runSetup();
                                if (instructions !== "") {
                                    setupOutput.text = instructions;
                                    setupOutput.visible = true;
                                }
                            }
                        }

                        AppButton {
                            visible: setupOutput.visible
                            text: qsTrId("common.copy")
                            icon: "copy"
                            onClicked: { setupOutput.selectAll(); setupOutput.copy(); setupOutput.deselect(); }
                        }

                        Item { Layout.fillWidth: true }
                    }

                    Card {
                        Layout.fillWidth: true
                        Layout.topMargin: Metrics.sm
                        visible: setupOutput.visible
                        implicitHeight: setupOutput.implicitHeight + Metrics.x4

                        Controls.TextArea {
                            id: setupOutput
                            anchors.fill: parent
                            anchors.margins: Metrics.lg
                            visible: false
                            readOnly: true
                            wrapMode: Text.Wrap
                            color: Colors.foreground
                            font.family: Metrics.monoFamily
                            font.pixelSize: Metrics.caption
                            background: null
                            selectByMouse: true
                        }
                    }
                }
            }

            // The console display -----------------------------------------
            Card {
                Layout.fillWidth: true
                Layout.leftMargin: Metrics.pagePadding
                Layout.rightMargin: Metrics.pagePadding
                implicitHeight: displayColumn.implicitHeight + Metrics.cardPadding * 2

                ColumnLayout {
                    id: displayColumn
                    anchors.fill: parent
                    anchors.margins: Metrics.cardPadding
                    spacing: Metrics.labelGap

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Metrics.lg
                        Icon { name: "display"; size: Metrics.icon; color: Colors.foreground }
                        SectionLabel { Layout.fillWidth: true; label: qsTrId("settings.console_display") }
                    }

                    Text {
                        Layout.fillWidth: true
                        Layout.topMargin: Metrics.xs
                        text: qsTrId("settings.console_display_description")
                        color: Colors.muted
                        font.pixelSize: Metrics.body
                        wrapMode: Text.Wrap
                    }

                    Select {
                        Layout.fillWidth: true
                        Layout.topMargin: Metrics.md
                        model: page.displays.map(page.displayLabel)
                        currentIndex: page.chosenIndex()
                        placeholder: qsTrId("settings.choose_display")
                        onActivated: {
                            const display = page.displays[currentIndex];
                            if (display) {
                                backend.setTv(display.connector);
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: Metrics.xs
                        visible: page.chosenIndex() >= 0
                        spacing: Metrics.md

                        Icon {
                            name: page.displays[page.chosenIndex()] && page.displays[page.chosenIndex()].connected
                                  ? "check" : "warn"
                            size: Metrics.iconSmall
                            color: page.displays[page.chosenIndex()] && page.displays[page.chosenIndex()].connected
                                   ? Colors.accent : Colors.muted
                        }

                        Text {
                            Layout.fillWidth: true
                            text: {
                                const d = page.displays[page.chosenIndex()];
                                if (!d) return "";
                                return d.connected ? qsTrId("settings.display_connected")
                                                   : qsTrId("settings.display_waiting");
                            }
                            color: Colors.muted
                            font.pixelSize: Metrics.caption
                            wrapMode: Text.Wrap
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: page.displays.length === 0
                        text: qsTrId("settings.no_displays")
                        color: Colors.urgent
                        font.pixelSize: Metrics.body
                        wrapMode: Text.Wrap
                    }
                }
            }

            // Behaviour ---------------------------------------------------
            Card {
                Layout.fillWidth: true
                Layout.leftMargin: Metrics.pagePadding
                Layout.rightMargin: Metrics.pagePadding
                implicitHeight: behaviourColumn.implicitHeight + Metrics.cardPadding * 2

                ColumnLayout {
                    id: behaviourColumn
                    anchors.fill: parent
                    anchors.margins: Metrics.cardPadding
                    spacing: Metrics.x3

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Metrics.lg
                        Icon { name: "power"; size: Metrics.icon; color: Colors.foreground }
                        SectionLabel { Layout.fillWidth: true; label: qsTrId("settings.console_behavior") }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Metrics.labelGap

                        Text {
                            text: qsTrId("settings.boot_label")
                            color: Colors.foreground
                            font.pixelSize: Metrics.body
                        }

                        Select {
                            id: bootSelect
                            Layout.fillWidth: true
                            textRole: "label"
                            valueRole: "value"
                            model: [
                                { value: "desktop", label: qsTrId("settings.boot_desktop") },
                                { value: "console", label: qsTrId("settings.boot_console") },
                                { value: "last",    label: qsTrId("settings.boot_last") }
                            ]
                            onActivated: backend.setBootMode(currentValue)
                        }

                        Text {
                            Layout.fillWidth: true
                            text: qsTrId("settings.boot_description")
                            color: Colors.muted
                            font.pixelSize: Metrics.caption
                            wrapMode: Text.Wrap
                        }
                    }

                    SettingSwitch {
                        Layout.fillWidth: true
                        label: qsTrId("settings.enter_on_controller")
                        description: qsTrId("settings.enter_on_controller_description")
                        checked: page.status.enter_on_controller_connect === true
                        onToggled: function(value) { backend.setEnterOnController(value); }
                    }

                    SettingSwitch {
                        Layout.fillWidth: true
                        label: qsTrId("settings.autostart")
                        description: qsTrId("settings.autostart_description")
                        checked: page.autostart
                        // The portal can refuse, so the switch follows what the
                        // attempt actually achieved rather than what was asked.
                        onToggled: function(value) {
                            backend.setAutostart(value);
                            page.autostart = backend.autostartEnabled();
                        }
                    }

                    SettingSwitch {
                        Layout.fillWidth: true
                        label: qsTrId("settings.start_minimized")
                        description: qsTrId("settings.start_minimized_description")
                        checked: page.startMinimized
                        // It only means something at login, so it follows the
                        // autostart switch. The value itself is kept: turning
                        // autostart back on restores the behaviour.
                        enabled: page.autostart
                        onToggled: function(value) {
                            backend.setStartMinimized(value);
                            page.startMinimized = backend.startMinimized();
                        }
                    }

                    SettingSwitch {
                        Layout.fillWidth: true
                        label: qsTrId("settings.background_on_close")
                        description: qsTrId("settings.background_on_close_description")
                        checked: page.backgroundOnClose
                        onToggled: function(value) {
                            backend.setBackgroundOnClose(value);
                            page.backgroundOnClose = backend.backgroundOnClose();
                        }
                    }
                }
            }

            // Every setting here is one engine call, applied when it is chosen.
            // A console half-configured because someone walked away before
            // saving is worse than one configured slowly, so there is no Save.
            Item { Layout.preferredHeight: Metrics.x4 }
        }
    }
}
