//
//  ExperimentalPrivateHiding.swift
//  FloeBar
//

import AppKit
import Combine

/// Session-only opt-in. API completion is not proof of physical concealment.
@MainActor
final class ExperimentalPrivateHiding: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var active = false
    @Published private(set) var failed = false
    var onRecovery: (() -> Void)?
    private var lease: FBPrivateLease?
    private var targets = Set<String>()
    private var generation = 0
    private var observers = Set<AnyCancellable>()
    private let screenCount: () -> Int

    init(screenCount: @escaping () -> Int = { NSScreen.screens.count }) {
        self.screenCount = screenCount
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.willSleepNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ] {
            NSWorkspace.shared.notificationCenter.publisher(for: name).sink { [weak self] _ in
                self?.recover()
            }.store(in: &observers)
        }
        for name in [NSApplication.willTerminateNotification, NSApplication.didChangeScreenParametersNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                guard let self else { return }
                if self.screenCount() != 1 { setEnabled(false) }
                recover()
            }
                .store(in: &observers)
        }
    }

    func setEnabled(_ value: Bool) {
        release()
        enabled = value && screenCount() == 1
        failed = value && !enabled
        onRecovery?()
    }

    func release() {
        generation += 1
        lease?.invalidate()
        lease = nil
        targets = []
        active = false
    }

    func recover() {
        // Recovery also cancels a verified edit waiting for Settings to close.
        // Editing temporarily releases its lease, so absence is not a no-op.
        release()
        onRecovery?()
    }

    func conceal(_ requested: Set<String>?) {
        guard enabled else { return }
        guard screenCount() == 1, let requested else {
            release()
            failed = true
            onRecovery?()
            return
        }
        guard !requested.isEmpty else {
            release()
            failed = false
            onRecovery?()
            return
        }
        if lease != nil && targets == requested { return }
        release()
        guard FBPrivateLease.isAvailable() else {
            failed = true
            onRecovery?()
            return
        }
        failed = false
        let current = FBPrivateLease()
        lease = current
        targets = requested
        let token = generation
        var allowed = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        allowed.formUnion([
            Constants.bundleIdentifier,
            "com.apple.MenuBarAgent",
            "com.apple.appkit.status-items",
            "com.apple.MenuBarAgent.systemservices",
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
            "com.apple.notificationcenterui",
            "com.apple.TextInputMenuAgent",
            "com.apple.loginwindow",
            "com.apple.Spotlight",
        ])
        allowed.subtract(requested)
        current.activate(allowed.sorted()) { [weak self] success in
            guard let self, self.generation == token else { current.invalidate(); return }
            if success { self.active = true } else { self.failed = true; self.recover() }
        }
        // Pending activation timeout and a separate hard maximum session lease.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.generation == token, !self.active else { return }
            self.failed = true
            self.recover()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            current.invalidate()
            guard let self, self.generation == token else { return }
            self.recover()
        }
    }
}
