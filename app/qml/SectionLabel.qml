import QtQuick
import io.github.gustavobelo.opencouch

// The small-caps register: 11px, bold, letterspaced, dimmed. It is doing more
// work than its size suggests -- it is what lets the page have a hierarchy
// without a second type size or a rule across the page.
Text {
    property string label: ""

    text: label.toUpperCase()
    color: Colors.muted
    font.pixelSize: Metrics.caption
    font.bold: true
    font.letterSpacing: 1.2
    elide: Text.ElideRight
}
