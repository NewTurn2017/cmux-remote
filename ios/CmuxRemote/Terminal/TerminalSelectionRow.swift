struct TerminalSelectionRow: Equatable, Sendable {
    static let empty = TerminalSelectionRow(spans: [])

    let spans: [TerminalColumnSpan]

    init(spans: [TerminalColumnSpan]) {
        self.spans = spans
    }

    func contains(column: Int) -> Bool {
        spans.contains { $0.contains(column: column) }
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
