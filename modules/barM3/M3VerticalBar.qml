pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.SystemTray
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets

// Local addition: vertical host for the M3 bar. It reads the same
// bar.m3.layouts as M3Bar (left -> top, middle -> center, right -> bottom) and
// loads the same widgets with `vertical: true`, so both orientations share
// widgets, colours and interactions. Selected by ShellIiCriticalPanels when
// bar.vertical and bar.appearanceStyle === "m3". bar.bottom puts it on the right.
Scope {
    id: bar

    component VerticalSection: Rectangle {
        id: section
        required property var layout
        readonly property bool trayHasItems: SystemTray.items.values.length > 0
        readonly property var effectiveLayout: Array.from(section.layout ?? []).filter(name =>
            name !== "visualizer"
            && (name !== "sysTray" || section.trayHasItems)
            && (name !== "batteryIndicator" || Battery.available))

        function shouldPaintMaterialPill(name: string): bool {
            if (Config.options?.bar?.m3?.cornerStyle !== 3) return false
            if (!(Config.options?.bar?.m3?.showBackground ?? true)) return false
            const groupStyle = Config.options?.bar?.m3?.borderless ?? "pills"
            if (groupStyle === "transparent") return false
            if (groupStyle === "separated") return name !== "divisor"
            const joinedBlacklist = [
                "workspaces", "divisor", "powerButton", "docktoPanel",
                "leftSidebarButton", "rightSidebarButton", "activeWindow", "visualizer",
                "notificationUnreadCount"
            ]
            return !joinedBlacklist.includes(name)
        }

        visible: column.implicitHeight > 0.5
        width: Appearance.sizes.baseVerticalBarWidth
        implicitHeight: column.implicitHeight + 10
        radius: Appearance.rounding.full
        color: (Config.options?.bar?.m3?.showBackground ?? true)
            && (Config.options?.bar?.m3?.borderless ?? "pills") === "pills"
            ? Appearance.colors.colLayer0 : "transparent"

        ColumnLayout {
            id: column
            anchors.centerIn: parent
            spacing: 3

            Repeater {
                model: section.effectiveLayout
                delegate: BarGroup {
                    id: group
                    required property string modelData
                    required property int index
                    Layout.alignment: Qt.AlignHCenter
                    vertical: true
                    currentIndex: index
                    totalCount: section.effectiveLayout.length
                    paintMaterialPill: section.shouldPaintMaterialPill(modelData)
                    bgColor: M3Palette.pillContainer(modelData)

                    Loader {
                        Layout.alignment: Qt.AlignHCenter
                        source: Qt.resolvedUrl("./" + group.modelData.charAt(0).toUpperCase()
                            + group.modelData.slice(1) + ".qml")
                        onLoaded: {
                            if (item && item.hasOwnProperty("vertical"))
                                item.vertical = true
                        }
                    }
                }
            }
        }
    }

    Variants {
        // For each monitor
        model: {
            const screens = Quickshell.screens;
            const list = Config.options?.bar?.screenList ?? [];
            if (!list || list.length === 0)
                return screens;
            const matched = screens.filter(screen => {
                const screenName = screen?.name ?? "";
                return screenName.length > 0 && list.includes(screenName);
            });
            return matched.length > 0 ? matched : screens;
        }
        LazyLoader {
            id: barLoader
            active: GlobalStates.barOpen && !GlobalStates.screenLocked
                && !GlobalStates.widgetEditMode
            required property ShellScreen modelData
            component: PanelWindow {
                id: barRoot
                screen: barLoader.modelData

                readonly property bool onRight: Config.options?.bar?.bottom ?? false
                readonly property real gap: Config.options?.bar?.m3?.gapsOut ?? 5

                WlrLayershell.namespace: "quickshell:verticalBar"
                WlrLayershell.layer: WlrLayer.Top
                exclusionMode: ExclusionMode.Ignore
                exclusiveZone: Appearance.sizes.baseVerticalBarWidth + gap
                implicitWidth: Appearance.sizes.baseVerticalBarWidth + gap
                color: "transparent"

                anchors {
                    top: true
                    bottom: true
                    left: !barRoot.onRight
                    right: barRoot.onRight
                }

                Item {
                    anchors {
                        fill: parent
                        topMargin: barRoot.gap
                        bottomMargin: barRoot.gap
                        leftMargin: barRoot.onRight ? 0 : barRoot.gap
                        rightMargin: barRoot.onRight ? barRoot.gap : 0
                    }

                    VerticalSection {
                        anchors.top: parent.top
                        anchors.horizontalCenter: parent.horizontalCenter
                        layout: Config.options?.bar?.m3?.layouts?.leftLayout ?? []
                    }

                    VerticalSection {
                        anchors.centerIn: parent
                        layout: Config.options?.bar?.m3?.layouts?.middleLayout ?? []
                    }

                    VerticalSection {
                        anchors.bottom: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        layout: Config.options?.bar?.m3?.layouts?.rightLayout ?? []
                    }
                }
            }
        }
    }
}
