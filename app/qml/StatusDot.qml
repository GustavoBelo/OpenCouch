import QtQuick
import io.github.gustavobelo.opencouch

// A requirement, as one line. The icon carries the answer and the colour
// repeats it, so it reads at a glance from across a room -- which is where this
// app is used.
Row {
    id: root

    property bool ok: false
    property string text: ""

    spacing: Metrics.lg

    Icon {
        anchors.verticalCenter: parent.verticalCenter
        name: root.ok ? "check" : "warn"
        size: Metrics.iconSmall
        color: root.ok ? Colors.accent : Colors.urgent
    }

    Text {
        anchors.verticalCenter: parent.verticalCenter
        width: root.width - Metrics.iconSmall - Metrics.lg
        text: root.text
        color: root.ok ? Colors.muted : Colors.foreground
        font.pixelSize: Metrics.body
        wrapMode: Text.Wrap
    }
}
