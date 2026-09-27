import Foundation

/// Public plan names, rather than title-cased backend identifiers.
/// Sources: https://learn.chatgpt.com/docs/pricing and https://claude.com/pricing.
/// OpenAI's account enum uses `prolite` for Pro 5x and `pro` for Pro 20x.
enum PlanNames {
    static func codex(_ value: String?) -> String? {
        switch normalized(value) {
        case "free": "Free"
        case "go": "Go"
        case "plus": "Plus"
        case "prolite": "Pro 5x"
        case "pro": "Pro 20x"
        case "team", "business", "self_serve_business_prolite", "self_serve_business_usage_based":
            "Business"
        case "enterprise", "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based":
            "Enterprise"
        case "edu", "education", "edu_plus", "edu_pro": "Edu"
        default: nil
        }
    }

    static func claude(_ subscription: String?, rateLimitTier: String?) -> String? {
        switch normalized(subscription) {
        case "free": return "Free"
        case "pro": return "Pro"
        case "max":
            switch normalized(rateLimitTier) {
            case "default_claude_max_5x": return "Max 5x"
            case "default_claude_max_20x": return "Max 20x"
            default: return "Max"
            }
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default: return nil
        }
    }

    private static func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
