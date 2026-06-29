import Foundation

enum ProbeCommand {
    static func run() {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await runAsync()
            semaphore.signal()
        }
        semaphore.wait()
    }

    private static func runAsync() async {
        let fetchers: [(Provider, any UsageFetching)] = [
            (.codex, CodexUsageFetcher()),
            (.claude, ClaudeUsageFetcher()),
        ]
        for (provider, fetcher) in fetchers {
            do {
                let snapshot = try await fetcher.fetch()
                print(summary(snapshot))
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                print("\(provider.displayName): failed: \(message)")
            }
        }
    }

    private static func summary(_ snapshot: UsageSnapshot) -> String {
        let fiveHour = snapshot.fiveHour.map { DisplayFormatter.percent($0.usedPercent) } ?? "--"
        let sevenDay = snapshot.sevenDay.map { DisplayFormatter.percent($0.usedPercent) } ?? "--"
        let amount = DisplayFormatter.amountText(snapshot) ?? DisplayFormatter.dollars(0)
        let amountLabel = snapshot.credits != nil ? "credits" : snapshot.billingCost != nil ? "billing" : "local usage"
        let account = snapshot.accountEmail ?? snapshot.plan ?? "unknown account"
        return "\(snapshot.provider.displayName): 5h \(fiveHour), 7d \(sevenDay), \(amountLabel) \(amount), \(account), source \(snapshot.source)"
    }
}
