import Foundation

struct LyricLine {
    let time: TimeInterval
    let text: String

    static func parse(_ source: String) -> [LyricLine] {
        let rows = source.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let offset = rows.compactMap { row -> Double? in
            guard row.lowercased().hasPrefix("[offset:"), row.hasSuffix("]") else { return nil }
            return Double(row.dropFirst(8).dropLast())
        }.last ?? 0

        return rows.flatMap { row -> [LyricLine] in
            var rest = row[...]
            var times: [TimeInterval] = []
            while rest.first == "[", let end = rest.firstIndex(of: "]") {
                let timestamp = rest[rest.index(after: rest.startIndex)..<end]
                let parts = timestamp.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 2, let minutes = Int(parts[0]), minutes >= 0,
                      let seconds = Double(parts[1]), seconds.isFinite, seconds >= 0, seconds < 60 else { break }
                times.append(Double(minutes) * 60 + seconds + offset / 1000)
                rest = rest[rest.index(after: end)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            return times.map { LyricLine(time: $0, text: text) }
        }.sorted { $0.time < $1.time }
    }
}
