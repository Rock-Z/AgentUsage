import Foundation

enum Provider: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }

    var shortName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

enum MenuProviderSelection: String, CaseIterable, Identifiable {
    case codex
    case claude
    case combined

    var id: String { self.rawValue }

    /// Both or neither maps to `.combined`.
    init(codex: Bool, claude: Bool) {
        self = switch (codex, claude) {
        case (true, false): .codex
        case (false, true): .claude
        default: .combined
        }
    }

    var provider: Provider? {
        switch self {
        case .codex: .codex
        case .claude: .claude
        case .combined: nil
        }
    }

    var providers: [Provider] {
        provider.map { [$0] } ?? Provider.allCases
    }

    /// This selection with `provider` added or removed; `nil` when none would remain.
    func setting(_ provider: Provider, _ included: Bool) -> MenuProviderSelection? {
        var providers = Set(providers)
        if included { providers.insert(provider) } else { providers.remove(provider) }
        guard !providers.isEmpty else { return nil }
        return MenuProviderSelection(codex: providers.contains(.codex), claude: providers.contains(.claude))
    }

    func isAvailable(with trackedProviders: [Provider]) -> Bool {
        switch self {
        case .codex:
            trackedProviders.contains(.codex)
        case .claude:
            trackedProviders.contains(.claude)
        case .combined:
            Provider.allCases.allSatisfy(trackedProviders.contains)
        }
    }

    func constrained(to trackedProviders: [Provider]) -> MenuProviderSelection {
        guard !isAvailable(with: trackedProviders),
              let provider = trackedProviders.first
        else { return self }
        return MenuProviderSelection(codex: provider == .codex, claude: provider == .claude)
    }
}

/// What the menu bar shows for each provider; any combination can be chosen.
enum MenuMetric: String, CaseIterable, Identifiable {
    /// The account-wide limits: short and long windows as nested rings.
    case limits
    case credits

    /// Reads a comma-separated set, including single values stored by earlier versions.
    static func set(stored: String) -> Set<MenuMetric> {
        let metrics = stored.split(separator: ",").compactMap { value -> MenuMetric? in
            switch value {
            case "fiveHourPercent", "sevenDayPercent", "bothPercent", "tightest", "topTwo", "limits": .limits
            case "billingDollars", "credits": .credits
            default: nil
            }
        }
        return metrics.isEmpty ? [.limits] : Set(metrics)
    }

    static func stored(_ metrics: Set<MenuMetric>) -> String {
        allCases.filter(metrics.contains).map(\.rawValue).joined(separator: ",")
    }

    var id: String { self.rawValue }
}

/// How limits are drawn in the menu bar: a ring, percentages, or both.
enum MenuDisplayMode: String, CaseIterable {
    case ring
    case percentage
    case ringAndPercentage

    /// `nil` when neither is shown.
    init?(ring: Bool, percentage: Bool) {
        switch (ring, percentage) {
        case (true, true): self = .ringAndPercentage
        case (true, false): self = .ring
        case (false, true): self = .percentage
        case (false, false): return nil
        }
    }

    var showsRing: Bool { self != .percentage }
    var showsPercentage: Bool { self != .ring }
}

struct FirstLaunchSettings {
    private static let initializedKey = "initialSettingsVersion"
    private static let currentVersion = 1

    static func applyIfNeeded(
        defaults: UserDefaults,
        availableProviders: [Provider],
        hasLaunchedBefore: Bool
    ) {
        guard defaults.integer(forKey: initializedKey) < currentVersion else {
            return
        }
        defaults.set(currentVersion, forKey: initializedKey)
        guard !hasLaunchedBefore else { return }

        let providers = Set(availableProviders)
        defaults.set(providers.contains(.codex), forKey: "trackCodex")
        defaults.set(providers.contains(.claude), forKey: "trackClaude")

        let selection = MenuProviderSelection(
            codex: providers.contains(.codex),
            claude: providers.contains(.claude))
        defaults.set(selection.rawValue, forKey: "menuProvider")
        defaults.set(MenuMetric.limits.rawValue, forKey: "menuMetric")
        defaults.set(
            MenuDisplayMode.ringAndPercentage.rawValue,
            forKey: "menuDisplayMode")
    }

    static func locallyAvailableProviders(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [Provider] {
        Provider.allCases.filter { provider in
            switch provider {
            case .codex:
                BinaryLocator.resolve("codex", env: environment) != nil
            case .claude:
                BinaryLocator.resolve("claude", env: environment) != nil
            }
        }
    }
}

struct ChartPositionPersistence {
    private let defaults: UserDefaults
    private let keyPrefix: String

    init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "codexActivityScrollPosition"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func restoredPosition(
        for period: String,
        availableDates: [Date]
    ) -> Date? {
        guard let latest = availableDates.last else { return nil }
        guard let timestamp = defaults.object(
            forKey: key(for: period)) as? Double
        else { return latest }

        let saved = Date(timeIntervalSince1970: timestamp)
        return availableDates.min {
            abs($0.timeIntervalSince(saved)) < abs($1.timeIntervalSince(saved))
        }
    }

    func save(_ date: Date?, for period: String) {
        let key = key(for: period)
        guard let date else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(date.timeIntervalSince1970, forKey: key)
    }

    private func key(for period: String) -> String {
        "\(keyPrefix).\(period)"
    }
}

/// One usage limit as the provider reports it. Titles come from the
/// provider's own names, so new or returning limits appear without code changes.
struct UsageLimit: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var usedPercent: Double
    var resetsAt: Date?
    /// The model or surface this limit applies to; `nil` for account-wide limits.
    var scope: String? = nil

    var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }

    static func durationLabel(minutes: Int) -> String {
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        let remainingMinutes = minutes % 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if remainingMinutes > 0 || parts.isEmpty { parts.append("\(remainingMinutes)m") }
        return parts.joined(separator: " ")
    }
}

struct CreditSnapshot: Equatable, Sendable {
    var balance: Double?
    var unlimited: Bool
    var currencyCode: String? = nil
}

struct ResetCredit: Decodable, Equatable, Sendable {
    var resetType: String?
    var status: String
    var grantedAt: Date?
    var expiresAt: Date?
    var title: String?
    var description: String?
}

struct ResetCreditSnapshot: Equatable, Sendable {
    var availableCount: Int
    var credits: [ResetCredit]
}

struct TokenUsageDay: Equatable, Sendable, Identifiable {
    var startDate: String
    var tokens: Int64

    var id: String { startDate }

    var date: Date? {
        let components = startDate.split(separator: "-").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        var dateComponents = DateComponents()
        dateComponents.calendar = Calendar(identifier: .gregorian)
        dateComponents.timeZone = .current
        dateComponents.year = components[0]
        dateComponents.month = components[1]
        dateComponents.day = components[2]
        dateComponents.hour = 12
        return dateComponents.date
    }
}

struct TokenWeekBucket: Identifiable {
    var startDate: Date
    var endDate: Date
    var tokens: Int64

    var id: Date { startDate }

    static func calendarWeeks(
        from days: [TokenUsageDay],
        calendar sourceCalendar: Calendar = .current,
        minimumCount: Int = 12
    ) -> [TokenWeekBucket] {
        var calendar = sourceCalendar
        calendar.firstWeekday = 2

        let dated = Dictionary(uniqueKeysWithValues: days.compactMap { day -> (Date, Int64)? in
            guard let date = day.date else { return nil }
            return (calendar.startOfDay(for: date), day.tokens)
        })
        let latestDay = dated.keys.max() ?? calendar.startOfDay(for: Date())
        let earliestDay = dated.keys.min() ?? latestDay
        let latestWeekStart = monday(for: latestDay, calendar: calendar)
        let earliestWeekStart = monday(for: earliestDay, calendar: calendar)
        let dataWeekCount = ((calendar.dateComponents(
            [.day],
            from: earliestWeekStart,
            to: latestWeekStart).day ?? 0) / 7) + 1
        let bucketCount = max(minimumCount, dataWeekCount)

        return (0..<bucketCount).map { index in
            let weeksAgo = bucketCount - 1 - index
            let startDate = calendar.date(
                byAdding: .day,
                value: -(weeksAgo * 7),
                to: latestWeekStart) ?? latestWeekStart
            let fullWeekEnd = calendar.date(
                byAdding: .day,
                value: 6,
                to: startDate) ?? startDate
            let endDate = min(fullWeekEnd, latestDay)
            let dayCount = (calendar.dateComponents(
                [.day],
                from: startDate,
                to: endDate).day ?? 0) + 1
            let tokens = (0..<max(0, dayCount)).reduce(Int64(0)) { total, offset in
                let date = calendar.date(
                    byAdding: .day,
                    value: offset,
                    to: startDate) ?? startDate
                return total + (dated[date] ?? 0)
            }
            return TokenWeekBucket(startDate: startDate, endDate: endDate, tokens: tokens)
        }
    }

    private static func monday(for date: Date, calendar: Calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let daysSinceMonday = (calendar.component(.weekday, from: startOfDay) + 5) % 7
        return calendar.date(
            byAdding: .day,
            value: -daysSinceMonday,
            to: startOfDay) ?? startOfDay
    }
}

struct CodexActivitySnapshot: Equatable, Sendable {
    var lifetimeTokens: Int64?
    var peakDailyTokens: Int64?
    var longestRunningTurnSec: Int64?
    var currentStreakDays: Int64?
    var longestStreakDays: Int64?
    var dailyUsage: [TokenUsageDay]
}

struct UsageSnapshot: Equatable, Sendable {
    var provider: Provider
    var limits: [UsageLimit] = []
    var credits: CreditSnapshot? = nil
    var resetCredits: ResetCreditSnapshot? = nil
    var plan: String?
    var codexActivity: CodexActivitySnapshot? = nil
    var updatedAt: Date

    /// Account-wide limits, shortest window first as the provider reports them.
    var accountLimits: [UsageLimit] {
        limits.filter { $0.scope == nil }
    }
}

struct ProviderState: Equatable {
    var snapshot: UsageSnapshot?
    var isRefreshing = false
    var error: String?
}

/// What the menu bar shows for one provider under the selected metrics.
struct MenuBarStatusEntry: Sendable {
    var provider: Provider
    /// Up to two account-wide limits, shortest window first (e.g. 5h and 7d).
    var limits: [UsageLimit]
    var percentText: String?
    var amountText: String?

    init(provider: Provider, snapshot: UsageSnapshot?, metrics: Set<MenuMetric>) {
        self.provider = provider
        limits = metrics.contains(.limits)
            ? Array((snapshot?.accountLimits ?? []).prefix(2))
            : []
        percentText = limits.isEmpty
            ? nil
            : limits.map { "\($0.title) \(DisplayFormatter.percent($0.remainingPercent))" }
                .joined(separator: "\n")
        // Without limits to show, credits are the only useful fallback.
        amountText = metrics.contains(.credits) || limits.isEmpty
            ? DisplayFormatter.amountText(snapshot)
            : nil
    }

    var summary: String {
        let parts = limits.map { "\($0.title) \(DisplayFormatter.percent($0.remainingPercent)) left" }
            + [amountText].compactMap { $0 }
        return parts.isEmpty ? "No usage data" : parts.joined(separator: ", ")
    }
}

/// Turns an API identifier such as `weekly_all` into "Weekly all".
func humanizedIdentifier(_ identifier: String) -> String {
    let words = identifier.replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .trimmingCharacters(in: .whitespaces)
    return words.prefix(1).uppercased() + words.dropFirst()
}

/// Parses ISO 8601 timestamps with or without fractional seconds.
func parseISO8601Date(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}

enum DisplayFormatter {
    static func rateLimitResetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.doesRelativeDateFormatting = false
        formatter.dateFormat = "hh:mm a, MMM d"
        return formatter.string(from: date)
    }

    static func percent(_ value: Double) -> String {
        "\(Int(max(0, min(100, value)).rounded()))%"
    }

    static func dollars(_ value: Double) -> String {
        if value < 100 {
            return String(format: "$%.2f", value)
        }
        return String(format: "$%.0f", value)
    }

    static func compactTokens(_ value: Int64?) -> String {
        guard let value else { return "--" }
        let absolute = abs(Double(value))
        let divisor: Double
        let suffix: String
        switch absolute {
        case 1_000_000_000...:
            divisor = 1_000_000_000
            suffix = "B"
        case 1_000_000...:
            divisor = 1_000_000
            suffix = "M"
        case 1_000...:
            divisor = 1_000
            suffix = "K"
        default:
            return value.formatted()
        }

        let scaled = Double(value) / divisor
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 3
        formatter.minimumSignificantDigits = 1
        let number = formatter.string(from: NSNumber(value: scaled)) ?? String(format: "%.1f", scaled)
        return "\(number)\(suffix)"
    }

    static func compactAxisTokens(_ value: Int64) -> String {
        let absolute = abs(Double(value))
        let divisor: Double
        let suffix: String
        switch absolute {
        case 100_000_000..<1_000_000_000:
            divisor = 1_000_000_000
            suffix = "B"
        case 100_000..<1_000_000:
            divisor = 1_000_000
            suffix = "M"
        case 100..<1_000:
            divisor = 1_000
            suffix = "K"
        default:
            return compactTokens(value)
        }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        let scaled = Double(value) / divisor
        let number = formatter.string(from: NSNumber(value: scaled))
            ?? String(format: "%.1f", scaled)
        return "\(number)\(suffix)"
    }

    static func duration(seconds: Int64?) -> String {
        guard let seconds else { return "--" }
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    static func roundedAxisMaximum(_ value: Int64) -> Int64 {
        guard value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(Double(value))))
        let preferredSteps = [1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0, 15.0]
        let minimumWithHeadroom = Double(value) * 1.05
        let candidates = preferredSteps.map { $0 * magnitude }
        var candidateIndex = candidates.firstIndex { $0 >= minimumWithHeadroom }
            ?? candidates.index(before: candidates.endIndex)

        if candidates[candidateIndex] / Double(value) > 1.40, candidateIndex > candidates.startIndex {
            let previous = candidates[candidates.index(before: candidateIndex)]
            if previous > Double(value) {
                candidateIndex = candidates.index(before: candidateIndex)
            }
        }

        return Int64(candidates[candidateIndex].rounded(.up))
    }

    static func credits(_ snapshot: CreditSnapshot) -> String {
        if snapshot.unlimited { return "Unlimited" }
        // A zero balance is still a balance; only an unknown one shows "--".
        guard let balance = snapshot.balance else { return "--" }

        if snapshot.currencyCode?.uppercased() == "USD" {
            return dollars(balance)
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = balance < 100 ? 2 : 0
        formatter.minimumFractionDigits = 0
        let amount = formatter.string(from: NSNumber(value: balance)) ?? String(format: "%.0f", balance)
        if let currencyCode = snapshot.currencyCode?.uppercased(), !currencyCode.isEmpty {
            return "\(amount) \(currencyCode)"
        }
        return amount
    }

    static func resetSummary(_ snapshot: ResetCreditSnapshot?) -> String {
        guard let snapshot else { return "Resets: --" }
        return "Resets: \(snapshot.availableCount) available"
    }

    static func resetExpirationHelp(_ snapshot: ResetCreditSnapshot?) -> String {
        guard let snapshot else { return "Reset expiration data unavailable" }
        let available = snapshot.credits
            .filter { $0.status == "available" }
            .sorted {
                switch ($0.expiresAt, $1.expiresAt) {
                case let (lhs?, rhs?): lhs < rhs
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): ($0.title ?? "") < ($1.title ?? "")
                }
            }
        guard !available.isEmpty else {
            return snapshot.availableCount > 0
                ? "Expiration details unavailable"
                : "No resets available"
        }
        return available.enumerated()
            .map { index, credit in
                let date = credit.expiresAt.map(Self.resetExpirationDate) ?? "unknown"
                return "Reset \(index + 1): expires \(date)"
            }
            .joined(separator: "\n")
    }

    static func resetExpirationDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = false
        formatter.dateFormat = "MMM d, h:mm a"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    static func amountText(_ snapshot: UsageSnapshot?) -> String? {
        snapshot?.credits.map(self.credits)
    }
}
