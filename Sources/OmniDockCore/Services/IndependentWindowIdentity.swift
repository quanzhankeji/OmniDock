import CoreGraphics

enum IndependentWindowIdentity: Hashable {
    case windowID(CGWindowID)
    case frame(WindowFrameKey)
    case fallback(String)

    init(windowID: CGWindowID?, frame: CGRect, fallbackID: String, prefersFrame: Bool = true) {
        if prefersFrame, !frame.isEmpty {
            self = .frame(WindowFrameKey(frame))
        } else if let windowID {
            self = .windowID(windowID)
        } else if !frame.isEmpty {
            self = .frame(WindowFrameKey(frame))
        } else {
            self = .fallback(fallbackID)
        }
    }
}

struct WindowFrameKey: Hashable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(_ frame: CGRect) {
        x = Int(frame.origin.x.rounded())
        y = Int(frame.origin.y.rounded())
        width = Int(frame.size.width.rounded())
        height = Int(frame.size.height.rounded())
    }
}
