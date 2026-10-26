pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Widgets
import Qt5Compat.GraphicalEffects
import qs.services
import qs.modules.barM3
import qs.modules.common
import qs.modules.common.functions

// Every window on this output's active Niri workspace, in strip order
// (left to right, floating ones last). The active window gets a full-size
// icon cropped to a circle, like the workspace indicator it replaces; the
// rest sit beside it, smaller. Click focuses the window.
Item {
    id: root
    property bool vertical: Config.options.bar.vertical
    readonly property bool isMaterial: Config.options.bar.m3.cornerStyle === 3
    readonly property int activeSize: 26
    readonly property int buttonSize: 20
    readonly property int iconSize: 14

    readonly property string screenName: root.QsWindow.window?.screen?.name ?? ""
    readonly property var activeWorkspace: (NiriService.allWorkspaces ?? [])
        .find(w => w.output === root.screenName && w.is_active) ?? null

    readonly property var windows: {
        const ws = root.activeWorkspace
        if (!CompositorService.isNiri || !ws) return []
        const pos = w => w.layout?.pos_in_scrolling_layout ?? null
        return (NiriService.windows ?? [])
            .filter(w => w.workspace_id === ws.id)
            .sort((a, b) => {
                const pa = pos(a), pb = pos(b)
                if (!pa || !pb) return (pa ? -1 : 0) - (pb ? -1 : 0) || a.id - b.id
                return pa[0] - pb[0] || pa[1] - pb[1]
            })
    }

    visible: windows.length > 0
    implicitWidth: vertical ? activeSize : row.implicitWidth + 4
    implicitHeight: vertical ? row.implicitHeight + 4 : activeSize

    Grid {
        id: row
        anchors.centerIn: parent
        columns: root.vertical ? 1 : Math.max(root.windows.length, 1)
        spacing: 4
        horizontalItemAlignment: Grid.AlignHCenter
        verticalItemAlignment: Grid.AlignVCenter

        Repeater {
            model: root.windows

            Item {
                id: entry
                required property var modelData
                // active_window_id keeps the right window big on unfocused monitors too.
                readonly property bool isActive: modelData.id === root.activeWorkspace?.active_window_id
                readonly property color ink: root.isMaterial ? M3Palette.pillInk("windowList") : Appearance.colors.colOnLayer1
                readonly property string iconSource: AppSearch.getIconSource(modelData.app_id ?? "")

                width: isActive ? root.activeSize : root.buttonSize
                height: width

                Behavior on width {
                    NumberAnimation { duration: Appearance.animation.elementMoveFast.duration }
                }

                Rectangle {
                    anchors.fill: parent
                    visible: !entry.isActive
                    radius: Appearance.rounding.full
                    color: mouseArea.containsMouse ? ColorUtils.transparentize(entry.ink, 0.9) : "transparent"

                    Behavior on color {
                        ColorAnimation { duration: Appearance.animation.elementMoveFast.duration }
                    }
                }

                // Active window: icon fills the circle, so icons with transparent
                // margins don't leave a ring around them.
                Item {
                    id: activeIconHost
                    anchors.fill: parent
                    visible: entry.isActive
                    layer.enabled: visible
                    layer.effect: OpacityMask {
                        maskSource: Rectangle {
                            width: activeIconHost.width
                            height: activeIconHost.height
                            radius: width / 2
                        }
                    }

                    IconImage {
                        anchors.centerIn: parent
                        implicitSize: root.activeSize
                        source: entry.iconSource
                    }
                }

                IconImage {
                    anchors.centerIn: parent
                    visible: !entry.isActive
                    implicitSize: root.iconSize
                    source: entry.iconSource
                    opacity: mouseArea.containsMouse ? 1 : 0.6

                    Behavior on opacity {
                        NumberAnimation { duration: Appearance.animation.elementMoveFast.duration }
                    }
                }

                MouseArea {
                    id: mouseArea
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: NiriService.focusWindow(entry.modelData.id)
                }

                M3ToolTip {
                    text: entry.modelData.title ?? entry.modelData.app_id ?? ""
                    extraVisibleCondition: text.length > 0 && mouseArea.containsMouse
                    alternativeVisibleCondition: extraVisibleCondition
                    anchorEdges: Config.options?.bar?.bottom ?? false ? Edges.Top : Edges.Bottom
                }
            }
        }
    }
}
