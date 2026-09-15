import SwiftUI
import AppKit

struct MainSplitViewRightPart: View {
    let selectedNoteId: NoteModel.ID?
    @ObservedObject var noteViewModel: NoteListViewModel
    let selectedFolderId: FolderModel.ID?
    let editorFocusRequest: UUID
    @ObservedObject var promptPopoverVM: PromptPopoverViewModel
    let showConfetti: Bool
    let onTogglePromptPopover: () -> Void
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        ZStack {
            if let selectedNoteId = selectedNoteId {
                NoteEditorView(
                    noteId: selectedNoteId,
                    viewModel: noteViewModel,
                    focusRequest: editorFocusRequest,
                    folderId: selectedFolderId,
                    promptPopoverVM: promptPopoverVM
                )
            } else {
                Text("No note selected")
                    .foregroundColor(themeManager.currentTheme.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showConfetti {
                ConfettiHostView()
                    .transition(.opacity)
                    .zIndex(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .background(themeManager.currentTheme.bgNoteEditor)
        .toolbar {
            ToolbarItem(id: "note_info", placement: .primaryAction) {
                Button {
                    onTogglePromptPopover()
                } label: {
                    Label("Note Info", systemImage: "info.circle")
                }
                .disabled(selectedNoteId == nil)
                .popover(isPresented: $promptPopoverVM.isPresented, arrowEdge: .bottom) {
                    PromptPopoverView(vm: promptPopoverVM)
                        .environmentObject(themeManager)
                }
            }
        }
    }
}

struct ConfettiView: View {
    struct Particle {
        let id = UUID()
        let color: Color
        let x0: CGFloat
        let y0: CGFloat
        let vx: CGFloat
        let vy: CGFloat
        let rot0: Double
        let rotSpeed: Double
        let size: CGFloat
        let shapeRect: CGRect
    }

    @State private var particles: [Particle] = []
    @State private var startDate: Date? = nil
    private let colors: [Color] = [.red, .pink, .orange, .yellow, .green, .blue, .purple]

    private func makeParticles(in size: CGSize, count: Int = 80) -> [Particle] {
        var out: [Particle] = []
        let centerX = size.width * 0.5
        let startY = size.height * 0.95
        for _ in 0..<count {
            let angle = Double.random(in: (-Double.pi / 2.0 - 0.6)...(-Double.pi / 2.0 + 0.6))
            let speed = CGFloat.random(in: 120...520)
            let vx = CGFloat(cos(angle)) * speed
            let vy = CGFloat(sin(angle)) * speed
            let sz = CGFloat.random(in: 6...18)
            let xJitter = CGFloat.random(in: -80...80)
            let color = colors.randomElement() ?? .blue
            let rot0 = Double.random(in: 0...360)
            let rotSpeed = Double.random(in: -360...360)
            let rect = CGRect(x: centerX + xJitter - sz/2, y: startY - sz/2, width: sz, height: sz * CGFloat.random(in: 0.7...1.6))
            out.append(Particle(color: color, x0: rect.midX, y0: rect.midY, vx: vx, vy: vy, rot0: rot0, rotSpeed: rotSpeed, size: sz, shapeRect: rect))
        }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                let now = timeline.date
                Canvas { context, size in
                    guard let sd = startDate else {
                        DispatchQueue.main.async {
                            if startDate == nil {
                                particles = makeParticles(in: size)
                                startDate = Date()
                            }
                        }
                        return
                    }
                    let dt = CGFloat(min(2.0, max(0.0, now.timeIntervalSince(sd))))
                    let gravity: CGFloat = 600

                    for p in particles {
                        let x = p.x0 + p.vx * dt
                        let y = p.y0 + p.vy * dt + 0.5 * gravity * dt * dt
                        let rot = p.rot0 + p.rotSpeed * Double(dt)

                        context.drawLayer { localContext in
                            localContext.translateBy(x: x, y: y)
                            localContext.rotate(by: .degrees(rot))
                            let rect = CGRect(x: -p.size/2, y: -p.size/2, width: p.size, height: p.size * 1.2)
                            let path = Path(roundedRect: rect, cornerRadius: p.size * 0.2)
                            let opacity = max(0.0, 1.0 - Double(dt / 2.0))
                            localContext.fill(path, with: .color(p.color.opacity(opacity)))
                            localContext.stroke(path, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
                        }
                    }
                }
                .allowsHitTesting(false)
                .compositingGroup()
            }
            .onAppear {
                if geo.size.width > 0 {
                    particles = makeParticles(in: geo.size)
                    startDate = Date()
                }
            }
            .onChange(of: geo.size) { oldSize, newSize in
                if newSize.width > 0 {
                    particles = makeParticles(in: newSize)
                    startDate = Date()
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct ConfettiHostView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSHostingView<ConfettiView> {
        let view = NSHostingView(rootView: ConfettiView())
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: NSHostingView<ConfettiView>, context: Context) {}
}
