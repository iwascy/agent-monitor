import SwiftUI
import AgentMonitorCore

struct SessionList: View {
    @ObservedObject var viewModel: MonitorViewModel
    @LocalState private var isIdleHovered = false
    @LocalState private var contentHeight: CGFloat = 0
    @LocalState private var buttonHeight: CGFloat = 46
    @LocalState private var scrollPosition = ScrollPosition()
    @LocalState private var scrollMetrics = ScrollMetrics()
    @LocalState private var isScrolling: Bool = false
    @LocalState private var hideTimerTask: Task<Void, Never>? = nil

    /// Tall enough that a typical handful of sessions fits without scrolling, short enough for a 13" screen
    private let maxListHeight: CGFloat = 600

    private var showBottomButton: Bool {
        viewModel.showBottomButton
    }

    private var totalContentHeight: CGFloat {
        contentHeight + (showBottomButton ? buttonHeight : 0)
    }

    private var needsScrolling: Bool {
        totalContentHeight > maxListHeight
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    let waitingSessions = viewModel.roots(in: .waitingForUser)
                    let doneSessions = viewModel.roots(in: .completed)
                    let runningSessions = viewModel.roots(in: .running)
                    let idleSessions = viewModel.roots(in: .idle)
                    let allIdleSessions = idleSessions

                    if viewModel.filterState == nil || viewModel.filterState == .waitingForUser {
                        if !waitingSessions.isEmpty {
                            let threshold = Double(AppSettings.shared.remindAfterMinutes * 60)
                            let overdueCount = AppSettings.shared.remindEnabled ? waitingSessions.filter { Date().timeIntervalSince($0.stateSince) >= threshold }.count : 0
                            let overdueText: Text? = overdueCount > 0 ? Text("· \(overdueCount) 个已超时").foregroundColor(.red) : nil
                            sectionHeader(title: "等你回复", dotColor: .orange, trailing: overdueText)
                            ForEach(waitingSessions) { session in
                                SessionGroup(session: session, viewModel: viewModel)
                                    .id(session.id)
                            }
                        }
                    }

                    if viewModel.filterState == nil || viewModel.filterState == .completed {
                        if !doneSessions.isEmpty {
                            sectionHeader(title: "已完成", dotColor: .green)
                            ForEach(doneSessions) { session in
                                SessionGroup(session: session, viewModel: viewModel)
                                    .id(session.id)
                            }
                        }
                    }

                    if viewModel.filterState == nil || viewModel.filterState == .running {
                        if !runningSessions.isEmpty {
                            sectionHeader(title: "运行中", dotColor: .blue)
                            ForEach(runningSessions) { session in
                                SessionGroup(session: session, viewModel: viewModel)
                                    .id(session.id)
                            }
                        }
                    }

                    if viewModel.filterState == nil || viewModel.filterState == .idle {
                        if !allIdleSessions.isEmpty {
                            let isExpanded = viewModel.isIdleExpanded || viewModel.filterState == .idle
                            Button(action: {
                                withAnimation(.snappy(duration: 0.2)) {
                                    viewModel.isIdleExpanded.toggle()
                                }
                            }) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color.gray)
                                        .frame(width: 6, height: 6)
                                    Text("空闲 · \(allIdleSessions.count) 个会话")
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.secondary)
                                        .rotationEffect(isExpanded ? .degrees(90) : .zero)
                                }
                                .padding(8)
                                .background(isIdleHovered ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(Color.clear))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .onHover { isIdleHovered = $0 }

                            if isExpanded {
                                ForEach(idleSessions) { session in
                                    SessionGroup(session: session, viewModel: viewModel)
                                        .id(session.id)
                                }
                                .transition(.asymmetric(insertion: .opacity, removal: .identity))
                            }
                        }
                    }

                    if viewModel.sessions.isEmpty {
                        ContentUnavailableView {
                            Label("暂无活跃会话", systemImage: "rectangle.stack")
                        } description: {
                            Text("各 agent 启动后将在此处自动汇总")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 1)
                .background(ScrollViewConfigurator())
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                    contentHeight = newHeight
                }
            }
            .scrollDisabled(!needsScrolling)
            .scrollIndicators(.hidden)
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geo in
                let insets = geo.contentInsets.top + geo.contentInsets.bottom
                let visible = geo.containerSize.height - insets
                return ScrollMetrics(
                    offset: geo.contentOffset.y + geo.contentInsets.top,
                    maxOffset: max(0, geo.contentSize.height - visible),
                    visibleHeight: visible,
                    visibleFraction: geo.contentSize.height > 0 ? min(1, visible / geo.contentSize.height) : 1
                )
            } action: { old, new in
                scrollMetrics = new
                if abs(new.offset - old.offset) > 0.5 {
                    triggerScrollIndicator()
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            // spacing: 0 so the inset equals the measured button height that the frame below adds
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showBottomButton {
                    Button(action: {
                        withAnimation(.smooth) {
                            viewModel.markAllAsRead()
                        }
                    }) {
                        Label("全部标为已读", systemImage: "checkmark")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .glassEffectTransition(.materialize)
                    .padding(.top, 4)
                    .padding(.bottom, 2)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                        buttonHeight = newHeight
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: contentHeight > 0 ? min(totalContentHeight, maxListHeight) : nil)
            .frame(maxHeight: maxListHeight)
            .clipped()
            // After clipped() so the thumb can sit in MenuView's side padding instead of over the rows
            .overlay(alignment: .trailing) {
                CustomScrollIndicator(
                    metrics: scrollMetrics,
                    bottomInset: showBottomButton ? buttonHeight : 0,
                    isScrolling: isScrolling,
                    onScrollTo: { targetOffset in
                        triggerScrollIndicator()
                        scrollPosition.scrollTo(y: targetOffset)
                    }
                )
                .offset(x: CustomScrollIndicator.gutterWidth)
            }
            .onChange(of: viewModel.isIdleExpanded) { _, _ in
                triggerScrollIndicator()
            }
            .onChange(of: viewModel.filterState) { _, _ in
                triggerScrollIndicator()
            }
            .onChange(of: viewModel.keyboardSelectionID) { _, newID in
                if let id = newID {
                    proxy.scrollTo(id, anchor: nil)
                }
            }
            .onChange(of: viewModel.visibleSessionIDs) { _, newIDs in
                if let id = viewModel.keyboardSelectionID, !newIDs.contains(id) {
                    viewModel.keyboardSelectionID = nil
                }
            }
        }
    }

    private func triggerScrollIndicator() {
        guard needsScrolling else {
            isScrolling = false
            return
        }
        isScrolling = true
        hideTimerTask?.cancel()
        hideTimerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.3)) {
                    isScrolling = false
                }
            }
        }
    }

    private func sectionHeader(title: String, dotColor: Color, trailing: Text? = nil) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            if let trailing = trailing {
                trailing
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 0, trailing: 8))
    }
}

/// Each row keeps its own jump button; disclosure is a separate accessible control.
private struct SessionGroup: View {
    let session: AgentSession
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(viewModel.subtree(of: session)) { row in
                VStack(alignment: .leading, spacing: 0) {
                    SessionRow(session: row, viewModel: viewModel)
                        .id(row.id)
                    let count = viewModel.childSessions(of: row.id).count
                    if count > 0 {
                        let expanded = viewModel.expandedSubagentIDs.contains(row.id)
                        Button {
                            viewModel.toggleSubagents(of: row.id)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                Text("子代理 · \(count) 个")
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("子代理 · \(count) 个")
                        .accessibilityValue(expanded ? "已展开" : "已折叠")
                    }
                }
                .padding(.leading, CGFloat(min(viewModel.depth(of: row), 3)) * 14)
            }
        }
    }
}

private struct ScrollViewConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfiguratorView {
        ConfiguratorView()
    }
    func updateNSView(_ nsView: ConfiguratorView, context: Context) {}
}

/// Removes the system scroller so CustomScrollIndicator is the only one. With a mouse attached macOS
/// switches to legacy scrollers, which reserve ~19pt of width and draw a track; hiding alone keeps that width.
@MainActor
private final class ConfiguratorView: NSView {
    private var observation: NSKeyValueObservation?
    private var styleObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let sv = self.enclosingScrollView else { return }
            Self.removeScroller(sv)
            self.observation = sv.observe(\.hasVerticalScroller, options: [.new]) { sv, _ in
                DispatchQueue.main.async { Self.removeScroller(sv) }
            }
            self.styleObserver = NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
            ) { [weak sv] _ in
                MainActor.assumeIsolated {
                    if let sv { Self.removeScroller(sv) }
                }
            }
        }
    }

    private static func removeScroller(_ sv: NSScrollView) {
        sv.scrollerStyle = .overlay
        if sv.hasVerticalScroller { sv.hasVerticalScroller = false }
        if sv.hasHorizontalScroller { sv.hasHorizontalScroller = false }
    }
}
