import SwiftUI

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
            ExpandedView(vm: vm, ns: ns)
                .padding(.horizontal, 26)
                .padding(.bottom, 10)
                .frame(width: vm.expandedSize.width, height: vm.expandedSize.height, alignment: .top)
                .opacity(expanded ? 1 : 0)
                .blur(radius: expanded ? 0 : 10)
                .scaleEffect(expanded ? 1 : 0.92, anchor: .top)
                .allowsHitTesting(expanded)
                .animation(expanded ? .spring(response: 0.42, dampingFraction: 0.85).delay(0.06) : .easeIn(duration: 0.1), value: expanded)

            CompactView(vm: vm)
                .padding(.horizontal, vm.topRadius + 8)
                // Pin to the island's own size; otherwise the ZStack hands it the
                // (wider) expanded layer's width and the edges get clipped.
                .frame(width: size.width, height: size.height, alignment: .top)
                .opacity(expanded ? 0 : 1)
                .blur(radius: expanded ? 6 : 0)
                .scaleEffect(expanded ? 1.15 : 1, anchor: .top)
                .allowsHitTesting(!expanded)
                .animation(expanded ? .easeIn(duration: 0.1) : .spring(response: 0.36, dampingFraction: 0.85).delay(0.08), value: expanded)
        }
        // The island's frame animates; content keeps a fixed layout and is revealed
        // by the clip — no per-frame text re-layout, no blurred shadow to recompute.
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Color.black)
        .clipShape(shape)
        .overlay(
            // P2/P6: cyan outline pulse when something is copied (top edge left open).
            NotchShape(topRadius: vm.topRadius, bottomRadius: vm.bottomRadius, closed: false)
                .stroke(Feature.clipboard.tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .opacity(vm.copyPulse ? 1 : 0)
                .allowsHitTesting(false)
        )
        .modifier(ShakeEffect(animatableData: vm.shakeTrigger))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(expanded ? IslandViewModel.spring : IslandViewModel.collapseSpring, value: size)
        .environment(\.colorScheme, .dark)
    }
}
