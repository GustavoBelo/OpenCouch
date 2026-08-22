import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami

Controls.Dialog {
    id: root
    parent: Controls.Overlay.overlay
    title: qsTrId("resource_control.running_picker_title")
    modal: true
    standardButtons: Controls.Dialog.Close
    implicitWidth: Math.min(480, root.parent ? root.parent.width - Kirigami.Units.gridUnit * 4 : 420)
    implicitHeight: Math.min(480, root.parent ? root.parent.height - Kirigami.Units.gridUnit * 8 : 420)

    property var apps: []

    onAboutToShow: {
        searchField.text = "";
        appCleanupModel.requestRunningApplications();
        if (appCleanupModel.runningApps.length > 0) {
            apps = appCleanupModel.runningApps;
        }
    }

    Connections {
        target: appCleanupModel
        function onRunningAppsChanged() {
            root.apps = appCleanupModel.runningApps;
        }
    }

    contentItem: ColumnLayout {
        spacing: Kirigami.Units.smallSpacing

        Kirigami.SearchField {
            id: searchField
            Layout.fillWidth: true
            enabled: !appCleanupModel.loadingRunning
        }

        Controls.BusyIndicator {
            Layout.alignment: Qt.AlignHCenter
            visible: appCleanupModel.loadingRunning
            running: visible
        }

        Kirigami.PlaceholderMessage {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !appCleanupModel.loadingRunning && filteredApps.length === 0
            icon.name: "edit-find"
            text: qsTrId("resource_control.running_picker_empty")
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            reuseItems: true
            cacheBuffer: Kirigami.Units.gridUnit * 10
            visible: !appCleanupModel.loadingRunning && filteredApps.length > 0
            model: filteredApps
            Controls.ScrollBar.vertical: Controls.ScrollBar {}

            delegate: Controls.ItemDelegate {
                width: ListView.view.width
                onClicked: {
                    appCleanupModel.addApp(modelData.processName, modelData.displayName, modelData.icon);
                    root.close();
                }

                contentItem: AppRowDelegate {
                    displayName: modelData.displayName
                    subtitle: modelData.windowTitle
                    iconSource: modelData.icon
                }
            }
        }
    }

    readonly property var filteredApps: {
        if (searchField.text.length === 0) return apps;
        var needle = searchField.text.toLowerCase();
        return apps.filter(function(a) {
            return a.displayName.toLowerCase().indexOf(needle) !== -1
                || (a.windowTitle && a.windowTitle.toLowerCase().indexOf(needle) !== -1);
        });
    }
}
