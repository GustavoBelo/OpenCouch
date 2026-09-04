import QtQuick
import io.github.gustavobelo.opencouch

// A surface. One hairline border over a 4%-alpha fill is the entire depth
// system -- no shadow, no blur, no gradient. Restraint is what separates this
// from a themed control, and it also means a card can never disagree with any
// other surface about how far off the page it sits.
Rectangle {
    id: root

    property bool accented: false

    color: accented ? Colors.accentFill : Colors.fill
    radius: Metrics.radius
    border.width: 1
    border.color: accented ? Colors.accentLine : Colors.line

    Behavior on color { ColorAnimation { duration: Metrics.fadeDuration } }
    Behavior on border.color { ColorAnimation { duration: Metrics.fadeDuration } }
}
