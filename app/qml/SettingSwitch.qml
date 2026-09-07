import QtQuick
import QtQuick.Layouts
import io.github.gustavobelo.opencouch

// A labelled switch. The whole row is the target, not just the switch: a 24px
// control is a fine mouse target and a poor everything-else one.
//
// The MouseArea is the root with the layout inside it, rather than a MouseArea
// filling a layout -- anchoring inside a layout is undefined behaviour, and
// Qt says so at runtime.
MouseArea {
    id: root

    property string label: ""
    property string description: ""
    property bool checked: false
    signal toggled(bool value)

    implicitHeight: row.implicitHeight
    cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    // Asks, like the switch inside it: the state comes back from whoever owns
    // the setting, so a call that fails leaves the switch where it was.
    onClicked: root.toggled(!root.checked)

    RowLayout {
        id: row
        anchors.fill: parent
        spacing: Metrics.xxl
        opacity: root.enabled ? 1 : 0.4

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Metrics.xxs

            Text {
                Layout.fillWidth: true
                text: root.label
                color: Colors.foreground
                font.pixelSize: Metrics.body
                wrapMode: Text.Wrap
            }

            Text {
                Layout.fillWidth: true
                visible: root.description !== ""
                text: root.description
                color: Colors.muted
                font.pixelSize: Metrics.caption
                wrapMode: Text.Wrap
            }
        }

        Toggle {
            id: control
            Layout.alignment: Qt.AlignVCenter
            checked: root.checked
            enabled: root.enabled
            onToggled: function(value) { root.toggled(value); }
        }
    }
}
