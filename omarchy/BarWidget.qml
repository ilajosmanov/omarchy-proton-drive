import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
    id: root
    moduleName: "placq.proton-drive"

    readonly property var sharedDriveService: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
    readonly property var driveService: sharedDriveService || localService.item

    // Replacement bars cannot expose the host's service objects. Listen to
    // the daemon locally when no shared service is available.
    Loader {
        id: localService
        active: root.bar && root.bar.shell && !root.sharedDriveService
        sourceComponent: Service {}
    }

    readonly property bool connected: driveService ? driveService.connected : false
    readonly property bool loading: driveService ? driveService.loading : true
    readonly property string provider: driveService ? driveService.provider : "unconfigured"
    readonly property bool needsAttention: driveService && (driveService.lastError !== "" || driveService.conflicts.length > 0)
        || (!connected && provider !== "unconfigured" && !loading)
    readonly property bool transferring: connected && driveService
        && (driveService.transfers.length > 0 || root.clearingCache)
    readonly property bool deleting: connected && driveService
        && driveService.transfers.some(item => item.direction === "trash")
    // Keep the integration UI consistent across Omarchy locales.
    readonly property string uiLanguage: "en"
    readonly property color logsLinkColor: {
        const background=Color.popups.background
        const luminance=0.2126 * background.r + 0.7152 * background.g + 0.0722 * background.b
        return luminance > 0.5 ? "#000000" : "#ffffff"
    }
    property bool cacheActionRunning: false
    readonly property bool clearingCache: cacheActionRunning
    property string cacheActionKind: "disposable"
    property bool cacheClearSucceeded: false
    property string cacheActionMessage: ""
    property real cacheClearFreedBytes: 0
    property real cacheClearRetainedBytes: 0
    property int cacheClearRetainedFiles: 0
    property int cacheClearClearedPinnedFiles: 0
    property int cacheClearRetainedUnsafeFiles: 0
    property Item cacheTooltipTarget: null
    property string cacheTooltipText: ""
    readonly property string statusLabel: {
        if (driveService && driveService.lastError !== "") return root.l10n("Wymaga uwagi", "Needs attention")
        if (loading) return root.l10n("Uruchamianie Proton Drive…", "Starting Proton Drive…")
        if (root.clearingCache) return root.l10n("Usuwanie pamięci podręcznej…", "Clearing cache…")
        if (root.deleting) return root.l10n("Przenoszenie do kosza…", "Moving to trash…")
        if (connected) return driveService && driveService.transfers.length > 0
            ? root.l10n("Trwa pobieranie", "Transfer in progress")
            : root.l10n("Połączono", "Connected")
        return provider === "unconfigured"
            ? root.l10n("Nieskonfigurowany", "Not configured")
            : root.l10n("Wymagane logowanie", "Sign-in required")
    }
    property bool popupOpen: false
    readonly property bool opened: popupOpen

    function open() { popupOpen = true }
    function close() { popupOpen = false }
    function toggle() { popupOpen = !popupOpen }
    function l10n(polish, english) { return english }
    function startCacheAction(kind) {
        if (root.cacheActionRunning) return
        root.cacheActionKind=kind
        root.cacheActionRunning=true
        root.cacheClearSucceeded=false
        root.cacheClearFreedBytes=0
        root.cacheClearRetainedBytes=0
        root.cacheClearRetainedFiles=0
        root.cacheClearClearedPinnedFiles=0
        root.cacheClearRetainedUnsafeFiles=0
        root.cacheActionMessage=""
        clearCacheProcess.running=true
    }
    function clearCache() { root.startCacheAction("disposable") }
    function clearPinnedCache() { root.startCacheAction("pinned") }
    function showCacheTooltip(target, text) {
        root.cacheTooltipTarget=target
        root.cacheTooltipText=text
    }
    function hideCacheTooltip(target) {
        if (root.cacheTooltipTarget !== target) return
        root.cacheTooltipTarget=null
        root.cacheTooltipText=""
    }
    function finishCacheClear() {
        root.cacheActionRunning=false
        if (!root.cacheClearSucceeded) {
            root.cacheActionMessage=root.l10n("Nie udało się wyczyścić pamięci podręcznej.", "Could not clear the cache.")
        } else if (root.cacheActionKind === "pinned") {
            root.cacheActionMessage="Removed " + root.cacheClearClearedPinnedFiles
                    + (root.cacheClearClearedPinnedFiles === 1 ? " offline file" : " offline files")
                    + " · freed " + root.formatBytes(root.cacheClearFreedBytes) + "."
            if (root.cacheClearRetainedUnsafeFiles > 0)
                root.cacheActionMessage += root.l10n(
                    " Zachowano niezapisane pliki: " + root.cacheClearRetainedUnsafeFiles + ".",
                    " Unsaved files retained: " + root.cacheClearRetainedUnsafeFiles + ".")
        } else if (root.cacheClearRetainedBytes > 0) {
            root.cacheActionMessage=root.formatBytes(root.cacheClearRetainedBytes) + " retained"
                    + (root.cacheClearRetainedFiles === 1
                        ? " · 1 offline file."
                        : " · " + root.cacheClearRetainedFiles + " offline files.")
        } else if (root.cacheClearFreedBytes > 0) {
            root.cacheActionMessage=root.l10n("Zwolniono ", "Freed ") + root.formatBytes(root.cacheClearFreedBytes) + "."
        } else {
            root.cacheActionMessage=root.l10n("Pamięć podręczna jest już pusta.", "The cache is already empty.")
        }
        if (root.driveService) root.driveService.refreshSoon()
        cacheMessageTimeout.restart()
    }
    function formatBytes(bytes) {
        const value = Math.max(0, Number(bytes) || 0)
        if (value < 1024) return value.toFixed(0) + " B"
        if (value < 1024 * 1024) return (value / 1024).toFixed(1) + " KiB"
        if (value < 1024 * 1024 * 1024) return (value / 1024 / 1024).toFixed(1) + " MiB"
        return (value / 1024 / 1024 / 1024).toFixed(1) + " GiB"
    }
    readonly property real usageRatio: driveService && driveService.totalBytes > 0
        ? Math.min(1, driveService.usedBytes / driveService.totalBytes) : 0
    visible: true
    implicitWidth: Style.space(24)
    implicitHeight: barSize

    Process {
        id: clearCacheProcess
        command: ["omarchy-drive-control", root.cacheActionKind === "pinned" ? "clear-pinned-cache" : "clear-cache"]
        running: false
        stdout: SplitParser { onRead: data => {
            try {
                const result=JSON.parse(data)
                root.cacheClearFreedBytes=Number(result.freedBytes || 0)
                root.cacheClearRetainedBytes=Number(result.retainedPinnedBytes || 0)
                root.cacheClearRetainedFiles=Number(result.retainedPinnedFiles || 0)
                root.cacheClearClearedPinnedFiles=Number(result.clearedPinnedFiles || 0)
                root.cacheClearRetainedUnsafeFiles=Number(result.retainedUnsafeFiles || 0)
                if (root.driveService) root.driveService.cacheBytes=Number(result.cacheBytes || 0)
            } catch (e) { console.log("omarchy-drive: invalid clear-cache output", e) }
        }}
        onExited: exitCode => {
            root.cacheClearSucceeded=exitCode === 0
            root.finishCacheClear()
        }
    }
    Timer {
        id: cacheMessageTimeout
        interval: 8000
        repeat: false
        onTriggered: root.cacheActionMessage=""
    }
    Process {
        id: openLogsProcess
        command: ["omarchy-drive-control", "logs"]
        running: false
        onExited: exitCode => {
            if (exitCode !== 0) {
                root.cacheActionMessage=root.l10n("Nie udało się otworzyć logów.", "Could not open the logs.")
                cacheMessageTimeout.restart()
            }
        }
    }

    ProtonDriveIcon {
        anchors.centerIn: parent
        iconSize: Style.space(14)
        color: Color.bar.text
        opacity: root.loading ? 0.65 : 1.0
    }

    Rectangle {
        visible: root.loading || root.transferring || root.needsAttention
        width: Style.space(4)
        height: width
        radius: width / 2
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.rightMargin: Style.space(2)
        anchors.topMargin: Style.space(4)
        color: root.needsAttention ? Color.bar.active : Color.accent
        SequentialAnimation on opacity {
            running: root.loading
            loops: Animation.Infinite
            NumberAnimation { to: 0.25; duration: 500 }
            NumberAnimation { to: 1.0; duration: 500 }
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        cursorShape: Qt.PointingHandCursor
        onClicked: root.popupOpen = !root.popupOpen
        onEntered: if (root.bar) root.bar.showTooltip(root, "Proton Drive · " + root.statusLabel)
        onExited: if (root.bar) root.bar.hideTooltip(root)
    }

    PopupCard {
        id: popup
        anchorItem: root
        bar: root.bar
        owner: root
        open: root.popupOpen
        contentWidth: popup.fittedContentWidth(Style.space(300))
        contentHeight: popup.fittedContentHeight(details.implicitHeight)

        ScrollView {
            id: detailsScroll
            anchors.fill: parent
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        Column {
            id: details
            width: detailsScroll.availableWidth
            spacing: Style.space(10)

            PanelHero {
                width: parent.width
                title: "Proton Drive"
                foreground: Color.popups.text
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                iconComponent: Component {
                    ProtonDriveIcon {
                        iconSize: Style.font.display
                        color: Color.popups.text
                    }
                }
            }

            Text {
                visible: root.driveService && root.driveService.accountEmail !== ""
                width: parent.width
                text: root.driveService ? root.driveService.accountEmail.toUpperCase() : ""
                textFormat: Text.PlainText
                color: Qt.darker(Color.popups.text, 1.4)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
            }

            PanelSeparator {
                width: parent.width
                foreground: Color.popups.text
            }

            Row {
                visible: root.loading
                width: parent.width
                spacing: Style.space(8)

                Item {
                    width: Style.space(16)
                    height: width
                    anchors.verticalCenter: parent.verticalCenter
                    RotationAnimation on rotation {
                        running: root.loading
                        from: 0
                        to: 360
                        duration: 1100
                        loops: Animation.Infinite
                    }

                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: "transparent"
                        border.width: Style.space(2)
                        border.color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.25)
                    }

                    Rectangle {
                        width: Style.space(6)
                        height: Style.space(2)
                        radius: height / 2
                        anchors.top: parent.top
                        anchors.horizontalCenter: parent.horizontalCenter
                        color: Color.accent
                    }
                }

                Text {
                    text: root.l10n("Uruchamianie Proton Drive…", "Starting Proton Drive…")
                    textFormat: Text.PlainText
                    color: Color.popups.text
                    font.pixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Column {
                visible: root.connected
                width: parent.width
                spacing: Style.space(5)

                Text {
                    text: root.driveService
                        ? root.formatBytes(root.driveService.usedBytes)
                            + root.l10n(" zajęte z ", " used of ")
                            + root.formatBytes(root.driveService.totalBytes)
                        : ""
                    textFormat: Text.PlainText
                    color: Color.popups.text
                    font.pixelSize: Style.font.bodySmall
                }

                Rectangle {
                    width: parent.width
                    height: Style.space(6)
                    radius: height / 2
                    color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.16)

                    Rectangle {
                        width: parent.width * root.usageRatio
                        height: parent.height
                        radius: height / 2
                        color: Color.accent
                    }
                }
            }

            Column {
                visible: root.connected
                width: parent.width
                spacing: Style.space(2)

                Text {
                    text: root.l10n("Połączono", "Connected")
                    textFormat: Text.PlainText
                    color: Color.popups.text
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                }

            }

            Column {
                visible: root.driveService && root.driveService.transfers.length > 0
                width: parent.width
                spacing: Style.space(7)

                Text {
                    text: root.l10n("Aktywne operacje", "Active transfers")
                    textFormat: Text.PlainText
                    color: Color.popups.text
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                }

                Repeater {
                    model: root.driveService ? root.driveService.transfers : []
                    delegate: Column {
                        required property var modelData
                        width: parent.width
                        spacing: Style.space(3)

                        Text {
                            text: (modelData.direction === "upload"
                                ? root.l10n("Wysyłanie: ", "Uploading: ")
                                : modelData.direction === "trash"
                                    ? root.l10n("Usuwanie: ", "Moving to trash: ")
                                    : root.l10n("Pobieranie: ", "Downloading: ")) + modelData.name
                            textFormat: Text.PlainText
                            color: Color.popups.text
                            font.pixelSize: Style.font.caption
                            elide: Text.ElideMiddle
                            width: parent.width
                        }

                        Rectangle {
                            width: parent.width
                            height: Style.space(4)
                            radius: height / 2
                            color: Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.16)
Rectangle {
                            width: modelData.bytesTotal > 0
                                ? parent.width * Math.min(1, modelData.bytesDone / modelData.bytesTotal)
                                : parent.width * 0.35
                            height: parent.height
                            radius: height / 2
                            color: Color.accent
                            opacity: modelData.bytesTotal > 0 ? 1.0 : 0.65
                        }
                    }

                    Button {
                        visible: modelData.direction === "upload" && (modelData.state === "queued" || modelData.state === "running")
                        width: parent.width
                        text: root.l10n("Anuluj wysyłanie", "Cancel upload")
                        bordered: true
                        foreground: Color.popups.text
                        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                        fontSize: Style.font.caption
                        onClicked: {
                            Quickshell.execDetached(["omarchy-drive-control", "cancel-transfer", String(modelData.id)])
                            if (root.driveService) root.driveService.refreshSoon()
                        }
                    }
                }
            }
        }

        Column {
            visible: root.driveService && root.driveService.conflicts.length > 0
            width: parent.width
            spacing: Style.space(7)

            Text {
                text: root.l10n("Konflikty", "Conflicts")
                textFormat: Text.PlainText
                color: Color.popups.text
                font.pixelSize: Style.font.bodySmall
                font.bold: true
            }

            Repeater {
                model: root.driveService ? root.driveService.conflicts : []
                delegate: Column {
                    required property var modelData
                    width: parent.width
                    spacing: Style.space(5)

                    Text {
                        text: modelData.name
                        textFormat: Text.PlainText
                        color: Color.popups.text
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        elide: Text.ElideMiddle
                        width: parent.width
                    }

                    Text {
                        visible: modelData.error !== undefined && modelData.error !== ""
                        text: modelData.error || ""
                        textFormat: Text.PlainText
                        color: Color.popups.text
                        opacity: 0.75
                        wrapMode: Text.Wrap
                        width: parent.width
                        font.pixelSize: Style.font.caption
                    }

                    Button {
                        width: parent.width
                        text: root.l10n("Zachowaj wersję lokalną", "Keep local version")
                        bordered: true
                        foreground: Color.popups.text
                        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                        fontSize: Style.font.caption
                        onClicked: {
                            Quickshell.execDetached(["omarchy-drive-control", "conflict-keep-local", String(modelData.nodeId)])
                            if (root.driveService) root.driveService.refreshSoon()
                        }
                    }

                    Button {
                        width: parent.width
                        text: root.l10n("Zachowaj wersję zdalną", "Keep remote version")
                        bordered: true
                        foreground: Color.popups.text
                        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                        fontSize: Style.font.caption
                        onClicked: {
                            Quickshell.execDetached(["omarchy-drive-control", "conflict-keep-remote", String(modelData.nodeId)])
                            if (root.driveService) root.driveService.refreshSoon()
                        }
                    }

                    Button {
                        width: parent.width
                        text: root.l10n("Zachowaj obie wersje", "Save both versions")
                        bordered: true
                        foreground: Color.popups.text
                        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                        fontSize: Style.font.caption
                        onClicked: {
                            Quickshell.execDetached(["omarchy-drive-control", "conflict-save-both", String(modelData.nodeId)])
                            if (root.driveService) root.driveService.refreshSoon()
                        }
                    }
                }
            }
        }

            Column {
                visible: root.driveService && root.driveService.lastError !== ""
                width: parent.width
                spacing: Style.space(6)

                Text {
                    text: root.driveService ? root.driveService.lastError : ""
                    textFormat: Text.PlainText
                    color: Color.popups.text
                    wrapMode: Text.Wrap
                    width: parent.width
                    font.pixelSize: Style.font.bodySmall
                }

                Button {
                    width: parent.width
                    text: root.l10n("Spróbuj ponownie", "Try again")
                    bordered: true
                    foreground: Color.popups.text
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    onClicked: {
                        root.bar.run("omarchy-drive-control sync")
                        if (root.driveService) root.driveService.refreshSoon()
                    }
                }
            }

            Column {
                visible: root.connected
                width: parent.width
                spacing: Style.space(7)

                Text {
                    text: root.l10n("Zajęte miejsce lokalnie: ", "Local storage used: ")
                        + (root.driveService ? root.formatBytes(root.driveService.cacheBytes) : "0 B")
                    textFormat: Text.PlainText
                    color: Color.popups.text
                    font.pixelSize: Style.font.caption
                    width: parent.width
                }

                Button {
                    id: clearCacheButton
                    width: parent.width
                    text: root.cacheActionRunning && root.cacheActionKind === "disposable"
                        ? root.l10n("Usuwanie pamięci podręcznej…", "Clearing cache…")
                        : root.l10n("Zwolnij miejsce", "Free local space")
                    enabled: !root.cacheActionRunning
                    bordered: true
                    foreground: Color.popups.text
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    fontSize: Style.font.caption
                    onHovered: function(isHovered) {
                        if (isHovered) root.showCacheTooltip(clearCacheButton, "Removes temporary local cache. Always-available files and unsaved changes are kept.")
                        else root.hideCacheTooltip(clearCacheButton)
                    }
                    onClicked: root.clearCache()
                }

                Button {
                    id: clearPinnedCacheButton
                    width: parent.width
                    text: root.cacheActionRunning && root.cacheActionKind === "pinned"
                        ? root.l10n("Usuwanie plików offline…", "Removing offline files…")
                        : root.l10n("Usuń pliki „Zawsze dostępne”", "Remove “Always available” files")
                    enabled: !root.cacheActionRunning
                    bordered: true
                    foreground: Color.popups.text
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    fontSize: Style.font.caption
                    onHovered: function(isHovered) {
                        if (isHovered) root.showCacheTooltip(clearPinnedCacheButton, "Removes Always available local copies. Cloud files and unsaved changes are kept.")
                        else root.hideCacheTooltip(clearPinnedCacheButton)
                    }
                    onClicked: root.clearPinnedCache()
                }
            }

            Item {
                visible: root.connected && (root.cacheActionRunning || root.cacheActionMessage !== "")
                width: parent.width
                height: Style.space(34)

                Row {
                    visible: root.cacheActionRunning || root.cacheActionMessage !== ""
                    anchors.fill: parent
                    spacing: Style.space(7)

                    Text {
                        visible: root.cacheActionRunning
                        text: "↻"
                        textFormat: Text.PlainText
                        color: Color.accent
                        font.pixelSize: Style.font.body
                        anchors.verticalCenter: parent.verticalCenter
                        RotationAnimation on rotation {
                            running: root.cacheActionRunning
                            from: 0
                            to: 360
                            duration: 800
                            loops: Animation.Infinite
                        }
                    }

                    Text {
                        text: root.cacheActionRunning
                            ? (root.cacheActionKind === "pinned"
                                ? root.l10n("Usuwamy lokalne pliki „Zawsze dostępne”…", "Removing local “Always available” files…")
                                : root.l10n("Usuwamy pamięć podręczną…", "Clearing cache…"))
                            : root.cacheActionMessage
                        textFormat: Text.PlainText
                        color: root.cacheActionRunning ? Color.accent : Color.popups.text
                        opacity: root.cacheActionRunning ? 1.0 : 0.75
                        font.pixelSize: Style.font.caption
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - (root.cacheActionRunning ? Style.space(24) : 0)
                        wrapMode: Text.Wrap
                    }
                }
            }

            Button {
                visible: !root.connected && !root.loading && (!root.driveService || root.driveService.lastError === "")
                width: parent.width
                text: root.l10n("Zaloguj się", "Sign in")
                bordered: true
                foreground: Color.popups.text
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                onClicked: {
                    if (root.driveService) root.driveService.beginLoading()
                    root.bar.run("omarchy-drive-control login")
                    root.popupOpen = false
                }
            }

            Button {
                visible: root.connected
                width: parent.width
                text: root.l10n("Wyloguj się", "Sign out")
                bordered: true
                foreground: Color.popups.text
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                onClicked: {
                    if (root.driveService) root.driveService.beginLoading()
                    root.bar.run("omarchy-drive-control logout")
                    root.popupOpen = false
                }
            }

            Text {
                visible: root.driveService && root.driveService.version !== ""
                text: root.l10n("pokaż logi", "view logs")
                textFormat: Text.PlainText
                color: root.logsLinkColor
                opacity: 1.0
                font.pixelSize: Style.font.caption
                font.underline: true
                width: parent.width
                horizontalAlignment: Text.AlignHCenter

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (!openLogsProcess.running) openLogsProcess.running=true
                    }
                }
            }

            Text {
                visible: root.driveService && root.driveService.version !== ""
                text: "Proton Drive for Omarchy " + (root.driveService ? root.driveService.version : "")
                textFormat: Text.PlainText
                color: Color.popups.text
                opacity: 0.45
                font.pixelSize: Style.font.caption
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
            }
        }
        }

        Rectangle {
            id: cacheTooltipBubble
            z: 100
            visible: root.popupOpen && root.cacheTooltipTarget !== null && root.cacheTooltipText !== ""
            width: Math.min(parent.width, Style.space(280))
            height: cacheTooltipLabel.implicitHeight + Style.space(16)
            x: Math.round((parent.width - width) / 2)
            y: {
                if (!root.cacheTooltipTarget) return 0
                const point=root.cacheTooltipTarget.mapToItem(parent, 0, 0)
                return Math.max(0, Math.min(parent.height - height, point.y - height - Style.space(5)))
            }
            color: Color.tooltip.background
            border.color: Color.tooltip.border
            border.width: 1
            radius: Style.cornerRadius

            Text {
                id: cacheTooltipLabel
                anchors.centerIn: parent
                width: parent.width - Style.space(16)
                text: root.cacheTooltipText
                textFormat: Text.PlainText
                color: Color.tooltip.text
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
            }
        }
}
}
