import AppKit

enum PermissionOnboardingMode {
    case initialSetup
    case review

    var enablesFeatureDefaultsOnCompletion: Bool {
        self == .initialSetup
    }

    var recordsSkippedState: Bool {
        self == .initialSetup
    }
}

enum PermissionOnboardingClosePolicy {
    static func shouldRecordSkipped(
        isProgrammaticClose: Bool,
        didComplete: Bool,
        recordsSkippedState: Bool,
        isApplicationTerminating: Bool
    ) -> Bool {
        !isProgrammaticClose && !didComplete && recordsSkippedState && !isApplicationTerminating
    }
}

protocol PermissionOnboardingPermissionProviding: AnyObject {
    func snapshot() -> PermissionSnapshot
    func openPrivacySettings(for kind: PermissionKind)
    func isGranted(_ kind: PermissionKind, in snapshot: PermissionSnapshot) -> Bool
}

extension PermissionService: PermissionOnboardingPermissionProviding {}

private struct PermissionOnboardingSessionState {
    typealias Generation = UInt64

    private var latestGeneration: Generation = 0
    private(set) var visibleGeneration: Generation?

    mutating func beginVisibleSession() -> Generation {
        latestGeneration &+= 1
        visibleGeneration = latestGeneration
        return latestGeneration
    }

    mutating func invalidateVisibleSession() {
        visibleGeneration = nil
    }

    func acceptsRefresh(for generation: Generation) -> Bool {
        visibleGeneration == generation
    }
}

@MainActor
final class PermissionOnboardingWindowController: NSWindowController, NSWindowDelegate {
    typealias DeferredAction = @MainActor () -> Void
    typealias DeferredScheduler = @MainActor (TimeInterval, @escaping DeferredAction) -> Void

    private let settings: SettingsStore
    private let permissionService: any PermissionOnboardingPermissionProviding
    private let presentationCoordinator: ApplicationPresentationCoordinator
    private let scheduleDeferredAction: DeferredScheduler
    private let onCompleted: () -> Void
    private let onSkipped: () -> Void
    private let onPermissionStatusChanged: () -> Void

    private let statusLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let laterButton = NSButton(title: "", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let privacyLabel = NSTextField(wrappingLabelWithString: "")
    private var permissionViews: [PermissionKind: PermissionCardView] = [:]
    private var timer: Timer?
    private var highlightedPermission: PermissionKind?
    private var isProgrammaticClose = false
    private var didComplete = false
    private var lastSnapshot: PermissionSnapshot?
    private var mode: PermissionOnboardingMode = .review
    private var isApplicationTerminating = false
    private var sessionState = PermissionOnboardingSessionState()
    private var renderedLanguage: AppLanguage.Resolved?

    init(
        settings: SettingsStore,
        permissionService: any PermissionOnboardingPermissionProviding,
        presentationCoordinator: ApplicationPresentationCoordinator,
        onCompleted: @escaping () -> Void,
        onSkipped: @escaping () -> Void,
        onPermissionStatusChanged: @escaping () -> Void,
        scheduleDeferredAction: @escaping DeferredScheduler = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                action()
            }
        }
    ) {
        self.settings = settings
        self.permissionService = permissionService
        self.presentationCoordinator = presentationCoordinator
        self.scheduleDeferredAction = scheduleDeferredAction
        self.onCompleted = onCompleted
        self.onSkipped = onSkipped
        self.onPermissionStatusChanged = onPermissionStatusChanged

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "OmniDock"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContentView()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: SettingsStore.changedNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show(
        focus permission: PermissionKind? = nil,
        automaticallyOpenSettings: Bool = false,
        mode: PermissionOnboardingMode = .review
    ) {
        invalidateVisibleSession()
        highlightedPermission = permission
        self.mode = mode
        didComplete = false
        lastSnapshot = nil
        guard !isApplicationTerminating, let window else {
            return
        }
        let generation = sessionState.beginVisibleSession()
        presentationCoordinator.present(.permissionOnboarding)
        refreshLocalizedText()
        refresh(for: generation)
        startPolling(for: generation)
        window.center()
        window.makeKeyAndOrderFront(nil)

        if automaticallyOpenSettings, let permission {
            scheduleDeferredAction(0.25) { [weak self] in
                self?.openPermissionSettings(
                    permission,
                    sessionGeneration: generation
                )
            }
        }
    }

    func showRefreshingBeforeRelaunch() {
        refreshLocalizedText()
        statusLabel.stringValue = AppStrings.text(.onboardingStatusRefreshing)
        primaryButton.isEnabled = false
        laterButton.isEnabled = false
    }

    func prepareForApplicationTermination() {
        isApplicationTerminating = true
        invalidateVisibleSession()
    }

    func windowWillClose(_ notification: Notification) {
        invalidateVisibleSession()
        presentationCoordinator.dismiss(.permissionOnboarding)
        guard PermissionOnboardingClosePolicy.shouldRecordSkipped(
            isProgrammaticClose: isProgrammaticClose,
            didComplete: didComplete,
            recordsSkippedState: mode.recordsSkippedState,
            isApplicationTerminating: isApplicationTerminating
        ) else {
            return
        }
        markSkipped()
    }

    private func makeContentView() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        configureWrappingLabel(subtitleLabel, size: 14, color: .secondaryLabelColor)
        configureWrappingLabel(privacyLabel, size: 12, color: .tertiaryLabelColor)
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = .labelColor

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor

        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.addArrangedSubview(statusLabel)

        for kind in PermissionFeatureGate.onboardingPermissions {
            let view = PermissionCardView(kind: kind)
            view.onRequest = { [weak self] kind in
                self?.openPermissionSettings(kind)
            }
            permissionViews[kind] = view
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        stack.addArrangedSubview(privacyLabel)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        laterButton.title = AppStrings.text(.onboardingLater)
        laterButton.bezelStyle = .rounded
        laterButton.target = self
        laterButton.action = #selector(skip(_:))

        primaryButton.bezelStyle = .rounded
        primaryButton.target = self
        primaryButton.action = #selector(primaryAction(_:))

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addArrangedSubview(spacer)
        buttonRow.addArrangedSubview(laterButton)
        buttonRow.addArrangedSubview(primaryButton)
        stack.addArrangedSubview(buttonRow)
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -24),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])

        return root
    }

    private func configureWrappingLabel(_ label: NSTextField, size: CGFloat, color: NSColor) {
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.maximumNumberOfLines = 3
    }

    private func refreshLocalizedText() {
        renderedLanguage = AppLocalization.currentResolvedLanguage
        titleLabel.stringValue = AppStrings.text(.onboardingTitle)
        subtitleLabel.stringValue = AppStrings.text(.onboardingSubtitle)
        privacyLabel.stringValue = AppStrings.text(.onboardingPrivacyNote)
        laterButton.title = AppStrings.text(.onboardingLater)
    }

    @objc private func settingsChanged() {
        guard renderedLanguage != AppLocalization.currentResolvedLanguage else {
            return
        }
        refreshLocalizedText()
        if let generation = sessionState.visibleGeneration {
            refresh(for: generation)
        }
    }

    private func startPolling(for generation: PermissionOnboardingSessionState.Generation) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh(for: generation)
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh(for generation: PermissionOnboardingSessionState.Generation) {
        guard sessionState.acceptsRefresh(for: generation) else {
            return
        }

        let snapshot = permissionService.snapshot()
        let didChange = snapshot != lastSnapshot
        lastSnapshot = snapshot
        let allGranted = PermissionFeatureGate.allOnboardingPermissionsGranted(in: snapshot)
        statusLabel.stringValue = allGranted
            ? AppStrings.text(.onboardingStatusReady)
            : AppStrings.text(.onboardingStatusNeedsPermissions)
        primaryButton.title = allGranted
            ? AppStrings.text(.onboardingFinish)
            : AppStrings.text(.onboardingContinue)
        primaryButton.isEnabled = true
        laterButton.title = AppStrings.text(.onboardingLater)

        for kind in PermissionFeatureGate.onboardingPermissions {
            permissionViews[kind]?.update(
                isGranted: permissionService.isGranted(kind, in: snapshot),
                isHighlighted: kind == highlightedPermission
            )
        }

        if allGranted, !didComplete {
            didComplete = true
            if mode.enablesFeatureDefaultsOnCompletion {
                settings.enablePermissionBackedDefaultsAfterOnboarding()
            }
            onCompleted()
        } else if didChange {
            onPermissionStatusChanged()
        }
    }

    @objc private func primaryAction(_ sender: NSButton) {
        guard let generation = sessionState.visibleGeneration else {
            return
        }

        let snapshot = permissionService.snapshot()
        if PermissionFeatureGate.allOnboardingPermissionsGranted(in: snapshot) {
            closeProgrammatically()
            return
        }

        let nextPermission = PermissionFeatureGate.onboardingPermissions.first {
            !permissionService.isGranted($0, in: snapshot)
        }
        if let nextPermission {
            openPermissionSettings(nextPermission, sessionGeneration: generation)
        }
    }

    @objc private func skip(_ sender: NSButton) {
        guard sessionState.visibleGeneration != nil else {
            return
        }

        invalidateVisibleSession()
        if mode.recordsSkippedState {
            markSkipped()
        }
        closeProgrammatically()
    }

    private func openPermissionSettings(
        _ kind: PermissionKind,
        sessionGeneration: PermissionOnboardingSessionState.Generation? = nil
    ) {
        guard let generation = sessionGeneration ?? sessionState.visibleGeneration,
              sessionState.acceptsRefresh(for: generation)
        else {
            return
        }

        highlightedPermission = kind
        permissionService.openPrivacySettings(for: kind)
        schedulePermissionRefreshes(for: generation)
        refresh(for: generation)
    }

    private func schedulePermissionRefreshes(
        for generation: PermissionOnboardingSessionState.Generation
    ) {
        for delay in [0.5, 1.5, 3.0, 6.0] {
            scheduleDeferredAction(delay) { [weak self] in
                self?.refresh(for: generation)
            }
        }
    }

    private func invalidateVisibleSession() {
        sessionState.invalidateVisibleSession()
        stopPolling()
    }

    private func markSkipped() {
        settings.permissionOnboardingSkipped = true
        settings.permissionOnboardingCompleted = false
        onSkipped()
    }

    private func closeProgrammatically() {
        invalidateVisibleSession()
        isProgrammaticClose = true
        defer { isProgrammaticClose = false }
        close()
    }
}

private final class PermissionCardView: NSView {
    var onRequest: ((PermissionKind) -> Void)?

    private let kind: PermissionKind
    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)

    init(kind: PermissionKind) {
        self.kind = kind
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(isGranted: Bool, isHighlighted: Bool) {
        titleLabel.stringValue = kind.title
        detailLabel.stringValue = AppStrings.onboardingPurpose(kind)
        button.title = isGranted ? AppStrings.text(.onboardingEnabled) : AppStrings.text(.onboardingGoEnable)
        button.isEnabled = !isGranted
        dot.layer?.backgroundColor = (isGranted ? NSColor.systemGreen : NSColor.systemGray).cgColor
        layer?.borderColor = (isHighlighted && !isGranted ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor

        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2

        let labelStack = NSStackView()
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 3
        labelStack.translatesAutoresizingMaskIntoConstraints = false
        labelStack.addArrangedSubview(titleLabel)
        labelStack.addArrangedSubview(detailLabel)

        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(request(_:))
        button.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(labelStack)
        addSubview(button)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 76),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),

            labelStack.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
            labelStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelStack.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -14),

            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            button.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @objc private func request(_ sender: NSButton) {
        onRequest?(kind)
    }
}
