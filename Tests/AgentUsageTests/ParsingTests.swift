import Foundation
import Testing
@testable import AgentUsage

struct ClaudeUsageParsingTests {
    @Test func readsEveryReportedLimitWithItsOwnTitle() throws {
        let data = Data(#"""
        {
          "five_hour":{"utilization":99},
          "extra_usage":{"is_enabled":true,"monthly_limit":10000,"used_credits":3750,"currency":"USD"},
          "limits":[
            {"kind":"session","group":"session","percent":26,"resets_at":"2026-09-27T20:39:59.988796+00:00","scope":null,"is_active":false},
            {"kind":"weekly_all","group":"weekly","percent":43,"resets_at":"2026-09-29T17:59:59Z","scope":null},
            {"kind":"weekly_scoped","group":"weekly","percent":0,"scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}},
            {"kind":"weekly_scoped","group":"weekly","percent":90,"scope":{"model":{"display_name":"Fable"}}},
            {"kind":"weekly_scoped","group":"weekly","percent":130,"scope":{"surface":"cowork"}},
            {"kind":"daily_future","percent":5,"scope":{"surface":{"unexpected":"shape"}}},
            {"kind":"weekly_scoped","group":"weekly","percent":null,"scope":{"model":{"display_name":"Unknown"}}}
          ]
        }
        """#.utf8)
        let snapshot = try ClaudeUsageFetcher.snapshot(from: data)

        #expect(snapshot.limits.map(\.title) == ["Session", "Weekly", "Weekly Fable", "Weekly Cowork", "Daily future"],
                "titles come from group, kind, and scope; duplicates and null percentages are skipped")
        #expect(snapshot.limits.map(\.remainingPercent) == [74, 57, 100, 0, 95], "percentages are clamped")
        #expect(snapshot.limits.map(\.scope) == [nil, nil, "Fable", "Cowork", nil])
        #expect(snapshot.limits[0].resetsAt != nil, "fractional-second timestamps parse")
        #expect(!snapshot.limits.contains { $0.usedPercent == 99 }, "legacy top-level windows are not read")
        // Minor currency units: 10000 - 3750 cents leaves $62.50.
        #expect(DisplayFormatter.amountText(snapshot) == "$62.50")
    }

    @Test func disabledExtraUsageStillShowsZeroCredits() throws {
        let data = Data(#"""
        {"extra_usage":{"is_enabled":false,"monthly_limit":null,"currency":null},
         "spend":{"used":{"amount_minor":0,"currency":"USD","exponent":2}},"limits":[]}
        """#.utf8)
        #expect(DisplayFormatter.amountText(try ClaudeUsageFetcher.snapshot(from: data)) == "$0.00")
        let oddSpend = Data(#"{"extra_usage":{"is_enabled":false},"spend":"unexpected"}"#.utf8)
        #expect(DisplayFormatter.amountText(try ClaudeUsageFetcher.snapshot(from: oddSpend)) == "0")
    }

    @Test func noLimitsMeansNoBars() throws {
        for json in ["{}", #"{"limits":null}"#, #"{"limits":[]}"#] {
            #expect(try ClaudeUsageFetcher.snapshot(from: Data(json.utf8)).limits.isEmpty)
        }
    }

    @Test func rejectsInvalidBody() {
        #expect(throws: FetchError.self) {
            try ClaudeUsageFetcher.snapshot(from: Data("<html>".utf8))
        }
    }

    @Test func parsesHelperOutput() throws {
        let body = Data(#"{"five_hour":{"utilization":12.5}}"#.utf8)
        let output = Data(#"{"status":200,"retryAfter":"120","subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}"#.utf8)
            + Data([0x0A]) + body
        let response = try ClaudeCredentialHelper.parse(output)

        #expect(response.statusCode == 200)
        #expect(response.retryAfter == "120")
        #expect(PlanNames.claude(response.subscriptionType, rateLimitTier: response.rateLimitTier) == "Max 20x")
        #expect(response.body == body, "body bytes pass through unchanged")

        #expect(throws: FetchError.self) {
            try ClaudeCredentialHelper.parse(Data("200\n\n{}".utf8))
        }
    }
}

struct PlanNameTests {
    @Test func claudeMaxTierComesFromRateLimitTier() {
        #expect(PlanNames.claude("max", rateLimitTier: "default_claude_max_5x") == "Max 5x")
        #expect(PlanNames.claude("max", rateLimitTier: "future_tier") == "Max")
        #expect(PlanNames.claude("pro", rateLimitTier: "default_claude_max_20x") == "Pro", "tier only qualifies Max")
    }

    @Test func unknownPlansAreOmitted() {
        #expect(PlanNames.codex(" ProLite ") == "Pro 5x", "normalizes case and whitespace")
        for raw in [nil, "", "future_plan"] as [String?] {
            #expect(PlanNames.codex(raw) == nil)
            #expect(PlanNames.claude(raw, rateLimitTier: nil) == nil)
        }
    }
}

struct CodexParsingTests {
    @Test func readsEveryLimitAndWindow() throws {
        let body = """
        {
          "rateLimits": {"limitId":"codex","limitName":null,"primary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":1791062073},
                         "secondary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1791000000},
                         "credits":{"hasCredits":false,"unlimited":false,"balance":"0"},"planType":"prolite"},
          "rateLimitsByLimitId": {
            "base_model_inference":{"limitId":"base_model_inference","limitName":"gpt-reserve","normalModelSlug":"gpt-5.6-luna",
                                    "primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1791136735},"secondary":null},
            "future_limit":{"limitId":"future_limit","primary":{"usedPercent":5}},
            "codex":{"limitId":"codex","primary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":1791062073},
                     "secondary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1791000000}}
          },
          "rateLimitResetCredits": {"availableCount":1,"credits":[
            {"id":"x","resetType":"codexRateLimits","status":"available","grantedAt":1788582033,"expiresAt":1791174033,"title":"Full reset"}]}
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let response = try decoder.decode(CodexRateLimitsResponse.self, from: Data(body.utf8))

        #expect(response.limits.map(\.title) == ["5h", "7d", "7d gpt-reserve", "Future limit"],
                "main limit first, shortest window first, other limits titled by their own names")
        #expect(response.limits.map(\.usedPercent) == [40, 10, 0, 5])
        #expect(response.limits.map(\.scope) == [nil, nil, "gpt-reserve", "Future limit"])
        #expect(response.rateLimitResetCredits?.credits?.first?.expiresAt == Date(timeIntervalSince1970: 1791174033))
    }

    @Test func fallsBackToMainLimitAlone() throws {
        let body = #"{"rateLimits":{"primary":{"usedPercent":3,"windowDurationMins":10080}}}"#
        let response = try JSONDecoder().decode(CodexRateLimitsResponse.self, from: Data(body.utf8))
        #expect(response.limits.map(\.title) == ["7d"])
    }

    @Test func parsesAccountUsage() throws {
        let body = """
        {
          "summary": {
            "lifetimeTokens": 24670581944,
            "peakDailyTokens": 1954897499,
            "longestRunningTurnSec": 47828
          },
          "dailyUsageBuckets": [
            {"startDate": "2026-07-19", "tokens": 726133164},
            {"startDate": "2026-07-20", "tokens": 198515919}
          ]
        }
        """
        let activity = try JSONDecoder().decode(
            CodexAccountUsageResponse.self,
            from: Data(body.utf8)).snapshot

        #expect(activity.lifetimeTokens == 24_670_581_944)
        #expect(activity.dailyUsage.count == 2)
        #expect(activity.dailyUsage.last?.date != nil)
        #expect(DisplayFormatter.duration(seconds: activity.longestRunningTurnSec) == "13h 17m")
    }
}
