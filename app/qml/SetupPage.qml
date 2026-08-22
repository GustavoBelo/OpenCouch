import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami

Kirigami.ScrollablePage {
    id: page
    title: qsTrId("app.settings")

    Component.onCompleted: {
        displaySettingsModel.bindBackend(backend);
        appCleanupModel.bindBackend(backend);
        displaySettingsModel.refreshOutputs();
    }

    Timer {
        id: saveFeedbackTimer
        interval: 2500
        onTriggered: statusLabel.visible = false
    }

    Timer {
        id: outputsFeedbackTimer
        interval: 2500
        onTriggered: statusLabel.visible = false
    }

    Connections {
        target: displaySettingsModel
        function onOutputsChanged() {
            if (displaySettingsModel.outputs.length === 0) {
                statusLabel.type = Kirigami.MessageType.Warning;
                statusLabel.text = displaySettingsModel.lastError || qsTrId("settings.no_monitors");
                statusLabel.visible = true;
            } else {
                statusLabel.visible = false;
            }
        }

        function onLastErrorChanged() {
            if (displaySettingsModel.lastError.length > 0 && displaySettingsModel.outputs.length === 0) {
                statusLabel.type = Kirigami.MessageType.Warning;
                statusLabel.text = displaySettingsModel.lastError;
                statusLabel.visible = true;
            }
        }
    }

    function outputModes(name) {
        return displaySettingsModel.outputModes(name);
    }

    function uniqueResolutions(modes) {
        if (!modes) return [];
        var res = [];
        for (var i = 0; i < modes.length; i++) {
            var r = String(modes[i]).split('@')[0];
            if (res.indexOf(r) === -1) res.push(r);
        }
        
        res.sort(function(a, b) {
            var partsA = a.split('x');
            var partsB = b.split('x');
            var widthA = parseInt(partsA[0]) || 0;
            var widthB = parseInt(partsB[0]) || 0;
            
            if (widthA !== widthB) {
                return widthB - widthA; 
            }
            
            var heightA = parseInt(partsA[1]) || 0;
            var heightB = parseInt(partsB[1]) || 0;
            return heightB - heightA; 
        });
        
        return res;
    }

    function ratesForResolution(modes, resolution) {
        if (!modes || !resolution) return [];
        var rates = [];
        for (var i = 0; i < modes.length; i++) {
            var parts = String(modes[i]).split('@');
            if (parts[0] === resolution && parts.length > 1) {
                var rateStr = parts[1] + " Hz";
                if (rates.indexOf(rateStr) === -1) rates.push(rateStr);
            }
        }
        
        rates.sort(function(a, b) {
            var valA = parseFloat(a) || 0;
            var valB = parseFloat(b) || 0;
            return valB - valA; 
        });
        
        return rates;
    }

    ColumnLayout {
        width: page.width
        spacing: Kirigami.Units.largeSpacing

        Controls.Label {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: qsTrId("settings.displays_description")
            opacity: 0.8
        }

        Kirigami.Heading {
            text: qsTrId("settings.displays")
            level: 3
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                
                Kirigami.Icon {
                    source: "computer"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                    Kirigami.Theme.colorSet: Kirigami.Theme.Button
                    Kirigami.Theme.inherit: false
                }
                
                Kirigami.Heading {
                    text: qsTrId("settings.desktop_environment")
                    level: 4
                    Layout.fillWidth: true
                }
            }

            Kirigami.FormLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.gridUnit * 2

                Controls.ComboBox {
                    Kirigami.FormData.label: qsTrId("settings.desktop_display")
                    model: displaySettingsModel.outputs.map(function(o) { return o.name; })
                    currentIndex: model.indexOf(displaySettingsModel.desktopOutput)
                    onActivated: displaySettingsModel.desktopOutput = currentText
                }

                Controls.ComboBox {
                    id: deskResCombo
                    Kirigami.FormData.label: qsTrId("settings.resolution")
                    
                    property var allModes: {
                        var _trigger = displaySettingsModel.outputs;
                        return page.outputModes(displaySettingsModel.desktopOutput);
                    }
                    property var resList: page.uniqueResolutions(allModes)
                    
                    model: resList
                    currentIndex: resList.indexOf(String(displaySettingsModel.desktopMode).split('@')[0])
                    
                    onActivated: {
                        var newRes = currentText;
                        var availableRates = page.ratesForResolution(allModes, newRes);
                        var bestRate = availableRates.length > 0 ? availableRates[0].replace(" Hz", "") : "";
                        displaySettingsModel.desktopMode = bestRate ? (newRes + "@" + bestRate) : newRes;
                    }
                }

                Controls.ComboBox {
                    id: deskRateCombo
                    Kirigami.FormData.label: qsTrId("settings.refresh_rate")
                    
                    property var allModes: deskResCombo.allModes
                    property string currentRes: String(displaySettingsModel.desktopMode).split('@')[0]
                    property var rateList: page.ratesForResolution(allModes, currentRes)
                    
                    model: rateList
                    visible: rateList.length > 0
                    
                    currentIndex: {
                        var parts = String(displaySettingsModel.desktopMode).split('@');
                        if (parts.length > 1) return rateList.indexOf(parts[1] + " Hz");
                        return -1;
                    }
                    
                    onActivated: {
                        var cleanRate = currentText.replace(" Hz", "");
                        displaySettingsModel.desktopMode = currentRes + "@" + cleanRate;
                    }
                }

                RowLayout {
                    Kirigami.FormData.label: qsTrId("settings.desktop_scale")
                    spacing: Kirigami.Units.smallSpacing

                    Controls.TextField {
                        id: deskScaleField
                        text: displaySettingsModel.desktopScale
                        onTextEdited: displaySettingsModel.desktopScale = text
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                    }

                    Controls.ToolButton {
                        icon.name: "help-hint"
                        display: Controls.ToolButton.IconOnly
                        Controls.ToolTip.visible: hovered
                        Controls.ToolTip.text: qsTrId("settings.desktop_scale_tooltip")
                    }
                }
            }
        }

        Kirigami.Separator {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.largeSpacing
            Layout.bottomMargin: Kirigami.Units.largeSpacing
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                
                Kirigami.Icon {
                    source: "video-display"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                    Kirigami.Theme.colorSet: Kirigami.Theme.Button
                    Kirigami.Theme.inherit: false
                }
                
                Kirigami.Heading {
                    text: qsTrId("settings.couch_environment")
                    level: 4
                    Layout.fillWidth: true
                }
            }

            Kirigami.FormLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.gridUnit * 2

                Controls.ComboBox {
                    Kirigami.FormData.label: qsTrId("settings.couch_display")
                    model: displaySettingsModel.outputs.map(function(o) { return o.name; })
                    currentIndex: model.indexOf(displaySettingsModel.tvOutput)
                    onActivated: displaySettingsModel.tvOutput = currentText
                }

                Controls.ComboBox {
                    id: tvResCombo
                    Kirigami.FormData.label: qsTrId("settings.resolution")
                    
                    property var allModes: {
                        var _trigger = displaySettingsModel.outputs;
                        return page.outputModes(displaySettingsModel.tvOutput);
                    }
                    property var resList: page.uniqueResolutions(allModes)
                    
                    model: resList
                    currentIndex: resList.indexOf(String(displaySettingsModel.tvMode).split('@')[0])
                    
                    onActivated: {
                        var newRes = currentText;
                        var availableRates = page.ratesForResolution(allModes, newRes);
                        var bestRate = availableRates.length > 0 ? availableRates[0].replace(" Hz", "") : "";
                        displaySettingsModel.tvMode = bestRate ? (newRes + "@" + bestRate) : newRes;
                    }
                }

                Controls.ComboBox {
                    id: tvRateCombo
                    Kirigami.FormData.label: qsTrId("settings.refresh_rate")
                    
                    property var allModes: tvResCombo.allModes
                    property string currentRes: String(displaySettingsModel.tvMode).split('@')[0]
                    property var rateList: page.ratesForResolution(allModes, currentRes)
                    
                    model: rateList
                    visible: rateList.length > 0
                    
                    currentIndex: {
                        var parts = String(displaySettingsModel.tvMode).split('@');
                        if (parts.length > 1) return rateList.indexOf(parts[1] + " Hz");
                        return -1;
                    }
                    
                    onActivated: {
                        var cleanRate = currentText.replace(" Hz", "");
                        displaySettingsModel.tvMode = currentRes + "@" + cleanRate;
                    }
                }

                RowLayout {
                    Kirigami.FormData.label: qsTrId("settings.couch_scale")
                    spacing: Kirigami.Units.smallSpacing

                    Controls.TextField {
                        id: tvScaleField
                        text: displaySettingsModel.tvScale
                        onTextEdited: displaySettingsModel.tvScale = text
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 4
                    }

                    Controls.ToolButton {
                        icon.name: "help-hint"
                        display: Controls.ToolButton.IconOnly
                        Controls.ToolTip.visible: hovered
                        Controls.ToolTip.text: qsTrId("settings.couch_scale_tooltip")
                    }
                }
            }
        }

        Kirigami.Separator {
            Layout.fillWidth: true
        }

        Kirigami.Heading {
            text: qsTrId("settings.couch_behavior")
            level: 3
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        Kirigami.FormLayout {
            Layout.fillWidth: true

            ColumnLayout {
                Layout.fillWidth: true
                Kirigami.FormData.label: qsTrId("settings.desktop_display_label")
                spacing: 0

                Controls.CheckBox {
                    id: keepDeskEnabledCheck
                    Layout.fillWidth: true
                    text: qsTrId("settings.keep_desktop_enabled")
                    checked: displaySettingsModel.keepDeskEnabled
                    onToggled: displaySettingsModel.keepDeskEnabled = checked
                }
                Controls.Label {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.gridUnit * 1.5
                    wrapMode: Text.Wrap
                    text: qsTrId("settings.keep_desktop_description")
                    opacity: 0.7
                    font.pixelSize: Math.max(9, Kirigami.Theme.defaultFont.pixelSize - 1)
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.maximumHeight: keepDeskEnabledCheck.checked ? -1 : 0
                Kirigami.FormData.label: qsTrId("settings.mirroring")
                opacity: keepDeskEnabledCheck.checked ? 1 : 0
                enabled: keepDeskEnabledCheck.checked
                clip: true
                spacing: 0

                Controls.CheckBox {
                    id: mirrorDeskToTvCheck
                    Layout.fillWidth: true
                    text: qsTrId("settings.mirror_desktop")
                    checked: displaySettingsModel.mirrorDeskToTv
                    onToggled: displaySettingsModel.mirrorDeskToTv = checked
                }
                Controls.Label {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.gridUnit * 1.5
                    wrapMode: Text.Wrap
                    text: qsTrId("settings.mirror_desktop_description")
                    opacity: 0.7
                    font.pixelSize: Math.max(9, Kirigami.Theme.defaultFont.pixelSize - 1)
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Kirigami.FormData.label: qsTrId("settings.big_picture_label")
                spacing: 0

                Controls.CheckBox {
                    id: watchBigPictureCheck
                    Layout.fillWidth: true
                    text: qsTrId("settings.watch_big_picture")
                    checked: displaySettingsModel.watchBigPicture
                    onToggled: displaySettingsModel.watchBigPicture = checked
                }
                Controls.Label {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.gridUnit * 1.5
                    wrapMode: Text.Wrap
                    text: qsTrId("settings.watch_big_picture_description")
                    opacity: 0.7
                    font.pixelSize: Math.max(9, Kirigami.Theme.defaultFont.pixelSize - 1)
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Kirigami.FormData.label: qsTrId("settings.controllers_label")
                spacing: 0

                Controls.CheckBox {
                    id: exitOnControllersOffCheck
                    Layout.fillWidth: true
                    text: qsTrId("settings.exit_on_controllers_off")
                    checked: displaySettingsModel.exitOnControllersOff
                    onToggled: displaySettingsModel.exitOnControllersOff = checked
                }
                Controls.Label {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.gridUnit * 1.5
                    wrapMode: Text.Wrap
                    text: qsTrId("settings.exit_on_controllers_off_description")
                    opacity: 0.7
                    font.pixelSize: Math.max(9, Kirigami.Theme.defaultFont.pixelSize - 1)
                }
            }
        }

        Kirigami.Separator {
            Layout.fillWidth: true
        }

        Kirigami.Heading {
            text: qsTrId("resource_control.heading")
            level: 3
            Layout.topMargin: Kirigami.Units.smallSpacing
            enabled: !backend.engineNeedsUpdate()
            opacity: backend.engineNeedsUpdate() ? 0.5 : 1
        }

        Controls.Label {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: qsTrId("resource_control.description")
            opacity: backend.engineNeedsUpdate() ? 0.5 : 0.8
            enabled: !backend.engineNeedsUpdate()
        }

        Controls.Label {
            Layout.fillWidth: true
            visible: backend.engineNeedsUpdate()
            wrapMode: Text.Wrap
            color: Kirigami.Theme.negativeTextColor
            text: qsTrId("engine.outdated")
            opacity: 0.9
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.largeSpacing
            enabled: !backend.engineNeedsUpdate()
            opacity: backend.engineNeedsUpdate() ? 0.5 : 1

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Kirigami.Icon {
                    source: "edit-clear-all"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                    Kirigami.Theme.colorSet: Kirigami.Theme.Button
                    Kirigami.Theme.inherit: false
                }

                Kirigami.Heading {
                    text: qsTrId("resource_control.app_cleanup_heading")
                    level: 4
                    Layout.fillWidth: true
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                Controls.CheckBox {
                    id: closeAppsEnabledCheck
                    Layout.fillWidth: true
                    text: qsTrId("resource_control.enable_cleanup")
                    checked: appCleanupModel.enabled
                    onToggled: appCleanupModel.enabled = checked
                }
                Controls.Label {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.gridUnit * 1.5
                    wrapMode: Text.Wrap
                    text: qsTrId("resource_control.enable_cleanup_description")
                    opacity: 0.7
                    font.pixelSize: Math.max(9, Kirigami.Theme.defaultFont.pixelSize - 1)
                }
            }

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                visible: closeAppsEnabledCheck.checked
                showCloseButton: false
                type: Kirigami.MessageType.Warning
                text: qsTrId("resource_control.warning_terminate")
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.largeSpacing
                Layout.leftMargin: Kirigami.Units.gridUnit * 2
                spacing: Kirigami.Units.smallSpacing
                enabled: closeAppsEnabledCheck.checked
                opacity: closeAppsEnabledCheck.checked ? 1 : 0.5

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Controls.Label {
                        Layout.fillWidth: true
                        text: qsTrId("resource_control.apps_to_close")
                        font.bold: true
                    }

                    Controls.Button {
                        text: qsTrId("resource_control.choose_app")
                        icon.name: "list-add"
                        onClicked: chooseAppDialog.open()
                    }

                    Controls.Button {
                        text: qsTrId("resource_control.running_apps")
                        icon.name: "view-list-details"
                        onClicked: runningAppsDialog.open()
                    }
                }

                Controls.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    text: qsTrId("resource_control.apps_to_close_description")
                    opacity: 0.7
                    font.pixelSize: Math.max(9, Kirigami.Theme.defaultFont.pixelSize - 1)
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 10
                    radius: Kirigami.Units.smallSpacing
                    color: Kirigami.Theme.backgroundColor
                    border.color: Kirigami.Theme.separatorColor
                    border.width: 1

                    Controls.BusyIndicator {
                        anchors.centerIn: parent
                        visible: appCleanupModel.loadingInstalled
                        running: visible
                    }

                    Kirigami.PlaceholderMessage {
                        anchors.centerIn: parent
                        width: parent.width - Kirigami.Units.largeSpacing * 4
                        visible: !appCleanupModel.loadingInstalled && appCleanupModel.appsToClose.length === 0
                        icon.name: "edit-clear-all"
                        text: qsTrId("resource_control.no_apps_selected")
                    }

                    ListView {
                        id: appsToCloseList
                        anchors.fill: parent
                        anchors.margins: Kirigami.Units.smallSpacing
                        visible: !appCleanupModel.loadingInstalled && appCleanupModel.appsToClose.length > 0
                        clip: true
                        reuseItems: true
                        spacing: Kirigami.Units.smallSpacing
                        model: appCleanupModel.appsToClose
                        Controls.ScrollBar.vertical: Controls.ScrollBar {}

                        delegate: Controls.ItemDelegate {
                            width: ListView.view.width
                            hoverEnabled: false
                            down: false

                            contentItem: RowLayout {
                                spacing: Kirigami.Units.smallSpacing

                                AppRowDelegate {
                                    Layout.fillWidth: true
                                    displayName: modelData.displayName
                                    subtitle: modelData.processName
                                    iconSource: modelData.icon
                                }

                                Controls.ToolButton {
                                    icon.name: "edit-delete"
                                    display: Controls.ToolButton.IconOnly
                                    Controls.ToolTip.visible: hovered
                                    Controls.ToolTip.text: qsTrId("resource_control.remove_app")
                                    onClicked: appCleanupModel.removeApp(index)
                                }
                            }
                        }
                    }
                }
            }

            Kirigami.FormLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.gridUnit * 2
                enabled: closeAppsEnabledCheck.checked
                opacity: closeAppsEnabledCheck.checked ? 1 : 0.5

                Controls.SpinBox {
                    id: waitSecondsSpin
                    Kirigami.FormData.label: qsTrId("resource_control.wait_before_closing")
                    from: 0
                    to: 60
                    value: appCleanupModel.waitSeconds
                    onValueModified: appCleanupModel.waitSeconds = value
                    textFromValue: function(value) { return value + " s"; }
                    valueFromText: function(text) { return parseInt(text) || 0; }
                }
            }

            Controls.Label {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.gridUnit * 2
                wrapMode: Text.Wrap
                text: qsTrId("resource_control.wait_before_closing_description")
                opacity: 0.7
                font.pixelSize: Math.max(9, Kirigami.Theme.defaultFont.pixelSize - 1)
            }
        }

        Kirigami.Separator {
            Layout.fillWidth: true
        }

        Kirigami.Heading {
            text: qsTrId("settings.startup")
            level: 3
            Layout.topMargin: Kirigami.Units.smallSpacing
        }

        Kirigami.FormLayout {
            Layout.fillWidth: true

            ColumnLayout {
                Layout.fillWidth: true
                Kirigami.FormData.label: qsTrId("settings.system")
                spacing: 0

                Controls.CheckBox {
                    id: autostartCheck
                    Layout.fillWidth: true
                    text: qsTrId("settings.autostart")
                    checked: displaySettingsModel.autostart
                    onToggled: displaySettingsModel.autostart = checked
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
                    checked: displaySettingsModel.backgroundOnClose
                    onToggled: displaySettingsModel.backgroundOnClose = checked
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

        Kirigami.InlineMessage {
            id: statusLabel
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.largeSpacing
            visible: false
            type: Kirigami.MessageType.Warning
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing

            Item { Layout.fillWidth: true }

            Controls.Button {
                text: qsTrId("settings.detect_again")
                icon.name: "view-refresh"
                onClicked: {
                    displaySettingsModel.refreshOutputs();
                    if (displaySettingsModel.outputs.length > 0) {
                        statusLabel.type = Kirigami.MessageType.Positive;
                        statusLabel.text = qsTrId("settings.outputs_detected");
                        statusLabel.visible = true;
                        outputsFeedbackTimer.restart();
                    }
                }
            }
            
            Controls.Button {
                text: qsTrId("common.save")
                icon.name: "dialog-ok"
                highlighted: true
                enabled: displaySettingsModel.desktopOutput.length > 0
                         && displaySettingsModel.tvOutput.length > 0
                         && displaySettingsModel.desktopOutput !== displaySettingsModel.tvOutput
                onClicked: {
                    var validationMessage = displaySettingsModel.validate();
                    if (validationMessage.length > 0) {
                        statusLabel.type = Kirigami.MessageType.Error;
                        statusLabel.text = validationMessage;
                        statusLabel.visible = true;
                        return;
                    }

                    var ok = displaySettingsModel.save();
                    var ok2 = appCleanupModel.save();
                    if (ok && ok2) {
                        statusLabel.type = Kirigami.MessageType.Positive;
                        statusLabel.text = qsTrId("settings.saved");
                        statusLabel.visible = true;
                        saveFeedbackTimer.restart();
                    } else {
                        statusLabel.type = Kirigami.MessageType.Error;
                        statusLabel.text = displaySettingsModel.lastError || qsTrId("settings.error.save_failed");
                        statusLabel.visible = true;
                    }
                }
            }
        }
    }

    ChooseAppDialog { id: chooseAppDialog }
    RunningAppsDialog { id: runningAppsDialog }
}