import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami

Kirigami.ScrollablePage {
    id: page
    title: qsTrId("app.settings")

    property var status: ({})
    property var displays: []

    // Kirigami.Theme.separatorColor does not exist in KF6: every card that
    // asked for it drew no border at all. This is the blend the platform styles
    // use in its place, and it follows the theme in both light and dark.
    readonly property color cardBorderColor: Qt.rgba(Kirigami.Theme.textColor.r,
                                                     Kirigami.Theme.textColor.g,
                                                     Kirigami.Theme.textColor.b, 0.15)

    Component.onCompleted: {
        page.reload();
    }

    function reload() {
        page.status = backend.consoleStatus();
        page.displays = backend.listDisplays();
    }

    // The connector is what gamescope takes; the description is what a person
    // recognises. Both are shown, because a machine with two HDMI ports gives no
    // other way to tell which one the cable is in.
    function displayLabel(display) {
        if (!display) return "";
        return display.description === display.connector
            ? display.connector
            : display.description + "  (" + display.connector + ")";
    }

    function chosenDisplayIndex() {
        for (var i = 0; i < page.displays.length; i++) {
            if (page.displays[i].connector === page.status.tv_name) return i;
        }
        return -1;
    }

    Timer {
        id: saveFeedbackTimer
        interval: 2500
        onTriggered: statusLabel.visible = false
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.largeSpacing

        Controls.Label {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            opacity: 0.8
            text: qsTrId("settings.console_description")
        }

        Kirigami.Heading {
            text: qsTrId("settings.console")
            level: 3
            Layout.fillWidth: true
        }

        // What is still missing. The engine answers this in one place so the
        // page and the command line cannot disagree about what "ready" means.
        Rectangle {
            Layout.fillWidth: true
            radius: Kirigami.Units.largeSpacing
            color: Kirigami.Theme.backgroundColor
            border.color: page.cardBorderColor
            border.width: 1
            implicitHeight: requirementsColumn.implicitHeight + Kirigami.Units.largeSpacing * 2

            ColumnLayout {
                id: requirementsColumn
                anchors.fill: parent
                anchors.margins: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    Kirigami.Icon {
                        source: page.status.ready ? "checkmark" : "dialog-warning"
                        Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                        Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                        Kirigami.Theme.colorSet: Kirigami.Theme.Button
                        Kirigami.Theme.inherit: false
                    }

                    Kirigami.Heading {
                        text: page.status.ready ? qsTrId("settings.ready") : qsTrId("settings.not_ready")
                        level: 4
                        Layout.fillWidth: true
                    }

                    Controls.Button {
                        text: qsTrId("settings.recheck")
                        icon.name: "view-refresh"
                        onClicked: page.reload()
                    }
                }

                Repeater {
                    model: page.status.requirements || []

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: Kirigami.Units.gridUnit
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Icon {
                            source: modelData.ok ? "dialog-ok" : "dialog-cancel"
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        }

                        Controls.Label {
                            Layout.fillWidth: true
                            wrapMode: Text.Wrap
                            opacity: modelData.ok ? 0.7 : 1
                            text: modelData.ok ? modelData.have : modelData.want
                        }
                    }
                }
            }
        }

        // The hosting session. This is the one step that needs root, and the
        // page prints the command rather than running it: getting it wrong
        // leaves a machine that will not present a desktop at all, which is a
        // bad thing to inflict on someone who has not seen it coming.
        Rectangle {
            Layout.fillWidth: true
            radius: Kirigami.Units.largeSpacing
            color: Kirigami.Theme.backgroundColor
            border.color: page.cardBorderColor
            border.width: 1
            implicitHeight: hostingColumn.implicitHeight + Kirigami.Units.largeSpacing * 2

            ColumnLayout {
                id: hostingColumn
                anchors.fill: parent
                anchors.margins: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    Kirigami.Icon {
                        source: "system-switch-user"
                        Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                        Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                        Kirigami.Theme.colorSet: Kirigami.Theme.Button
                        Kirigami.Theme.inherit: false
                    }

                    Kirigami.Heading {
                        text: qsTrId("settings.hosting_session")
                        level: 4
                        Layout.fillWidth: true
                    }
                }

                Controls.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    opacity: 0.8
                    text: qsTrId("settings.hosting_description")
                }

                RowLayout {
                    Layout.fillWidth: true

                    Controls.Button {
                        text: qsTrId("settings.run_setup")
                        icon.name: "run-build-configure"
                        onClicked: {
                            var instructions = backend.runSetup();
                            if (instructions.length > 0) {
                                setupInstructions.text = instructions;
                                setupInstructions.visible = true;
                            } else {
                                statusLabel.type = Kirigami.MessageType.Error;
                                statusLabel.text = qsTrId("settings.setup_failed");
                                statusLabel.visible = true;
                            }
                            page.reload();
                        }
                    }

                    Item { Layout.fillWidth: true }

                    Controls.Button {
                        visible: setupInstructions.visible
                        text: qsTrId("common.copy")
                        icon.name: "edit-copy"
                        onClicked: setupInstructions.selectAll(), setupInstructions.copy()
                    }
                }

                Controls.TextArea {
                    id: setupInstructions
                    Layout.fillWidth: true
                    visible: false
                    readOnly: true
                    wrapMode: Text.Wrap
                    font.family: "monospace"
                }
            }
        }

        // The television.
        Rectangle {
            Layout.fillWidth: true
            radius: Kirigami.Units.largeSpacing
            color: Kirigami.Theme.backgroundColor
            border.color: page.cardBorderColor
            border.width: 1
            implicitHeight: televisionColumn.implicitHeight + Kirigami.Units.largeSpacing * 2

            ColumnLayout {
                id: televisionColumn
                anchors.fill: parent
                anchors.margins: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    Kirigami.Icon {
                        source: "video-television"
                        Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                        Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                        Kirigami.Theme.colorSet: Kirigami.Theme.Button
                        Kirigami.Theme.inherit: false
                    }

                    Kirigami.Heading {
                        text: qsTrId("settings.television")
                        level: 4
                        Layout.fillWidth: true
                    }
                }

                Controls.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    opacity: 0.8
                    text: qsTrId("settings.television_description")
                }

                Kirigami.FormLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.gridUnit * 2

                    Controls.ComboBox {
                        id: televisionCombo
                        Kirigami.FormData.label: qsTrId("settings.television_display")
                        Layout.fillWidth: true
                        model: page.displays.map(page.displayLabel)
                        currentIndex: page.chosenDisplayIndex()
                        onActivated: {
                            var display = page.displays[currentIndex];
                            if (display && backend.setTv(display.connector)) {
                                page.reload();
                            }
                        }
                    }

                    Controls.Label {
                        Kirigami.FormData.label: qsTrId("settings.television_state")
                        visible: page.chosenDisplayIndex() >= 0
                        wrapMode: Text.Wrap
                        opacity: 0.7
                        text: {
                            var display = page.displays[page.chosenDisplayIndex()];
                            if (!display) return "";
                            return display.connected
                                ? qsTrId("settings.television_connected")
                                : qsTrId("settings.television_waiting");
                        }
                    }
                }

                Controls.Label {
                    Layout.fillWidth: true
                    visible: page.displays.length === 0
                    wrapMode: Text.Wrap
                    color: Kirigami.Theme.negativeTextColor
                    text: qsTrId("settings.no_displays")
                }
            }
        }

        // Where a fresh login lands, and whether a controller may ask.
        Rectangle {
            Layout.fillWidth: true
            radius: Kirigami.Units.largeSpacing
            color: Kirigami.Theme.backgroundColor
            border.color: page.cardBorderColor
            border.width: 1
            implicitHeight: behaviourColumn.implicitHeight + Kirigami.Units.largeSpacing * 2

            ColumnLayout {
                id: behaviourColumn
                anchors.fill: parent
                anchors.margins: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    Kirigami.Icon {
                        source: "preferences-desktop-gaming"
                        Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                        Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                        Kirigami.Theme.colorSet: Kirigami.Theme.Button
                        Kirigami.Theme.inherit: false
                    }

                    Kirigami.Heading {
                        text: qsTrId("settings.console_behavior")
                        level: 4
                        Layout.fillWidth: true
                    }
                }

                Kirigami.FormLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.gridUnit * 2

                    ColumnLayout {
                        Layout.fillWidth: true
                        Kirigami.FormData.label: qsTrId("settings.boot_label")
                        spacing: 0

                        Controls.ComboBox {
                            id: bootCombo
                            Layout.fillWidth: true
                            textRole: "label"
                            valueRole: "value"
                            model: [
                                { value: "desktop", label: qsTrId("settings.boot_desktop") },
                                { value: "console", label: qsTrId("settings.boot_console") },
                                { value: "last", label: qsTrId("settings.boot_last") }
                            ]
                            currentIndex: {
                                var boot = page.status.boot || "desktop";
                                return boot === "console" ? 1 : (boot === "last" ? 2 : 0);
                            }
                            onActivated: {
                                if (backend.setBootMode(currentValue)) page.reload();
                            }
                        }
                        Controls.Label {
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit * 1.5
                            wrapMode: Text.Wrap
                            text: qsTrId("settings.boot_description")
                            opacity: 0.7
                            font.pixelSize: Math.max(9, Kirigami.Theme.defaultFont.pixelSize - 1)
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Kirigami.FormData.label: qsTrId("settings.controllers_label")
                        spacing: 0

                        Controls.CheckBox {
                            Layout.fillWidth: true
                            text: qsTrId("settings.enter_on_controller")
                            checked: page.status.enter_on_controller_connect === true
                            onToggled: {
                                var config = backend.loadConfig();
                                config["ENTER_ON_CONTROLLER_CONNECT"] = checked ? "true" : "false";
                                backend.saveConfig(config);
                            }
                        }
                        Controls.Label {
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit * 1.5
                            wrapMode: Text.Wrap
                            text: qsTrId("settings.enter_on_controller_description")
                            opacity: 0.7
                            font.pixelSize: Math.max(9, Kirigami.Theme.defaultFont.pixelSize - 1)
                        }
                    }
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            radius: Kirigami.Units.largeSpacing
            color: Kirigami.Theme.backgroundColor
            border.color: page.cardBorderColor
            border.width: 1
            implicitHeight: startupColumn.implicitHeight + Kirigami.Units.largeSpacing * 2

            ColumnLayout {
                id: startupColumn
                anchors.fill: parent
                anchors.margins: Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    Kirigami.Icon {
                        source: "system-run"
                        Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                        Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                        Kirigami.Theme.colorSet: Kirigami.Theme.Button
                        Kirigami.Theme.inherit: false
                    }

                    Kirigami.Heading {
                        text: qsTrId("settings.startup")
                        level: 4
                        Layout.fillWidth: true
                    }
                }

                Kirigami.FormLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.gridUnit * 2

                    ColumnLayout {
                        Layout.fillWidth: true
                        Kirigami.FormData.label: qsTrId("settings.system")
                        spacing: 0

                        Controls.CheckBox {
                            id: autostartCheck
                            Layout.fillWidth: true
                            text: qsTrId("settings.autostart")
                            checked: backend.autostartEnabled()
                            onToggled: backend.setAutostart(checked)
                        }
                        Controls.Label {
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit * 1.5
                            wrapMode: Text.Wrap
                            text: qsTrId("settings.autostart_description")
                            opacity: 0.7
                            font.pixelSize: Math.max(9, Kirigami.Theme.defaultFont.pixelSize - 1)
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Kirigami.FormData.label: qsTrId("settings.background")
                        spacing: 0

                        Controls.CheckBox {
                            id: backgroundOnCloseCheck
                            Layout.fillWidth: true
                            text: qsTrId("settings.background_on_close")
                            checked: backend.backgroundOnClose()
                            onToggled: backend.setBackgroundOnClose(checked)
                        }
                        Controls.Label {
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.gridUnit * 1.5
                            wrapMode: Text.Wrap
                            text: qsTrId("settings.background_on_close_description")
                            opacity: 0.7
                            font.pixelSize: Math.max(9, Kirigami.Theme.defaultFont.pixelSize - 1)
                        }
                    }
                }
            }
        }

        Kirigami.InlineMessage {
            id: statusLabel
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.largeSpacing
            visible: false
            type: Kirigami.MessageType.Warning
        }

        // No Save button. Every setting on this page is one engine call and is
        // applied when it is chosen: a console half-configured because someone
        // walked away before saving is worse than one configured slowly.
    }
}
