import Foundation

struct ServiceUsageBoard {
    static let services: [ModelService] = [.deepseek, .zai]
    static let openInterval: TimeInterval = 60

    enum Status: Equatable {
        case unknown, notConfigured, keySaved
        case ready(ModelServiceUsage, Date)
        case failed(ModelServiceUsageError)

        var hasKey: Bool {
            switch self {
            case .keySaved, .ready, .failed(.unauthorized), .failed(.unavailable), .failed(.invalidResponse): return true
            default: return false
            }
        }
    }

    struct Account: Equatable {
        var status: Status = .unknown
        var request: UUID?
        var lastStarted: Date?
    }

    private var accounts: [ModelService: Account] = [:]

    subscript(service: ModelService) -> Account { accounts[service] ?? Account() }

    mutating func begin(_ service: ModelService, at now: Date, minimumInterval: TimeInterval) -> UUID? {
        var account = self[service]
        guard account.request == nil else { return nil }
        if let last = account.lastStarted, now.timeIntervalSince(last) < minimumInterval,
           minimumInterval > 0 { return nil }
        let request = UUID()
        account.request = request
        account.lastStarted = now
        accounts[service] = account
        return request
    }

    mutating func reset(_ service: ModelService, to status: Status = .unknown) {
        accounts[service] = Account(status: status)
    }

    @discardableResult
    mutating func finish(_ service: ModelService, request: UUID,
                         result: Result<ModelServiceUsage, ModelServiceUsageError>, at now: Date) -> Bool {
        var account = self[service]
        guard account.request == request else { return false }
        account.request = nil
        switch result {
        case .success(let usage): account.status = .ready(usage, now)
        case .failure(.keyMissing): account.status = .notConfigured
        case .failure(let error): account.status = .failed(error)
        }
        accounts[service] = account
        return true
    }
}
