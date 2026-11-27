import ServiceManagement

enum LoginItem {
    static var enabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    static func set(_ enabled: Bool) {
        guard enabled != Self.enabled else { return }
        if enabled { try? SMAppService.mainApp.register() }
        else { try? SMAppService.mainApp.unregister() }
    }
}
