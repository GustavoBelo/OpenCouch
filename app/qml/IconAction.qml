import QtQuick
import QtQuick.Controls as Controls
import io.github.gustavobelo.opencouch

// An icon-only action in the header. The hit area is deliberately larger than
// the glyph: a 20px icon is a 20px target only if you are using a mouse on a
// desk, which is half of what this app is for.
Item {
    id: root

    property string icon: ""
    property string tip: ""
    property bool active: false
    signal triggered()

    implicitWidth: Metrics.iconButton
    implicitHeight: Metrics.iconButton

    StateSurface {
        anchors.fill: parent
        pressed: mouse.pressed
        hovered: mouse.containsMouse
        selected: root.active
        accented: root.active
        bordered: false
    }

    Icon {
        anchors.centerIn: parent
        name: root.icon
        size: Metrics.icon
        color: root.active ? Colors.accent
             : mouse.containsMouse ? Colors.foreground
             : Colors.muted
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.triggered()
    }

    Controls.ToolTip.visible: mouse.containsMouse && root.tip !== ""
    Controls.ToolTip.text: root.tip
    Controls.ToolTip.delay: 600
}
