import FinderSync

enum FinderExtensionActivation {
    static var isEnabledInFinder: Bool {
        FIFinderSyncController.isExtensionEnabled
    }

    static func showManagementInterface() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    static func requiresManualActivation(
        isFeatureEnabled: Bool,
        isExtensionEnabledInFinder: Bool
    ) -> Bool {
        isFeatureEnabled && !isExtensionEnabledInFinder
    }
}
