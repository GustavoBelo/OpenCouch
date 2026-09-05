import QtQuick
import io.github.gustavobelo.opencouch

// The one button. State priority is declared once, here, in the order every
// control in the app follows: pressed, then hover, then selected, then idle.
// Widgets that write their own ladder are how a pressed state ends up losing to
// a hover in one place and winning in another.
Item {
    id: root

    property string text: ""
    property string icon: ""
    property bool primary: false
    property bool busy: false
    // Large is the console-sized target: the one thing on a page you press
    // without looking, from a sofa.
    property bool large: false

    signal clicked()

    implicitHeight: large ? Metrics.buttonHeight : Metrics.controlHeight
    implicitWidth: content.implicitWidth + (large ? Metrics.x5 + Metrics.md : Metrics.x4) * 2

    readonly property bool hot: mouse.containsMouse && root.enabled
    readonly property color tone: !root.enabled ? Colors.muted
                                 : root.primary ? Colors.accent
                                 : Colors.foreground

    StateSurface {
        anchors.fill: parent
        pressed: mouse.pressed
        hovered: root.hot
        accented: root.primary
        disabled: !root.enabled
    }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: Metrics.lg

        Icon {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.icon !== ""
            name: root.icon
            size: root.large ? Metrics.icon : Metrics.iconSmall
            color: root.tone
            rotation: root.busy ? 360 : 0
            RotationAnimation on rotation {
                running: root.busy
                from: 0; to: 360
                duration: Metrics.spinDuration
                loops: Animation.Infinite
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.text
            color: root.tone
            font.pixelSize: root.large ? Metrics.title : Metrics.body
            font.bold: root.primary
            font.letterSpacing: root.large ? 0.5 : 0
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
