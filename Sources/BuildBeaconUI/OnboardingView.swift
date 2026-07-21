import AppKit
import BuildBeaconKit
import SwiftUI

public struct OnboardingView: View {
    private enum FocusedField: Hashable {
        case email
        case token
    }

    @Bindable private var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedField: FocusedField?
    @State private var didOpenTokenPage = false
    @State private var didCopyPermissions = false
    @State private var copiedScope: String?

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    accountStep
                    tokenCreationStep
                    tokenPasteStep

                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                            .accessibilityLabel(error)
                    }
                }
                .padding(24)
            }

            Divider()

            HStack {
                Button("Cancel") { dismissWindow(id: "onboarding") }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Connecting")
                }
                Button("Connect") {
                    Task {
                        if await model.connect() {
                            dismissWindow(id: "onboarding")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    model.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    model.token.isEmpty ||
                    model.isBusy
                )
            }
            .padding(20)
        }
        .frame(width: 590, height: 560)
        .onAppear { focusedField = .email }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, didOpenTokenPage else { return }
            focusedField = .token
            didOpenTokenPage = false
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: BuildBeaconBrand.symbolName)
                .font(.system(size: 34, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to Build Beacon")
                    .font(.title.bold())
                Text("Native Bitbucket pipeline monitoring for your menu bar.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
    }

    private var accountStep: some View {
        step("1. Atlassian account") {
            TextField("Atlassian account email", text: $model.email)
                .textContentType(.emailAddress)
                .focused($focusedField, equals: .email)
                .accessibilityHint("The email for your Atlassian account")
        }
    }

    private var tokenCreationStep: some View {
        step("2. Create a read-only API token") {
            Button("Open Atlassian Token Page") {
                didOpenTokenPage = true
                openURL(TokenSetupGuide.tokenManagementURL)
            }
            .accessibilityHint("Opens Atlassian in your default browser to create a token")

            VStack(alignment: .leading, spacing: 6) {
                Text("Choose Create API token with scopes — not Create API token.")
                    .font(.subheadline.weight(.semibold))
                Text("After the name and expiration, select Bitbucket, then search for and enable the four Read scopes below.")
                    .font(.subheadline)
                Link("View Atlassian step-by-step guide", destination: TokenSetupGuide.officialInstructionsURL)
                    .font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 10) {
                Text("Required Bitbucket scopes")
                    .font(.subheadline.weight(.semibold))

                ForEach(TokenSetupGuide.requiredScopes.indices, id: \.self) { index in
                    let permission = TokenSetupGuide.requiredPermissions[index]
                    let scope = TokenSetupGuide.requiredScopes[index]

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(permission)
                                .foregroundStyle(.secondary)
                            Text(scope)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .accessibilityLabel("Scope: \(scope)")
                        }

                        Spacer(minLength: 4)

                        Button(copiedScope == scope ? "Copied" : "Copy") {
                            copyScope(scope)
                        }
                        .controlSize(.small)
                        .accessibilityLabel("Copy \(scope)")
                        .accessibilityHint("Copies this exact Bitbucket scope")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Optional pull request context")
                        .font(.subheadline.weight(.semibold))
                    Text("Build Beacon works with the four scopes above. Add this extra Read scope only if you want pull request context when it is available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(TokenSetupGuide.optionalPullRequestPermission)
                            .foregroundStyle(.secondary)
                        Text(TokenSetupGuide.optionalPullRequestScope)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityLabel("Optional scope: \(TokenSetupGuide.optionalPullRequestScope)")
                    }

                    Spacer(minLength: 4)

                    Button(copiedScope == TokenSetupGuide.optionalPullRequestScope ? "Copied" : "Copy") {
                        copyScope(TokenSetupGuide.optionalPullRequestScope)
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Copy \(TokenSetupGuide.optionalPullRequestScope)")
                    .accessibilityHint("Copies this optional Bitbucket scope")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(didCopyPermissions ? "Scope IDs Copied" : "Copy All Scope IDs") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(TokenSetupGuide.permissionsClipboardText, forType: .string)
                didCopyPermissions = true
            }
            .accessibilityHint("Copies all required Bitbucket scope IDs")
        }
    }

    private var tokenPasteStep: some View {
        step("3. Paste the API token") {
            HStack(spacing: 10) {
                SecureField("API token", text: $model.token)
                    .focused($focusedField, equals: .token)
                    .accessibilityHint("Your read-only Bitbucket API token")

                VStack(alignment: .leading, spacing: 3) {
                    Text("Paste Token")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    PasteButton(payloadType: String.self) { values in
                        guard let token = values.first else { return }
                        model.token = token
                    }
                    .accessibilityLabel("Paste Token")
                    .accessibilityHint("Pastes an API token only after you explicitly choose it")
                }
            }

            Text("The token is stored only in your Mac login Keychain. Build Beacon never stores it in preferences or files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func step<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func copyScope(_ scope: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(scope, forType: .string)
        copiedScope = scope
    }
}
