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
        id: shape
        anchors.fill: parent
        transform: Scale { xScale: root.size / 24; yScale: root.size / 24 }

        // CurveRenderer gives the strokes native anti-aliasing, but the
        // property only exists since Qt 6.6 and the CI builds against 6.4 --
        // there, declaring it fails at runtime. Without it the shape takes
        // the default renderer, which is all 6.4 has to offer anyway.
        Component.onCompleted: {
            if (typeof shape.preferredRendererType !== "undefined") {
                shape.preferredRendererType = Shape.CurveRenderer;
            }
        }

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
