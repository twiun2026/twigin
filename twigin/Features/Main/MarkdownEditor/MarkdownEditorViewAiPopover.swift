import AppKit
import SwiftUI

// MARK: - Notifications

extension Notification.Name {
    static let aiPopoverNewNote = Notification.Name("twigin.aiPopover.newNote")
}

// MARK: - AiPopoverViewModel

@Observable
@MainActor
final class AiPopoverViewModel {
    var title: String
    var content: String = ""
    var isStreaming: Bool = false
    var isCompleted: Bool = false

    init(title: String) { self.title = title }
}

// MARK: - AiPopoverView

struct AiPopoverView: View {
    @Bindable var model: AiPopoverViewModel
    var theme: AppTheme
    let onClose: () -> Void
    let onInsert: (String) -> Void
    let onReplace: (String) -> Void
    let onCopy: (String) -> Void
    let onNewNote: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            contentArea
            Divider()
            bottomToolbar
        }
        .frame(minWidth: 300, minHeight: 200)
        .background(Color(theme.bgNoteEditor))
        .foregroundStyle(Color(theme.textMain))
    }

    private var headerBar: some View {
        HStack(alignment: .center) {
            Text(model.title)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.medium)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var contentArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                contentBody
                    .id("bottom")
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 50)
            .onChange(of: model.content) {
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        if model.content.isEmpty {
            if model.isStreaming {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.75)
                    Text("Generating…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Color.clear.frame(height: 40)
            }
        } else {
            Text(model.content)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var bottomToolbar: some View {
            HStack(spacing: 8) {
                Button("Insert")   { onInsert(model.content) }
                Button("Replace")  { onReplace(model.content) }
                Button("Copy")     { onCopy(model.content) }
                Button("New Note") { onNewNote(model.content) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Color(theme.textMain))
            .disabled(!model.isCompleted)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

// MARK: - AiPopoverPanel

private final class AiPopoverPanel: NSPanel {
    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isOpaque = true
        backgroundColor = .windowBackgroundColor
        hasShadow = true
        animationBehavior = .utilityWindow
    }
}

// MARK: - AiPopoverController

@MainActor
final class AiPopoverController {
    private var panel: AiPopoverPanel?
    let model: AiPopoverViewModel

    private var streamingTask: Task<Void, Never>?
    private var escapeMonitor: Any?
    private var scrollObserver: NSObjectProtocol?

    weak var anchorTextView: MarkdownNativeTextView?
    // Character offset (into textStorage) of the first char of the anchor line.
    // Adjusted in real-time by Coordinator whenever text is edited before this point.
    var anchorCharOffset: Int = 0

    private var onInsert: ((String) -> Void)?
    private var onReplace: ((String) -> Void)?
    private var onNewNote: ((String) -> Void)?

    init(title: String) {
        model = AiPopoverViewModel(title: title)
    }

    // MARK: - Public

    func show(
        anchorCharOffset: Int,
        in textView: MarkdownNativeTextView,
        theme: AppTheme,
        onInsert: @escaping (String) -> Void,
        onReplace: @escaping (String) -> Void,
        onNewNote: @escaping (String) -> Void
    ) {
        self.anchorTextView = textView
        self.anchorCharOffset = anchorCharOffset
        self.onInsert = onInsert
        self.onReplace = onReplace
        self.onNewNote = onNewNote

        let panel = AiPopoverPanel()
        panel.backgroundColor = NSColor(theme.bgNoteEditor)
        self.panel = panel

        let view = AiPopoverView(
            model: model,
            theme: theme,
            onClose:   { [weak self] in self?.dismiss() },
            onInsert:  { [weak self] t in
                self?.onInsert?(t)
                self?.dismiss()
            },
            onReplace: { [weak self] t in
                self?.onReplace?(t)
                self?.dismiss()
            },
            onCopy: { [weak self] t in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t, forType: .string)
                self?.dismiss()
            },
            onNewNote: { [weak self] t in
                self?.onNewNote?(t)
                self?.dismiss()
            }
        )
        panel.contentViewController = NSHostingController(rootView: view)

        updatePanelPosition()

        if let parentWindow = textView.window {
            parentWindow.addChildWindow(panel, ordered: .above)
        } else {
            panel.orderFront(nil)
        }

        startScrollObserver(for: textView)
        startEscapeMonitor()
    }

    func startStreaming(service: AIService, request: AIRequest) {
        model.isStreaming = true
        model.isCompleted = false
        
        streamingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            
            // 使用 defer 确保 Task 无论是正常结束、抛异常还是取消，都会结束 streaming 状态
            defer {
                self.model.content = self.model.content.replacingOccurrences(
                    of: #"(?<!\*)\*(?!\*)([^\*\n]+)\*(?!\*)"#,
                    with: "_$1_",
                    options: .regularExpression
                )
                self.model.isStreaming = false
                self.model.isCompleted = true // 【关键】保证流结束后按钮必定解除禁用！
            }
            
            let stream = await service.execute(request: request)
            do {
                for try await event in stream {
                    guard !Task.isCancelled else { break }
                    switch event {
                    case .chunk(let text):
                        self.model.content += text
                    case .completed:
                        break // 统一由 defer 处理
                    case .cancelled:
                        break
                    case .failed(let error):
                        self.model.content += "\n\n[Error: \(error.localizedDescription)]"
                    default:
                        break
                    }
                }
            } catch {
                self.model.content += "\n\n[Error: \(error.localizedDescription)]"
            }
        }
    }

    /// Called by Coordinator's textStorage delegate on every character edit.
    /// Keeps the anchor position accurate when text is inserted/deleted above the panel.
    func adjustAnchor(editedRange: NSRange, delta: Int) {
        if editedRange.location < anchorCharOffset {
            anchorCharOffset = max(0, anchorCharOffset + delta)
        }
        updatePanelPosition()
    }

    func updatePanelPosition() {
        guard let textView = anchorTextView,
              let panel,
              let screenPt = lineBottomScreenPoint(forCharOffset: anchorCharOffset, in: textView)
        else { return }

        let panelHeight = panel.frame.height
        // Place panel top 6pt below the anchor line's bottom edge.
        // Screen Y increases upward, so "below" = smaller Y.
        let origin = NSPoint(x: screenPt.x, y: screenPt.y - panelHeight - 6)
        panel.setFrameOrigin(origin)
    }

    func dismiss() {
        streamingTask?.cancel()
        streamingTask = nil
        stopEscapeMonitor()
        stopScrollObserver()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.close()
        }
        self.panel = nil
        anchorTextView = nil
    }

    // MARK: - Private helpers

    private func startScrollObserver(for textView: NSTextView) {
        guard let clipView = textView.enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updatePanelPosition()
            }
        }
    }

    private func stopScrollObserver() {
        if let observer = scrollObserver {
            NotificationCenter.default.removeObserver(observer)
            scrollObserver = nil
        }
    }

    private func startEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // 53 = Esc
            self?.dismiss()
            return nil // consume the event
        }
    }

    private func stopEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    /// Returns the screen-space point at the bottom-left of the line fragment containing `charOffset`.
    /// NSTextView is flipped (Y=0 at top), so fragment.layoutFragmentFrame.maxY is the visual bottom.
    private func lineBottomScreenPoint(forCharOffset offset: Int, in textView: NSTextView) -> NSPoint? {
        guard let layoutManager = textView.textLayoutManager,
              let contentManager = layoutManager.textContentManager
        else { return nil }

        let docRange = contentManager.documentRange
        guard let location = contentManager.location(docRange.location, offsetBy: offset) else { return nil }

        var fragmentFrame: CGRect? = nil
        layoutManager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
            fragmentFrame = fragment.layoutFragmentFrame
            return false // stop after first fragment
        }

        guard let frame = fragmentFrame else { return nil }

        // Translate: text-container coords → view coords → window coords → screen coords.
        let containerOrigin = textView.textContainerOrigin
        let viewPt = NSPoint(
            x: frame.minX + containerOrigin.x,
            y: frame.maxY + containerOrigin.y  // maxY = bottom of line in flipped view space
        )
        let windowPt = textView.convert(viewPt, to: nil)
        guard let window = textView.window else { return nil }
        return window.convertToScreen(NSRect(origin: windowPt, size: .zero)).origin
    }
}
