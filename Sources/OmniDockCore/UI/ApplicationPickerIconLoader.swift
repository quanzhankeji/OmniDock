import AppKit

private struct LoadedApplicationIcon: @unchecked Sendable {
    let image: NSImage
}

final class ApplicationPickerIconLoader: @unchecked Sendable {
    typealias IconProvider = @Sendable (String) -> NSImage

    private let queue = DispatchQueue(
        label: "com.omnidock.application-picker-icons",
        qos: .userInitiated
    )
    private let iconProvider: IconProvider

    init(iconProvider: @escaping IconProvider = { path in
        NSWorkspace.shared.icon(forFile: path)
    }) {
        self.iconProvider = iconProvider
    }

    func loadIcon(
        atPath path: String,
        completion: @escaping @MainActor @Sendable (NSImage) -> Void
    ) {
        queue.async { [iconProvider] in
            let loadedIcon = LoadedApplicationIcon(image: iconProvider(path))
            Task { @MainActor in
                loadedIcon.image.size = CGSize(width: 32, height: 32)
                completion(loadedIcon.image)
            }
        }
    }
}
