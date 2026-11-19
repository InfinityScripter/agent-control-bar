import Foundation

enum ModelServiceUsageError: Error, Equatable {
    case keyMissing, keychainUnavailable, unauthorized, unavailable, invalidResponse
}

struct ModelServiceUsage: Equatable {
    struct Metric: Equatable {
        let title: String
        let value: String
        let resetAt: Date?
    }

    let metrics: [Metric]

    static func decode(_ data: Data, for service: ModelService) throws -> ModelServiceUsage {
        var metrics: [Metric]
        let decoder = JSONDecoder()
        do {
            switch service {
            case .deepseek:
                let balance = try decoder.decode(DeepSeekBalance.self, from: data)
                metrics = balance.balance_infos.compactMap(\.metric)
                if !balance.is_available {
                    metrics.append(Metric(title: "API calls", value: "Unavailable", resetAt: nil))
                }
            case .zai:
                let response = try decoder.decode(ZaiQuota.self, from: data)
                if response.code == 401 || response.code == 403 { throw ModelServiceUsageError.unauthorized }
                guard response.code == 200, response.success == true, let limits = response.data?.limits else {
                    throw ModelServiceUsageError.invalidResponse
                }
                metrics = limits.compactMap(\.metric)
            default:
                throw ModelServiceUsageError.unavailable
            }
        } catch let error as ModelServiceUsageError {
            throw error
        } catch {
            throw ModelServiceUsageError.invalidResponse
        }
        guard !metrics.isEmpty else { throw ModelServiceUsageError.invalidResponse }
        return ModelServiceUsage(metrics: metrics)
    }

    private struct DeepSeekBalance: Decodable {
        let is_available: Bool
        let balance_infos: [Balance]

        struct Balance: Decodable {
            let currency: String
            let total_balance: String

            var metric: Metric? {
                guard ["USD", "CNY"].contains(currency),
                      total_balance.range(of: #"\A-?[0-9]{1,20}(\.[0-9]{1,12})?\z"#,
                                          options: .regularExpression) != nil
                else { return nil }
                return Metric(title: "Balance", value: "\(total_balance) \(currency)", resetAt: nil)
            }
        }
    }

    private struct ZaiQuota: Decodable {
        let code: Int?
        let success: Bool?
        let data: Quota?

        struct Quota: Decodable {
            let limits: [Limit]
        }

        struct Limit: Decodable {
            let type: String
            let unit: Int?
            let number: Int?
            let percentage: Double?
            let usage: Double?
            let currentValue: Double?
            let remaining: Double?
            let nextResetTime: Double?

            var metric: Metric? {
                let resource: String
                switch type {
                case "CREDIT_LIMIT": resource = "Credits"
                case "TOKENS_LIMIT": resource = "Tokens"
                case "TIME_LIMIT": resource = "MCP calls"
                default: return nil
                }
                guard var percent = percentage, percent.isFinite, percent >= 0 else { return nil }
                if let usage, usage > 0 {
                    let used = remaining.map { max(usage - $0, currentValue ?? 0) } ?? currentValue
                    if let used { percent = max(0, min(usage, used)) / usage * 100 }
                }
                let window: String?
                switch (unit, number) {
                case (5, 1) where type == "TIME_LIMIT": window = "1 month"
                case (1, let count?) where count > 0: window = "\(count) d"
                case (3, let count?) where count > 0: window = "\(count) h"
                case (5, let count?) where count > 0: window = "\(count) min"
                case (6, 1): window = "7 d"
                case (6, let count?) where count > 0: window = "\(count) wk"
                default: window = nil
                }
                let title = window.map { resource + " · " + $0 } ?? resource
                let reset = nextResetTime.flatMap { milliseconds in
                    milliseconds.isFinite && milliseconds > 0
                        ? Date(timeIntervalSince1970: milliseconds / 1000) : nil
                }
                return Metric(title: title, value: "\(Int(min(percent, 100).rounded()))% used", resetAt: reset)
            }
        }
    }
}
