import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import org.kde.kirigami as Kirigami

RowLayout {
    id: root
    spacing: Kirigami.Units.smallSpacing

    property string displayName: ""
    property string subtitle: ""
    property string iconSource: ""

    Kirigami.Icon {
        source: root.iconSource.length > 0 ? root.iconSource : "application-x-executable"
        Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
        Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
        Layout.alignment: Qt.AlignVCenter
    }

    ColumnLayout {
        Layout.fillWidth: true
        Layout.alignment: Qt.AlignVCenter
        spacing: 0

        Controls.Label {
            Layout.fillWidth: true
            text: root.displayName
            elide: Text.ElideRight
        }

        Controls.Label {
            Layout.fillWidth: true
            visible: root.subtitle.length > 0
            text: root.subtitle
            opacity: 0.7
            elide: Text.ElideRight
            font.pixelSize: Math.max(9, Kirigami.Theme.defaultFont.pixelSize - 1)
        }
    }
}
