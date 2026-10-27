import AppKit
import CoreGraphics

/// Where the scrolling-capture viewfinder goes.
///
/// The pod's **frame** is a pure function of the selection: it is decided once
/// and never depends on how long the stitch becomes. Inside that frame the
/// *card* starts short — the first screen of the page, sharp — and grows
/// upward as rows arrive, until it is exactly as tall as the selection. From
/// then on it is frozen and only the picture inside moves.
///
/// The card is about a third of the selection's width and as tall as the
/// selection at most, bottom-aligned with it and fully outside it. Growing
/// upward from a fixed bottom edge is what makes the viewfinder read as the
/// selected region being filled in, instead of a fixed window with an empty
/// well at the start.
struct ScrollPreviewPlacement: Equatable {
    /// Total view frame. Equal to `card`: the card grows inside this frame, so
    /// the window itself never has to move or resize.
    var frame: CGRect
    /// The final card (the height it freezes at).
    var card: CGRect
    /// The card's size, so the pod lays out its well and footer with the same
    /// numbers the placement used.
    var cardSize: CGSize
    /// True when the pod hangs off the selection's left side.
    var onLeft: Bool
    /// True when neither side had room and the card had to be clamped.
    var clampedX: Bool
    /// True when the pod could not be placed clear of the selection. The
    /// captured region is never covered in normal use; this is the last resort
    /// for a selection that spans the whole screen.
    var overlapsRegion: Bool

    static func make(
        region: CGRect,
        screen: CGRect
    ) -> ScrollPreviewPlacement {
        let inset = ScrollPreviewPod.screenInset
        let gap = ScrollPreviewPod.gap
        let availableHeight = max(1, screen.height - inset * 2)

        let cardWidth = ScrollPreviewPod.cardWidth(forSelectionWidth: region.width)
        // The card freezes at the selection's height. Only a selection taller
        // than the usable screen shortens it; the stitched length never takes
        // part in this calculation.
        let cardHeight = min(
            max(region.height, ScrollPreviewPod.minimumCardHeight),
            max(ScrollPreviewPod.minimumCardHeight, availableHeight)
        )
        let cardSize = CGSize(width: cardWidth, height: cardHeight)

        let minX = screen.minX + inset
        let maxX = max(minX, screen.maxX - inset - cardWidth)

        // Preferred side: the one with the most room, exactly like a caption
        // card next to a cropped photo.
        var onLeft = region.midX >= screen.midX
        func sideX(_ left: Bool) -> CGFloat {
            left ? region.minX - gap - cardWidth : region.maxX + gap
        }
        func fits(_ x: CGFloat) -> Bool {
            x >= minX && x <= maxX
        }

        var clampedX = false
        var x = sideX(onLeft)
        if !fits(x) {
            onLeft.toggle()
            let alternate = sideX(onLeft)
            if fits(alternate) {
                x = alternate
            } else {
                onLeft.toggle()
                x = min(max(sideX(onLeft), minX), maxX)
                clampedX = true
            }
        }

        // Bottom-align the card with the selection. The card grows upward from
        // this edge, so the bottom edge is the one that must stay put.
        let y = min(
            max(region.minY, screen.minY + inset),
            max(screen.minY + inset, screen.maxY - inset - cardHeight)
        )

        var placement = ScrollPreviewPlacement(
            frame: CGRect(x: x, y: y, width: cardSize.width, height: cardSize.height),
            card: CGRect(origin: CGPoint(x: x, y: y), size: cardSize),
            cardSize: cardSize,
            onLeft: onLeft,
            clampedX: clampedX,
            overlapsRegion: false
        )

        // Clear of the selection beats any fixed preference.
        if placement.card.intersects(region.insetBy(dx: -gap + 1, dy: 0)) {
            let above = region.maxY + gap
            let aboveRoom = screen.maxY - inset - above
            if aboveRoom >= cardHeight {
                placement.card.origin.y = above
                placement.frame.origin.y = above
            } else {
                let below = region.minY - gap - cardHeight
                if below >= screen.minY + inset {
                    placement.card.origin.y = below
                    placement.frame.origin.y = below
                }
            }
        }
        placement.overlapsRegion = placement.card.intersects(region)
        return placement
    }
}

/// A small capsule button in the pod's footer. AppKit's default button chrome
/// is far too heavy on the dark viewfinder; this reuses the toolbar's ink
/// ladder instead of inventing a second button language.
final class ScrollPodButton: NSButton {
    var restingFill: Double = ToolbarInk.capsuleRestingFill
    var hoverFill: Double = ToolbarInk.hoverFill
    var strokeAlpha: Double = ToolbarInk.capsuleRestingStroke
    var isAccent = false {
        didSet { needsDisplay = true }
    }

    private var hovering = false
    private var trackingAreaReference: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .inline
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        font = .systemFont(ofSize: 11, weight: .medium)
        alignment = .center
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    /// The viewfinder lives in a non-activating panel; a click there must act
    /// immediately even when another app owns the keyboard.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        if isAccent {
            NSColor.controlAccentColor.withAlphaComponent(hovering ? 0.92 : 0.82).setFill()
        } else {
            let fill = hovering ? hoverFill : restingFill
            NSColor.white.withAlphaComponent(fill).setFill()
        }
        path.fill()
        NSColor.white.withAlphaComponent(isAccent ? 0.30 : (hovering ? 0.22 : strokeAlpha))
            .setStroke()
        path.lineWidth = 1
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(hovering ? 1 : 0.92)
        ]
        let text = attributedTitle.length > 0 ? attributedTitle.string : title
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = CGPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2
        )
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}

/// The viewfinder for a live scrolling capture.
///
/// The frame is constant; the card inside grows. It starts at the smallest
/// useful height and gets taller with every screen of new rows until it equals
/// the selection's height — the height the placement froze — and then stops.
/// The image is always sharp and always bottom-aligned: the newest rows sit on
/// the well's bottom edge, so the page reads as being pulled up through the
/// viewfinder.
@MainActor
final class ScrollPreviewPod: NSView {
    enum Phase: Equatable {
        /// No rows yet. Shows the "start scrolling" hint.
        case empty
        /// Rows are arriving.
        case capturing
        /// Session stopped; the image is final and the footer offers 完成.
        case finished
    }

    // MARK: - Geometry

    /// The width the card aims for, as a share of the selection's width. The
    /// band keeps the card from becoming a hairline on a narrow selection or a
    /// billboard on a wide one. It is always kept narrower than the selection.
    nonisolated static let cardWidthShare: CGFloat = 0.30
    nonisolated static let cardWidthRange: ClosedRange<CGFloat> = 176...220
    /// Smallest card the footer can still hold two labelled buttons in.
    nonisolated static let minimumCardWidth: CGFloat = 120
    /// Tallest the footer + a usable well can survive; only degenerate
    /// selections shorter than this break exact equality.
    nonisolated static let minimumCardHeight: CGFloat = 132
    /// Shortest well the growing card shows once it has content. It keeps the
    /// first frame from collapsing into the footer.
    nonisolated static let minimumWellHeight: CGFloat = 56
    /// The footer's own height plus its padding, i.e. everything in the card
    /// that is not the well.
    nonisolated static var chromeHeight: CGFloat { padding + footerHeight + footerGap }
    /// Starting geometry for a pod that has not been configured from a
    /// placement yet (the external panel is created before its first selection).
    nonisolated static let initialCardSize = CGSize(width: 200, height: 260)

    nonisolated static let gap: CGFloat = 12
    nonisolated static let screenInset: CGFloat = 16
    /// The card is a plain rectangle. The user asked for the rounded look to be
    /// carried by the *selection* (see `DimmingView`), not by this card.
    nonisolated static let cardCornerRadius: CGFloat = 0
    nonisolated static let wellCornerRadius: CGFloat = 0
    nonisolated static let padding: CGFloat = 8
    nonisolated static let footerHeight: CGFloat = 30
    nonisolated static let footerGap: CGFloat = 6

    /// Card width for one selection: a third of its width, clamped to the
    /// legible band and never as wide as the selection itself.
    nonisolated static func cardWidth(forSelectionWidth width: CGFloat) -> CGFloat {
        let preferred = min(
            max(width * cardWidthShare, cardWidthRange.lowerBound),
            cardWidthRange.upperBound
        )
        let ceiling = max(minimumCardWidth, width - 12)
        return min(preferred, ceiling)
    }

    /// The image well plus the spill strip, in points, for one card size.
    /// This is the size the session composes its preview band at.
    nonisolated static func bandSize(forCardSize size: CGSize) -> CGSize {
        let cardWidth = max(minimumCardWidth, size.width)
        let cardHeight = max(minimumCardHeight, size.height)
        let chrome = padding + footerHeight + footerGap
        return CGSize(
            width: max(1, (cardWidth - padding * 2).rounded(.up)),
            height: max(1, (cardHeight - chrome).rounded(.up))
        )
    }

    /// The card's **box** for the current selection, set by
    /// `ScrollPreviewPlacement`. It is constant for the whole capture session;
    /// the card drawn inside it grows to this size and, once the page is longer
    /// than the box, shrinks inside it (see `scale`).
    private(set) var cardSize = ScrollPreviewPod.initialCardSize
    /// Height the card currently draws at. Starts short (the first screen of
    /// the page) and grows upward until it equals `cardSize.height`. After that
    /// the whole card shrinks, anchored on the corner nearest the selection, so
    /// the viewfinder keeps its proportions instead of growing past the screen.
    private(set) var visibleCardHeight = ScrollPreviewPod.minimumCardHeight
    /// How much of the box the card currently occupies. 1 while the page fits
    /// the box; below 1 once the stitch is longer than the selection.
    private(set) var scale: CGFloat = 1
    /// True once the stitch is at least as tall as the box. From that point on
    /// the card never grows again — it only scales down.
    private(set) var isFrozen = false
    /// Which side of the card faces the selection. The card is anchored on that
    /// edge (and on its bottom edge), so shrinking never moves the gap.
    private(set) var innerEdgeOnRight = false
    /// Called when the drawn size changes, so the session can compose its band
    /// at exactly the size the card draws.
    var onDrawnSizeChange: ((CGSize) -> Void)?

    /// Adopt the geometry of a placement. Called when the selection is
    /// committed and again only if the user resizes the box.
    func configure(cardSize: CGSize, innerEdgeOnRight: Bool? = nil) {
        if let innerEdgeOnRight, innerEdgeOnRight != self.innerEdgeOnRight {
            self.innerEdgeOnRight = innerEdgeOnRight
            layoutButtons()
            needsDisplay = true
        }
        let size = CGSize(
            width: max(Self.minimumCardWidth, cardSize.width),
            height: max(Self.minimumCardHeight, cardSize.height)
        )
        guard size != self.cardSize else { return }
        self.cardSize = size
        visibleCardHeight = min(max(visibleCardHeight, Self.minimumCardHeight), size.height)
        updateGeometry()
        layoutButtons()
        needsDisplay = true
        notifyDrawnSizeIfChanged()
    }

    /// The card as currently drawn, in this view's coordinates (origin
    /// bottom-left). Its bottom edge is fixed and, when it is narrower than the
    /// box, its edge facing the selection stays put.
    var cardRect: CGRect {
        CGRect(
            x: innerEdgeOnRight ? cardSize.width - drawnCardSize.width : 0,
            y: 0,
            width: drawnCardSize.width,
            height: visibleCardHeight
        )
    }

    /// The size the card draws at right now.
    var drawnCardSize: CGSize {
        CGSize(width: drawnCardWidth, height: visibleCardHeight)
    }

    /// The size the **preview band** is composed at.
    ///
    /// While the card grows, that is the box: the well is content-tall but the
    /// band is composed once at the box's size, so the pixel work does not
    /// change on every frame. Once the card has scaled down, the band follows
    /// the smaller card, because that is the size it is drawn at.
    var bandCardSize: CGSize {
        scale < 1 ? drawnCardSize : cardSize
    }

    private var drawnCardWidth: CGFloat {
        min(
            cardSize.width,
            max(Self.minimumCardWidth, (cardSize.width * scale).rounded())
        )
    }

    /// The clipped image well as currently drawn.
    var wellRect: CGRect {
        let card = cardRect
        return CGRect(
            x: card.minX + Self.padding,
            y: Self.chromeHeight,
            width: card.width - Self.padding * 2,
            height: max(1, visibleCardHeight - Self.chromeHeight)
        )
    }

    /// The well at the box's **full** size. Used to normalise the stitched
    /// length, so the shrink maths do not depend on the band's own width.
    var fullWellRect: CGRect {
        CGRect(
            x: Self.padding,
            y: Self.chromeHeight,
            width: cardSize.width - Self.padding * 2,
            height: max(1, cardSize.height - Self.chromeHeight)
        )
    }

    // MARK: - State

    /// The composed bottom band of the stitch, already at display size.
    private(set) var preview: ScrollPreviewFrame?
    private(set) var phase: Phase = .empty
    private(set) var isAutoScrolling = false
    /// Whether the finished session can be picked up again. Set by the caller
    /// together with the finished phase: a session that hit a frame/height
    /// ceiling has no room left, so 继续 would be a dead button.
    var isResumable = false {
        didSet { layoutButtons() }
    }

    var onToggleAutoScroll: (() -> Void)?
    var onStop: (() -> Void)?
    /// The finished result was confirmed: copy it and close, exactly like the
    /// Return key on a region shot.
    var onConfirm: (() -> Void)?
    /// The user wants to keep scrolling the page after the result was final.
    var onResume: (() -> Void)?

    private let autoButton = ScrollPodButton(title: "", target: nil, action: nil)
    private let stopButton = ScrollPodButton(title: "", target: nil, action: nil)
    private let closeButton = ScrollPodButton(title: "", target: nil, action: nil)
    private let resumeButton = ScrollPodButton(title: "", target: nil, action: nil)
    private var trackingAreaReference: NSTrackingArea?

    // MARK: - Init

    init() {
        super.init(frame: CGRect(origin: .zero, size: Self.initialCardSize))
        wantsLayer = true
        layer?.masksToBounds = false
        alphaValue = 1
        isHidden = true

        for button in [autoButton, stopButton, closeButton, resumeButton] {
            button.target = self
            addSubview(button)
        }
        autoButton.action = #selector(autoTapped)
        stopButton.action = #selector(stopTapped)
        closeButton.action = #selector(closeTapped)
        resumeButton.action = #selector(resumeTapped)
        closeButton.isAccent = true
        closeButton.isHidden = true
        resumeButton.isHidden = true
        // The finished card says what it is and what it can do, in the two
        // places a Mac user looks: the buttons themselves and their tooltips.
        resumeButton.toolTip = "已结束。点这里接着滚动，长图会继续变长"
        closeButton.toolTip = "已结束。完成并交付长截图（等同 Return）"
        layoutButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Accept clicks on the card and on the spill strip, so a click near the
    /// viewfinder never starts a new selection behind it. The footer buttons
    /// are real subviews and keep their own hits.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only the card is a surface. The area above it is transparent while it
        // grows, and a click there must reach whatever is behind the window.
        guard !isHidden, alphaValue > 0.01, cardRect.contains(point) else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: cardRect,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    // MARK: - Updates

    func update(preview: ScrollPreviewFrame?, phase: Phase, autoScrolling: Bool) {
        self.preview = preview
        self.phase = phase
        self.isAutoScrolling = autoScrolling
        updateGeometry()
        layoutButtons()
        needsDisplay = true
        notifyDrawnSizeIfChanged()
    }

    func reset() {
        preview = nil
        phase = .empty
        isAutoScrolling = false
        isResumable = false
        scale = 1
        isFrozen = false
        visibleCardHeight = min(Self.minimumCardHeight, cardSize.height)
        layoutButtons()
        needsDisplay = true
        notifyDrawnSizeIfChanged()
    }

    private var lastNotifiedDrawnSize: CGSize = .zero

    private func notifyDrawnSizeIfChanged() {
        let size = bandCardSize
        guard size != lastNotifiedDrawnSize else { return }
        lastNotifiedDrawnSize = size
        onDrawnSizeChange?(size)
    }

    /// Where the card sits between "first screen" and "one selection high".
    ///
    /// Up to the selection's height the card grows upward. Past that the user
    /// explicitly does not want the viewfinder to keep growing: it **scales the
    /// whole card down** instead, anchored on the corner nearest the selection,
    /// so the gap to the selection never changes and the card never turns into a
    /// hairline (`scaleFloor`). The scaling follows the stitched length with a
    /// square root, which reads as "the page is getting longer" without
    /// collapsing the card on the second screen.
    private func updateGeometry() {
        let fullWellWidth = max(1, cardSize.width - Self.padding * 2)
        let fullWellHeight = max(1, cardSize.height - Self.chromeHeight)

        guard let preview, preview.image.width > 0, cardSize.height > 0 else {
            scale = 1
            isFrozen = false
            visibleCardHeight = min(Self.minimumCardHeight, cardSize.height)
            return
        }

        // The band is composed at the *current* card size, so the stitched
        // length has to be normalised to the box's width before it can mean
        // anything.
        let contentAtFullWidth = preview.contentHeight
            * fullWellWidth
            / CGFloat(preview.image.width)
        // "Frozen" means the page is at least as tall as the box: the card will
        // never grow again, it can only scale down from here.
        isFrozen = contentAtFullWidth >= fullWellHeight - 0.5

        if contentAtFullWidth <= fullWellHeight + 0.5 {
            // Growing phase: exactly as before, the card is content + chrome.
            scale = 1
            let well = min(
                max(contentAtFullWidth, Self.minimumWellHeight),
                fullWellHeight
            )
            visibleCardHeight = min(
                cardSize.height,
                max(Self.minimumCardHeight, Self.chromeHeight + well)
            )
            return
        }

        // Scaling phase. The floor keeps the footer's two labelled buttons
        // legible and the card off the hairline.
        let ratio = contentAtFullWidth / fullWellHeight
        let floor = max(
            Self.minimumCardWidth / cardSize.width,
            (Self.chromeHeight + Self.minimumWellHeight) / cardSize.height
        )
        let raw = max(floor, 1 / ratio.squareRoot())
        // Quantise so the band is recomposed a handful of times per run, not on
        // every single frame.
        let quantised = min(1, (raw * 40).rounded() / 40)
        scale = quantised
        visibleCardHeight = min(
            cardSize.height,
            max(
                (cardSize.height * quantised).rounded(),
                Self.chromeHeight + Self.minimumWellHeight
            )
        )
    }

    // MARK: - Buttons

    private func layoutButtons() {
        let width = cardRect.width - Self.padding * 2
        let y = Self.padding
        let height = Self.footerHeight
        let closeWide = width
        closeButton.frame = CGRect(x: Self.padding, y: y, width: closeWide, height: height)
        let half = (width - 6) / 2
        autoButton.frame = CGRect(x: Self.padding, y: y, width: half, height: height)
        stopButton.frame = CGRect(x: Self.padding + half + 6, y: y, width: half, height: height)
        resumeButton.frame = CGRect(x: Self.padding, y: y, width: half, height: height)
        let resumeHalf = CGRect(
            x: Self.padding + half + 6,
            y: y,
            width: half,
            height: height
        )
        closeButton.frame = resumeHalf

        switch phase {
        case .empty, .capturing:
            autoButton.isHidden = false
            stopButton.isHidden = false
            closeButton.isHidden = true
            resumeButton.isHidden = true
            autoButton.title = isAutoScrolling ? "停止滚动" : "自动滚动"
            autoButton.isAccent = isAutoScrolling
            stopButton.title = "停止"
            stopButton.isAccent = false
        case .finished:
            autoButton.isHidden = true
            stopButton.isHidden = true
            // The finished card is not a dead end. 继续 restarts sampling on the
            // same stitch, so a page with more below costs one click instead of
            // a fresh selection — and a wheel over the finished overlay resumes
            // too (see `CaptureOverlayView.scrollWheel`). A session that ran out
            // of frames or height has nothing left to append, so it keeps the
            // single 完成 button.
            resumeButton.isHidden = !isResumable
            resumeButton.title = "继续"
            resumeButton.isAccent = false
            closeButton.isHidden = false
            closeButton.title = "完成"
            closeButton.isAccent = true
            closeButton.frame = isResumable ? resumeHalf : CGRect(
                x: Self.padding,
                y: y,
                width: closeWide,
                height: height
            )
            // The finished footer is the recovery entry; log where it landed so
            // a run can click it instead of guessing the geometry.
            DebugLog.log(
                "scroll: finished footer card=\(NSStringFromRect(cardRect)) "
                    + "resume=\(isResumable ? NSStringFromRect(resumeButton.frame) : "-") "
                    + "close=\(NSStringFromRect(closeButton.frame))"
            )
        }
    }

    override func layout() {
        super.layout()
        layoutButtons()
    }

    @objc private func autoTapped() {
        DebugLog.log("scroll: pod auto button tapped")
        onToggleAutoScroll?()
    }

    @objc private func stopTapped() {
        DebugLog.log("scroll: pod stop button tapped")
        onStop?()
    }

    @objc private func closeTapped() {
        DebugLog.log("scroll: pod 完成 tapped")
        onConfirm?()
    }

    @objc private func resumeTapped() {
        DebugLog.log("scroll: pod resume button tapped")
        onResume?()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let started = Date()
        defer {
            ScrollPerf.log(String(
                format: "pod draw %.2f ms band=%dx%d content=%.1f well=%.0fx%.0f",
                Date().timeIntervalSince(started) * 1000,
                preview?.image.width ?? 0,
                preview?.image.height ?? 0,
                contentHeight,
                wellRect.width,
                wellRect.height
            ))
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let card = cardRect
        let well = wellRect

        drawCardGround(context, card: card)

        if let preview {
            drawImageInsideWell(preview, context: context)
        } else if phase != .finished {
            drawEmptyState(in: well)
        }

        drawCardChrome(context, card: card)
        drawViewfinderBrackets(context, well: well)
        drawFooterDivider(context, well: well)
    }

    /// The card's one and only ground: **glass**, not a black well.
    ///
    /// Three translucent layers, in the app's existing language:
    /// 1. the `液态玻璃` plate tint (`GlassSurfaceFactory.liquidGlassTint`) —
    ///    the same number the toolbar's plate wears, so the two surfaces read
    ///    as one material and the lighter/darker appearance is the system's
    ///    call;
    /// 2. a soft vertical shade so white footer labels stay legible over a
    ///    bright page;
    /// 3. a top-down sheen, which is what makes it look like a pane instead of
    ///    a flat rectangle.
    ///
    /// Everything *above* the last captured row is left empty: the glass shows
    /// through instead of being filled with a mirror or a blur.
    private func drawCardGround(_ context: CGContext, card: CGRect) {
        context.saveGState()
        context.addPath(CGPath(rect: card, transform: nil))
        context.clip()

        GlassSurfaceFactory.liquidGlassTint().setFill()
        card.fill()

        let colors = [
            NSColor.black.withAlphaComponent(0.30).cgColor,
            NSColor.black.withAlphaComponent(0.18).cgColor
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: card.midX, y: card.maxY),
                end: CGPoint(x: card.midX, y: card.minY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        // The sheen: a short, bright falloff from the top edge. This is the one
        // layer that says "glass" in both appearances.
        let sheen = [
            NSColor.white.withAlphaComponent(0.085).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: sheen,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: card.midX, y: card.maxY),
                end: CGPoint(x: card.midX, y: card.maxY - min(card.height, 120)),
                options: []
            )
        }
        context.restoreGState()
    }

    /// Height of the whole stitched page, in this view's points.
    var contentHeight: CGFloat {
        guard let preview else { return 0 }
        return preview.contentHeight * displayScale
    }

    /// How many view points one band pixel occupies. Measured on the well as it
    /// is drawn right now, because the session composes its band at exactly
    /// that size.
    var displayScale: CGFloat {
        guard let preview, preview.image.width > 0 else { return 1 }
        return wellRect.width / CGFloat(preview.image.width)
    }

    /// Titles of the buttons currently offered, for the self test.
    var visibleButtonTitlesForTesting: [String] {
        [autoButton, stopButton, resumeButton, closeButton]
            .filter { !$0.isHidden }
            .map(\.title)
    }

    private func drawImageInsideWell(_ preview: ScrollPreviewFrame, context: CGContext) {
        let well = wellRect
        let scale = displayScale
        let bandPoints = CGFloat(preview.image.height) * scale
        let band = CGRect(
            x: well.minX,
            y: well.minY,
            width: well.width,
            height: bandPoints
        )

        context.saveGState()
        context.addPath(CGPath(rect: well, transform: nil))
        context.clip()
        NSImage(cgImage: preview.image, size: preview.size).draw(
            in: band,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        context.restoreGState()
    }

    /// The border, still an independent **square** layer on top of the picture
    /// (the user's "边框/描边保持独立于图片的一层框的观感"), with the
    /// selection language's dark halo plus a wide faint glow so the card reads
    /// as a lit object on the veiled desktop.
    private func drawCardChrome(_ context: CGContext, card: CGRect) {
        let path = NSBezierPath(rect: card.insetBy(dx: 0.75, dy: 0.75))

        for (outset, alpha, width) in [
            (CGFloat(2.5), 0.10, CGFloat(5)),
            (CGFloat(5.0), 0.06, CGFloat(7)),
            (CGFloat(8.5), 0.03, CGFloat(10))
        ] {
            NSColor.white.withAlphaComponent(alpha).setStroke()
            let glow = NSBezierPath(rect: card.insetBy(dx: -outset, dy: -outset))
            glow.lineWidth = width
            glow.stroke()
        }

        NSColor.black.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 4
        path.stroke()

        NSColor.white.withAlphaComponent(0.92).setStroke()
        path.lineWidth = 1.5
        path.stroke()

        // A one-point inner highlight along the top edge: the glass line that
        // separates the plate from whatever it is floating over.
        NSColor.white.withAlphaComponent(0.16).setFill()
        CGRect(x: card.minX + 1, y: card.maxY - 1.5, width: card.width - 2, height: 1).fill()
    }

    private func drawViewfinderBrackets(_ context: CGContext, well: CGRect) {
        let inset: CGFloat = 9
        let length: CGFloat = 13
        let radius: CGFloat = 2
        NSColor.white.withAlphaComponent(0.52).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: well.minX + inset, y: well.minY + inset), 1, 1),
            (CGPoint(x: well.maxX - inset, y: well.minY + inset), -1, 1),
            (CGPoint(x: well.minX + inset, y: well.maxY - inset), 1, -1),
            (CGPoint(x: well.maxX - inset, y: well.maxY - inset), -1, -1)
        ]
        for (point, dx, dy) in corners {
            path.move(to: CGPoint(x: point.x + dx * length, y: point.y))
            path.line(to: CGPoint(x: point.x + dx * radius, y: point.y))
            path.line(to: CGPoint(x: point.x, y: point.y + dy * radius))
            path.line(to: CGPoint(x: point.x, y: point.y + dy * length))
        }
        path.stroke()
    }

    private func drawFooterDivider(_ context: CGContext, well: CGRect) {
        let y = well.minY - Self.footerGap / 2
        NSColor.white.withAlphaComponent(0.10).setFill()
        CGRect(x: Self.padding, y: y, width: cardRect.width - Self.padding * 2, height: 1).fill()
    }

    private func drawEmptyState(in well: CGRect) {
        // A quiet vertical double arrow: no bitmap chrome, no second palette.
        let centre = CGPoint(x: well.midX, y: well.midY + 4)
        let ink = NSColor.white.withAlphaComponent(0.50)
        ink.setStroke()
        let arrow = NSBezierPath()
        arrow.lineWidth = 1.4
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.move(to: CGPoint(x: centre.x, y: centre.y - 9))
        arrow.line(to: CGPoint(x: centre.x, y: centre.y + 9))
        arrow.move(to: CGPoint(x: centre.x - 5, y: centre.y + 4))
        arrow.line(to: CGPoint(x: centre.x, y: centre.y + 9))
        arrow.line(to: CGPoint(x: centre.x + 5, y: centre.y + 4))
        arrow.move(to: CGPoint(x: centre.x - 5, y: centre.y - 4))
        arrow.line(to: CGPoint(x: centre.x, y: centre.y - 9))
        arrow.line(to: CGPoint(x: centre.x + 5, y: centre.y - 4))
        arrow.stroke()
        let text = "滚动页面即开始拼接"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.52)
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: CGPoint(x: well.midX - size.width / 2, y: well.midY - 30),
            withAttributes: attributes
        )
    }
}

/// The viewfinder as its own window.
///
/// It is deliberately **not** a subview of the capture overlay: while Auto
/// Scroll runs (and while the user scrolls by hand), the overlay has to be
/// mouse-transparent for the wheel to reach the page. A separate
/// non-activating panel keeps the viewfinder's buttons clickable in exactly
/// those moments, and it is an own window of this process, so the capture's
/// `excludingOwnWindows` filter already keeps it out of the stitched image.
@MainActor
final class ScrollPreviewPanelController {
    private(set) var panel: NSPanel
    let pod: ScrollPreviewPod

    var onToggleAutoScroll: (() -> Void)?
    var onStop: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onResume: (() -> Void)?

    init() {
        let size = ScrollPreviewPod.initialCardSize
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(
            rawValue: NSWindow.Level.screenSaver.rawValue + 1
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle
        ]
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false

        pod = ScrollPreviewPod()
        pod.frame = CGRect(origin: .zero, size: size)
        pod.isHidden = false
        pod.onToggleAutoScroll = { [weak self] in self?.onToggleAutoScroll?() }
        pod.onStop = { [weak self] in self?.onStop?() }
        pod.onConfirm = { [weak self] in self?.onConfirm?() }
        pod.onResume = { [weak self] in self?.onResume?() }
        panel.contentView = pod
    }

    /// Show the panel at an already-computed global placement. The pod adopts
    /// the placement's card geometry first, so the well and footer are laid out
    /// for the new height before the window commits its frame.
    func present(placement: ScrollPreviewPlacement) {
        pod.configure(cardSize: placement.cardSize)
        if panel.frame != placement.frame {
            panel.setFrame(placement.frame, display: false)
        }
        if pod.frame.size != placement.frame.size {
            pod.frame = CGRect(origin: .zero, size: placement.frame.size)
        }
        panel.orderFrontRegardless()
        // Stay above the capture panel even after the overlay re-orders itself.
        panel.order(.above, relativeTo: 0)
    }

    func setPlacement(_ placement: ScrollPreviewPlacement) {
        pod.configure(cardSize: placement.cardSize)
        guard panel.frame != placement.frame else { return }
        panel.setFrame(placement.frame, display: true)
    }

    func update(preview: ScrollPreviewFrame?, phase: ScrollPreviewPod.Phase, autoScrolling: Bool) {
        pod.update(preview: preview, phase: phase, autoScrolling: autoScrolling)
    }

    func close() {
        panel.orderOut(nil)
        panel.contentView = nil
    }
}
