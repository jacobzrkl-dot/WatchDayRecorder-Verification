import Foundation

enum ExportSpaceBudget {
    static func requiredBytes(for chunks: [PhoneRecordingChunk]) -> Int64 {
        var total: Int64 = 32 * 1024 * 1024
        for chunk in chunks {
            guard chunk.byteCount > 0 else { return Int64.max }
            let (doubled, overflow) = chunk.byteCount.multipliedReportingOverflow(by: 2)
            let (next, sumOverflow) = total.addingReportingOverflow(doubled)
            guard !overflow, !sumOverflow else { return Int64.max }
            total = next
        }
        return total
    }
}
