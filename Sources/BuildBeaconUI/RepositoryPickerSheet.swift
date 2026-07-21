import BuildBeaconKit
import SwiftUI

struct RepositoryPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var model: AppModel

    @State private var query = ""
    @State private var projectFilter = ProjectFilter.all
    @State private var selectedRepositoryIDs = Set<RepositoryID>()
    @State private var target: MonitorTarget = .repositoryLatest
    @State private var isAdding = false

    init(model: AppModel) {
        self.model = model
    }

    private enum ProjectFilter: Hashable, Identifiable {
        case all
        case project(key: String)
        case noProject

        var id: String {
            switch self {
            case .all: "all"
            case let .project(key): "project-\(key)"
            case .noProject: "no-project"
            }
        }
    }

    private struct Project: Identifiable, Hashable {
        let key: String
        let name: String
        var id: String { key }
    }

    private var projects: [Project] {
        let values = model.repositories.compactMap { repository -> Project? in
            guard let key = repository.projectKey, !key.isEmpty else { return nil }
            return Project(key: key, name: repository.projectName ?? key)
        }
        return Dictionary(grouping: values, by: \.key).compactMap { $0.value.first }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return order == .orderedAscending || (order == .orderedSame && lhs.key < rhs.key)
            }
    }

    private var filteredRepositories: [RepositoryInfo] {
        model.repositories.filter { matches(project: $0) && matches(query: query, repository: $0) }
            .sorted { lhs, rhs in
                let leftProject = lhs.projectName ?? lhs.projectKey ?? ""
                let rightProject = rhs.projectName ?? rhs.projectKey ?? ""
                let projectOrder = leftProject.localizedStandardCompare(rightProject)
                if projectOrder != .orderedSame { return projectOrder == .orderedAscending }
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.slug.localizedStandardCompare(rhs.slug) == .orderedAscending
            }
    }

    private var selectableVisibleRepositories: [RepositoryInfo] {
        filteredRepositories.filter { !isAlreadyMonitored($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose Repositories")
                        .font(.title2.weight(.semibold))
                    Text("Add multiple repositories from the selected workspace.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Monitor", selection: $target) {
                    Text("Latest run").tag(MonitorTarget.repositoryLatest)
                    Text("Default branch").tag(MonitorTarget.defaultBranch)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            .padding(20)

            Divider()
            HStack(spacing: 0) {
                projectSidebar.frame(width: 210)
                Divider()
                repositoryList
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Text("\(selectedRepositoryIDs.count) selected")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isAdding ? "Adding…" : "Add \(selectedRepositoryIDs.count) Monitors") {
                    addSelectedRepositories()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedRepositoryIDs.isEmpty || isAdding || model.isMutatingMonitors)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 820, height: 560)
        .onChange(of: target) { _, _ in pruneAlreadyMonitoredSelections() }
        .onChange(of: model.configuration.monitors) { _, _ in pruneAlreadyMonitoredSelections() }
    }

    private var projectSidebar: some View {
        List(selection: $projectFilter) {
            Label("All Projects", systemImage: "square.grid.2x2")
                .tag(ProjectFilter.all)
            ForEach(projects) { project in
                HStack {
                    Text(project.name)
                    Spacer(minLength: 4)
                    Text("\(repositoryCount(for: .project(key: project.key)))")
                        .foregroundStyle(.tertiary)
                }
                .tag(ProjectFilter.project(key: project.key))
            }
            HStack {
                Text("No Project")
                Spacer(minLength: 4)
                Text("\(repositoryCount(for: .noProject))")
                    .foregroundStyle(.tertiary)
            }
            .tag(ProjectFilter.noProject)
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Project filter")
    }

    private var repositoryList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search repositories", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding([.top, .horizontal], 14)

            HStack {
                Button("Select All Visible") {
                    selectedRepositoryIDs.formUnion(selectableVisibleRepositories.map(\.id))
                }
                .buttonStyle(.link)
                .disabled(selectableVisibleRepositories.isEmpty)
                Button("Clear") { selectedRepositoryIDs.removeAll() }
                    .buttonStyle(.link)
                    .disabled(selectedRepositoryIDs.isEmpty)
                Spacer()
                Text("\(filteredRepositories.count) repositories")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            if model.repositories.isEmpty {
                ContentUnavailableView("No Repositories", systemImage: "folder", description: Text("This workspace has no repositories to add."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredRepositories.isEmpty {
                ContentUnavailableView("No Matching Repositories", systemImage: "magnifyingglass", description: Text("Try a different project or search term."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredRepositories) { repository in
                    repositoryRow(repository)
                }
                .listStyle(.inset)
            }
        }
    }

    private func repositoryRow(_ repository: RepositoryInfo) -> some View {
        let alreadyMonitored = isAlreadyMonitored(repository)
        return Button {
            guard !alreadyMonitored else { return }
            if selectedRepositoryIDs.contains(repository.id) {
                selectedRepositoryIDs.remove(repository.id)
            } else {
                selectedRepositoryIDs.insert(repository.id)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selectedRepositoryIDs.contains(repository.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedRepositoryIDs.contains(repository.id) ? Color.accentColor : .secondary)
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 3) {
                    Text(repository.name).foregroundStyle(.primary)
                    Text(detailText(for: repository)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if alreadyMonitored {
                    Text("Already monitored").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(alreadyMonitored)
        .opacity(alreadyMonitored ? 0.55 : 1)
        .accessibilityLabel(alreadyMonitored ? "\(repository.name), already monitored" : repository.name)
        .accessibilityValue(selectedRepositoryIDs.contains(repository.id) ? "Selected" : "Not selected")
    }

    private func matches(project repository: RepositoryInfo) -> Bool {
        switch projectFilter {
        case .all: true
        case let .project(key): repository.projectKey == key
        case .noProject: repository.projectKey == nil || repository.projectKey?.isEmpty == true
        }
    }

    private func matches(query: String, repository: RepositoryInfo) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return true }
        return [repository.name, repository.slug, repository.projectKey, repository.projectName]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(term) }
    }

    private func repositoryCount(for filter: ProjectFilter) -> Int {
        model.repositories.filter {
            switch filter {
            case .all: true
            case let .project(key): $0.projectKey == key
            case .noProject: $0.projectKey == nil || $0.projectKey?.isEmpty == true
            }
        }.count
    }

    private func detailText(for repository: RepositoryInfo) -> String {
        let project = repository.projectName ?? repository.projectKey ?? "No project"
        return "\(project) · \(repository.slug)"
    }

    private func isAlreadyMonitored(_ repository: RepositoryInfo) -> Bool {
        guard let account = model.configuration.account else { return false }
        let id = MonitorID(accountID: account.id, workspaceID: repository.workspaceID, repositoryID: repository.id, target: target)
        return model.configuration.monitors.contains { $0.id == id }
    }

    private func pruneAlreadyMonitoredSelections() {
        selectedRepositoryIDs = selectedRepositoryIDs.filter { identifier in
            guard let repository = model.repositories.first(where: { $0.id == identifier }) else { return false }
            return !isAlreadyMonitored(repository)
        }
    }

    private func addSelectedRepositories() {
        let repositories = model.repositories.filter { selectedRepositoryIDs.contains($0.id) && !isAlreadyMonitored($0) }
        guard !repositories.isEmpty else { return }
        isAdding = true
        Task {
            let added = await model.addMonitors(repositories: repositories, target: target)
            isAdding = false
            if added > 0 { dismiss() }
        }
    }
}
