import SwiftUI
import UIKit

/// Press-and-hold that tracks the full touch until finger lifts (works inside `ScrollView`).
struct HoldDownButton<Label: View>: View {
    let enabled: Bool
    @Binding var isHeld: Bool
    let onHoldStart: () -> Void
    let onHoldEnd: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        HoldDownButtonRepresentable(
            enabled: enabled,
            isHeld: $isHeld,
            onHoldStart: onHoldStart,
            onHoldEnd: onHoldEnd,
            label: label()
        )
    }
}

// MARK: - UIKit touch tracking (ScrollView-safe)

private final class HoldDownCoordinator {
    var isHeld: Binding<Bool>
    var onHoldStart: () -> Void
    var onHoldEnd: () -> Void
    var hostingController: UIHostingController<AnyView>?
    private(set) var pressing = false

    init(isHeld: Binding<Bool>, onHoldStart: @escaping () -> Void, onHoldEnd: @escaping () -> Void) {
        self.isHeld = isHeld
        self.onHoldStart = onHoldStart
        self.onHoldEnd = onHoldEnd
    }

    func beginPress() {
        guard !pressing else { return }
        pressing = true
        if !isHeld.wrappedValue {
            isHeld.wrappedValue = true
            onHoldStart()
        }
    }

    func endPress() {
        guard pressing else { return }
        pressing = false
        if isHeld.wrappedValue {
            isHeld.wrappedValue = false
            onHoldEnd()
        }
    }

    func cancelPress() {
        endPress()
    }
}

private struct HoldDownButtonRepresentable<Label: View>: UIViewRepresentable {
    let enabled: Bool
    @Binding var isHeld: Bool
    let onHoldStart: () -> Void
    let onHoldEnd: () -> Void
    let label: Label

    func makeCoordinator() -> HoldDownCoordinator {
        HoldDownCoordinator(
            isHeld: $isHeld,
            onHoldStart: onHoldStart,
            onHoldEnd: onHoldEnd
        )
    }

    func makeUIView(context: Context) -> HoldTouchControl {
        let control = HoldTouchControl()
        control.coordinator = context.coordinator
        control.isEnabled = enabled

        let host = UIHostingController(rootView: AnyView(label))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.isUserInteractionEnabled = false
        control.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: control.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: control.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: control.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: control.bottomAnchor),
        ])
        context.coordinator.hostingController = host
        return control
    }

    func updateUIView(_ control: HoldTouchControl, context: Context) {
        context.coordinator.isHeld = $isHeld
        context.coordinator.onHoldStart = onHoldStart
        context.coordinator.onHoldEnd = onHoldEnd
        control.coordinator = context.coordinator
        control.isEnabled = enabled
        context.coordinator.hostingController?.rootView = AnyView(label)
        if !enabled {
            context.coordinator.cancelPress()
        }
    }

    static func dismantleUIView(_ uiView: HoldTouchControl, coordinator: HoldDownCoordinator) {
        coordinator.cancelPress()
    }
}

/// Touch down → up; finger can move without ending the hold (unlike `DragGesture` inside a scroll view).
private final class HoldTouchControl: UIControl {
    weak var coordinator: HoldDownCoordinator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard isEnabled, let touch = touches.first else { return }
        let point = touch.location(in: self)
        guard bounds.contains(point) else { return }
        coordinator?.beginPress()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        coordinator?.endPress()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        coordinator?.cancelPress()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 52)
    }
}
