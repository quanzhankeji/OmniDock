import CoreGraphics

struct PreviewCaptureWindowCandidate {
    let info: PreviewWindowInfo
    let isOnScreen: Bool
}

enum PreviewWindowCatalog {
    static func mergeForDisplay(
        axWindows: [PreviewWindowInfo],
        shareableWindows: [PreviewWindowInfo]
    ) -> [PreviewWindowInfo] {
        let collapsedAXWindows = collapseTabbedWindows(axWindows)
        let collapsedShareableWindows = collapseTabbedWindows(
            shareableWindows,
            prefersFrameIdentity: false
        )

        guard !collapsedShareableWindows.isEmpty else {
            return stableDisplayOrder(collapsedAXWindows)
        }

        let shareableIdentities = Set(collapsedShareableWindows.map { independentIdentity(for: $0) })
        let minimizedAXWindows = collapsedAXWindows.filter { axWindow in
            axWindow.isMinimized && !shareableIdentities.contains(independentIdentity(for: axWindow))
        }

        return stableDisplayOrder(collapsedShareableWindows + minimizedAXWindows)
    }

    static func collapseTabbedWindows(
        _ windows: [PreviewWindowInfo],
        prefersFrameIdentity: Bool = true
    ) -> [PreviewWindowInfo] {
        var seen = Set<IndependentWindowIdentity>()
        var collapsed: [PreviewWindowInfo] = []
        for window in windows {
            let identity = IndependentWindowIdentity(
                windowID: window.windowID,
                frame: window.frame,
                fallbackID: window.id,
                prefersFrame: prefersFrameIdentity
            )
            guard seen.insert(identity).inserted else {
                continue
            }
            collapsed.append(window)
        }
        return collapsed
    }

    static func stableDisplayOrder(_ windows: [PreviewWindowInfo]) -> [PreviewWindowInfo] {
        windows.sorted { lhs, rhs in
            switch (lhs.windowID, rhs.windowID) {
            case let (lhsID?, rhsID?) where lhsID != rhsID:
                return lhsID < rhsID
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                if lhs.title != rhs.title {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhs.id < rhs.id
            }
        }
    }

    static func reconcileCaptureCandidates(
        axWindows: [PreviewWindowInfo],
        candidates: [PreviewCaptureWindowCandidate]
    ) -> [PreviewCaptureWindowCandidate] {
        var unmatchedAXWindows = axWindows.filter { !$0.isMinimized }
        var acceptedCandidateIDs = Set<String>()

        for candidate in candidates where candidate.isOnScreen {
            acceptedCandidateIDs.insert(candidate.info.id)
            consumeBestAvailableAXMatch(for: candidate.info, from: &unmatchedAXWindows)
        }

        consumeExactWindowIDMatches(
            candidates: candidates,
            acceptedCandidateIDs: &acceptedCandidateIDs,
            unmatchedAXWindows: &unmatchedAXWindows
        )
        consumeUniqueTitleAndFrameMatches(
            candidates: candidates,
            acceptedCandidateIDs: &acceptedCandidateIDs,
            unmatchedAXWindows: &unmatchedAXWindows
        )
        consumeUniqueFrameMatches(
            candidates: candidates,
            acceptedCandidateIDs: &acceptedCandidateIDs,
            unmatchedAXWindows: &unmatchedAXWindows
        )

        return candidates.filter { acceptedCandidateIDs.contains($0.info.id) }
    }

    private static func independentIdentity(for window: PreviewWindowInfo) -> IndependentWindowIdentity {
        IndependentWindowIdentity(
            windowID: window.windowID,
            frame: window.frame,
            fallbackID: window.id,
            prefersFrame: true
        )
    }

    private static func consumeBestAvailableAXMatch(
        for candidate: PreviewWindowInfo,
        from windows: inout [PreviewWindowInfo]
    ) {
        if let windowID = candidate.windowID,
           let index = windows.firstIndex(where: { $0.windowID == windowID }) {
            windows.remove(at: index)
            return
        }

        let candidateTitle = normalizedTitle(candidate.title)
        if !candidateTitle.isEmpty,
           let index = windows.firstIndex(where: {
               normalizedTitle($0.title) == candidateTitle && framesMatch($0.frame, candidate.frame)
           }) {
            windows.remove(at: index)
            return
        }

        if let index = windows.firstIndex(where: { framesMatch($0.frame, candidate.frame) }) {
            windows.remove(at: index)
        }
    }

    private static func consumeExactWindowIDMatches(
        candidates: [PreviewCaptureWindowCandidate],
        acceptedCandidateIDs: inout Set<String>,
        unmatchedAXWindows: inout [PreviewWindowInfo]
    ) {
        for candidate in candidates where !candidate.isOnScreen && !acceptedCandidateIDs.contains(candidate.info.id) {
            guard let windowID = candidate.info.windowID else {
                continue
            }
            let matchingIndices = unmatchedAXWindows.indices.filter {
                unmatchedAXWindows[$0].windowID == windowID
            }
            guard matchingIndices.count == 1, let index = matchingIndices.first else {
                continue
            }
            acceptedCandidateIDs.insert(candidate.info.id)
            unmatchedAXWindows.remove(at: index)
        }
    }

    private static func consumeUniqueTitleAndFrameMatches(
        candidates: [PreviewCaptureWindowCandidate],
        acceptedCandidateIDs: inout Set<String>,
        unmatchedAXWindows: inout [PreviewWindowInfo]
    ) {
        for candidate in candidates where !candidate.isOnScreen && !acceptedCandidateIDs.contains(candidate.info.id) {
            let title = normalizedTitle(candidate.info.title)
            guard !title.isEmpty else {
                continue
            }

            let matchingCandidates = candidates.filter {
                !$0.isOnScreen
                    && !acceptedCandidateIDs.contains($0.info.id)
                    && normalizedTitle($0.info.title) == title
                    && framesMatch($0.info.frame, candidate.info.frame)
            }
            let matchingAXIndices = unmatchedAXWindows.indices.filter {
                normalizedTitle(unmatchedAXWindows[$0].title) == title
                    && framesMatch(unmatchedAXWindows[$0].frame, candidate.info.frame)
            }
            guard matchingCandidates.count == 1,
                  matchingAXIndices.count == 1,
                  let index = matchingAXIndices.first
            else {
                continue
            }

            acceptedCandidateIDs.insert(candidate.info.id)
            unmatchedAXWindows.remove(at: index)
        }
    }

    private static func consumeUniqueFrameMatches(
        candidates: [PreviewCaptureWindowCandidate],
        acceptedCandidateIDs: inout Set<String>,
        unmatchedAXWindows: inout [PreviewWindowInfo]
    ) {
        for candidate in candidates where !candidate.isOnScreen && !acceptedCandidateIDs.contains(candidate.info.id) {
            let matchingCandidates = candidates.filter {
                !$0.isOnScreen
                    && !acceptedCandidateIDs.contains($0.info.id)
                    && framesMatch($0.info.frame, candidate.info.frame)
            }
            let matchingAXIndices = unmatchedAXWindows.indices.filter {
                framesMatch(unmatchedAXWindows[$0].frame, candidate.info.frame)
            }
            guard matchingCandidates.count == 1,
                  matchingAXIndices.count == 1,
                  let index = matchingAXIndices.first
            else {
                continue
            }

            acceptedCandidateIDs.insert(candidate.info.id)
            unmatchedAXWindows.remove(at: index)
        }
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        WindowFrameKey(lhs) == WindowFrameKey(rhs)
    }
}
