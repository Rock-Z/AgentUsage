import Foundation

enum Provider: String, CaseIterable, Identifiable, Codable, Sendable {
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
        self.displayName
    }
}

enum MenuProviderSelection: String, CaseIterable, Identifiable {
    case codex
    case claude
    case combined

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .combined: "Combined"
        }
    }

    var provider: Provider? {
        switch self {
        case .codex: .codex
        case .claude: .claude
        case .combined: nil
        }
    }
}

enum MenuMetric: String, CaseIterable, Identifiable {
    case fiveHourPercent
    case sevenDayPercent
    case bothPercent
    case billingDollars

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .fiveHourPercent: "Short %"
        case .sevenDayPercent: "Long %"
        case .bothPercent: "All limits"
        case .billingDollars: "Billing $"
        }
    }
}

enum MenuDisplayMode: String, CaseIterable, Identifiable {
    case ring
    case percentage
    case ringAndPercentage

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .ring: "Ring"
        case .percentage: "Percentage"
        case .ringAndPercentage: "Ring + Percentage"
        }
    }
}

struct RateWindow: Codable, Equatable, Sendable {
    var usedPercent: Double
    var windowMinutes: Int?
    var resetsAt: Date?
    var resetDescription: String?

    var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }

    var durationLabel: String {
        guard let windowMinutes, windowMinutes > 0 else { return "Limit" }
        return Self.durationLabel(minutes: windowMinutes)
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

struct CostSnapshot: Codable, Equatable, Sendable {
    var dollars: Double
    var since: Date
    var updatedAt: Date
    var scannedFiles: Int
}

struct CreditSnapshot: Codable, Equatable, Sendable {
    var balance: Double?
    var hasCredits: Bool
    var unlimited: Bool
}

struct ResetCredit: Codable, Equatable, Sendable {
    var resetType: String?
    var status: String
    var grantedAt: Date?
    var expiresAt: Date?
    var title: String?
    var description: String?
}

struct ResetCreditSnapshot: Codable, Equatable, Sendable {
    var availableCount: Int
    var credits: [ResetCredit]
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    var provider: Provider
    var fiveHour: RateWindow?
    var sevenDay: RateWindow?
    var credits: CreditSnapshot? = nil
    var resetCredits: ResetCreditSnapshot? = nil
    var billingCost: CostSnapshot?
    var localUsageCost: CostSnapshot?
    var accountEmail: String?
    var plan: String?
    var source: String
    var updatedAt: Date

    var rateWindows: [RateWindow] {
        [fiveHour, sevenDay].compactMap { $0 }
    }
}

struct ProviderState: Equatable {
    var snapshot: UsageSnapshot?
    var isRefreshing = false
    var error: String?
}

enum DisplayFormatter {
    static func percent(_ value: Double) -> String {
        "\(Int(max(0, min(100, value)).rounded()))%"
    }

    static func dollars(_ value: Double) -> String {
        if value < 100 {
            return String(format: "$%.2f", value)
        }
        return String(format: "$%.0f", value)
    }

    static func credits(_ snapshot: CreditSnapshot) -> String {
        if snapshot.unlimited { return "Unlimited" }
        guard snapshot.hasCredits, let balance = snapshot.balance else { return "--" }

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = balance < 100 ? 2 : 0
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: balance)) ?? String(format: "%.0f", balance)
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

    static func menuTitle(
        states: [Provider: ProviderState],
        providerSelection: MenuProviderSelection,
        metric: MenuMetric,
        showUsed: Bool) -> String
    {
        switch metric {
        case .fiveHourPercent, .sevenDayPercent:
            let window: RateWindow?
            let prefix: String
            if let provider = providerSelection.provider {
                window = self.selectedWindow(
                    states: states,
                    providerSelection: providerSelection,
                    metric: metric)
                prefix = provider.shortName
            } else {
                window = self.selectedWindow(
                    states: states,
                    providerSelection: providerSelection,
                    metric: metric)
                prefix = "AI"
            }
            guard let window else {
                if let amount = self.fallbackAmountText(
                    states: states,
                    providerSelection: providerSelection)
                {
                    return "\(prefix) \(amount)"
                }
                return "\(prefix) --"
            }
            let percent = showUsed ? window.usedPercent : window.remainingPercent
            return "\(prefix) \(Self.percent(percent))"

        case .bothPercent:
            let prefix = providerSelection.provider?.shortName ?? "AI"
            let shortWindow = self.selectedWindow(
                states: states,
                providerSelection: providerSelection,
                metric: .fiveHourPercent)
            let longWindow = self.selectedWindow(
                states: states,
                providerSelection: providerSelection,
                metric: .sevenDayPercent)
            let summaries = [shortWindow, longWindow].compactMap { window -> String? in
                guard let window else { return nil }
                let value = showUsed ? window.usedPercent : window.remainingPercent
                return "\(window.durationLabel) \(Self.percent(value))"
            }
            if !summaries.isEmpty {
                return "\(prefix) \(summaries.joined(separator: " · "))"
            }
            if let amount = self.fallbackAmountText(
                states: states,
                providerSelection: providerSelection)
            {
                return "\(prefix) \(amount)"
            }
            return "\(prefix) --"

        case .billingDollars:
            let prefix: String
            if let provider = providerSelection.provider {
                prefix = provider.shortName
                let amount = self.amountText(states[provider]?.snapshot) ?? "--"
                return "\(prefix) \(amount)"
            } else {
                prefix = "AI"
                let dollars = Provider.allCases.reduce(0) { total, provider in
                    total + (self.amountDollars(states[provider]?.snapshot) ?? 0)
                }
                return "\(prefix) \(Self.dollars(dollars))"
            }
        }
    }

    static func amountText(_ snapshot: UsageSnapshot?) -> String? {
        guard let snapshot else { return nil }
        if let credits = snapshot.credits {
            return self.credits(credits)
        }
        if let dollars = self.amountDollars(snapshot) {
            return self.dollars(dollars)
        }
        return nil
    }

    static func amountDollars(_ snapshot: UsageSnapshot?) -> Double? {
        guard let snapshot else { return nil }
        return snapshot.billingCost?.dollars ?? snapshot.localUsageCost?.dollars
    }

    static func fallbackAmountText(
        states: [Provider: ProviderState],
        providerSelection: MenuProviderSelection) -> String?
    {
        if let provider = providerSelection.provider {
            return self.amountText(states[provider]?.snapshot)
        }
        let values = Provider.allCases.compactMap { self.amountDollars(states[$0]?.snapshot) }
        guard !values.isEmpty else { return nil }
        return self.dollars(values.reduce(0, +))
    }

    static func selectedWindow(
        states: [Provider: ProviderState],
        providerSelection: MenuProviderSelection,
        metric: MenuMetric) -> RateWindow?
    {
        guard metric == .fiveHourPercent || metric == .sevenDayPercent else { return nil }
        if let provider = providerSelection.provider {
            return metric == .fiveHourPercent
                ? states[provider]?.snapshot?.fiveHour
                : states[provider]?.snapshot?.sevenDay
        }
        let windows = Provider.allCases.compactMap { provider in
            metric == .fiveHourPercent
                ? states[provider]?.snapshot?.fiveHour
                : states[provider]?.snapshot?.sevenDay
        }
        return windows.max { $0.usedPercent < $1.usedPercent }
    }

    static func fallbackDollars(
        states: [Provider: ProviderState],
        providerSelection: MenuProviderSelection) -> Double?
    {
        if let provider = providerSelection.provider {
            return self.amountDollars(states[provider]?.snapshot)
        }
        let values = Provider.allCases.compactMap { self.amountDollars(states[$0]?.snapshot) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    static func menuPercentText(
        window: RateWindow?,
        innerWindow: RateWindow?,
        metric: MenuMetric,
        showUsed: Bool) -> String?
    {
        guard metric != .billingDollars else { return nil }
        if metric == .bothPercent {
            let lines = [window, innerWindow].compactMap { rateWindow -> String? in
                guard let rateWindow else { return nil }
                let value = showUsed ? rateWindow.usedPercent : rateWindow.remainingPercent
                return "\(rateWindow.durationLabel): \(Self.percent(value))"
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
        guard let window else { return nil }
        let percent = showUsed ? window.usedPercent : window.remainingPercent
        return Self.percent(percent)
    }
}

enum TextParsing {
    static func stripANSICodes(_ text: String) -> String {
        let pattern = "\u{001B}(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-~])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
