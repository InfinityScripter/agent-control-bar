import Cocoa

extension ModelServiceUsageError {
    var message: String {
        switch self {
        case .keyMissing: return "Enter an API key."
        case .keychainUnavailable: return "Couldn't access the key in macOS Keychain."
        case .unauthorized: return "This key wasn't accepted. Check the key and account type."
        case .unavailable: return "The service couldn't be reached. Refresh to try again."
        case .invalidResponse: return "The service returned no readable account figures."
        }
    }
}

extension StatusController {
    func pollServiceUsage(now: Date = Date()) {
        for service in ServiceUsageBoard.services {
            refreshServiceUsage(service, now: now, minimumInterval: ServiceUsageBoard.openInterval)
        }
    }

    func refreshServiceUsage(_ service: ModelService, now: Date = Date(), minimumInterval: TimeInterval = 0) {
        guard !hiddenModelServices.contains(service),
              let request = serviceUsage.begin(service, at: now, minimumInterval: minimumInterval)
        else { return }
        settingsStore.refresh()
        refreshCounts()
        let finished: @MainActor @Sendable (Result<ModelServiceUsage, ModelServiceUsageError>) -> Void = {
            [weak self] result in
            guard let self, self.serviceUsage.finish(service, request: request, result: result, at: Date())
            else { return }
            self.settingsStore.refresh()
            self.refreshCounts()
        }
        DispatchQueue.global(qos: .utility).async {
            ServiceUsage.fetch(for: service, completion: finished)
        }
    }

    func editServiceKey(_ service: ModelService) {
        let alert = NSAlert()
        alert.messageText = "\(service.title) API key"
        alert.informativeText = service == .zai
            ? "Enter your Z.ai Personal Coding Plan API key. It will be stored in macOS Keychain."
            : "Enter a DeepSeek API key to read your balance. It will be stored in macOS Keychain."
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = "API key"
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try ServiceUsage.saveKey(input.stringValue, for: service)
            serviceUsage.reset(service, to: .keySaved)
            refreshServiceUsage(service)
            settingsStore.refresh()
            refreshCounts()
        } catch {
            showServiceKeyError(error)
        }
    }

    func removeServiceKey(_ service: ModelService) {
        do {
            try ServiceUsage.removeKey(for: service)
            serviceUsage.reset(service, to: .notConfigured)
            settingsStore.refresh()
            refreshCounts()
        } catch {
            showServiceKeyError(error)
        }
    }

    private func showServiceKeyError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't update the API key"
        alert.informativeText = (error as? ModelServiceUsageError)?.message
            ?? ModelServiceUsageError.keychainUnavailable.message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
