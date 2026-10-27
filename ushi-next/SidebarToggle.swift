//
//  SidebarToggle.swift
//  UshiNext
//
//  Кнопка сворачивания левой колонки — как в Claude Code: простая иконка
//  панели без «пузыря». Пока колонка открыта, кнопка стоит в правом верхнем
//  углу колонки (напротив «светофора»); свёрнута — сразу после «светофора».
//
//  Кнопка живёт в панели инструментов окна (иначе по ней нельзя кликнуть —
//  заголовок окна перехватывает клики). Чтобы сдвинуть её к правому краю
//  колонки, меряем, где в окне начинается элемент панели инструментов, и
//  добавляем перед кнопкой прозрачный отступ нужной ширины.
//

import SwiftUI
import AppKit

struct SidebarToggleToolbar: ToolbarContent {
    @Binding var isSidebarVisible: Bool
    /// X начала элемента панели инструментов в координатах окна (меряется на лету).
    @Binding var itemStartX: CGFloat

    private let buttonSize: CGFloat = 28
    private let trailingInset: CGFloat = 8

    /// Отступ, чтобы кнопка встала у правого края открытой колонки.
    private var offset: CGFloat {
        guard isSidebarVisible else { return 0 }
        return max(0, SidebarMetrics.width - itemStartX - buttonSize - trailingInset)
    }

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { content }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { content }
        }
    }

    private var content: some View {
        HStack(spacing: 0) {
            WindowXReader { x in
                if abs(x - itemStartX) > 0.5 { itemStartX = x }
            }
            .frame(width: 0, height: 0)

            Color.clear.frame(width: offset, height: 1)

            SidebarToggleButton(isSidebarVisible: $isSidebarVisible, size: buttonSize)
        }
    }
}

private struct SidebarToggleButton: View {
    @Binding var isSidebarVisible: Bool
    let size: CGFloat

    var body: some View {
        ToolbarIconButton(
            imageName: "PanelLeft",
            help: isSidebarVisible ? "Скрыть боковую панель  ⌃⌘S" : "Показать боковую панель  ⌃⌘S"
        ) {
            withAnimation(.easeInOut(duration: 0.2)) { isSidebarVisible.toggle() }
        }
        .keyboardShortcut("s", modifiers: [.control, .command])
    }
}

/// Сообщает X своего левого края в координатах окна (на каждой раскладке).
private struct WindowXReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        nsView.onChange = onChange
        nsView.report()
    }

    final class ReportingView: NSView {
        var onChange: ((CGFloat) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        func report() {
            guard window != nil else { return }
            let x = convert(bounds.origin, to: nil).x
            DispatchQueue.main.async { [weak self] in self?.onChange?(x) }
        }
    }
}

/// Убирает заголовок экрана из панели инструментов окна.
struct HiddenWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content.navigationTitle("")
        }
    }
}

// MARK: - Кнопки в стиле Claude Code

/// Кнопка без фона: иконка и подпись цвета Claude Code, при наведении — ярче
/// и с лёгкой подложкой. Подсказка (если есть) — плашкой под кнопкой.
extension View {
    /// Тень карточек из макета: мягкая широкая (y 4, blur 40, spread 8, 3%)
    /// и плотная близкая (y 2, blur 8, 5%). Радиус SwiftUI ≈ половина blur Figma.
    func cardShadow() -> some View {
        self
            .shadow(color: .black.opacity(0.032), radius: 24, y: 4)
            .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
    }
}

struct ClaudeButton<Label: View>: View {
    var help: String? = nil
    var isEnabled = true
    /// Поля по бокам: у одной иконки — 0 (кнопка и так квадрат 28×28).
    var horizontalPadding: CGFloat = 8
    /// Высота и скругление: у кнопок тулбара 28 и 7, у плашки проекта крупнее.
    var height: CGFloat = 28
    var cornerRadius: CGFloat = 7
    /// Белая карточка с тенью — для заметных кнопок («Загрузить», выбор проекта).
    var isCard = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(isHighlighted ? AppColors.toolbarGlyphHover : AppColors.toolbarGlyph)
                .padding(.horizontal, horizontalPadding)
                .frame(minWidth: 28, minHeight: height)
                .background {
                    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    if isCard {
                        shape.fill(AppColors.elevated)
                            .overlay(shape.fill(Color.primary.opacity(isHighlighted ? 0.04 : 0)))
                            .cardShadow()
                    } else {
                        shape.fill(Color.primary.opacity(isHighlighted ? 0.07 : 0))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovered = $0 }
        .background(TooltipAnchor(text: help ?? "", isShown: isHighlighted && help != nil))
    }

    private var isHighlighted: Bool { isHovered && isEnabled }
}

/// Иконка (и, если есть, подпись) в панели окна.
struct ToolbarIconButton: View {
    let imageName: String
    var title: String? = nil
    let help: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        // С подписью («Загрузить») — белая карточка 32, как выбор проекта.
        ClaudeButton(
            help: help,
            isEnabled: isEnabled,
            horizontalPadding: title == nil ? 0 : 8,
            height: title == nil ? 28 : 32,
            cornerRadius: title == nil ? 7 : 10,
            isCard: title != nil,
            action: action
        ) {
            HStack(spacing: 6) {
                Image(imageName)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: title == nil ? 17 : 16, height: title == nil ? 17 : 16)
                if let title {
                    Text(title)
                        .font(.system(size: 13))
                }
            }
        }
        .accessibilityLabel(title.map { "\($0): \(help)" } ?? help)
    }
}

/// Кнопка у правого края панели окна (без стеклянной подложки на macOS 26).
/// Заголовка в панели нет, поэтому сами отодвигаем кнопку вправо гибким отступом.
struct TrailingToolbarButton: ToolbarContent {
    let imageName: String
    var title: String? = nil
    let help: String
    var isEnabled = true
    let action: () -> Void

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .automatic)
            ToolbarItem(placement: .automatic) { button }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .automatic) { button }
        }
    }

    /// Справа от кнопки 13 pt до края окна, как у Claude Code
    /// (панель сама даёт 8 pt).
    private var button: some View {
        ToolbarIconButton(imageName: imageName, title: title, help: help, isEnabled: isEnabled, action: action)
            .padding(.trailing, 5)
    }
}

// MARK: - Выпадающее меню под кнопкой

/// Пункт выпадающего меню.
enum PopUpMenuItem {
    case item(String, isChecked: Bool = false, action: () -> Void)
    case separator
}

/// Меню AppKit, которое раскрывается под кнопкой. SwiftUI `Menu` на macOS
/// рисует свою кнопку, а нам нужна такая же, как «Загрузить».
@MainActor
final class PopUpMenuAnchor {
    fileprivate weak var view: NSView?

    func popUp(_ items: [PopUpMenuItem]) {
        guard let view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case let .item(title, isChecked, action):
                let target = MenuActionTarget(action)
                let menuItem = NSMenuItem(title: title, action: #selector(MenuActionTarget.run), keyEquivalent: "")
                menuItem.target = target
                menuItem.representedObject = target   // NSMenuItem.target — слабая ссылка
                menuItem.state = isChecked ? .on : .off
                menu.addItem(menuItem)
            }
        }
        menu.minimumWidth = view.bounds.width
        // Левый верхний угол меню — чуть ниже левого нижнего угла кнопки.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }
}

private final class MenuActionTarget: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }
}

/// Кладётся фоном под кнопку: даёт меню место, откуда раскрыться.
struct PopUpMenuAnchorView: NSViewRepresentable {
    let anchor: PopUpMenuAnchor

    func makeNSView(context: Context) -> FlippedView {
        let view = FlippedView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: FlippedView, context: Context) {
        anchor.view = view
    }

    final class FlippedView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Подсказка в стиле Claude Code

/// Плашка под кнопкой. Рисуется отдельным маленьким окном поверх основного:
/// внутри панели инструментов её бы обрезало.
private struct TooltipAnchor: NSViewRepresentable {
    let text: String
    let isShown: Bool

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.text = text
        view.setShown(isShown)
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        view.setShown(false)
    }

    final class AnchorView: NSView {
        var text = ""
        private var panel: NSPanel?
        private var pending: Task<Void, Never>?
        private var watchdog: Task<Void, Never>?
        private var clickMonitor: Any?
        /// Спрятали по клику — снова покажем только после нового наведения.
        private var isDismissed = false

        /// Задержка, чтобы подсказка не мелькала, когда мышь проходит мимо.
        private static let delay: Duration = .milliseconds(400)
        /// Зазор между кнопкой и плашкой.
        private static let gap: CGFloat = 6
        /// Не ближе этого к краю окна (как у Claude Code).
        private static let margin: CGFloat = 5

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { setShown(false) }
        }

        func setShown(_ shown: Bool) {
            if shown {
                guard !isDismissed, panel == nil, pending == nil else { return }
                watchClicks()
                pending = Task { [weak self] in
                    try? await Task.sleep(for: Self.delay)
                    guard !Task.isCancelled else { return }
                    self?.pending = nil
                    self?.show()
                }
            } else {
                isDismissed = false
                cancel()
            }
        }

        /// Клик или клавиша — подсказка сразу исчезает (и не всплывает поверх
        /// открывшегося окна выбора файла).
        private func watchClicks() {
            guard clickMonitor == nil else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .keyDown]
            ) { [weak self] event in
                self?.isDismissed = true
                self?.cancel()
                return event
            }
        }

        private func cancel() {
            pending?.cancel()
            pending = nil
            if let clickMonitor {
                NSEvent.removeMonitor(clickMonitor)
                self.clickMonitor = nil
            }
            hide()
        }

        /// Мышь над кнопкой и окно на экране.
        private var isMouseInside: Bool {
            guard let window, window.isVisible else { return false }
            let rect = window.convertToScreen(convert(bounds, to: nil))
            return rect.contains(NSEvent.mouseLocation)
        }

        private func show() {
            guard let window, panel == nil, !text.isEmpty, isMouseInside else { return }

            let content = NSHostingView(rootView: TooltipBubble(text: text))
            let size = content.fittingSize
            let inset = TooltipBubble.shadowInset
            let anchor = window.convertToScreen(convert(bounds, to: nil))
            let frame = window.frame

            // По центру под кнопкой, но не вылезая за край окна.
            var x = anchor.midX - size.width / 2
            x = min(x, frame.maxX - Self.margin - size.width + inset)
            x = max(x, frame.minX + Self.margin - inset)
            let y = anchor.minY - Self.gap - size.height + inset

            let panel = NSPanel(
                contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            panel.appearance = window.effectiveAppearance
            panel.contentView = content
            panel.alphaValue = 0
            window.addChildWindow(panel, ordered: .above)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
            self.panel = panel

            // Страховка: если окно ушло на задний план и SwiftUI не сообщил,
            // что мышь ушла, — прячем сами.
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, !Task.isCancelled else { return }
                    if !self.isMouseInside {
                        self.hide()
                        return
                    }
                }
            }
        }

        private func hide() {
            watchdog?.cancel()
            watchdog = nil
            guard let panel else { return }
            self.panel = nil
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }
}

/// Сама плашка: тёмная с тонкой рамкой и мягкой тенью (в светлой теме — белая).
private struct TooltipBubble: View {
    let text: String

    /// Поля вокруг плашки, чтобы тень не обрезалась краем окна-подсказки.
    static let shadowInset: CGFloat = 8

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(AppColors.tooltipText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(AppColors.tooltipFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(AppColors.tooltipBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .padding(Self.shadowInset)
            .fixedSize()
    }
}
