import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami

Controls.Dialog {
    id: root
    parent: Controls.Overlay.overlay
    title: qsTrId("resource_control.picker_title")
    modal: true
    standardButtons: Controls.Dialog.Close
    implicitWidth: Math.min(480, root.parent ? root.parent.width - Kirigami.Units.gridUnit * 4 : 420)
    implicitHeight: Math.min(480, root.parent ? root.parent.height - Kirigami.Units.gridUnit * 8 : 420)
    x: root.parent ? Math.round((root.parent.width - width) / 2) : 0
    y: root.parent ? Math.round((root.parent.height - height) / 2) : 0

    property var apps: []

    onAboutToShow: {
        searchField.text = "";
        if (appCleanupModel.installedApps.length === 0 && !appCleanupModel.loadingInstalled) {
            appCleanupModel.requestInstalledApplications();
        } else {
            apps = appCleanupModel.installedApps;
        }
    }

    Connections {
        target: appCleanupModel
        function onInstalledAppsChanged() {
            root.apps = appCleanupModel.installedApps;
        }
    }

    contentItem: ColumnLayout {
        spacing: Kirigami.Units.smallSpacing

        Kirigami.SearchField {
            id: searchField
            Layout.fillWidth: true
            enabled: !appCleanupModel.loadingInstalled
        }

        Controls.BusyIndicator {
            Layout.alignment: Qt.AlignHCenter
            visible: appCleanupModel.loadingInstalled
            running: visible
        }

        Kirigami.PlaceholderMessage {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !appCleanupModel.loadingInstalled && filteredApps.length === 0
            icon.name: "edit-find"
            text: qsTrId("resource_control.picker_empty")
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !appCleanupModel.loadingInstalled && filteredApps.length > 0
            clip: true
            reuseItems: true
            cacheBuffer: Kirigami.Units.gridUnit * 10
            model: filteredApps
            Controls.ScrollBar.vertical: Controls.ScrollBar {}

            delegate: Controls.ItemDelegate {
                id: appDelegate
                width: ListView.view.width
                onClicked: {
                    appCleanupModel.addApp(modelData.processName, modelData.displayName, modelData.icon);
                    root.close();
                }

                background: Rectangle {
                    radius: Kirigami.Units.smallSpacing
                    color: appDelegate.hovered ? Kirigami.Theme.alternateBackgroundColor : "transparent"

                    Behavior on color { ColorAnimation { duration: 120 } }
                }

                contentItem: AppRowDelegate {
                    displayName: modelData.displayName
                    subtitle: modelData.processName
                    iconSource: modelData.icon
                }
            }
        }
    }

    readonly property var filteredApps: {
        if (searchField.text.length === 0) return apps;
        var needle = searchField.text.toLowerCase();
        return apps.filter(function(a) {
            return a.displayName.toLowerCase().indexOf(needle) !== -1;
        });
    }
}
