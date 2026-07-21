import BuildBeaconKit
import BuildBeaconUI
import SwiftUI

@main
struct BuildBeaconApp: App {
    @State private var model: AppModel
    @State private var lifecycle: AppLifecycleCoordinator
    @State private var dashboardPresentation: DashboardPresentationController

    init() {
        let runtime: any BuildBeaconRuntime
        do {
            runtime = try ProductionRuntime()
        } catch {
            runtime = UnavailableRuntime(failure: error)
        }
        let model = AppModel(runtime: runtime)
        let dashboardPresentation = DashboardPresentationController()
        let lifecycle = AppLifecycleCoordinator(
            model: model,
            dashboardPresentation: dashboardPresentation
        )
        _model = State(initialValue: model)
        _lifecycle = State(initialValue: lifecycle)
        _dashboardPresentation = State(initialValue: dashboardPresentation)
        lifecycle.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarDashboardHost(
                model: model,
                dashboardPresentation: dashboardPresentation
            )
        } label: {
            MenuBarLifecycleBridge(
                state: model.aggregateState,
                dashboardPresentation: dashboardPresentation
            )
        }
        .menuBarExtraStyle(.window)

        Window("Build Beacon", id: "dashboard") {
            LaunchContainerView(
                model: model,
                dashboardPresentation: dashboardPresentation
            )
        }
        .defaultSize(width: 980, height: 650)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Pipelines") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.isConnected || model.isRefreshing)
            }
        }

        Window("Connect Bitbucket", id: "onboarding") {
            OnboardingView(model: model)
        }
        .windowResizability(.contentSize)

        Settings {
            BuildBeaconSettingsView(model: model)
        }
    }
}

private struct LaunchContainerView: View {
    @Bindable var model: AppModel
    let dashboardPresentation: DashboardPresentationController

    var body: some View {
        Group {
            if model.isConnected {
                DashboardView(model: model)
            } else {
                OnboardingView(model: model)
            }
        }
        .background(
            DashboardWindowRegistrationBridge(presentation: dashboardPresentation)
                .frame(width: 0, height: 0)
        )
    }
}

private struct MenuBarDashboardHost: View {
    @Bindable var model: AppModel
    let dashboardPresentation: DashboardPresentationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarContentView(model: model) {
            dashboardPresentation.openDashboard()
        }
        .onAppear {
            dashboardPresentation.install {
                openWindow(id: "dashboard")
            }
        }
    }
}

private struct MenuBarLifecycleBridge: View {
    let state: AggregateState
    let dashboardPresentation: DashboardPresentationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        BuildBeaconMenuBarLabel(state: state)
            .onAppear {
                dashboardPresentation.install {
                    openWindow(id: "dashboard")
                }
            }
    }
}
