import AppKit

/// Bridges AppKit reopen requests, including Dock clicks, into the dashboard
/// presentation coordinator owned by the SwiftUI app composition root.
@MainActor
final class BuildBeaconApplicationDelegate: NSObject, NSApplicationDelegate {
    typealias DashboardReopener = @MainActor () -> Void

    private var dashboardReopener: DashboardReopener?
    private var hasPendingReopenRequest = false

    override init() {
        super.init()
    }

    /// Installs the presentation route after the app composition is available.
    ///
    /// Keeping the route injectable makes the delegate independently testable
    /// and avoids introducing process-global presentation state.
    func install(reopenHandler: @escaping DashboardReopener) {
        dashboardReopener = reopenHandler

        guard hasPendingReopenRequest else { return }
        hasPendingReopenRequest = false
        reopenHandler()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard let dashboardReopener else {
            hasPendingReopenRequest = true
            return false
        }

        dashboardReopener()
        return false
    }
}
