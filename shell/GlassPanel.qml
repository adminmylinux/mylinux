import QtQuick
import QtQuick.Effects
import MyShell

// Liquid-glass style panel: blurs whatever `backdrop` shows behind this item, masks it to a
// rounded rectangle, then adds a tint, a hairline border and a specular top highlight.
// Keep panels small: the blur is rendered by llvmpipe in software.
Item {
    id: glass
    property Item backdrop
    property real radius: 22
    property color tint: Theme.panelTint
    property color borderColor: Theme.isLight ? "#66ffffff" : "#3fffffff"
    property real blurAmount: 0.9
    property real saturation: 0.25
    property real dim: 0.0            // darken the blurred backdrop (0..1), for readability
    // Solid: no blur, the tint drawn opaque. Default for menus and sheets (Theme.solidPanels): over app
    // windows the see-through look reads badly, and skipping the software blur is cheaper too.
    property bool solid: Theme.solidPanels

    // What's behind us, tracked as we move/resize.
    ShaderEffectSource {
        id: behind
        sourceItem: glass.backdrop
        live: !glass.solid
        hideSource: false
        visible: false
        smooth: true
        sourceRect: {
            if (!glass.backdrop) return Qt.rect(0, 0, 1, 1)
            const p = glass.mapToItem(glass.backdrop, 0, 0)
            return Qt.rect(p.x, p.y, Math.max(1, glass.width), Math.max(1, glass.height))
        }
    }
    Rectangle { id: maskShape; width: glass.width; height: glass.height; radius: glass.radius; color: "black" }
    ShaderEffectSource { id: maskTex; sourceItem: maskShape; hideSource: true; visible: false; smooth: true }

    MultiEffect {
        visible: !glass.solid
        anchors.fill: parent
        source: behind
        blurEnabled: true
        blur: glass.blurAmount
        blurMax: 32
        blurMultiplier: 0.6
        saturation: glass.saturation
        brightness: -glass.dim * 0.35
        maskEnabled: true
        maskSource: maskTex
        maskThresholdMin: 0.5
        maskSpreadAtMin: 0.0
    }
    // tint + hairline
    Rectangle { anchors.fill: parent; radius: glass.radius; color: glass.solid ? Qt.rgba(glass.tint.r, glass.tint.g, glass.tint.b, 1) : glass.tint; border.color: glass.borderColor; border.width: 1 }
    // specular highlight along the top edge
    Rectangle {
        anchors { top: parent.top; left: parent.left; right: parent.right; margins: 1 }
        height: Math.min(parent.height * 0.5, 22); radius: glass.radius
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#55ffffff" }
            GradientStop { position: 1.0; color: "#00ffffff" }
        }
    }
    // soft inner shadow at the bottom edge for depth
    Rectangle {
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right; margins: 1 }
        height: Math.min(parent.height * 0.35, 14); radius: glass.radius
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#00000000" }
            GradientStop { position: 1.0; color: "#22000000" }
        }
    }
}
