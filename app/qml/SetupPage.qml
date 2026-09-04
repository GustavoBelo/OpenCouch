import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import io.github.gustavobelo.opencouch

Item {
    id: page

    property var status: ({})
    property var displays: []

    function reload() {
        page.status = backend.consoleStatus();
        page.displays = backend.listDisplays();
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

    Controls.ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true

        ColumnLayout {
            width: parent.parent.width
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

                    Text {
                        Layout.fillWidth: true
                        Layout.topMargin: Metrics.xs
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
                            text: qsTrId("settings.run_setup")
                            icon: "session"
                            onClicked: {
                                const instructions = backend.runSetup();
                                if (instructions !== "") {
                                    setupOutput.text = instructions;
                                    setupOutput.visible = true;
                                }
                                page.reload();
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
                            if (display && backend.setTv(display.connector)) {
                                page.reload();
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
                            Layout.fillWidth: true
                            textRole: "label"
                            valueRole: "value"
                            model: [
                                { value: "desktop", label: qsTrId("settings.boot_desktop") },
                                { value: "console", label: qsTrId("settings.boot_console") },
                                { value: "last",    label: qsTrId("settings.boot_last") }
                            ]
                            currentIndex: {
                                const boot = page.status.boot || "desktop";
                                return boot === "console" ? 1 : (boot === "last" ? 2 : 0);
                            }
                            onActivated: { if (backend.setBootMode(currentValue)) page.reload(); }
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
                        onToggled: function(value) {
                            var config = backend.loadConfig();
                            config["ENTER_ON_CONTROLLER_CONNECT"] = value ? "true" : "false";
                            backend.saveConfig(config);
                        }
                    }

                    SettingSwitch {
                        Layout.fillWidth: true
                        label: qsTrId("settings.autostart")
                        description: qsTrId("settings.autostart_description")
                        checked: backend.autostartEnabled()
                        onToggled: function(value) { backend.setAutostart(value); }
                    }

                    SettingSwitch {
                        Layout.fillWidth: true
                        label: qsTrId("settings.background_on_close")
                        description: qsTrId("settings.background_on_close_description")
                        checked: backend.backgroundOnClose()
                        onToggled: function(value) { backend.setBackgroundOnClose(value); }
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
