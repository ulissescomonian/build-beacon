import Foundation

public enum TokenSetupGuide {
    public static let tokenManagementURL = URL(
        string: "https://id.atlassian.com/manage-profile/security/api-tokens"
    )!

    public static let officialInstructionsURL = URL(
        string: "https://support.atlassian.com/bitbucket-cloud/docs/create-an-api-token/"
    )!

    public static let recommendedPermissions = [
        "Accounts (Read)",
        "GPG keys (Read)",
        "Issues (Read)",
        "User data (Read)",
        "Packages (Read)",
        "Permissions (Read)",
        "Pipelines (Read)",
        "Projects (Read)",
        "Pull requests (Read)",
        "Repositories (Read)",
        "Runners (Read)",
        "Snippets (Read)",
        "SSH keys (Read)",
        "Tests (Read)",
        "Users (Read)",
        "Webhooks (Read)",
        "Wikis (Read)",
        "Workspaces (Read)",
    ]

    public static let recommendedScopes = [
        "read:account",
        "read:gpg-key:bitbucket",
        "read:issue:bitbucket",
        "read:me",
        "read:package:bitbucket",
        "read:permission:bitbucket",
        "read:pipeline:bitbucket",
        "read:project:bitbucket",
        "read:pullrequest:bitbucket",
        "read:repository:bitbucket",
        "read:runner:bitbucket",
        "read:snippet:bitbucket",
        "read:ssh-key:bitbucket",
        "read:test:bitbucket",
        "read:user:bitbucket",
        "read:webhook:bitbucket",
        "read:wiki:bitbucket",
        "read:workspace:bitbucket",
    ]

    public static let permissionsClipboardText = recommendedScopes.joined(separator: "\n")
}
