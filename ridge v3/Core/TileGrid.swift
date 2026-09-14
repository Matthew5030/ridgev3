import Foundation

struct AreaSelection: Equatable, Sendable {
    var minU: Double = 0
    var minV: Double = 0
    var maxU: Double = 1
    var maxV: Double = 1
    var isWhole: Bool { minU == 0 && minV == 0 && maxU == 1 && maxV == 1 }
}

struct TerrainCell: Hashable, Sendable, Identifiable {
    var column: Int
    var row: Int
    var id: String { "\(column)-\(row)" }
}

/// Original precision-child cells: 48 × 48 per z10 source tile and 512 native
/// one-metre intervals per cell. Origins are global; selection indices are local.
struct TerrainGrid: Codable, Hashable, Sendable {
    var gridID: String
    var worldTileID: String
    var originColumn: Int
    var originRow: Int
    var columns: Int
    var rows: Int
    static let worldSide = 48
    static let nativeIntervals = 512

    var isValid: Bool {
        let side = gridID == "ridge-eryri-uniform-v1" ? 256 : Self.worldSide
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let validID: (String) -> Bool = { !$0.isEmpty && $0.count <= 100 && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy { allowed.contains($0) } }
        return validID(gridID) && validID(worldTileID) && originColumn >= 0 && originRow >= 0
            && columns >= 1 && rows >= 1 && columns <= side && rows <= side
            && originColumn <= side - columns && originRow <= side - rows
    }

    func selection(column: Int, row: Int) -> AreaSelection? {
        rectangle(from: TerrainCell(column: column, row: row), to: TerrainCell(column: column, row: row))
    }

    func rectangle(from first: TerrainCell, to last: TerrainCell) -> AreaSelection? {
        guard isValid, contains(first), contains(last) else { return nil }
        return AreaSelection(minU: Double(min(first.column, last.column)) / Double(columns),
                             minV: Double(min(first.row, last.row)) / Double(rows),
                             maxU: Double(max(first.column, last.column) + 1) / Double(columns),
                             maxV: Double(max(first.row, last.row) + 1) / Double(rows))
    }

    /// Include every original cell touched by a valid normalized rectangle.
    func cellsSelection(_ selection: AreaSelection) -> AreaSelection? {
        guard isValid, [selection.minU, selection.minV, selection.maxU, selection.maxV].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              selection.minU < selection.maxU, selection.minV < selection.maxV else { return nil }
        let first = TerrainCell(column: min(columns - 1, max(0, Int(floor(selection.minU * Double(columns) + 1e-9)))),
                                row: min(rows - 1, max(0, Int(floor(selection.minV * Double(rows) + 1e-9)))))
        let last = TerrainCell(column: min(columns - 1, max(first.column, Int(ceil(selection.maxU * Double(columns) - 1e-9)) - 1)),
                               row: min(rows - 1, max(first.row, Int(ceil(selection.maxV * Double(rows) - 1e-9)) - 1)))
        return rectangle(from: first, to: last)
    }

    func cropped(to selection: AreaSelection) -> TerrainGrid? {
        guard let aligned = cellsSelection(selection) else { return nil }
        let left = Int((aligned.minU * Double(columns)).rounded()), top = Int((aligned.minV * Double(rows)).rounded())
        let right = Int((aligned.maxU * Double(columns)).rounded()), bottom = Int((aligned.maxV * Double(rows)).rounded())
        return TerrainGrid(gridID: gridID, worldTileID: worldTileID, originColumn: originColumn + left,
                           originRow: originRow + top, columns: right - left, rows: bottom - top)
    }

    func cellID(column: Int, row: Int) -> String? {
        guard let selection = selection(column: column, row: row), let cell = cropped(to: selection) else { return nil }
        return cell.stableID
    }

    func cellName(column: Int, row: Int) -> String? {
        guard let selection = selection(column: column, row: row), let cell = cropped(to: selection) else { return nil }
        return cell.name(sourceName: "")
    }

    var stableID: String {
        if columns == 1 && rows == 1 {
            return worldTileID + String(format: "-c%02d-%02d-p%02d-%02d", originColumn / 4, originRow / 4, originColumn % 4, originRow % 4)
        }
        return worldTileID + String(format: "-r%02d-%02d-%02dx%02d", originColumn, originRow, columns, rows)
    }

    func name(sourceName: String) -> String {
        if columns == 1 && rows == 1 { return String(format: "Tile c%02d-%02d · p%02d-%02d", originColumn / 4, originRow / 4, originColumn % 4, originRow % 4) }
        // Re-selecting within a saved rectangle keeps the original collection name.
        let collection = sourceName.range(of: " tiles · ").map { String(sourceName[$0.upperBound...]) } ?? sourceName
        return "\(columns)×\(rows) tiles · \(collection)"
    }

    private func contains(_ cell: TerrainCell) -> Bool { cell.column >= 0 && cell.row >= 0 && cell.column < columns && cell.row < rows }
}
