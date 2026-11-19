import Foundation
import Security

enum ServiceUsage {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static func key(for service: ModelService) throws -> String? {
        var query = try keychainQuery(for: service)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw ModelServiceUsageError.keychainUnavailable
        }
        return key
    }

    static func saveKey(_ key: String, for service: ModelService) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ModelServiceUsageError.keyMissing }
        guard value.utf8.count <= 4096, value.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw ModelServiceUsageError.unauthorized
        }
        let query = try keychainQuery(for: service)
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw ModelServiceUsageError.keychainUnavailable }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw ModelServiceUsageError.keychainUnavailable
        }
    }

    static func removeKey(for service: ModelService) throws {
        let query = try keychainQuery(for: service)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ModelServiceUsageError.keychainUnavailable
        }
    }

    static func fetch(for service: ModelService,
                      completion: @escaping @MainActor @Sendable (Result<ModelServiceUsage, ModelServiceUsageError>) -> Void) {
        @Sendable func finish(_ result: Result<ModelServiceUsage, ModelServiceUsageError>) {
            DispatchQueue.main.async { completion(result) }
        }
        let endpoint: String
        switch service {
        case .deepseek: endpoint = "https://api.deepseek.com/user/balance"
        case .zai: endpoint = "https://api.z.ai/api/monitor/usage/quota/limit"
        default: finish(.failure(.unavailable)); return
        }
        guard let url = URL(string: endpoint) else { finish(.failure(.unavailable)); return }
        let token: String
        do {
            guard let value = try key(for: service) else { finish(.failure(.keyMissing)); return }
            token = value
        } catch {
            finish(.failure(.keychainUnavailable))
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue(service == .deepseek ? "Bearer " + token : token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, response, error in
            guard error == nil, let response = response as? HTTPURLResponse else {
                finish(.failure(.unavailable)); return
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                finish(.failure(.unauthorized)); return
            }
            guard response.statusCode == 200 else { finish(.failure(.unavailable)); return }
            guard let data, data.count <= 1_048_576 else { finish(.failure(.invalidResponse)); return }
            do {
                finish(.success(try ModelServiceUsage.decode(data, for: service)))
            } catch let error as ModelServiceUsageError {
                finish(.failure(error))
            } catch {
                finish(.failure(.invalidResponse))
            }
        }.resume()
    }

    private static func keychainQuery(for service: ModelService) throws -> [String: Any] {
        guard service == .deepseek || service == .zai, let bundleID = Bundle.main.bundleIdentifier else {
            throw ModelServiceUsageError.keychainUnavailable
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: bundleID + ".model-services",
            kSecAttrAccount as String: service.rawValue,
        ]
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
