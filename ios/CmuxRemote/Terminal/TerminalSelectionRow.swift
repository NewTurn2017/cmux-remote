struct TerminalSelectionRow: Equatable, Sendable {
    static let empty = TerminalSelectionRow(spans: [])

    let spans: [TerminalColumnSpan]

    init(spans: [TerminalColumnSpan]) {
        self.spans = spans
    }

    var isWellFormed: Bool {
        var previousUpperBound = 0
        for span in spans {
            guard span.columns.lowerBound >= 0,
                  span.columns.lowerBound < span.columns.upperBound,
                  span.columns.lowerBound >= previousUpperBound,
                  !span.text.isEmpty
            else { return false }
            previousUpperBound = span.columns.upperBound
        }
        return true
    }

    func contains(column: Int) -> Bool {
        spans.contains { $0.contains(column: column) }
    }

    func canonicalColumn(containing column: Int) -> Int? {
        spans.first { $0.contains(column: column) }?.columns.lowerBound
    }

    func clampedCanonicalColumn(for column: Int) -> Int? {
        guard let first = spans.first, let last = spans.last else { return nil }
        if column <= first.columns.lowerBound { return first.columns.lowerBound }
        if column >= last.columns.upperBound { return last.columns.lowerBound }
        if let contained = canonicalColumn(containing: column) { return contained }

        for (previous, next) in zip(spans, spans.dropFirst())
        where column >= previous.columns.upperBound && column < next.columns.lowerBound {
            let previousColumn = previous.columns.upperBound - 1
            let previousDistance = column - previousColumn
            let nextDistance = next.columns.lowerBound - column
            return previousDistance <= nextDistance
                ? previous.columns.lowerBound
                : next.columns.lowerBound
        }
        return nil
    }

    func text(fromColumn lowerBound: Int?, throughColumn upperBound: Int?) -> String {
        spans.reduce(into: "") { result, span in
            let reachesLowerBound = lowerBound.map { span.columns.upperBound > $0 } ?? true
            let reachesUpperBound = upperBound.map { span.columns.lowerBound <= $0 } ?? true
            if reachesLowerBound && reachesUpperBound {
                result.append(span.text)
            }
        }
    }
}
