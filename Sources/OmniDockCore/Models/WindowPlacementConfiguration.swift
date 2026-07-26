import Foundation

struct WindowPlacementRegion: Codable, Equatable, Hashable {
    static let columns = 24
    static let rows = 12
    static let full = WindowPlacementRegion(x: 0, y: 0, width: 1, height: 1)

    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        let safeX = min(max(x, 0), 1)
        let safeY = min(max(y, 0), 1)
        self.x = safeX
        self.y = safeY
        self.width = min(max(width, 0), 1 - safeX)
        self.height = min(max(height, 0), 1 - safeY)
    }

    init(column: Int, row: Int, columnSpan: Int, rowSpan: Int) {
        self.init(
            x: Double(column) / Double(Self.columns),
            y: Double(row) / Double(Self.rows),
            width: Double(columnSpan) / Double(Self.columns),
            height: Double(rowSpan) / Double(Self.rows)
        )
    }

    var isEmpty: Bool {
        width <= 0 || height <= 0
    }

    func frame(in container: CGRect) -> CGRect {
        CGRect(
            x: container.minX + container.width * x,
            y: container.minY + container.height * y,
            width: container.width * width,
            height: container.height * height
        ).integral
    }

    func intersects(_ other: WindowPlacementRegion) -> Bool {
        guard !isEmpty, !other.isEmpty else {
            return false
        }
        return x < other.x + other.width
            && x + width > other.x
            && y < other.y + other.height
            && y + height > other.y
    }

    static func gridSelection(from start: (column: Int, row: Int), to end: (column: Int, row: Int)) -> Self {
        let lowerColumn = min(max(min(start.column, end.column), 0), columns - 1)
        let upperColumn = min(max(max(start.column, end.column), 0), columns - 1)
        let lowerRow = min(max(min(start.row, end.row), 0), rows - 1)
        let upperRow = min(max(max(start.row, end.row), 0), rows - 1)
        return Self(
            column: lowerColumn,
            row: lowerRow,
            columnSpan: upperColumn - lowerColumn + 1,
            rowSpan: upperRow - lowerRow + 1
        )
    }

    var gridBounds: WindowPlacementGridBounds {
        WindowPlacementGridBounds(region: self)
    }
}

struct WindowPlacementGridBounds: Equatable {
    var minimumColumn: Int
    var maximumColumn: Int
    var minimumRow: Int
    var maximumRow: Int

    init(
        minimumColumn: Int,
        maximumColumn: Int,
        minimumRow: Int,
        maximumRow: Int
    ) {
        self.minimumColumn = min(
            max(minimumColumn, 0),
            WindowPlacementRegion.columns - 1
        )
        self.maximumColumn = min(
            max(maximumColumn, self.minimumColumn),
            WindowPlacementRegion.columns - 1
        )
        self.minimumRow = min(
            max(minimumRow, 0),
            WindowPlacementRegion.rows - 1
        )
        self.maximumRow = min(
            max(maximumRow, self.minimumRow),
            WindowPlacementRegion.rows - 1
        )
    }

    init(region: WindowPlacementRegion) {
        let columnScale = Double(WindowPlacementRegion.columns)
        let rowScale = Double(WindowPlacementRegion.rows)
        self.init(
            minimumColumn: Int(floor(region.x * columnScale)),
            maximumColumn: Int(ceil((region.x + region.width) * columnScale)) - 1,
            minimumRow: Int(floor(region.y * rowScale)),
            maximumRow: Int(ceil((region.y + region.height) * rowScale)) - 1
        )
    }

    var region: WindowPlacementRegion {
        WindowPlacementRegion(
            column: minimumColumn,
            row: minimumRow,
            columnSpan: maximumColumn - minimumColumn + 1,
            rowSpan: maximumRow - minimumRow + 1
        )
    }

    func resized(
        edges: WindowPlacementResizeEdges,
        to position: (column: Int, row: Int)
    ) -> WindowPlacementRegion {
        var result = self
        if edges.contains(.left) {
            result.minimumColumn = min(position.column, result.maximumColumn)
        }
        if edges.contains(.right) {
            result.maximumColumn = max(position.column, result.minimumColumn)
        }
        if edges.contains(.top) {
            result.minimumRow = min(position.row, result.maximumRow)
        }
        if edges.contains(.bottom) {
            result.maximumRow = max(position.row, result.minimumRow)
        }
        return WindowPlacementGridBounds(
            minimumColumn: result.minimumColumn,
            maximumColumn: result.maximumColumn,
            minimumRow: result.minimumRow,
            maximumRow: result.maximumRow
        ).region
    }
}

struct WindowPlacementResizeEdges: OptionSet, Equatable {
    let rawValue: UInt8

    static let left = Self(rawValue: 1 << 0)
    static let right = Self(rawValue: 1 << 1)
    static let top = Self(rawValue: 1 << 2)
    static let bottom = Self(rawValue: 1 << 3)
}

enum WindowPlacementBehavior: String, Codable, CaseIterable {
    case proportional
    case nextDisplay
    case previousDisplay
    case maximize
    case center
    case restore

    var supportsRegionEditing: Bool {
        self == .proportional
    }

    var supportsDragActivation: Bool {
        self != .restore
    }
}

enum BuiltInWindowPlacement: String, Codable, CaseIterable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case leftThird
    case centerThird
    case rightThird
    case leftTwoThirds
    case centerTwoThirds
    case rightTwoThirds
    case nextDisplay
    case previousDisplay
    case maximize
    case center
    case restore

    var behavior: WindowPlacementBehavior {
        switch self {
        case .nextDisplay:
            return .nextDisplay
        case .previousDisplay:
            return .previousDisplay
        case .maximize:
            return .maximize
        case .center:
            return .center
        case .restore:
            return .restore
        default:
            return .proportional
        }
    }

    var defaultRegion: WindowPlacementRegion? {
        switch self {
        case .leftHalf:
            return .init(column: 0, row: 0, columnSpan: 12, rowSpan: 12)
        case .rightHalf:
            return .init(column: 12, row: 0, columnSpan: 12, rowSpan: 12)
        case .topHalf:
            return .init(column: 0, row: 0, columnSpan: 24, rowSpan: 6)
        case .bottomHalf:
            return .init(column: 0, row: 6, columnSpan: 24, rowSpan: 6)
        case .topLeft:
            return .init(column: 0, row: 0, columnSpan: 12, rowSpan: 6)
        case .topRight:
            return .init(column: 12, row: 0, columnSpan: 12, rowSpan: 6)
        case .bottomLeft:
            return .init(column: 0, row: 6, columnSpan: 12, rowSpan: 6)
        case .bottomRight:
            return .init(column: 12, row: 6, columnSpan: 12, rowSpan: 6)
        case .leftThird:
            return .init(column: 0, row: 0, columnSpan: 8, rowSpan: 12)
        case .centerThird:
            return .init(column: 8, row: 0, columnSpan: 8, rowSpan: 12)
        case .rightThird:
            return .init(column: 16, row: 0, columnSpan: 8, rowSpan: 12)
        case .leftTwoThirds:
            return .init(column: 0, row: 0, columnSpan: 16, rowSpan: 12)
        case .centerTwoThirds:
            return .init(column: 4, row: 0, columnSpan: 16, rowSpan: 12)
        case .rightTwoThirds:
            return .init(column: 8, row: 0, columnSpan: 16, rowSpan: 12)
        case .nextDisplay, .previousDisplay, .center, .restore:
            return nil
        case .maximize:
            return .full
        }
    }

    var defaultActivationRegion: WindowPlacementRegion? {
        switch self {
        case .leftHalf:
            return .init(column: 0, row: 2, columnSpan: 1, rowSpan: 8)
        case .rightHalf:
            return .init(column: 23, row: 2, columnSpan: 1, rowSpan: 8)
        case .topLeft:
            return .init(column: 0, row: 0, columnSpan: 2, rowSpan: 2)
        case .topRight:
            return .init(column: 22, row: 0, columnSpan: 2, rowSpan: 2)
        case .bottomLeft:
            return .init(column: 0, row: 10, columnSpan: 2, rowSpan: 2)
        case .bottomRight:
            return .init(column: 22, row: 10, columnSpan: 2, rowSpan: 2)
        case .maximize:
            return .init(column: 2, row: 0, columnSpan: 20, rowSpan: 1)
        default:
            return nil
        }
    }
}

struct WindowPlacementCommand: Codable, Equatable, Identifiable {
    let id: UUID
    var builtIn: BuiltInWindowPlacement?
    var customName: String?
    var behavior: WindowPlacementBehavior
    var targetRegion: WindowPlacementRegion?
    var shortcut: RecordedShortcut?
    var activationRegion: WindowPlacementRegion?
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        builtIn: BuiltInWindowPlacement? = nil,
        customName: String? = nil,
        behavior: WindowPlacementBehavior,
        targetRegion: WindowPlacementRegion? = nil,
        shortcut: RecordedShortcut? = nil,
        activationRegion: WindowPlacementRegion? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.builtIn = builtIn
        self.customName = customName
        self.behavior = behavior
        self.targetRegion = targetRegion
        self.shortcut = shortcut
        self.activationRegion = activationRegion
        self.isEnabled = isEnabled
    }

    static func builtIn(_ placement: BuiltInWindowPlacement) -> Self {
        Self(
            id: stableIdentifier(for: placement),
            builtIn: placement,
            behavior: placement.behavior,
            targetRegion: placement.defaultRegion,
            activationRegion: placement.defaultActivationRegion
        )
    }

    static func custom(name: String) -> Self {
        Self(
            customName: name,
            behavior: .proportional,
            targetRegion: .init(column: 6, row: 3, columnSpan: 12, rowSpan: 6)
        )
    }

    private static func stableIdentifier(for placement: BuiltInWindowPlacement) -> UUID {
        let bytes = Array(placement.rawValue.utf8)
        var values = [UInt8](repeating: 0, count: 16)
        for (index, byte) in bytes.enumerated() {
            values[index % values.count] = values[index % values.count] &+ byte &+ UInt8(index & 0xFF)
        }
        values[6] = (values[6] & 0x0F) | 0x40
        values[8] = (values[8] & 0x3F) | 0x80
        return UUID(uuid: (
            values[0], values[1], values[2], values[3],
            values[4], values[5], values[6], values[7],
            values[8], values[9], values[10], values[11],
            values[12], values[13], values[14], values[15]
        ))
    }
}

struct WindowPlacementConfiguration: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var isEnabled: Bool
    var showsGreenButtonPalette: Bool
    var observesWindowDragging: Bool
    var commands: [WindowPlacementCommand]

    init(
        schemaVersion: Int = currentSchemaVersion,
        isEnabled: Bool = false,
        showsGreenButtonPalette: Bool = true,
        observesWindowDragging: Bool = true,
        commands: [WindowPlacementCommand] = BuiltInWindowPlacement.allCases.map(WindowPlacementCommand.builtIn)
    ) {
        self.schemaVersion = schemaVersion
        self.isEnabled = isEnabled
        self.showsGreenButtonPalette = showsGreenButtonPalette
        self.observesWindowDragging = observesWindowDragging
        self.commands = commands
    }

    static let `default` = WindowPlacementConfiguration()

    func activationConflict(for commandID: UUID, region: WindowPlacementRegion?) -> UUID? {
        guard let region, !region.isEmpty else {
            return nil
        }
        return commands.first {
            $0.id != commandID
                && $0.activationRegion?.intersects(region) == true
        }?.id
    }

    func reservedActivationRegions(excluding commandID: UUID) -> [WindowPlacementRegion] {
        commands.compactMap { command in
            guard command.id != commandID else {
                return nil
            }
            return command.activationRegion
        }
    }

    mutating func normalize() {
        schemaVersion = Self.currentSchemaVersion
        var seen = Set<UUID>()
        commands = commands.filter { seen.insert($0.id).inserted }
        for placement in BuiltInWindowPlacement.allCases {
            let identifier = WindowPlacementCommand.builtIn(placement).id
            if !commands.contains(where: { $0.id == identifier }) {
                commands.append(.builtIn(placement))
            }
        }
    }
}
