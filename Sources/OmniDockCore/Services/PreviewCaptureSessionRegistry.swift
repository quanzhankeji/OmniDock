import Foundation

enum PreviewCaptureMode: Equatable {
    case live
    case staticImage
}

struct PreviewCaptureSessionTermination: Equatable {
    let message: String?
}

enum PreviewCaptureSessionTerminationEvent: Equatable {
    case streamStopped
    case finished(PreviewCaptureSessionTermination)
}

protocol PreviewCaptureSessionTerminationReporting: PreviewCaptureSession {
    func setTerminationHandler(
        _ handler: @escaping (PreviewCaptureSessionTerminationEvent) -> Void
    )
}

struct PreviewCaptureSessionReconciliation: Equatable {
    let retained: Set<PreviewWindowIdentity>
    let started: Set<PreviewWindowIdentity>
    let stopped: Set<PreviewWindowIdentity>
}

final class PreviewCaptureSessionRegistry {
    private struct Entry {
        let token: UUID
        let mode: PreviewCaptureMode
        let session: any PreviewCaptureSession
        let policy: PreviewCapturePolicy
        let terminationHandler: ((
            PreviewWindowIdentity,
            PreviewCaptureMode,
            PreviewCaptureSessionTermination
        ) -> Void)?
    }

    private struct TerminatingEntry {
        let identity: PreviewWindowIdentity
        let entry: Entry
    }

    private var entries: [PreviewWindowIdentity: Entry] = [:]
    private var terminatingEntries: [UUID: TerminatingEntry] = [:]

    var liveIdentities: Set<PreviewWindowIdentity> {
        Set(entries.compactMap { identity, entry in
            entry.mode == .live ? identity : nil
        })
    }

    var identities: Set<PreviewWindowIdentity> {
        Set(entries.keys)
    }

    @discardableResult
    func reconcile(
        orderedIdentities: [PreviewWindowIdentity],
        availableIdentities: Set<PreviewWindowIdentity>,
        sourceSizes: [PreviewWindowIdentity: CGSize] = [:],
        policy: PreviewCapturePolicy,
        forcedStaticIdentities: Set<PreviewWindowIdentity> = [],
        onSessionTermination: ((
            PreviewWindowIdentity,
            PreviewCaptureMode,
            PreviewCaptureSessionTermination
        ) -> Void)? = nil,
        startSession: (
            PreviewWindowIdentity,
            PreviewCaptureMode,
            PreviewCapturePolicy
        ) -> (any PreviewCaptureSession)?
    ) -> PreviewCaptureSessionReconciliation {
        let desiredModes = desiredModes(
            orderedIdentities: orderedIdentities,
            availableIdentities: availableIdentities,
            forcedStaticIdentities: forcedStaticIdentities,
            policy: policy
        )
        let previousEntries = entries
        let terminatingIdentities = Set(terminatingEntries.values.map(\.identity))
        var nextEntries: [PreviewWindowIdentity: Entry] = [:]
        var reportersToInstall: [(
            identity: PreviewWindowIdentity,
            token: UUID,
            reporter: any PreviewCaptureSessionTerminationReporting
        )] = []
        var retained = Set<PreviewWindowIdentity>()
        var started = Set<PreviewWindowIdentity>()

        for identity in orderedIdentities {
            guard let mode = desiredModes[identity],
                  !terminatingIdentities.contains(identity)
            else {
                continue
            }

            if let existing = previousEntries[identity], existing.mode == mode {
                if let sourceSize = sourceSizes[identity] {
                    existing.session.update(policy: policy, sourceSize: sourceSize)
                } else if existing.policy != policy {
                    existing.session.update(policy: policy)
                }
                nextEntries[identity] = Entry(
                    token: existing.token,
                    mode: mode,
                    session: existing.session,
                    policy: policy,
                    terminationHandler: onSessionTermination
                )
                retained.insert(identity)
                continue
            }

            guard let session = startSession(identity, mode, policy) else {
                continue
            }
            let token = UUID()
            nextEntries[identity] = Entry(
                token: token,
                mode: mode,
                session: session,
                policy: policy,
                terminationHandler: onSessionTermination
            )
            if mode == .live,
               let reporter = session as? any PreviewCaptureSessionTerminationReporting {
                reportersToInstall.append((identity, token, reporter))
            }
            started.insert(identity)
        }

        var stopped = Set<PreviewWindowIdentity>()
        for (identity, entry) in previousEntries {
            guard nextEntries[identity]?.session !== entry.session else {
                continue
            }
            entry.session.stop()
            stopped.insert(identity)
        }

        entries = nextEntries
        for installation in reportersToInstall {
            installation.reporter.setTerminationHandler { [weak self] event in
                self?.handleTerminationEvent(
                    event,
                    identity: installation.identity,
                    token: installation.token
                )
            }
        }
        return PreviewCaptureSessionReconciliation(
            retained: retained,
            started: started,
            stopped: stopped
        )
    }

    func remove(_ identity: PreviewWindowIdentity) {
        var sessions: [any PreviewCaptureSession] = []
        if let entry = entries.removeValue(forKey: identity) {
            sessions.append(entry.session)
        }

        let terminatingTokens = terminatingEntries.compactMap { token, terminatingEntry in
            terminatingEntry.identity == identity ? token : nil
        }
        for token in terminatingTokens {
            if let terminatingEntry = terminatingEntries.removeValue(forKey: token) {
                sessions.append(terminatingEntry.entry.session)
            }
        }
        sessions.forEach { $0.stop() }
    }

    func stopAll() {
        let sessions = entries.values.map(\.session)
            + terminatingEntries.values.map { $0.entry.session }
        entries.removeAll()
        terminatingEntries.removeAll()
        sessions.forEach { $0.stop() }
    }

    private func handleTerminationEvent(
        _ event: PreviewCaptureSessionTerminationEvent,
        identity: PreviewWindowIdentity,
        token: UUID
    ) {
        switch event {
        case .streamStopped:
            guard let entry = entries[identity], entry.token == token else {
                return
            }
            entries[identity] = nil
            terminatingEntries[token] = TerminatingEntry(identity: identity, entry: entry)
        case let .finished(termination):
            let terminatingEntry: TerminatingEntry?
            if let entry = entries[identity], entry.token == token {
                entries[identity] = nil
                terminatingEntry = TerminatingEntry(identity: identity, entry: entry)
            } else {
                terminatingEntry = terminatingEntries.removeValue(forKey: token)
            }
            guard let terminatingEntry, terminatingEntry.identity == identity else {
                return
            }
            terminatingEntry.entry.terminationHandler?(
                identity,
                terminatingEntry.entry.mode,
                termination
            )
        }
    }

    private func desiredModes(
        orderedIdentities: [PreviewWindowIdentity],
        availableIdentities: Set<PreviewWindowIdentity>,
        forcedStaticIdentities: Set<PreviewWindowIdentity>,
        policy: PreviewCapturePolicy
    ) -> [PreviewWindowIdentity: PreviewCaptureMode] {
        let candidates = orderedIdentities.filter(availableIdentities.contains)
        let forcedStaticCandidates = candidates.filter(forcedStaticIdentities.contains)
        let liveCandidates = candidates.filter { !forcedStaticIdentities.contains($0) }
        let liveLimit = max(0, policy.maxStreamCount - forcedStaticCandidates.count)
        let existingLiveIdentities = liveIdentities
        var selectedLiveIdentities = Array(
            liveCandidates.filter(existingLiveIdentities.contains).prefix(liveLimit)
        )

        if selectedLiveIdentities.count < liveLimit {
            let selected = Set(selectedLiveIdentities)
            selectedLiveIdentities.append(contentsOf: liveCandidates
                .filter { !selected.contains($0) }
                .prefix(liveLimit - selectedLiveIdentities.count))
        }

        let liveSet = Set(selectedLiveIdentities)
        let staticIdentities = candidates
            .filter { !liveSet.contains($0) && !forcedStaticIdentities.contains($0) }
            .prefix(max(0, policy.maxStaticSnapshotCount))

        var modes = Dictionary(uniqueKeysWithValues: selectedLiveIdentities.map { ($0, PreviewCaptureMode.live) })
        for identity in forcedStaticCandidates {
            modes[identity] = .staticImage
        }
        for identity in staticIdentities {
            modes[identity] = .staticImage
        }
        return modes
    }
}
