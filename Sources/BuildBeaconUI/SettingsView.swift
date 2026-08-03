import BuildBeaconKit
import ServiceManagement
import SwiftUI

public struct BuildBeaconSettingsView: View {
    @Bindable private var model: AppModel
    @State private var isRepositoryPickerPresented = false
    @State private var isClearHistoryConfirmationPresented = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        TabView {
            account
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            monitoring
                .tabItem { Label("Monitoring", systemImage: "rectangle.3.group") }
            refreshAndNotifications
                .tabItem { Label("Refresh", systemImage: "arrow.clockwise") }
            general
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 680, height: 520)
        .padding(18)
        .overlay(alignment: .top) {
            if let error = model.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error).lineLimit(2)
                    Spacer()
                    Button("Dismiss") { model.errorMessage = nil }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(8)
            }
        }
        .onAppear { model.startIfNeeded() }
        .task { _ = await model.refreshNotificationPermissionStatus() }
    }

    private var account: some View {
        Form {
            Section("Bitbucket Cloud") {
                if let account = model.configuration.account {
                    LabeledContent("Account", value: account.displayName)
                    LabeledContent("Email", value: account.email)
                    HStack {
                        Button("Revalidate") { Task { await model.revalidate() } }
                        Button("Disconnect", role: .destructive) { Task { await model.disconnect() } }
                    }
                } else {
                    TextField("Atlassian account email", text: $model.email)
                    SecureField("API token", text: $model.token)
                    Button("Connect") { Task { _ = await model.connect() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var monitoring: some View {
        VStack(spacing: 14) {
            Form {
                Section("Add Monitor") {
                    Picker("Workspace", selection: $model.selectedWorkspace) {
                        Text("Select…").tag(Optional<WorkspaceInfo>.none)
                        ForEach(model.workspaces) { workspace in
                            Text(workspace.name).tag(Optional(workspace))
                        }
                    }
                    .onChange(of: model.selectedWorkspace) { _, workspace in
                        Task { await model.selectWorkspace(workspace) }
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Repositories")
                            Text(model.selectedWorkspace == nil
                                ? "Choose a workspace first."
                                : "Filter by project and add multiple repositories at once.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Choose Repositories…") {
                            isRepositoryPickerPresented = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selectedWorkspace == nil || model.isMutatingMonitors)
                    }

                    DisclosureGroup("Advanced: add one repository or branch") {
                        Picker("Repository", selection: $model.selectedRepository) {
                            Text("Select…").tag(Optional<RepositoryInfo>.none)
                            ForEach(model.repositories) { repository in
                                Text(repository.name).tag(Optional(repository))
                            }
                        }
                        .disabled(model.selectedWorkspace == nil)
                        .onChange(of: model.selectedRepository) { _, repository in
                            Task { await model.selectRepository(repository) }
                        }

                        Picker("Target", selection: $model.selectedTarget) {
                            Text("Latest run").tag(MonitorTarget.repositoryLatest)
                            Text("Default branch").tag(MonitorTarget.defaultBranch)
                            ForEach(model.branches) { branch in
                                Text(branch.name).tag(MonitorTarget.branch(exactName: branch.name))
                            }
                        }
                        .disabled(model.selectedRepository == nil)

                        Button("Add Monitor") { Task { await model.addSelectedMonitor() } }
                            .buttonStyle(.bordered)
                            .disabled(model.selectedRepository == nil || model.isMutatingMonitors)
                    }
                }
            }
            .formStyle(.grouped)

            List {
                ForEach(model.configuration.monitors) { monitor in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(monitor.repositoryName).font(.body.weight(.medium))
                            Text("\(monitor.workspaceName) · \(monitor.id.target.displayName)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Production", isOn: Binding(
                            get: { monitor.isProduction },
                            set: { isProduction in
                                Task { await model.setMonitorProduction(isProduction, for: monitor.id) }
                            }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityHint("Marks \(monitor.repositoryName) as a production monitor")
                        .disabled(model.isMutatingMonitors)
                        Spacer()
                        Button(role: .destructive) {
                            Task { await model.removeMonitor(monitor.id) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(monitor.repositoryName)")
                        .disabled(model.isMutatingMonitors)
                    }
                }
            }
            .overlay {
                if model.configuration.monitors.isEmpty {
                    ContentUnavailableView("No Monitors", systemImage: "tray", description: Text("Choose a workspace, then add one or more repositories."))
                }
            }
        }
        .sheet(isPresented: $isRepositoryPickerPresented) {
            RepositoryPickerSheet(model: model)
        }
    }

    private var refreshAndNotifications: some View {
        Form {
            Section("Refresh Interval") {
                Picker("Check every", selection: $model.refreshIntervalSeconds) {
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                    Text("15 minutes").tag(900)
                }
                .onChange(of: model.refreshIntervalSeconds) { _, value in
                    Task { await model.setRefreshInterval(value) }
                }
            }

            Section("Notifications") {
                Toggle("Enable notifications", isOn: $model.notificationsEnabled)
                    .onChange(of: model.notificationsEnabled) { _, value in
                        Task { await model.setNotificationsEnabled(value) }
                    }
                Text("This app setting chooses which pipeline events Build Beacon sends. The system permission below controls whether macOS can show them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                notificationPermission

                Group {
                    Toggle("Pipeline failures", isOn: $model.notifyOnFailure)
                        .onChange(of: model.notifyOnFailure) { _, _ in
                            Task { await model.saveNotificationPreferences() }
                        }
                    Toggle("Pipeline recoveries", isOn: $model.notifyOnRecovery)
                        .onChange(of: model.notifyOnRecovery) { _, _ in
                            Task { await model.saveNotificationPreferences() }
                        }
                    Toggle("Awaiting approval", isOn: $model.notifyOnApproval)
                        .onChange(of: model.notifyOnApproval) { _, _ in
                            Task { await model.saveNotificationPreferences() }
                        }
                    Picker("Approval reminder", selection: Binding(
                        get: { model.approvalReminderInterval },
                        set: { model.setApprovalReminderInterval($0) }
                    )) {
                        Text("Off").tag(ApprovalReminderInterval.none)
                        Text("10 minutes").tag(ApprovalReminderInterval.tenMinutes)
                        Text("15 minutes").tag(ApprovalReminderInterval.fifteenMinutes)
                    }
                    Text("Reminds you once while a pipeline still awaits approval.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Successful favorite pipelines", isOn: $model.notifyOnFavoriteSuccess)
                        .onChange(of: model.notifyOnFavoriteSuccess) { _, _ in
                            Task { await model.saveNotificationPreferences() }
                        }
                }
                .disabled(!model.notificationsEnabled)
            }
        }
        .formStyle(.grouped)
    }

    private var general: some View {
        Form {
            Section("Dashboard") {
                Picker("Group monitors by", selection: presentationBinding(\.grouping)) {
                    Text("No grouping").tag(MonitorPresentationPreferences.Grouping.none)
                    Text("Project").tag(MonitorPresentationPreferences.Grouping.project)
                }
                Picker("Sort monitors by", selection: presentationBinding(\.sortOrder)) {
                    Text("Status").tag(MonitorPresentationPreferences.SortOrder.status)
                    Text("Project").tag(MonitorPresentationPreferences.SortOrder.project)
                    Text("Repository").tag(MonitorPresentationPreferences.SortOrder.repository)
                    Text("Recent activity").tag(MonitorPresentationPreferences.SortOrder.recentActivity)
                }
                Toggle("Show favorites first", isOn: presentationBinding(\.favoritesFirst))
                Toggle("Hide repositories without runs", isOn: presentationBinding(\.hideRepositoriesWithoutRuns))
            }

            Section("History") {
                Toggle("Record pipeline history", isOn: $model.historyEnabled)
                    .onChange(of: model.historyEnabled) { _, enabled in
                        Task { await model.setHistoryEnabled(enabled) }
                    }
                Text("Turning this off pauses new local history recordings. Existing history stays until you clear it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Monitor", selection: $model.selectedMonitorID) {
                    Text("Select a monitor…").tag(Optional<MonitorID>.none)
                    ForEach(model.configuration.monitors) { monitor in
                        Text("\(monitor.workspaceName) · \(monitor.repositoryName)")
                            .tag(Optional(monitor.id))
                    }
                }
                .disabled(model.configuration.monitors.isEmpty)
                .onChange(of: model.selectedMonitorID) { _, monitorID in
                    Task { _ = await model.loadHistory(for: monitorID) }
                }
                Button("Clear History", role: .destructive) {
                    isClearHistoryConfirmationPresented = true
                }
                .disabled(model.selectedMonitorID == nil)
                .accessibilityHint("Clears history for the selected monitor only")
            }

            Section("Startup") {
                Toggle("Open Build Beacon at login", isOn: $model.launchAtLogin)
                    .onChange(of: model.launchAtLogin) { _, enabled in
                        Task { await model.setLaunchAtLogin(enabled) }
                    }
            }
            Section("Privacy") {
                LabeledContent("Credential storage", value: "macOS Keychain")
                LabeledContent("Remote telemetry", value: "Disabled")
                Text("Repository names and pipeline metadata stay on this Mac and are sent only to Bitbucket Cloud when required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Clear Pipeline History?", isPresented: $isClearHistoryConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) {
                Task { await model.clearHistory() }
            }
        } message: {
            Text("This removes the locally stored history for the selected monitor. It does not change anything in Bitbucket.")
        }
    }

    private var notificationPermission: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Notification permission", value: notificationPermissionTitle)
            Text(notificationPermissionDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if model.notificationPermissionStatus?.authorization == .notDetermined {
                    Button("Allow Notifications") {
                        Task { _ = await model.requestNotificationPermission() }
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("Test Notification") {
                    guard let route = notificationTestRoute else { return }
                    Task { await model.sendTestNotification(route: route) }
                }
                .disabled(notificationTestRoute == nil || !notificationsAreAvailable)

                Button("Open System Settings") {
                    model.openNotificationSettings()
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }

    private var notificationPermissionTitle: String {
        guard let status = model.notificationPermissionStatus else { return "Checking…" }
        return switch status.authorization {
        case .notDetermined: "Permission needed"
        case .denied: "Not allowed"
        case .authorized: status.alertsEnabled ? "Allowed" : "Alerts are disabled"
        case .provisional: "Allowed temporarily"
        case .ephemeral: "Allowed for this session"
        case .unsupported: "Unavailable"
        }
    }

    private var notificationPermissionDescription: String {
        guard let status = model.notificationPermissionStatus else {
            return "Checking the current notification permission."
        }
        return switch status.authorization {
        case .notDetermined:
            "Allow notifications to receive pipeline failures, recoveries, and approval requests."
        case .denied:
            "Notifications are turned off for Build Beacon. Open System Settings to allow them."
        case .authorized, .provisional, .ephemeral:
            status.soundsEnabled
                ? "Notifications are available. Send a test to confirm how they appear."
                : "Notifications are available, but sound is disabled in System Settings."
        case .unsupported:
            "Notifications are unavailable on this system."
        }
    }

    private var notificationsAreAvailable: Bool {
        guard let status = model.notificationPermissionStatus else { return false }
        return switch status.authorization {
        case .authorized, .provisional, .ephemeral: status.alertsEnabled
        case .notDetermined, .denied, .unsupported: false
        }
    }

    private var notificationTestRoute: NotificationRoute? {
        guard let monitorID = model.selectedMonitorID ?? model.configuration.monitors.first?.id else { return nil }
        let run = model.snapshot?.observations[monitorID]?.lastKnownRun
        return NotificationRoute(monitorID: monitorID, runID: run?.id, buildNumber: run?.buildNumber)
    }

    private func presentationBinding<Value>(
        _ keyPath: WritableKeyPath<MonitorPresentationPreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model.monitorPresentation[keyPath: keyPath] },
            set: { value in
                var updated = model.monitorPresentation
                updated[keyPath: keyPath] = value
                Task { await model.saveMonitorPresentation(updated) }
            }
        )
    }
}
