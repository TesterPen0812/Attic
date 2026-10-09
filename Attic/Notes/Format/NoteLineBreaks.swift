import Foundation

enum NoteLineBreaks {
    static func normalizeLineBreaks(_ text: String) -> (String, (Int) -> Int, Int) {
        let units = Array(text.utf16)
        var output: [UInt16] = []
        output.reserveCapacity(units.count)
        var newOffsets = [Int](repeating: 0, count: units.count + 1)
        var breaks = 0
        var index = 0
        while index < units.count {
            newOffsets[index] = output.count
            let unit = units[index]
            if unit == 0x0D {
                output.append(0x0A)
                breaks += 1
                if index + 1 < units.count, units[index + 1] == 0x0A {
                    newOffsets[index + 1] = output.count - 1
                    index += 2
                    continue
                }
            } else if unit == 0x2029 || unit == 0x2028 {
                output.append(0x0A)
                breaks += 1
            } else {
                output.append(unit)
            }
            index += 1
        }
        newOffsets[units.count] = output.count
        let normalized = String(utf16CodeUnits: output, count: output.count)
        let map: (Int) -> Int = { offset in newOffsets[min(max(0, offset), units.count)] }
        return (normalized, map, breaks)
    }
}
