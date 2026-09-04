import QtQuick
import io.github.gustavobelo.opencouch

// The one place state priority is declared: pressed, then hover, then selected,
// then idle. Every interactive control in the app is built on this rather than
// writing its own ladder, which is how a pressed state ends up losing to a
// hover in one control and winning in another.
//
// A component rather than a helper function, so the animation and the border
// come with it and cannot be forgotten.
Rectangle {
    id: root

    property bool pressed: false
    property bool hovered: false
    property bool selected: false
    // Accented surfaces run the same ladder in the accent hue.
    property bool accented: false
    property bool bordered: true
    property bool disabled: false

    radius: Metrics.radiusSmall

    // Disabled is still a surface. Painting nothing makes the app's main action
    // look like it failed to draw rather than like it is waiting for something.
    color: disabled ? Colors.fill
         : pressed  ? (accented ? Colors.accentPressed  : Colors.fillPressed)
         : hovered  ? (accented ? Colors.accentHover    : Colors.fillHover)
         : selected ? (accented ? Colors.accentSelected : Colors.fillSelected)
         : accented ? Colors.accentFill : Colors.fill

    border.width: bordered ? 1 : 0
    border.color: disabled ? Colors.line
                : accented ? (hovered ? Colors.accentBright : Colors.accentBorder)
                : hovered  ? Colors.lineHover
                : selected ? Colors.foreground
                : Colors.line

    Behavior on color { ColorAnimation { duration: Metrics.fadeDuration } }
    Behavior on border.color { ColorAnimation { duration: Metrics.fadeDuration } }
}
