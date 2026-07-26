import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts

ApplicationWindow {
    id: win
    width: 1080
    height: 680
    minimumWidth: 920
    minimumHeight: 600
    visible: true
    title: "DeckBorne"
    color: "transparent"                 // frameless: inner rect draws the rounded body
    flags: Qt.Window | Qt.FramelessWindowHint

    // home (option cards) <-> progress (stage panel)
    property bool showProgress: false
    // outcome of the last run (drives the completion button)
    property bool runFinished: false
    property bool runOk: false

    // Null-guarded views of the backend. `installer` is a context property; during
    // initial construction QML may evaluate bindings a beat before it resolves, so
    // reading installer.* directly logs transient "property of null" warnings. Reading
    // through these aliases (installer ? … : default) keeps the logs clean.
    readonly property bool    busy:         installer ? installer.busy : false
    readonly property real    progress:     installer ? installer.progress : 0
    readonly property real    subProgress:  installer ? installer.subProgress : 0
    readonly property bool    indeterminate:installer ? installer.indeterminate : false
    readonly property bool    quoting:      installer ? installer.quoting : false
    readonly property string  subLabel:     installer ? installer.subLabel : ""
    readonly property bool    failed:       installer ? installer.failed : false
    readonly property string  statusText:   installer ? installer.status : ""
    readonly property string  headlineText: installer ? installer.headline : ""
    readonly property var     stagesModel:  installer ? installer.stages : null
    readonly property var     storageModel: installer ? installer.storage : null
    readonly property bool    storageReady: installer ? installer.storageReady : false
    readonly property string  storageWarning: installer ? installer.storageWarning : ""
    readonly property string  storageName:  installer ? installer.storageName : ""

    // Track run outcome for the completion button.
    Connections {
        target: installer
        function onFinished(ok, msg) { win.runFinished = true; win.runOk = ok }
    }

    // Start a run: reset outcome, switch to the progress view.
    function beginRun(fn) { win.runFinished = false; win.runOk = false; win.showProgress = true; fn() }

    // Bloodborne flavour quotes shown (rotating) during the long extract stage.
    readonly property var quotes: [
        { text: "A corpse should be left well alone. Oh, I know how the secrets beckon so sweetly. Only an honest death will cure you now. Free you from your wild curiosity.", who: "Lady Maria of the Astral Clocktower" },
        { text: "Has someone, anyone, seen my eyes? I'm afraid I've dropped them in a puddle. Everything is pale now…", who: "Eerily Familiar Research Hall patient" },
        { text: "We are born of the blood, made men by the blood, undone by the blood. Our eyes have yet to open… Fear the Old Blood.", who: "Provost Willem" },
        { text: "A hunter should hunt beasts. Leave the hunting of hunters to me.", who: "Eileen the Crow" },
        { text: "Now, let's begin the transfusion. Oh, don't you worry. Whatever happens… you may think it all a mere bad dream.", who: "Blood Minister" },
        { text: "Ah, Kos… or some say Kosm… Do you hear our prayers?", who: "Micolash, Host of the Nightmare" },
        { text: "I am a doll, created by you humans. Would you ever think to love me? Of course, I do love you. Isn't that how you've made me?", who: "The Plain Doll" },
        { text: "What's that smell? The sweet blood, oh, it sings to me. It's enough to make a man sick.", who: "Father Gascoigne" },
        { text: "Good hunter, have you seen the thread of light? Just a hair, a fleeting thing, yet I clung to it, steeped as I was in the stench of blood and beasts.", who: "Ludwig, the Holy Blade" },
        { text: "Aah, you were at my side, all along. My true mentor… My guiding moonlight…", who: "Ludwig, the Holy Blade" },
        { text: "The night… and the dream… were long…", who: "Old Hunter Gehrman" },
        { text: "Majestic! A hunter is a hunter, even in a dream. But alas, not too fast! The nightmare swirls and churns unending!", who: "Micolash, Host of the Nightmare" },
        { text: "As you once did for the vacuous Rom, grant us eyes, grant us eyes. Plant eyes on our brains, to cleanse our beastly idiocy.", who: "Micolash, Host of the Nightmare" },
        { text: "Curse the fiends, their children too. And their children, forever, true.", who: "Baneful Chanters" },
        { text: "Oh, doubt me not, sweet compeer. What is friendship, but a chance encounter?", who: "Patches the Spider" },
        { text: "Not even death offers solace, and the blood imbibes you. Ha, a most frightful fate, oh my.", who: "Patches the Spider" },
        { text: "Beast hunting is a sacred practice. May the good blood guide your way.", who: "Alfred, Hunter of the Vilebloods" }
    ]

    // Shuffled bag: every quote is shown once before any repeats.
    property var quoteBag: []
    property int lastQuote: -1

    function shuffledQuoteBag() {
        var bag = []
        for (var i = 0; i < win.quotes.length; ++i) bag.push(i)
        for (var j = bag.length - 1; j > 0; --j) {
            var k = Math.floor(Math.random() * (j + 1))
            var t = bag[j]; bag[j] = bag[k]; bag[k] = t
        }
        if (bag.length > 1 && bag[bag.length - 1] === win.lastQuote) {
            var s = bag[bag.length - 1]; bag[bag.length - 1] = bag[0]; bag[0] = s
        }
        return bag
    }

    function nextQuote() {
        var bag = win.quoteBag
        if (!bag || bag.length === 0) bag = win.shuffledQuoteBag()
        var n = bag[bag.length - 1]
        win.quoteBag = bag.slice(0, bag.length - 1)
        win.lastQuote = n
        return n
    }

    // ---- artist attribution (shown bottom-left on every view, links out) ----
    readonly property string artCreditName: "Artwork by Snatti89"
    readonly property string artCreditUrl:  "https://www.instagram.com/snatti89/"

    // ---- palette (drawn from the Bloodborne blood-moon art) ----
    readonly property color cBase:   "#0b0908"
    readonly property color cBone:   "#ece6da"
    readonly property color cMuted:  "#a79c8b"
    readonly property color cBlood:  "#a01f22"
    readonly property color cBloodHi:"#d0342f"
    readonly property color cGold:   "#e0a24b"
    readonly property color cBorder: Qt.rgba(1, 1, 1, 0.10)
    readonly property color cPanel:  Qt.rgba(0.055, 0.045, 0.045, 0.62)

    FontLoader { id: bbFont; source: deckborneFontUrl }

    // =========================================================
    // Reusable pieces
    // =========================================================

    // Small text button (Cancel / Back / Collect logs).
    component GhostButton: Button {
        id: gb
        property color accent: win.cGold
        implicitHeight: 40
        contentItem: Text {
            text: gb.text; color: gb.enabled ? win.cBone : win.cMuted
            font.pixelSize: 14; horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: 8
            color: gb.down ? Qt.rgba(1,1,1,0.10) : gb.hovered ? Qt.rgba(1,1,1,0.06) : Qt.rgba(0,0,0,0.25)
            border.width: 1
            border.color: gb.hovered && gb.enabled ? gb.accent : win.cBorder
            Behavior on border.color { ColorAnimation { duration: 120 } }
        }
        opacity: enabled ? 1 : 0.4
        Behavior on opacity { NumberAnimation { duration: 150 } }
    }

    // One device inside the StoragePicker dropdown. Unusable devices are still LISTED
    // (dimmed, with the reason) rather than hidden — a user whose SD card is exFAT needs
    // to be told that, not left wondering where their card went.
    component StorageOption: Rectangle {
        id: srow
        required property string name
        required property string root
        required property string detail
        required property string note
        required property bool usable
        required property bool selected
        required property int index
        signal picked()

        Layout.fillWidth: true
        implicitHeight: rowCol.implicitHeight + 16
        radius: 7
        color: selected ? Qt.rgba(0.16, 0.12, 0.11, 0.95)
             : srowHover.hovered && usable ? Qt.rgba(1, 1, 1, 0.07)
             : "transparent"
        opacity: usable ? 1 : 0.5
        Behavior on color { ColorAnimation { duration: 110 } }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            spacing: 9

            Text {
                Layout.alignment: Qt.AlignTop
                Layout.topMargin: 9
                text: srow.selected ? "✓" : "·"
                color: srow.selected ? win.cGold : win.cMuted
                font.pixelSize: srow.selected ? 12 : 14
                font.bold: srow.selected
                horizontalAlignment: Text.AlignHCenter
                Layout.preferredWidth: 10
            }

            ColumnLayout {
                id: rowCol
                Layout.fillWidth: true
                spacing: 1
                Text {
                    text: srow.name
                    color: srow.usable ? (srow.selected ? win.cGold : win.cBone) : win.cMuted
                    font.pixelSize: 14
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
                Text {
                    text: srow.detail
                    color: win.cMuted; font.pixelSize: 11
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
                Text {
                    visible: srow.note !== ""
                    text: srow.note
                    color: win.cBloodHi; font.pixelSize: 10
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                    Layout.topMargin: 3
                }
            }
        }

        HoverHandler { id: srowHover; enabled: srow.usable; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: if (srow.usable) srow.picked() }
    }

    // Install-location control: reads as a GhostButton, opens a device list on hover.
    // Sits inline beside "Collect logs" so the home view keeps its three-card shape.
    component StoragePicker: Item {
        id: sp
        implicitWidth: 250
        implicitHeight: 40

        readonly property bool open: pop.opened

        // How much room is left below the button. Measured as the menu opens rather than
        // bound live: mapToItem() does not re-evaluate on its own.
        property real maxDrop: 240

        // Same screenshot hook OptionCard uses: --open 9 forces the menu down.
        Component.onCompleted: if (previewOpen === 9) Qt.callLater(pop.open)

        Rectangle {
            id: face
            anchors.fill: parent
            radius: 8
            color: sp.open ? Qt.rgba(1,1,1,0.06) : Qt.rgba(0,0,0,0.25)
            border.width: 1
            border.color: sp.open ? win.cGold : win.cBorder
            Behavior on color { ColorAnimation { duration: 120 } }
            Behavior on border.color { ColorAnimation { duration: 120 } }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 13
                anchors.rightMargin: 11
                spacing: 6
                Text { text: "Install to:"; color: win.cMuted; font.pixelSize: 13 }
                Text {
                    text: win.storageName !== "" ? win.storageName : "No device"
                    color: win.storageReady ? win.cBone : win.cBloodHi
                    font.pixelSize: 13
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
                Text {
                    text: "⌄"
                    color: sp.open ? win.cGold : win.cMuted
                    font.pixelSize: 15
                    rotation: sp.open ? 180 : 0
                    Behavior on rotation { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                }
            }
        }

        // Hover REVEALS the menu; it never closes on hover-out. Two earlier attempts tied
        // closing to the pointer leaving the button/list pair, and both made the menu
        // impossible to use — it vanished on the way to the option you wanted. Closing is
        // now an explicit act: pick a device, click away, or press Escape.
        HoverHandler {
            id: faceHover
            cursorShape: Qt.PointingHandCursor
            onHoveredChanged: if (hovered) pop.open()
        }
        // The Deck is a touchscreen and Game Mode has no hover at all, so tap must open
        // it too. Deliberately open(), not a toggle: CloseOnPressOutside already fires on
        // this same press, and a toggle would immediately reopen what it just closed.
        TapHandler { onTapped: pop.open() }

        // A Controls Popup, NOT a plain child Rectangle. A child item is stacked inside
        // its parent's place in the scene graph, so `z` could not lift the list above the
        // rest of the view and it could not reliably take the pointer. A Popup renders in
        // the window's overlay layer, which is what "stays in the foreground" requires.
        Popup {
            id: pop
            x: (sp.width - width) / 2
            y: sp.height
            width: 400
            height: Math.min(popCol.implicitHeight + topPadding + bottomPadding, sp.maxDrop)
            padding: 8
            modal: false
            // focus is what makes CloseOnEscape actually fire — without it the key event
            // never reaches the popup. Nothing else in this window takes keyboard input.
            focus: true
            closePolicy: Popup.CloseOnPressOutside | Popup.CloseOnEscape

            onAboutToShow: sp.maxDrop = Math.max(150,
                root.height - sp.mapToItem(root, 0, sp.height).y - 20)

            background: Rectangle {
                radius: 10
                color: Qt.rgba(0.06, 0.05, 0.05, 0.98)
                border.width: 1
                border.color: win.cGold
            }
            enter: Transition { NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 120 } }
            exit:  Transition { NumberAnimation { property: "opacity"; from: 1; to: 0; duration: 120 } }

            contentItem: Flickable {
                id: popFlick
                contentWidth: width
                contentHeight: popCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {
                    policy: popFlick.contentHeight > popFlick.height
                            ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                }

                ColumnLayout {
                    id: popCol
                    width: popFlick.width
                    spacing: 2

                    Repeater {
                        model: win.storageModel
                        StorageOption {
                            onPicked: { installer.selectStorage(index); pop.close() }
                        }
                    }

                    Text {
                        visible: win.storageWarning !== ""
                        text: win.storageWarning
                        color: win.storageReady ? win.cGold : win.cBloodHi
                        font.pixelSize: 10
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                        Layout.leftMargin: 10
                        Layout.rightMargin: 10
                        Layout.topMargin: 4
                    }

                    Text {
                        Layout.alignment: Qt.AlignRight
                        Layout.rightMargin: 10
                        Layout.topMargin: 2
                        text: "Rescan devices"
                        color: rescanHover.hovered ? win.cGold : win.cMuted
                        font.pixelSize: 10
                        font.underline: rescanHover.hovered
                        HoverHandler { id: rescanHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: installer.refreshStorage() }
                    }
                }
            }
        }
    }

    // One frame-rate/resolution choice inside the DeckBorne card.
    component FpsPill: Button {
        id: fp
        property string rate
        property string note
        property bool recommended: false

        Layout.fillWidth: true
        implicitHeight: 50
        contentItem: ColumnLayout {
            spacing: 2
            Text {
                text: fp.rate
                color: fp.hovered ? win.cGold : win.cBone
                font.pixelSize: 15
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                Behavior on color { ColorAnimation { duration: 120 } }
            }
            Text {
                text: fp.note
                color: fp.recommended ? win.cGold : win.cMuted
                font.pixelSize: 10
                font.letterSpacing: 0.7
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
            }
        }
        background: Rectangle {
            radius: 8
            color: fp.down ? Qt.rgba(1,1,1,0.10) : fp.hovered ? Qt.rgba(1,1,1,0.06) : Qt.rgba(0,0,0,0.25)
            border.width: 1
            border.color: fp.hovered ? win.cGold : win.cBorder
            Behavior on color { ColorAnimation { duration: 120 } }
            Behavior on border.color { ColorAnimation { duration: 120 } }
        }
        HoverHandler { cursorShape: Qt.PointingHandCursor }
    }

    // An expandable action card: title + chevron; hovering smoothly reveals the blurb.
    // A card with `footer` set does NOT launch on click — the footer's own controls do.
    // Tapping such a card toggles it open, because Game Mode has no hover at all.
    component OptionCard: Rectangle {
        id: card
        property string title
        property string blurb
        property bool danger: false
        property bool disabled: false
        property int index: -1
        property Component footer: null
        property bool tapOpen: false
        signal activated()

        readonly property bool actionable: footer === null
        readonly property color accent: danger ? win.cBloodHi : win.cGold
        // expand on hover (mouse), on tap (touch), or when the preview forces it open
        readonly property bool open: hover.hovered || tapOpen || previewOpen === index

        onDisabledChanged: if (disabled) tapOpen = false

        opacity: disabled ? 0.4 : 1
        Behavior on opacity { NumberAnimation { duration: 150 } }

        Layout.fillWidth: true
        radius: 12
        clip: true
        color: hover.hovered ? Qt.rgba(0.10, 0.08, 0.08, 0.80) : Qt.rgba(0.03, 0.025, 0.025, 0.55)
        border.width: 1
        border.color: open ? accent : win.cBorder
        Behavior on color { ColorAnimation { duration: 140 } }
        Behavior on border.color { ColorAnimation { duration: 140 } }

        implicitHeight: 62 + (open ? blurbText.implicitHeight + 20
                                     + (footer ? footerLoader.implicitHeight + 12 : 0) : 0)
        Behavior on implicitHeight { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        // a thin accent bar on the left that grows in when open
        Rectangle {
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width: 3
            color: card.accent
            opacity: card.open ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 160 } }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: 20
            anchors.rightMargin: 18
            anchors.topMargin: 0
            spacing: 0
            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 62
                spacing: 12
                Text {
                    text: card.title
                    color: win.cBone
                    font.pixelSize: 19
                    Layout.fillWidth: true
                    verticalAlignment: Text.AlignVCenter
                }
                Text {                              // chevron, rotates when open
                    text: "⌄"                  // ⌄
                    color: card.open ? card.accent : win.cMuted
                    font.pixelSize: 22
                    rotation: card.open ? 180 : 0
                    Behavior on rotation { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                    Behavior on color { ColorAnimation { duration: 140 } }
                }
                TapHandler {
                    enabled: !card.actionable && !card.disabled
                    onTapped: card.tapOpen = !card.tapOpen
                }
            }
            Text {
                id: blurbText
                text: card.blurb
                color: win.cMuted
                font.pixelSize: 14
                lineHeight: 1.25
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                Layout.bottomMargin: card.footer ? 10 : 18
                opacity: card.open ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 180 } }
            }
            Loader {
                id: footerLoader
                active: card.footer !== null
                sourceComponent: card.footer
                Layout.fillWidth: true
                Layout.bottomMargin: 18
                opacity: card.open ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: 180 } }
            }
        }

        HoverHandler { id: hover; enabled: !card.disabled }
        TapHandler {
            enabled: card.actionable && !card.disabled
            onTapped: card.activated()
        }
    }

    // One row in the progress stage checklist.
    component StageRow: RowLayout {
        required property string label
        required property string stageState
        spacing: 14
        Item {
            Layout.preferredWidth: 22
            Layout.preferredHeight: 22
            Rectangle {
                anchors.centerIn: parent
                width: 18; height: 18; radius: 9
                color: stageState === "done"    ? Qt.rgba(0.88,0.64,0.29,0.18)
                     : stageState === "failed"  ? Qt.rgba(0.82,0.20,0.18,0.22)
                     : stageState === "running" ? Qt.rgba(0.82,0.20,0.18,0.22)
                     : "transparent"
                border.width: stageState === "pending" ? 2 : 0
                border.color: win.cMuted
                SequentialAnimation on opacity {
                    running: stageState === "running"
                    loops: Animation.Infinite
                    NumberAnimation { from: 0.45; to: 1.0; duration: 650; easing.type: Easing.InOutQuad }
                    NumberAnimation { from: 1.0; to: 0.45; duration: 650; easing.type: Easing.InOutQuad }
                }
            }
            Text {
                anchors.centerIn: parent
                text: stageState === "done" ? "✓" : stageState === "failed" ? "✕" : ""
                color: stageState === "failed" ? win.cBloodHi : win.cGold
                font.pixelSize: 13; font.bold: true
            }
            Rectangle {
                anchors.centerIn: parent
                visible: stageState === "running"
                width: 7; height: 7; radius: 4
                color: win.cBloodHi
            }
        }
        Text {
            text: label
            Layout.fillWidth: true
            color: stageState === "pending" ? win.cMuted : win.cBone
            font.pixelSize: 15
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
        }
    }

    // =========================================================
    // Body
    // =========================================================
    Rectangle {
        id: root
        anchors.fill: parent
        radius: 16
        clip: true
        color: win.cBase

        Image {
            id: bg
            anchors.fill: parent
            source: bgImageUrl
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            opacity: 0.55
        }
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(0.043,0.035,0.031,0.35) }
                GradientStop { position: 0.5; color: Qt.rgba(0.043,0.035,0.031,0.55) }
                GradientStop { position: 1.0; color: Qt.rgba(0.043,0.035,0.031,0.82) }
            }
        }
        Rectangle { anchors.fill: parent; color: "transparent"; radius: 16
            border.width: 1; border.color: Qt.rgba(1,1,1,0.07) }

        // ---- title bar (drag + window controls) ----
        Item {
            id: titlebar
            anchors { top: parent.top; left: parent.left; right: parent.right }
            height: 44
            z: 5
            MouseArea { anchors.fill: parent; onPressed: win.startSystemMove() }
            Row {
                anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                spacing: 4
                Rectangle {
                    width: 30; height: 30; radius: 6
                    color: minMa.containsMouse ? Qt.rgba(1,1,1,0.10) : "transparent"
                    Text { anchors.centerIn: parent; text: "–"; color: win.cBone; font.pixelSize: 16 }
                    MouseArea { id: minMa; anchors.fill: parent; hoverEnabled: true; onClicked: win.showMinimized() }
                }
                Rectangle {
                    width: 30; height: 30; radius: 6
                    color: closeMa.containsMouse ? win.cBlood : "transparent"
                    Text { anchors.centerIn: parent; text: "✕"; color: win.cBone; font.pixelSize: 13 }
                    MouseArea { id: closeMa; anchors.fill: parent; hoverEnabled: true; onClicked: Qt.quit() }
                }
            }
        }

        // ---- wordmark ----
        Item {
            id: header
            anchors { top: parent.top; topMargin: 30; left: parent.left; right: parent.right }
            height: 118
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.horizontalCenterOffset: 3; y: 7
                text: "DeckBorne"; font.family: bbFont.font.family; font.pixelSize: 80
                color: Qt.rgba(0, 0, 0, 0.6)
            }
            Text {
                id: wordmark
                anchors.horizontalCenter: parent.horizontalCenter; y: 4
                text: "DeckBorne"; font.family: bbFont.font.family; font.pixelSize: 80
                color: win.cBone
            }
            Text {
                anchors { horizontalCenter: parent.horizontalCenter; top: wordmark.bottom; topMargin: 2 }
                text: "BLOODBORNE   ·   shadPS4   ·   STEAM DECK"
                color: win.cMuted; font.pixelSize: 12; font.letterSpacing: 4
            }
        }

        // ---- content: home <-> progress ----
        Item {
            id: content
            anchors { top: header.bottom; topMargin: 8; left: parent.left; right: parent.right; bottom: parent.bottom }

            // ========== HOME (option cards) ==========
            Item {
                id: homeView
                anchors.fill: parent
                opacity: win.showProgress ? 0 : 1
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: 220 } }

                ColumnLayout {
                    width: Math.min(660, parent.width - 96)
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: parent.top
                    anchors.topMargin: 18
                    spacing: 14

                    OptionCard {
                        index: 0
                        disabled: !win.storageReady
                        title: "Install Vanilla Experience"
                        blurb: "An experience as close to the original Bloodborne as possible. Target 30 FPS."
                        onActivated: win.beginRun(installer.startVanilla)
                    }
                    OptionCard {
                        index: 1
                        disabled: !win.storageReady
                        title: "Install DeckBorne Experience"
                        blurb: "The DeckBorne experience. QOL improvements, visual enhancements, and community mods. Pick the frame rate you want to run at."
                        footer: Component {
                            ColumnLayout {
                                spacing: 8
                                enabled: win.storageReady
                                Text {
                                    text: "Choose your experience"
                                    color: win.cMuted
                                    font.pixelSize: 12
                                    Layout.fillWidth: true
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 10
                                    FpsPill {
                                        rate: "30 FPS · 800p"
                                        note: "STEAM DECK — RECOMMENDED"
                                        recommended: true
                                        onClicked: win.beginRun(function () { installer.startDeckBorne("deck30") })
                                    }
                                    FpsPill {
                                        rate: "60 FPS · 800p"
                                        note: "STEAM DECK — BETA"
                                        onClicked: win.beginRun(function () { installer.startDeckBorne("deck60") })
                                    }
                                    FpsPill {
                                        rate: "60 FPS · 1080p"
                                        note: "DESKTOP"
                                        onClicked: win.beginRun(function () { installer.startDeckBorne("desktop") })
                                    }
                                }
                            }
                        }
                    }
                    OptionCard {
                        index: 2
                        danger: true
                        title: "Uninstall"
                        blurb: "Uninstalls the emulator, removes the installed game, and cleans up Steam of any tile art or dependencies."
                        onActivated: win.beginRun(installer.startUninstall)
                    }

                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: 8
                        spacing: 10
                        StoragePicker { }
                        GhostButton {
                            implicitWidth: 220
                            text: "Collect logs for troubleshooting"
                            onClicked: win.beginRun(installer.startCollect)
                        }
                    }
                }
            }

            // ========== PROGRESS (stage panel) ==========
            Item {
                id: progressView
                anchors.fill: parent
                opacity: win.showProgress ? 1 : 0
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: 220 } }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 40
                    anchors.rightMargin: 40
                    anchors.topMargin: 10
                    anchors.bottomMargin: 20
                    spacing: 14

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: 12
                        color: win.cPanel
                        border.width: 1
                        border.color: win.cBorder
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 22
                            spacing: 6
                            Text { text: win.headlineText; color: win.failed ? win.cBloodHi : win.cBone; font.pixelSize: 21; font.family: bbFont.font.family }
                            Rectangle { Layout.fillWidth: true; height: 1; color: win.cBorder; Layout.topMargin: 8; Layout.bottomMargin: 10 }

                            RowLayout {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                spacing: 20

                                // the checks (left)
                                ListView {
                                    id: stageList
                                    Layout.preferredWidth: 300
                                    Layout.fillHeight: true
                                    clip: true
                                    spacing: 14
                                    model: win.stagesModel
                                    interactive: false
                                    delegate: StageRow { width: stageList.width }
                                }

                                Rectangle { Layout.fillHeight: true; Layout.topMargin: 2; Layout.bottomMargin: 2
                                    implicitWidth: 1; color: win.cBorder; opacity: flavor.visible ? 0.7 : 0 }

                                // flavour area (right): rotating quotes during extract,
                                // otherwise the friendly per-stage message.
                                Item {
                                    id: flavor
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    visible: win.busy || win.runFinished
                                    property int qi: 0
                                    Component.onCompleted: qi = win.nextQuote()

                                    Timer {
                                        interval: 10000; repeat: true
                                        running: win.busy && win.quoting
                                        onTriggered: qfade.restart()
                                    }
                                    SequentialAnimation {
                                        id: qfade
                                        NumberAnimation { target: qcol; property: "opacity"; to: 0; duration: 450; easing.type: Easing.InOutQuad }
                                        ScriptAction { script: flavor.qi = win.nextQuote() }
                                        NumberAnimation { target: qcol; property: "opacity"; to: 1; duration: 650; easing.type: Easing.InOutQuad }
                                    }

                                    // rotating quote (extract stage)
                                    Column {
                                        id: qcol
                                        visible: win.quoting
                                        anchors.centerIn: parent
                                        width: parent.width - 20
                                        spacing: 12
                                        Text {
                                            width: parent.width
                                            text: "“" + win.quotes[flavor.qi].text + "”"
                                            color: win.cBone; font.pixelSize: 15; font.italic: true
                                            wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
                                            lineHeight: 1.3
                                        }
                                        Text {
                                            width: parent.width
                                            text: "— " + win.quotes[flavor.qi].who
                                            color: win.cGold; font.pixelSize: 12
                                            horizontalAlignment: Text.AlignHCenter
                                        }
                                    }

                                    // friendly per-stage message (fades on change)
                                    Text {
                                        id: msgText
                                        visible: !win.quoting
                                        anchors.centerIn: parent
                                        width: parent.width - 24
                                        text: win.statusText
                                        color: win.failed ? win.cBloodHi : win.cBone
                                        font.pixelSize: win.failed ? 14 : 16
                                        wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
                                        lineHeight: 1.35
                                        onTextChanged: msgFade.restart()
                                        SequentialAnimation { id: msgFade
                                            NumberAnimation { target: msgText; property: "opacity"; from: 0.25; to: 1; duration: 400 } }
                                    }
                                }
                            }
                        }
                    }

                    // progress bar (determinate or indeterminate)
                    Rectangle {
                        id: track
                        Layout.fillWidth: true
                        height: 6; radius: 3
                        color: Qt.rgba(1,1,1,0.08)
                        clip: true
                        Rectangle {                     // determinate fill
                            visible: !win.indeterminate
                            height: parent.height; radius: 3
                            width: parent.width * win.progress
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: win.cBlood }
                                GradientStop { position: 1.0; color: win.cGold }
                            }
                            Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                        }
                        Rectangle {                     // indeterminate sweeper
                            visible: win.indeterminate
                            height: parent.height; radius: 3
                            width: track.width * 0.32
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.0; color: win.cBlood }
                                GradientStop { position: 1.0; color: win.cGold }
                            }
                            SequentialAnimation on x {
                                running: win.indeterminate
                                loops: Animation.Infinite
                                NumberAnimation { from: -track.width * 0.32; to: track.width; duration: 1200; easing.type: Easing.InOutQuad }
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Text {
                                text: !win.busy ? ""
                                      : win.quoting ? "Working… Blood Ministration for Deck proceeding. Please be patient, good hunter."
                                      : "Working…"
                                color: win.cMuted; font.pixelSize: 13; Layout.fillWidth: true; elide: Text.ElideRight
                            }
                            // extraction-only readout: progress of JUST the ISO extraction
                            Text {
                                visible: win.busy && win.quoting
                                text: "Game Installing: " + Math.round(win.subProgress * 100) + "% / 100%"
                                color: win.cGold; font.pixelSize: 12
                            }
                            Text {
                                visible: win.busy && !win.quoting && win.subLabel !== ""
                                text: win.subLabel + ": " + Math.round(win.subProgress * 100) + "% / 100%"
                                color: win.cGold; font.pixelSize: 12
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                        }
                        Text {
                            visible: !win.indeterminate
                            text: Math.round(win.progress * 100) + "%"
                            color: win.cGold; font.pixelSize: 13; font.bold: true
                            Layout.alignment: Qt.AlignTop
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12
                        Item { Layout.fillWidth: true }
                        // one primary button: Cancel while running, then Completed / Back
                        // to menu when the run finishes — both return you to the menu.
                        GhostButton {
                            text: win.busy ? "Cancel" : (win.runOk ? "Completed" : "← Back to menu")
                            accent: win.busy ? win.cBloodHi : win.cGold
                            implicitWidth: 200
                            onClicked: {
                                if (win.busy) installer.cancel()
                                // Re-detect on the way back: the run may have just
                                // filled the device, and a card can be swapped while
                                // the window sits open.
                                else { installer.refreshStorage(); win.showProgress = false }
                            }
                        }
                    }
                }
            }
        }

        // Artist attribution — sits on `root`, not inside `content`, so it shows on
        // every view. Permanent: the background art is Snatti89's, credited in place.
        Text {
            id: artCredit
            anchors { left: parent.left; leftMargin: 26; bottom: parent.bottom; bottomMargin: 16 }
            z: 4
            text: win.artCreditName
            color: artCreditHover.hovered ? win.cGold : win.cMuted
            opacity: artCreditHover.hovered ? 1 : 0.75
            font.pixelSize: 14
            font.underline: artCreditHover.hovered
            Behavior on color { ColorAnimation { duration: 140 } }
            Behavior on opacity { NumberAnimation { duration: 140 } }
            HoverHandler { id: artCreditHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: Qt.openUrlExternally(win.artCreditUrl) }
        }
    }
}
