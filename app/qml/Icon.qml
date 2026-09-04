import QtQuick
import QtQuick.Shapes
import "IconData.js" as IconData

// One icon from the bundled set, drawn as vector paths.
//
// Colour is a plain property here, which is the whole reason for drawing rather
// than loading an image: tinting an image needs a shader effect, and shader
// effects render nothing under a software rasteriser. This works anywhere the
// app runs.
Item {
    id: root

    property string name: ""
    property color color: "#ffffff"
    property int size: 20

    implicitWidth: size
    implicitHeight: size

    // Every stroke in an icon shares one style, so they are concatenated into a
    // single path rather than repeated into several. A Repeater cannot help
    // here anyway: ShapePath is not an Item, so it has nothing to parent into.
    readonly property string strokePath: IconData.strokesFor(name).join(" ")
    readonly property string fillPath: IconData.fillsFor(name).join(" ")

    // Authored on a 24 grid; the transform carries everything to the drawn
    // size, stroke weight included, so the icon keeps its proportion.
    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        transform: Scale { xScale: root.size / 24; yScale: root.size / 24 }

        ShapePath {
            strokeColor: root.strokePath === "" ? "transparent" : root.color
            strokeWidth: 2
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: root.strokePath }
        }

        ShapePath {
            strokeColor: "transparent"
            strokeWidth: 0
            fillColor: root.fillPath === "" ? "transparent" : root.color
            PathSvg { path: root.fillPath }
        }
    }

    Behavior on color {
        ColorAnimation { duration: 60 }
    }
}
