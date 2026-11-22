import Foundation

enum ChunkSequenceValidator {
    static func isContinuous(_ sequences: [Int]) -> Bool {
        let sorted = sequences.sorted()
        guard !sorted.isEmpty else { return true }
        guard sorted.first == 0 else { return false }
        return sorted == Array(0..<sorted.count)
    }
}
