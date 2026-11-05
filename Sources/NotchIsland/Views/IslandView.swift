import SwiftUI
import UniformTypeIdentifiers

struct IslandView: View {
    @ObservedObject var vm: IslandViewModel
    @Namespace private var ns

    var body: some View {
        let size = vm.currentSize
        let expanded = vm.mode == .expanded
        let shape = NotchShape(topRadius: vm.topRadius, bottomRadius: vm.bottomRadius)

        ZStack(alignment: .top) {
            // Both layouts stay alive; switching only cross-fades them. Building the
            // expanded hierarchy on every hover is what caused first-frame hitches.
            // Seasonal touches (snow, sparkles, confetti), behind the open island's content.
            if expanded, ThemeSettings.shared.seasonal, let season = Season.current() {
                SeasonalOverlay(season: season)
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity)
            }

            ExpandedView(vm: vm, ns: ns)
                // Rebuild the panels when Liquid Glass or the theme changes.
                .id("\(vm.usesGlass)-\(ThemeSettings.shared.theme.rawValue)")
                .padding(.horizontal, 26)
                .padding(.bottom, 10)
                .frame(width: vm.expandedSize.width, height: vm.expandedSize.height, alignment: .top)
                .opacity(expanded ? 1 : 0)
                // Scale + fade only: both are cheap GPU transforms. (A blur here was applied
                // permanently to the hidden layer and cost an offscreen pass on every update.)
                .scaleEffect(expanded ? 1 : 0.94, anchor: .top)
                .allowsHitTesting(expanded)
                .animation(expanded ? .spring(response: 0.42, dampingFraction: 0.85).delay(0.06) : .easeIn(duration: 0.1), value: expanded)

            CompactView(vm: vm)
                .padding(.horizontal, vm.topRadius + 8)
                // Pin to the island's own size; otherwise the ZStack hands it the
                // (wider) expanded layer's width and the edges get clipped.
                .frame(width: size.width, height: size.height, alignment: .top)
                .opacity(expanded ? 0 : 1)
                .scaleEffect(expanded ? 1.12 : 1, anchor: .top)
                .allowsHitTesting(!expanded)
                .animation(expanded ? .easeIn(duration: 0.1) : .spring(response: 0.36, dampingFraction: 0.85).delay(0.08), value: expanded)
        }
        // The island's frame animates; content keeps a fixed layout and is revealed
        // by the clip — no per-frame text re-layout, no blurred shadow to recompute.
        .frame(width: size.width, height: size.height, alignment: .top)
        .modifier(IslandSurface(glass: vm.usesGlassSurface, shape: shape,
                                height: size.height, notchHeight: vm.notchSize.height,
                                frosted: vm.showsFinishedGlow))
        .overlay(
            // Copied: a silver rim along the bottom curve (metallic sheen, brightest in the
            // middle, fading out before it reaches the sides).
            NotchShape(topRadius: vm.topRadius, bottomRadius: vm.bottomRadius, closed: false)
                .stroke(
                    LinearGradient(colors: [Color(white: 0.45), Color(white: 0.92), Color(white: 0.6),
                                            Color(white: 0.95), Color(white: 0.45)],
                                   startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
                )
                .mask(LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.45),
                    .init(color: .white, location: 1),
                ], startPoint: .top, endPoint: .bottom))
                .opacity(vm.copyPulse || vm.peek == .copied ? 0.75 : 0)
                .animation(.easeInOut(duration: 0.35), value: vm.copyPulse || vm.peek == .copied)
                .allowsHitTesting(false)
        )
        .modifier(ShakeEffect(animatableData: vm.shakeTrigger))
        .overlay(alignment: .top) {
            // Split island: the second activity buds off into its own bubble.
            ZStack {
                if let secondary = vm.secondaryActivity {
                    ActivityBubble(vm: vm, activity: secondary)
                        .id(secondary)
                        .offset(x: vm.bubbleOffset)
                        .transition(.bubbleBud)
                }
            }
            .animation(IslandViewModel.spring, value: vm.secondaryActivity)
        }
        .overlay(alignment: .top) {
            // Floating tab bar under the open island.
            ZStack {
                if vm.showsTabBar {
                    TabBar(vm: vm)
                        .offset(y: size.height + IslandViewModel.tabBarGap)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                }
            }
            .animation(IslandViewModel.spring, value: vm.showsTabBar)
        }
        // Files Tray: drop files on the open island to keep them on the shelf.
        .onDrop(of: [UTType.fileURL], isTargeted: Binding(
            get: { vm.fileTrayTargeted },
            set: { targeted in vm.fileTrayTargeted = targeted && vm.showsFileTray }
        )) { providers in
            guard vm.showsFileTray, !providers.isEmpty else { return false }
            var urls: [URL] = []
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    DispatchQueue.main.async {
                        if let url { urls.append(url) }
                        group.leave()
                    }
                }
            }
            group.notify(queue: .main) { vm.dropOnTray(urls) }
            return true
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Dynamic Island motion: opening and drop-downs grow with a soft overshoot;
        // tucking away is quicker and settles without bounce.
        .animation(expanded ? IslandViewModel.spring
                   : (vm.peek != nil || vm.showsCommandBar ? IslandViewModel.peekSpring : IslandViewModel.collapseSpring),
                   value: size)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Split island bubble

/// The second live activity, in a small notch-height bubble beside the island.
struct ActivityBubble: View {
    @ObservedObject var vm: IslandViewModel
    let activity: IslandViewModel.LiveActivity

    var body: some View {
        let size = vm.bubbleSize
        glyph
            .frame(width: size.width, height: size.height)
            .modifier(IslandSurface(
                glass: vm.usesGlassSurface,
                shape: NotchShape(topRadius: IslandViewModel.bubbleFlare, bottomRadius: size.height / 2)
            ))
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var glyph: some View {
        switch activity {
        case .music:
            ArtworkView(image: vm.nowPlaying.artwork, cornerRadius: 6)
                .frame(width: 22, height: 22)
        case .timer:
            TimerRing(timer: vm.timer, lineWidth: 2.5)
                .frame(width: 16, height: 16)
        case .download:
            BubbleDownloadRing(downloads: vm.downloads)
                .frame(width: 16, height: 16)
        case .apiProgress:
            if let progress = vm.api.progress {
                ProgressRing(fraction: progress.value, tint: IslandAPIService.swiftUIColor(progress.color))
                    .frame(width: 16, height: 16)
            }
        case .agent:
            if let session = vm.latestAgent {
                AgentIcon(session: session, size: 18)
            }
        case .privacy:
            PrivacyDots(privacy: vm.privacy)
        case .terminalInput:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.yellow)
        case .system:
            if let activity = vm.systemActivity {
                ProgressRing(fraction: activity.fraction, tint: activity.kind == .backup ? .green : .blue)
                    .frame(width: 16, height: 16)
            }
        case .meeting:
            if let meeting = vm.calendar.next {
                Image(systemName: "calendar")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: meeting.color))
            }
        }
    }
}

extension AnyTransition {
    /// The bubble buds out of the island's right edge and tucks back into it.
    static var bubbleBud: AnyTransition {
        .scale(scale: 0.3, anchor: .leading)
            .combined(with: .offset(x: -18))
            .combined(with: .opacity)
    }
}
