/// Records inbound action side effects without shared mutable test state.
actor InboundActionExecutionRecorder {
    private var values: [String] = []

    func record(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}
