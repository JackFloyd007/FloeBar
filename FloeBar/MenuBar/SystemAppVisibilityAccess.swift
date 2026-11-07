//
//  SystemAppVisibilityAccess.swift
//  FloeBar
//

import AppKit
import ApplicationServices
import Combine
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// User-selected, strictly validated third-party application visibility.
/// The selected application remains identifiable while its status items hide.
@MainActor
final class SystemAppVisibilityAccess: ObservableObject {
    @Published private(set) var isChoosing = false
    @Published private(set) var isReadable = false
    @Published private(set) var message: String?
    @Published private(set) var visibilityDiagnostic: String?
    @Published private(set) var isChanging = false
    @Published private(set) var isReady = false
    @Published private(set) var isAllowed: Bool?
    @Published private(set) var requiresRecovery = false
    struct Application: Identifiable {
        let id: String
        let name: String
        let icon: NSImage?
        let allowed: Bool?
        let unavailableReason: String?
    }
    @Published private(set) var applications: [Application] = []
    @Published private(set) var selectedBundles: Set<String> = {
        let defaults = UserDefaults.standard
        let key = "SystemMenuBarSelectedApplications.v2"
        if defaults.object(forKey: key) == nil {
            let migrated = defaults.bool(forKey: "SystemMenuBarFigmaSelected.v1") ? ["com.figma.Desktop"] : []
            defaults.set(migrated, forKey: key)
        }
        return Set(defaults.stringArray(forKey: key) ?? [])
    }()
    var isTargetSelected: Bool { !selectedBundles.isEmpty }
    var hasOwnedChanges: Bool { backend.hasJournal }
    var hasPendingRestoration: Bool { hasOwnedChanges || requiresRecovery }
    var shouldRouteToApplicationVisibility: Bool { isTargetSelected || hasPendingRestoration }
    var canEditSelection: Bool { isReady && !isChanging && !isChoosing && !isTerminating && !requiresRecovery }
    var onAllowedChanged: ((Bool) -> Void)?
    var canChangeVisibility: (() -> Bool)?
    var discoveredMenuOwners: (() -> [String: Set<pid_t>])?
    private let backend = SystemAppVisibilityBackend()
    private let visibilityVerifier = SystemAppVisibilityVerifier()
    private static let visibilityDiagnosticsEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["FLOEBAR_VISIBILITY_DIAGNOSTICS"] == "1"
        #else
        false
        #endif
    }()
    private var verificationTask: Task<Bool, Never>?
    private var mutationTask: Task<Void, Never>?
    private var isTerminating = false
    private var startupRecoveryPending = true
    private let bookmarkKey = "SystemMenuBarPreferencesBookmark.v1"
    private let logger = Logger(category: "SystemAppVisibility")

    init() {
        backend.reopenAuthorizedSnapshot = { [weak self] url in
            guard let self, SystemMenuBarFilePolicy.accepts(url) else { throw SystemAppVisibilityBackend.Failure.unavailable }
            let lease = try self.openAuthorizedFile(purpose: "snapshot-reopen")
            defer { if lease.accessing { lease.scope.stopAccessingSecurityScopedResource() } }
            return lease.data
        }
    }

    func chooseFile() async {
        guard !isChoosing, !isChanging, !isTerminating else { return }
        isChoosing = true
        defer { isChoosing = false }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.propertyList]
        panel.directoryURL = SystemMenuBarFilePolicy.expectedURL.deletingLastPathComponent()
        panel.nameFieldStringValue = SystemMenuBarFilePolicy.expectedURL.lastPathComponent
        panel.message = String(localized: "Choose the system menu bar preferences file so FloeBar can read visibility and restore its own changes.")
        guard await panel.begin() == .OK, let url = panel.url else { return }
        guard SystemMenuBarFilePolicy.accepts(url) else {
            message = String(localized: "Choose the system menu bar preferences file shown in this dialog.")
            return
        }
        guard !isTerminating else { return }
        let task = Task { [self] in
            defer { mutationTask = nil }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let canonical = SystemMenuBarFilePolicy.expectedURL
                try inspect(canonical)
                let bookmark = try canonical.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
                isReadable = true
                try await refreshAuthorizedState(canonical, recovering: backend.hasJournal)
            } catch {
                isReadable = false
                isReady = false
                message = String(localized: "Unable to read the selected system menu bar preferences file.")
                logger.error("System menu bar access check failed: \(String(describing: error), privacy: .public)")
            }
        }
        mutationTask = task
        await task.value
    }

    func checkSavedAccess(recovering: Bool? = nil) async {
        guard !isChoosing, !isChanging, !isTerminating, !isReady else { return }
        isChanging = true
        let task = Task { [self] in
            defer { isChanging = false; mutationTask = nil }
            do {
                try await withAuthorizedFileAsync { url in
                    try self.inspect(url)
                    self.isReadable = true
                    try await self.refreshAuthorizedState(url, recovering: (recovering ?? self.startupRecoveryPending) && self.backend.hasJournal)
                }
            } catch {
                isReady = false
                message = backend.hasJournal
                    ? String(localized: "Application visibility could not be restored.")
                    : String(localized: "Application visibility is not confirmed. Check file access or refresh before trying again.")
                logger.error("Saved system menu bar access failed error=\(String(describing: error), privacy: .public); journal=\(self.backend.hasJournal)")
            }
        }
        mutationTask = task
        await task.value
    }

    func hasOwnedApplicationChange(_ bundle: String) -> Bool {
        isReady && !requiresRecovery && backend.ownsSource(bundle)
    }

    var startupRecoveryMessage: String? { backend.hasJournal && !isReady ? message : nil }
    var blocksMenuBarChanges: Bool { isChanging || isChoosing || isTerminating || requiresRecovery || (backend.hasJournal && !isReady) }

    /// Keep the selected URL's security token alive; a narrowly classified
    /// exact-file access failure can reopen the existing bookmark without UI.
    private func openAuthorizedFile(purpose: String = "operation") throws -> (file: URL, scope: URL, accessing: Bool, data: Data) {
        var stage = "bookmark-data"
        var activeScope: URL?
        do {
            guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { throw SystemAppVisibilityBackend.Failure.unavailable }
            stage = "bookmark-resolution"
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            let exact = SystemMenuBarFilePolicy.accepts(url)
            logger.notice("System file access purpose=\(purpose, privacy: .public) stage=resolved exact_target=\(exact) stale=\(stale)")
            guard exact else { throw SystemAppVisibilityBackend.Failure.unavailable }
            let accessing = url.startAccessingSecurityScopedResource()
            if accessing { activeScope = url }
            let canonical = SystemMenuBarFilePolicy.expectedURL
            stage = "scoped-file-read"
            let data = try SystemMenuBarFilePolicy.validateAccess(
                url: url,
                stale: stale,
                read: { try Data(contentsOf: canonical) },
                renew: {
                    let updated = try canonical.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                    UserDefaults.standard.set(updated, forKey: self.bookmarkKey)
                    self.logger.notice("System file stale bookmark refreshed after successful exact-target scoped read")
                }
            )
            logger.notice("System file access stage=validated scope_started=\(accessing)")
            return (canonical, url, accessing, data)
        } catch {
            activeScope?.stopAccessingSecurityScopedResource()
            let failure = error as NSError
            logger.error("System file access failed stage=\(stage, privacy: .public) domain=\(failure.domain, privacy: .public) code=\(failure.code)")
            throw error
        }
    }

    private func withAuthorizedFile<T>(_ operation: (URL) throws -> T) throws -> T {
        let lease = try openAuthorizedFile()
        defer { if lease.accessing { lease.scope.stopAccessingSecurityScopedResource() } }
        return try operation(lease.file)
    }

    private func withAuthorizedFileAsync<T>(_ operation: (URL) async throws -> T) async throws -> T {
        let lease = try openAuthorizedFile()
        defer { if lease.accessing { lease.scope.stopAccessingSecurityScopedResource() } }
        return try await operation(lease.file)
    }

    private func candidateStates(_ url: URL) async throws -> [String: Bool] {
        let owners = discoveredMenuOwners?() ?? [:]
        for (bundle, pids) in owners.sorted(by: { $0.key < $1.key }).prefix(64) {
            logger.notice("Native application catalog menu_source=\(bundle, privacy: .public) source_pids=\(pids.sorted().map(String.init).joined(separator: ","), privacy: .public)")
        }
        return try await backend.candidates(url, discovering: Set(owners.keys))
    }

    private func publish(_ states: [String: Bool]) {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let discovered = Set((discoveredMenuOwners?() ?? [:]).keys).intersection(running).map { backend.displayRoot(for: $0) }
        let bundles = Set(states.keys.filter { !backend.memberBundles(for: $0).isDisjoint(with: running) }).union(selectedBundles).union(discovered)
        applications = bundles.compactMap { bundle in
            guard SystemAppVisibilityModel.eligible(bundle, own: Constants.bundleIdentifier) else { return nil }
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            let installed = url.flatMap { Bundle(url: $0) }?.bundleIdentifier == bundle
            // Stopped/unknown applications stay visible only to remove a saved
            // selection. They cannot become new mutation targets.
            let active = !backend.memberBundles(for: bundle).isDisjoint(with: running)
            let allowed = installed && active ? states[bundle] : nil
            let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundle
            let reason: String?
            if !active { reason = String(localized: "Not running") } else if !installed { reason = String(localized: "Unverified app identity") } else if states[bundle] == nil { reason = String(localized: "Not supported yet") } else { reason = nil }
            return Application(id: bundle, name: name, icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) }, allowed: allowed, unavailableReason: reason)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let selected = applications.filter { selectedBundles.contains($0.id) }
        isAllowed = !selectedBundles.isEmpty && selected.count == selectedBundles.count && selected.allSatisfy { $0.allowed != nil }
            ? selected.allSatisfy { $0.allowed == true } : nil
        onAllowedChanged?(!hasPendingRestoration)
    }

    private func refreshAuthorizedState(_ url: URL, recovering: Bool) async throws {
        if recovering {
            try await backend.restoreAll(url: url)
            guard !backend.hasJournal else { throw SystemAppSelectionEdit.Failure.journalRemaining }
            logger.notice("Native application startup restoration completed; checking fresh application state before new edits")
        }
        publish(try await candidateStates(url))
        if recovering {
            requiresRecovery = false
            onAllowedChanged?(true)
            logger.notice("Native application startup recovery completed before new edits")
        }
        isReady = true
        startupRecoveryPending = false
        message = requiresRecovery ? String(localized: "Application changes need recovery. Restore applications before editing the selection.") : nil
    }

    func setSelected(_ bundle: String, selected: Bool) {
        guard canEditSelection, let application = applications.first(where: { $0.id == bundle }),
            selected != selectedBundles.contains(bundle), !selected || application.allowed == true else { return }
        guard canChangeVisibility?() != false else {
            message = String(localized: "Application visibility is not ready. Finish the current operation or check file access.")
            return
        }
        let collapsed = backend.hasJournal
        isChanging = true
        visibilityDiagnostic = nil
        message = String(localized: "Application visibility is changing. Try again after it finishes.")
        mutationTask = Task { [weak self] in
            guard let self else { return }
            defer { isChanging = false; mutationTask = nil }
            do {
                guard isReady, !requiresRecovery, !isTerminating, canChangeVisibility?() != false else { throw NativeReorderFailure.visibilityChanging }
                try await withAuthorizedFileAsync { url in
                    let owned = try self.backend.ownedBundles().contains(bundle)
                    if selected {
                        self.publish(try await self.candidateStates(url))
                        guard self.applications.first(where: { $0.id == bundle })?.allowed == true else { throw SystemAppVisibilityBackend.Failure.unavailable }
                    }
                    guard !self.isTerminating else { throw NativeReorderFailure.visibilityChanging }
                    try await SystemAppSelectionEdit.perform(
                        selected: selected,
                        collapsed: collapsed,
                        requiresRecovery: self.requiresRecovery,
                        target: bundle,
                        expectedAllowed: selected && collapsed ? false : !selected && owned ? true : nil,
                        hide: { try await self.backend.hide(bundle: bundle, url: url) },
                        restoreOwned: { try await self.backend.restoreOwned(bundle: bundle, url: url) },
                        read: { try await self.candidateStates(url) },
                        commit: { states in
                            if selected { self.selectedBundles.insert(bundle) } else { self.selectedBundles.remove(bundle) }
                            UserDefaults.standard.set(self.selectedBundles.sorted(), forKey: "SystemMenuBarSelectedApplications.v2")
                            self.publish(states)
                        },
                        failed: { self.requiresRecovery = true }
                    )
                }
                message = String(localized: "Application selection updated.")
                logger.notice("Native application selection committed target=\(bundle, privacy: .public) selected=\(selected) collapsed=\(collapsed); other applications unchanged")
            } catch {
                requiresRecovery = true
                if let states = try? await withAuthorizedFileAsync({ try await self.candidateStates($0) }) { publish(states) }
                message = String(localized: "Application changes need recovery. Restore applications before editing the selection.")
                logger.error("Native application selection stopped target=\(bundle, privacy: .public) error=\(String(describing: error), privacy: .public); choice not committed; no automatic replay")
            }
        }
    }

    private func restoreApplicationChanges() {
        isChanging = true
        visibilityDiagnostic = nil
        message = String(localized: "Application visibility is changing. Try again after it finishes.")
        mutationTask = Task { [weak self] in
            guard let self else { return }
            defer { isChanging = false; mutationTask = nil }
            do {
                guard !isTerminating, canChangeVisibility?() != false else { throw NativeReorderFailure.visibilityChanging }
                try await withAuthorizedFileAsync { url in
                    try await SystemAppSelectionEdit.recover(
                        restoreAll: { try await self.backend.restoreAll(url: url) },
                        journalExists: { self.backend.hasJournal },
                        read: { try await self.candidateStates(url) },
                        commit: { states in
                            self.requiresRecovery = false
                            self.isReadable = true
                            self.isReady = true
                            self.startupRecoveryPending = false
                            self.publish(states)
                        },
                        failed: { self.requiresRecovery = true }
                    )
                }
                message = String(localized: "Show setting applied.")
                visibilityDiagnostic = String(localized: "Physical menu bar visibility is not automatically checked.")
                logger.notice("Native application recovery completed; owned journal empty; selection edits enabled")
            } catch {
                requiresRecovery = true
                if let states = try? await withAuthorizedFileAsync({ try await self.candidateStates($0) }) { publish(states) }
                message = String(localized: "Application visibility could not be restored.")
                logger.error("Native application restoration stopped: \(String(describing: error), privacy: .public); journal retained")
            }
        }
    }

    func refresh() {
        guard !isChanging, !isChoosing, !isTerminating else { return }
        let needsRecovery = startupRecoveryPending
        isReady = false
        Task { await checkSavedAccess(recovering: needsRecovery) }
    }

    func changeSelected(expanded: Bool?) {
        guard !isChanging, !isChoosing, !isTerminating else { return }
        let restoreIntent = expanded ?? hasPendingRestoration
        guard canChangeVisibility?() != false else {
            message = String(localized: "Application visibility is not ready. Finish the current operation or check file access.")
            return
        }
        if restoreIntent {
            restoreApplicationChanges()
            return
        }
        guard isReady, !requiresRecovery, !selectedBundles.isEmpty else {
            message = String(localized: "Application visibility is not ready. Finish the current operation or check file access.")
            return
        }
        let bundles = selectedBundles.sorted()
        isChanging = true
        visibilityDiagnostic = nil
        message = String(localized: "Application visibility is changing. Try again after it finishes.")
        mutationTask = Task { [weak self] in
            guard let self else { return }
            defer { isChanging = false; mutationTask = nil }
            do {
                guard isReady, canChangeVisibility?() != false else { throw NativeReorderFailure.visibilityChanging }
                let allowed = try await withAuthorizedFileAsync { url in
                    let states = try await self.candidateStates(url)
                    self.publish(states)
                    let desired = expanded ?? self.backend.hasJournal
                    let available = Dictionary(uniqueKeysWithValues: self.applications.compactMap { application in
                        application.allowed.map { (application.id, $0) }
                    })
                    let active = desired ? bundles : SystemAppVisibilityModel.manageableSelection(self.selectedBundles, available: available)
                    guard !active.isEmpty else {
                        self.message = String(localized: "No selected applications are available to hide. Open an application or refresh the list.")
                        return (expanded: desired, active: active, skipped: bundles.count, evidence: [String: SystemAppVisibilityVerifier.Baseline](), hostEvidence: Optional<SystemAppVisibilityVerifier.HostBaseline>.none)
                    }
                    let evidence = desired || !Self.visibilityDiagnosticsEnabled ? [:] : await self.visibilityVerifier.capture(bundles: active)
                    let hostEvidence = desired || !Self.visibilityDiagnosticsEnabled ? nil : await self.visibilityVerifier.captureHost(bundles: active, sources: evidence)
                    try Task.checkCancellation()
                    guard !self.isTerminating, self.canChangeVisibility?() != false else { throw NativeReorderFailure.visibilityChanging }
                    try await self.backend.change(bundles: active, expanded: desired, url: url)
                    return (expanded: desired, active: active, skipped: desired ? 0 : bundles.count - active.count, evidence: evidence, hostEvidence: hostEvidence)
                }
                guard !allowed.active.isEmpty, !isTerminating else { return }
                var confirmed = false
                if Self.visibilityDiagnosticsEnabled {
                    message = String(localized: "System setting applied. Verifying menu bar visibility…")
                    let verification = Task { [self] in
                        if !allowed.expanded {
                            guard let host = allowed.hostEvidence else { return false }
                            return await self.visibilityVerifier.hiddenInHost(host)
                        }
                        var visible = true
                        for bundle in allowed.active {
                            guard !Task.isCancelled else { return false }
                            let proven = await self.verifyNativeVisibility(bundle: bundle, allowed: true)
                            visible = proven && visible
                        }
                        return visible
                    }
                    verificationTask = verification
                    confirmed = await verification.value
                    verificationTask = nil
                }
                guard !isTerminating else { return }
                let states = try await withAuthorizedFileAsync { try await self.candidateStates($0) }
                publish(states)
                if Self.visibilityDiagnosticsEnabled {
                    if confirmed && allowed.active.allSatisfy({ states[$0] == allowed.expanded }) {
                        visibilityDiagnostic = allowed.expanded
                            ? String(localized: "Each selected application has a visible menu bar item.")
                            : String(localized: "Selected applications are hidden in the current menu bar.")
                    } else {
                        visibilityDiagnostic = String(localized: "System setting applied; actual menu bar visibility is not confirmed.")
                    }
                } else {
                    visibilityDiagnostic = String(localized: "Physical menu bar visibility is not automatically checked.")
                }
                let result = allowed.expanded
                    ? String(localized: "Show setting applied.")
                    : String(localized: "Hide setting applied.")
                message = result + " " + String.localizedStringWithFormat(String(localized: "Skipped applications: %lld."), allowed.skipped)
                logger.notice("Native application request applied expanded=\(allowed.expanded) diagnostic_requested=\(Self.visibilityDiagnosticsEnabled) skipped=\(allowed.skipped); system setting success is separate from physical evidence")
            } catch {
                requiresRecovery = true
                logger.error("Native application batch stopped: \(String(describing: error), privacy: .public); no automatic replay")
                if let states = try? await withAuthorizedFileAsync({ try await self.candidateStates($0) }) { publish(states) }
                message = backend.hasJournal
                    ? String(localized: "Applications may have changed. Use Show before editing.")
                    : String(localized: "Application visibility is not confirmed. Check file access or refresh before trying again.")
            }
        }
    }

    @available(macOS 27.0, *)
    private func verifyNativeVisibility27(bundle: String, allowed: Bool) async -> Bool {
        // Host AX exposes anonymous proxies and retains old owner nodes here.
        // No reliable hidden identity exists, so never infer absence from zero
        // hits, empty names or a filtered owner snapshot.
        guard allowed, AXIsProcessTrusted(), let display = Bridging.getActiveMenuBarDisplayID() else { return false }
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map(\.processIdentifier))
        guard !pids.isEmpty else { return false }
        let context = NativeMenuBarScanContext(purpose: "application-visibility", budget: 3)
        for _ in 0..<4 {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return false }
            guard display == Bridging.getActiveMenuBarDisplayID(),
                Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map(\.processIdentifier)) == pids else { return false }
            let result = await MacOS27MenuBarItemProvider.menuBarItems(
                sourcePIDs: pids, namespaces: [.string(bundle)], on: display, context: context
            )
            if let items = result.completeValue {
                let targetItems = items.filter { $0.tag.namespace == .string(bundle) }
                let hits = targetItems.filter { MacOS27MenuBarItemProvider.nativeHitMatches($0) }.count
                logger.notice("Native application AX verification target=\(bundle, privacy: .public) allowed=\(allowed) items=\(targetItems.count) exact_hits=\(hits)")
                if SystemAppVisibilityModel.visibilityConfirmed(allowed: allowed, exactHits: hits) { return true }
            }
        }
        return false
    }

    private func verifyNativeVisibility(bundle: String, allowed: Bool) async -> Bool {
        if #available(macOS 27.0, *) { return await verifyNativeVisibility27(bundle: bundle, allowed: allowed) }
        return false
    }

    /// Termination must wait for the in-flight change and its verification.
    /// New input is disabled before suspension, then only owned state restores.
    func beginTermination() {
        isTerminating = true
        verificationTask?.cancel()
    }

    func prepareForTermination() async -> Bool {
        beginTermination()
        if let mutationTask { await mutationTask.value }
        guard backend.hasJournal else { return true }
        do {
            guard canChangeVisibility?() != false else { throw NativeReorderFailure.visibilityChanging }
            try await withAuthorizedFileAsync { try await self.backend.restoreAll(url: $0) }
            if let states = try? await withAuthorizedFileAsync({ try await self.candidateStates($0) }) { publish(states) }
            return true
        } catch {
            isTerminating = false
            requiresRecovery = true
            logger.error("Native application quit recovery failed; journal retained: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    var needsTerminationRecovery: Bool { isChanging || mutationTask != nil || backend.hasJournal }

    private func inspect(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let lines = try SystemMenuBarFilePolicy.inspect(data, own: Constants.bundleIdentifier)
        logger.notice("System menu bar file readable bytes=\(data.count); no values changed")
        for line in lines { logger.notice("System menu bar inspection \(line, privacy: .public)") }
    }
}

/// Native application metadata and controls; only the application rows scroll.
struct SystemAppVisibilityAccessView: View {
    @ObservedObject var access: SystemAppVisibilityAccess
    @State private var isFileAccessExpanded = false
    @State private var isStatusDetailsExpanded = false

    private let statusColumnWidth: CGFloat = 110
    private let selectionColumnWidth: CGFloat = 120

    private var unavailableSelectionCount: Int {
        access.applications.filter { access.selectedBundles.contains($0.id) && $0.allowed == nil }.count
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 430
            VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                header
                applicationTable
                secondaryDetails(compact: compact)
                Divider()
                footer
            }
            .padding(compact ? 14 : 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task {
            // Reopen the catalog read-only so newly discovered menu owners
            // appear without altering an already hidden application group.
            if access.isReady { access.refresh() } else { await access.checkSavedAccess() }
            if !access.isReadable { isFileAccessExpanded = true }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button("Refresh List") { access.refresh() }
                    .disabled(access.isChoosing || access.isChanging)
            }
            Text("The arrow controls all menu bar items of each selected application.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var applicationTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Application").frame(maxWidth: .infinity, alignment: .leading)
                Text("System setting").frame(width: statusColumnWidth, alignment: .leading)
                Text("Controlled by arrow").frame(width: selectionColumnWidth)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.primary.opacity(0.04))
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(access.applications) { application in
                        applicationRow(application)
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary) }
    }

    @ViewBuilder
    private func secondaryDetails(compact: Bool) -> some View {
        if compact {
            HStack(alignment: .top, spacing: 16) {
                statusDetails.frame(maxWidth: .infinity, alignment: .leading)
                fileAccessDetails.frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                statusDetails
                fileAccessDetails
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private var statusDetails: some View {
        if let diagnostic = access.visibilityDiagnostic {
            DisclosureGroup("Status details", isExpanded: $isStatusDetailsExpanded) {
                Text(verbatim: diagnostic).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var fileAccessDetails: some View {
        DisclosureGroup(isExpanded: $isFileAccessExpanded) {
            Button("Choose System Menu Bar File…") { Task { await access.chooseFile() } }
                .disabled(access.isChoosing || access.isChanging)
                .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text("File access")
                Text(access.isReadable ? String(localized: "Authorized") : String(localized: "Not authorized"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: String.localizedStringWithFormat(
                    String(localized: "%lld applications selected · %lld unavailable"),
                    access.selectedBundles.count,
                    unavailableSelectionCount
                ))
                .font(.callout.weight(.medium))
                if let message = access.message {
                    Text(verbatim: message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(access.requiresRecovery ? String(localized: "Restore Applications") : access.hasOwnedChanges ? String(localized: "Show Selected Applications") : String(localized: "Hide Selected Applications")) {
                access.changeSelected(expanded: access.hasPendingRestoration)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .fixedSize()
            .disabled(access.isChoosing || access.isChanging || (!access.hasPendingRestoration && (!access.isReady || access.selectedBundles.isEmpty)))
        }
        .padding(.top, 4)
    }

    private func applicationRow(_ application: SystemAppVisibilityAccess.Application) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Group {
                    if let icon = application.icon {
                        Image(nsImage: icon).resizable().scaledToFit()
                    } else {
                        Image(systemName: "app").resizable().scaledToFit().foregroundStyle(.secondary)
                    }
                }
                .frame(width: 24, height: 24)
                Text(verbatim: application.name)
                    .lineLimit(1).truncationMode(.tail)
                    .help(application.name)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(application.allowed == nil ? application.unavailableReason ?? String(localized: "Unavailable") : application.allowed == false ? String(localized: "Set to hidden") : String(localized: "Allowed to show"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: statusColumnWidth, alignment: .leading)
                .help(application.unavailableReason ?? "")

            Toggle(isOn: Binding(
                get: { access.selectedBundles.contains(application.id) },
                set: { access.setSelected(application.id, selected: $0) }
            )) { Text(verbatim: application.name) }
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel(Text(verbatim: application.name))
            .help(String(localized: "Select applications for the FloeBar arrow. Hiding affects every menu bar item belonging to each selected application."))
            .frame(width: selectionColumnWidth)
            .disabled(!access.canEditSelection || (application.allowed != true && !access.selectedBundles.contains(application.id)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 38)
    }
}

/// Available even if Accessibility is missing: restoring the preference needs
/// the prior file grant, not AX setup, input listeners or pixel capture.
struct SystemAppVisibilityRecoveryView: View {
    @ObservedObject var access: SystemAppVisibilityAccess

    var body: some View {
        if let message = access.startupRecoveryMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: message)
                Button("Choose System Menu Bar File…") { Task { await access.chooseFile() } }
                    .disabled(access.isChoosing)
            }
            .font(.callout)
            .padding(.bottom)
        }
    }
}
