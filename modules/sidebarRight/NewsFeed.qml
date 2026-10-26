import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Widgets

// Local addition: "News" tab of the right sidebar widget group. Merges the
// feeds in sidebar.right.newsFeeds ("Category|https://feed.url"), newest first,
// with the site's favicon, the article image when the feed has one, and
// category chips to filter. Click a card to open the article.
//
// Likes/dislikes: votes are kept in news-prefs.json (user state dir) and turn
// into weights for headline words, sources and categories. "Para ti" sorts by
// those weights; disliked or muted articles, and once there are enough votes
// the ones that score low, are hidden behind a "ver ocultas" toggle.
// mutedWords in that file can be edited by hand.
Item {
    id: root

    readonly property var feedEntries: (Config.options?.sidebar?.right?.newsFeeds ?? []).map(entry => {
        const sep = entry.indexOf("|")
        return sep > 0
            ? { category: entry.slice(0, sep).trim(), url: entry.slice(sep + 1).trim() }
            : { category: "", url: entry.trim() }
    }).filter(feed => feed.url.length > 0)
    readonly property var categories: {
        const seen = []
        for (const feed of root.feedEntries)
            if (feed.category && !seen.includes(feed.category))
                seen.push(feed.category)
        return seen
    }
    readonly property var categoryIcons: ({
        "Mercados": "candlestick_chart",
        "Economía": "trending_up",
        "Videojuegos": "sports_esports",
        "Tecnología": "memory",
        "Linux": "terminal"
    })
    // Outlet names by domain: feed titles are often a section ("US Top News and
    // Analysis") rather than the outlet
    readonly property var sourceNames: ({
        "cnbc.com": "CNBC",
        "marketwatch.com": "MarketWatch",
        "bloomberg.com": "Bloomberg",
        "ft.com": "Financial Times",
        "expansion.com": "Expansión",
        "3djuegos.com": "3DJuegos",
        "eurogamer.es": "Eurogamer",
        "ign.com": "IGN",
        "pcgamer.com": "PC Gamer",
        "xataka.com": "Xataka",
        "genbeta.com": "Genbeta",
        "phoronix.com": "Phoronix",
        "archlinux.org": "Arch Linux"
    })

    property string selectedCategory: ""
    // "all", "es" or "en"; persisted in sidebar.right.newsLanguage
    readonly property string selectedLanguage: Config.options?.sidebar?.right?.newsLanguage ?? "all"
    readonly property bool forYou: Config.options?.sidebar?.right?.newsForYou ?? false
    property bool showHidden: false
    property var articles: []

    // Preferences: [{url, title, source, category, vote: 1|-1, time}]
    readonly property string prefsPath: `${Directories.stateUserPath}/news-prefs.json`
    property var votes: []
    property var mutedSources: []
    property var mutedWords: []
    property bool _saving: false
    // Below this many votes the learned score is too noisy to hide anything by itself
    readonly property int minVotesToHide: 10
    readonly property real hideBelow: -0.5

    readonly property var voteMap: {
        const map = {}
        for (const v of root.votes)
            map[v.url] = v.vote
        return map
    }
    // (likes - dislikes) / (votes + 1) per word, source and category: in (-1, 1),
    // and a single vote only counts half.
    readonly property var weights: {
        const words = {}, sources = {}, categories = {}
        const add = (map, key, vote) => {
            if (!key)
                return
            const entry = map[key] ?? (map[key] = { pos: 0, neg: 0 })
            if (vote > 0) entry.pos += 1
            else entry.neg += 1
        }
        for (const v of root.votes) {
            for (const word of new Set(root._words(v.title)))
                add(words, word, v.vote)
            add(sources, v.source, v.vote)
            add(categories, v.category, v.vote)
        }
        const finish = map => {
            const out = {}
            for (const key in map)
                out[key] = (map[key].pos - map[key].neg) / (map[key].pos + map[key].neg + 1)
            return out
        }
        return { words: finish(words), sources: finish(sources), categories: finish(categories) }
    }
    readonly property var scoredArticles: root.articles.map(article => {
        const vote = root.voteMap[article.url] ?? 0
        const score = root.scoreOf(article)
        const words = root._words(article.title)
        const muted = root.mutedSources.includes(article.source)
            || words.some(word => root.mutedWords.includes(word))
        const hidden = vote < 0 || muted
            || (vote === 0 && root.votes.length >= root.minVotesToHide && score <= root.hideBelow)
        return Object.assign({}, article, { vote: vote, score: score, muted: muted, hidden: hidden })
    })
    readonly property var filteredArticles: root.scoredArticles.filter(article =>
        (root.selectedCategory.length === 0 || article.category === root.selectedCategory)
        && (root.selectedLanguage === "all" || article.language === root.selectedLanguage))
    readonly property int hiddenCount: root.filteredArticles.filter(article => article.hidden).length
    // sidebar.right.newsCategoryWeights, "Category|weight": with Videojuegos|5 the list
    // takes five gaming articles for each one of a weight-1 category
    readonly property var categoryWeights: {
        const weights = {}
        for (const entry of (Config.options?.sidebar?.right?.newsCategoryWeights ?? [])) {
            const sep = entry.lastIndexOf("|")
            const weight = Number(entry.slice(sep + 1))
            if (sep > 0 && weight > 0)
                weights[entry.slice(0, sep).trim()] = weight
        }
        return weights
    }
    readonly property var visibleArticles: {
        const shown = root.filteredArticles.filter(article => root.showHidden || !article.hidden)
        // Within a category: newest first (cache order), or by preference in "Para ti",
        // where an article also loses a point every two days so old ones sink
        let ordered = shown
        if (root.forYou) {
            const now = Date.now() / 1000
            const rank = article => article.score + (article.vote > 0 ? 1 : 0)
                - (article.timestamp ? (now - article.timestamp) / 172800 : 1)
            ordered = shown.slice().sort((a, b) => rank(b) - rank(a))
        }
        return root._mixByWeight(ordered)
    }

    // Smooth weighted round-robin across categories: each category keeps its own
    // order, and over any stretch of the list they appear in proportion to their weight
    function _mixByWeight(articles: var): var {
        const queues = {}
        for (const article of articles)
            (queues[article.category] ?? (queues[article.category] = [])).push(article)
        const names = Object.keys(queues)
        if (names.length < 2)
            return articles
        const credit = {}
        for (const name of names)
            credit[name] = 0
        const mixed = []
        while (mixed.length < articles.length) {
            const live = names.filter(name => queues[name].length > 0)
            let total = 0, best = live[0]
            for (const name of live) {
                const weight = root.categoryWeights[name] ?? 1
                credit[name] += weight
                total += weight
                if (credit[name] > credit[best])
                    best = name
            }
            credit[best] -= total
            mixed.push(queues[best].shift())
        }
        return mixed
    }

    readonly property var _stopwords: [
        "the", "and", "for", "with", "that", "this", "from", "are", "was", "were", "has", "have", "its",
        "will", "into", "about", "after", "over", "than", "but", "not", "you", "your", "how", "what",
        "why", "who", "new", "says", "said", "more", "out", "can", "all", "now", "just", "his", "her",
        "los", "las", "del", "una", "unos", "unas", "por", "para", "con", "que", "como", "más", "mas",
        "sus", "son", "este", "esta", "estos", "estas", "ese", "esa", "pero", "sin", "sobre", "entre",
        "hasta", "desde", "cuando", "donde", "qué", "cómo", "ya", "hay", "ser", "está", "han", "nos",
        "todo", "todos", "tiene", "tras", "año", "años", "hoy", "nuevo", "nueva"
    ]

    function _words(title: string): var {
        return (title ?? "").toLowerCase().split(/[^a-z0-9áéíóúüñ+#]+/)
            .filter(word => word.length >= 3 && !root._stopwords.includes(word))
    }

    function scoreOf(article: var): real {
        const known = root._words(article.title).map(word => root.weights.words[word])
            .filter(weight => weight !== undefined)
        const wordScore = known.length > 0 ? known.reduce((a, b) => a + b, 0) / Math.sqrt(known.length) : 0
        return wordScore + 0.6 * (root.weights.sources[article.source] ?? 0)
            + 0.3 * (root.weights.categories[article.category] ?? 0)
    }

    // Same vote again clears it
    function vote(article: var, value: int): void {
        const rest = root.votes.filter(v => v.url !== article.url)
        if ((root.voteMap[article.url] ?? 0) !== value)
            rest.push({ url: article.url, title: article.title, source: article.source,
                category: article.category, vote: value, time: Math.floor(Date.now() / 1000) })
        root.votes = rest.slice(-1000)
        root._save()
    }

    function toggleMuteSource(source: string): void {
        root.mutedSources = root.mutedSources.includes(source)
            ? root.mutedSources.filter(s => s !== source)
            : root.mutedSources.concat([source])
        root._save()
    }

    function _save(): void {
        root._saving = true
        prefsFile.setText(JSON.stringify({ votes: root.votes, mutedSources: root.mutedSources,
            mutedWords: root.mutedWords }, null, 1))
    }

    FileView {
        id: prefsFile
        path: Qt.resolvedUrl(root.prefsPath)
        // Each monitor's sidebar has its own NewsFeed: pick up the others' votes
        watchChanges: true
        onFileChanged: prefsFile.reload()
        onLoaded: {
            if (root._saving) {
                root._saving = false
                return
            }
            try {
                const data = JSON.parse(prefsFile.text())
                root.votes = Array.isArray(data.votes) ? data.votes : []
                root.mutedSources = Array.isArray(data.mutedSources) ? data.mutedSources : []
                root.mutedWords = Array.isArray(data.mutedWords)
                    ? data.mutedWords.map(word => String(word).toLowerCase()) : []
            } catch (e) {
                console.warn("[NewsFeed] news-prefs.json is not valid JSON:", e)
            }
        }
    }

    implicitHeight: 560

    function iconFor(category: string): string {
        return root.categoryIcons[category] ?? "newspaper"
    }

    // Fetching and parsing run in scripts/news/fetch_news.py, out of process: doing it
    // here blocked the UI thread for seconds each time the sidebar content was built.
    // The script writes a JSON cache that every NewsFeed instance watches, and skips the
    // download while the cache is fresh, so opening the sidebar just reads that file.
    readonly property string cachePath: `${Directories.cachePath}/news/articles.json`
    readonly property int refreshSeconds: 15 * 60
    readonly property bool loading: fetchProc.running

    function refresh(force: bool): void {
        if (fetchProc.running || root.feedEntries.length === 0)
            return
        fetchProc.command = ["/usr/bin/python3", "-I", Quickshell.shellPath("scripts/news/fetch_news.py"),
            root.cachePath, String(force ? 0 : root.refreshSeconds),
            ...(Config.options?.sidebar?.right?.newsFeeds ?? [])]
        fetchProc.running = true
    }

    Process {
        id: fetchProc
        // The watcher misses a cache file created or atomically replaced after it
        // started watching, so re-read explicitly once the script is done
        onExited: cacheFile.reload()
        stderr: StdioCollector {
            onStreamFinished: {
                if (text.trim().length > 0)
                    console.warn("[NewsFeed] fetch_news.py:", text.trim())
            }
        }
    }

    FileView {
        id: cacheFile
        path: Qt.resolvedUrl(root.cachePath)
        watchChanges: true
        printErrors: false
        onFileChanged: cacheFile.reload()
        onLoaded: {
            try {
                const data = JSON.parse(cacheFile.text())
                root.articles = (data.articles ?? []).map(article => Object.assign(article, {
                    source: root._sourceName(article.domain) || article.source || article.domain,
                    favicon: article.domain ? `https://www.google.com/s2/favicons?domain=${article.domain}&sz=64` : ""
                }))
            } catch (e) {
                console.warn("[NewsFeed] news cache is not valid JSON:", e)
            }
        }
    }

    function _sourceName(domain: string): string {
        const host = (domain ?? "").toLowerCase()
        for (const key in root.sourceNames)
            if (host === key || host.endsWith("." + key))
                return root.sourceNames[key]
        return ""
    }

    function _age(timestamp: real): string {
        if (!timestamp)
            return ""
        const diff = Date.now() / 1000 - timestamp
        if (diff < 3600)
            return Math.max(1, Math.floor(diff / 60)) + " min"
        if (diff < 86400)
            return Math.floor(diff / 3600) + " h"
        return Math.floor(diff / 86400) + " d"
    }

    Component.onCompleted: root.refresh(false)
    // Deferred: refresh() reads feedEntries, which this handler is reacting to
    onFeedEntriesChanged: Qt.callLater(() => root.refresh(false))

    Timer {
        interval: root.refreshSeconds * 1000
        running: true
        repeat: true
        onTriggered: root.refresh(false)
    }

    component CategoryChip: RippleButton {
        id: chip
        required property string category
        required property string chipLabel
        required property string chipIcon
        readonly property bool active: root.selectedCategory === chip.category
        implicitHeight: 30
        implicitWidth: chipRow.implicitWidth + 20
        buttonRadius: Appearance.rounding.full
        colBackground: active ? Appearance.colors.colSecondaryContainer : Appearance.colors.colLayer2
        colBackgroundHover: active ? Appearance.colors.colSecondaryContainerHover : Appearance.colors.colLayer2Hover
        downAction: () => root.selectedCategory = chip.category
        contentItem: Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: 4
            MaterialSymbol {
                anchors.verticalCenter: parent.verticalCenter
                text: chip.chipIcon
                iconSize: Appearance.font.pixelSize.normal
                color: chip.active ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer2
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: chip.chipLabel
                font.family: Appearance.font.family.main
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: chip.active ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer2
            }
        }
    }

    // Small round icon button on a news card (like / dislike / mute source)
    component CardAction: RippleButton {
        id: action
        required property string symbol
        property bool active: false
        property color activeColor: Appearance.colors.colPrimary
        signal triggered()
        Layout.preferredWidth: 24
        Layout.preferredHeight: 24
        implicitWidth: 24
        implicitHeight: 24
        buttonRadius: Appearance.rounding.full
        colBackground: "transparent"
        colBackgroundHover: Appearance.colors.colLayer3Hover
        downAction: () => action.triggered()
        contentItem: MaterialSymbol {
            anchors.centerIn: parent
            text: action.symbol
            fill: action.active ? 1 : 0
            iconSize: Appearance.font.pixelSize.normal
            color: action.active ? action.activeColor : Appearance.colors.colSubtext
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 6
        spacing: 8

        // Toolbar: sort mode, language, hidden articles and refresh
        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            // Sort by likes/dislikes; works on top of the category filter
            RippleButton {
                implicitHeight: 30
                implicitWidth: forYouRow.implicitWidth + 20
                buttonRadius: Appearance.rounding.full
                colBackground: root.forYou ? Appearance.colors.colPrimary : Appearance.colors.colLayer2
                colBackgroundHover: root.forYou ? Appearance.colors.colPrimaryHover : Appearance.colors.colLayer2Hover
                downAction: () => Config.setNestedValue("sidebar.right.newsForYou", !root.forYou)
                contentItem: Row {
                    id: forYouRow
                    anchors.centerIn: parent
                    spacing: 4
                    MaterialSymbol {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "auto_awesome"
                        fill: root.forYou ? 1 : 0
                        iconSize: Appearance.font.pixelSize.normal
                        color: root.forYou ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer2
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Para ti"
                        font.family: Appearance.font.family.main
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: root.forYou ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer2
                    }
                }
            }

            // Language: segmented Todos | ES | EN
            Rectangle {
                implicitHeight: 30
                implicitWidth: langSegments.implicitWidth + 6
                radius: height / 2
                color: "transparent"
                border.width: 1
                border.color: Appearance.colors.colOutlineVariant
                Row {
                    id: langSegments
                    anchors.centerIn: parent
                    spacing: 2
                    Repeater {
                        model: [{ code: "all", label: "Todos" }, { code: "es", label: "ES" }, { code: "en", label: "EN" }]
                        RippleButton {
                            id: segment
                            required property var modelData
                            readonly property bool active: root.selectedLanguage === segment.modelData.code
                            implicitHeight: 24
                            implicitWidth: segmentLabel.implicitWidth + 16
                            buttonRadius: Appearance.rounding.full
                            colBackground: active ? Appearance.colors.colSecondaryContainer : "transparent"
                            colBackgroundHover: active ? Appearance.colors.colSecondaryContainerHover : Appearance.colors.colLayer2Hover
                            downAction: () => Config.setNestedValue("sidebar.right.newsLanguage", segment.modelData.code)
                            contentItem: Text {
                                id: segmentLabel
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                text: segment.modelData.label
                                font.family: Appearance.font.family.main
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                font.weight: segment.active ? Font.DemiBold : Font.Normal
                                color: segment.active ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer2
                            }
                        }
                    }
                }
            }

            Item { Layout.fillWidth: true }

            // Hidden articles in the current filter: count, click to show them
            RippleButton {
                visible: root.hiddenCount > 0
                implicitHeight: 30
                implicitWidth: hiddenRow.implicitWidth + 16
                buttonRadius: Appearance.rounding.full
                colBackground: root.showHidden ? Appearance.colors.colSecondaryContainer : "transparent"
                colBackgroundHover: root.showHidden ? Appearance.colors.colSecondaryContainerHover : Appearance.colors.colLayer2Hover
                downAction: () => root.showHidden = !root.showHidden
                contentItem: Row {
                    id: hiddenRow
                    anchors.centerIn: parent
                    spacing: 3
                    MaterialSymbol {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.showHidden ? "visibility" : "visibility_off"
                        iconSize: Appearance.font.pixelSize.normal
                        color: root.showHidden ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colSubtext
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.hiddenCount
                        font.family: Appearance.font.family.main
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: root.showHidden ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colSubtext
                    }
                }
                StyledToolTip {
                    text: root.showHidden ? "Esconder las ocultas" : "Ver las noticias ocultas"
                }
            }

            RippleButton {
                implicitWidth: 30
                implicitHeight: 30
                buttonRadius: Appearance.rounding.full
                colBackground: "transparent"
                colBackgroundHover: Appearance.colors.colLayer2Hover
                downAction: () => root.refresh(true)
                contentItem: MaterialSymbol {
                    anchors.centerIn: parent
                    text: root.loading ? "hourglass_empty" : "refresh"
                    iconSize: Appearance.font.pixelSize.larger
                    color: Appearance.colors.colOnLayer1
                }
            }
        }

        // Categories, scrollable sideways when they don't fit
        Flickable {
            Layout.fillWidth: true
            implicitHeight: 30
            contentWidth: chips.implicitWidth
            clip: true
            interactive: contentWidth > width
            boundsBehavior: Flickable.StopAtBounds

            Row {
                id: chips
                spacing: 6
                CategoryChip { category: ""; chipLabel: "Todo"; chipIcon: "newspaper" }
                Repeater {
                    model: root.categories
                    CategoryChip {
                        required property string modelData
                        category: modelData
                        chipLabel: modelData
                        chipIcon: root.iconFor(modelData)
                    }
                }
            }
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 6
            model: root.visibleArticles
            boundsBehavior: Flickable.StopAtBounds

            delegate: RippleButton {
                id: card
                required property var modelData
                // Vote buttons show on hover, or always once the card has a vote
                readonly property bool showActions: card.buttonHovered || likeButton.buttonHovered
                    || dislikeButton.buttonHovered || muteButton.buttonHovered || card.modelData.vote !== 0
                width: list.width
                opacity: card.modelData.hidden ? 0.5 : 1
                implicitHeight: Math.max(cardRow.implicitHeight + 16, 84)
                buttonRadius: Appearance.rounding.normal
                colBackground: Appearance.colors.colLayer2
                colBackgroundHover: Appearance.colors.colLayer2Hover
                downAction: () => Qt.openUrlExternally(card.modelData.url)

                contentItem: RowLayout {
                    id: cardRow
                    anchors.fill: parent
                    anchors.margins: 8
                    spacing: 10

                    // Article image, or the category icon on a tonal tile
                    ClippingRectangle {
                        Layout.preferredWidth: 88
                        Layout.preferredHeight: 66
                        Layout.alignment: Qt.AlignTop
                        radius: Appearance.rounding.small
                        color: Appearance.colors.colLayer3

                        MaterialSymbol {
                            anchors.centerIn: parent
                            visible: !thumb.usable
                            text: root.iconFor(card.modelData.category)
                            iconSize: 28
                            color: Appearance.colors.colPrimary
                        }
                        Image {
                            id: thumb
                            anchors.fill: parent
                            source: card.modelData.image
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            sourceSize.width: 176
                            sourceSize.height: 132
                            // Tracking pixels and tiny icons don't count as an article image
                            readonly property bool usable: status === Image.Ready && implicitWidth > 40
                            visible: usable
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignTop
                        spacing: 4

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            Image {
                                Layout.preferredWidth: 16
                                Layout.preferredHeight: 16
                                source: card.modelData.favicon
                                sourceSize.width: 32
                                sourceSize.height: 32
                                asynchronous: true
                                smooth: true
                            }
                            Text {
                                Layout.fillWidth: true
                                text: [card.modelData.source, root._age(card.modelData.timestamp),
                                    card.modelData.muted ? "silenciado" : ""]
                                    .filter(part => part.length > 0).join(" · ")
                                elide: Text.ElideRight
                                font.family: Appearance.font.family.main
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: Appearance.colors.colSubtext
                            }
                            CardAction {
                                id: likeButton
                                visible: card.showActions
                                symbol: "thumb_up"
                                active: card.modelData.vote > 0
                                activeColor: Appearance.colors.colPrimary
                                onTriggered: root.vote(card.modelData, 1)
                            }
                            CardAction {
                                id: dislikeButton
                                visible: card.showActions
                                symbol: "thumb_down"
                                active: card.modelData.vote < 0
                                activeColor: Appearance.colors.colError
                                onTriggered: root.vote(card.modelData, -1)
                            }
                            CardAction {
                                id: muteButton
                                visible: card.showActions && (card.buttonHovered || likeButton.buttonHovered
                                    || dislikeButton.buttonHovered || muteButton.buttonHovered)
                                symbol: "block"
                                active: root.mutedSources.includes(card.modelData.source)
                                activeColor: Appearance.colors.colError
                                onTriggered: root.toggleMuteSource(card.modelData.source)
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: card.modelData.title
                            wrapMode: Text.Wrap
                            maximumLineCount: 3
                            elide: Text.ElideRight
                            font.family: Appearance.font.family.main
                            font.pixelSize: Appearance.font.pixelSize.small
                            font.weight: Font.Medium
                            color: Appearance.colors.colOnLayer2
                        }
                    }
                }
            }
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            visible: root.visibleArticles.length === 0
            text: root.loading ? "Cargando…"
                : root.feedEntries.length === 0 ? "No hay feeds configurados"
                : "Sin noticias"
            font.family: Appearance.font.family.main
            font.pixelSize: Appearance.font.pixelSize.small
            color: Appearance.colors.colSubtext
        }
    }
}
