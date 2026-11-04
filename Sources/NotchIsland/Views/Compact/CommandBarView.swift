import AppKit
import SwiftUI

/// The Command Bar: a text field under the notch and what it understood.
struct CommandBarView: View {
    @ObservedObject var vm: IslandViewModel

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: vm.notchSize.height)

            HStack(spacing: 10) {
                Image(systemName: "command")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.55))
                CommandField(text: $vm.commandText,
                             placeholder: String(localized: "Calculate, convert, “timer 10m”, “remind me…”, a city"),
                             onSubmit: { vm.runSelectedCommand() },
                             onCancel: { vm.closeCommandBar() },
                             onMove: { vm.moveCommandSelection($0) })
                    .frame(height: 24)
                Text("esc")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2)))
            }
            .padding(.horizontal, 6)
            .frame(height: IslandViewModel.commandFieldHeight)

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

            VStack(spacing: 0) {
                ForEach(Array(vm.commandResults.prefix(IslandViewModel.commandMaxRows).enumerated()), id: \.element.id) { index, result in
                    CommandRow(result: result, selected: index == vm.commandSelection, isExample: vm.commandText.isEmpty)
                        .contentShape(Rectangle())
                        .onTapGesture { vm.run(result) }
                        .onHover { inside in if inside { vm.commandSelection = index } }
                }
            }
            .padding(.top, 4)

            if let message = vm.commandMessage {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.yellow)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
            }
        }
        .padding(.horizontal, 6)
    }
}

struct CommandRow: View {
    let result: CommandResult
    let selected: Bool
    let isExample: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: result.symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.black)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(result.tint))
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                    .font(.system(size: isExample ? 13 : 14, weight: isExample ? .medium : .semibold,
                                  design: isExample ? .monospaced : .default))
                    .foregroundStyle(Color.white.opacity(isExample ? 0.85 : 1))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = result.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if selected, let verb = result.verb {
                HStack(spacing: 4) {
                    Text(verb)
                    Image(systemName: "return")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: IslandViewModel.commandRowHeight)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(selected ? 0.1 : 0)))
    }
}

/// A borderless text field that takes focus as soon as it appears, with ↑ ↓ ⏎ esc.
struct CommandField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onMove: (Int) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 16, weight: .medium)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.35),
            .font: NSFont.systemFont(ofSize: 16, weight: .regular),
        ])
        field.cell?.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if let window = field.window, window.firstResponder !== field.currentEditor() {
            DispatchQueue.main.async { window.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandField
        init(parent: CommandField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            default: return false
            }
            return true
        }
    }
}

// MARK: - Backups & copies (collapsed island)

/// Time Machine / copy to a drive: a ring with the icon on the left, the percent on the right.
struct CompactSystemProgress: View {
    let activity: SystemProgressService.Activity
    let notchWidth: CGFloat

    private var tint: Color { activity.kind == .backup ? .green : .blue }
    private var symbol: String { activity.kind == .backup ? "clock.arrow.circlepath" : "externaldrive.fill" }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                ProgressRing(fraction: activity.fraction, tint: tint)
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 18, height: 18)
            .help([activity.title, activity.detail].compactMap { $0 }.joined(separator: " · "))
            Spacer(minLength: notchWidth)
            Text(activity.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "…")
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.9))
        }
    }
}
