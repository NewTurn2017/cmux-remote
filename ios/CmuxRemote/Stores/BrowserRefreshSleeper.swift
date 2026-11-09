/// Waits between automatic browser captures. Tests replace it with a manually advanced fake.
protocol BrowserRefreshSleeper: Sendable {
    /// Suspends for `seconds`; throws `CancellationError` when the waiting task is cancelled.
    func sleep(seconds: Double) async throws
}

struct SystemBrowserRefreshSleeper: BrowserRefreshSleeper {
    func sleep(seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}
