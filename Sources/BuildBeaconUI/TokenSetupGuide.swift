import Foundation

public enum TokenSetupGuide {
    public static let tokenManagementURL = URL(
        string: "https://id.atlassian.com/manage-profile/security/api-tokens"
    )!

    public static let officialInstructionsURL = URL(
        string: "https://support.atlassian.com/bitbucket-cloud/docs/create-an-api-token/"
    )!

    public static let requiredPermissions = [
        "User data — Read",
        "Workspaces — Read",
        "Repositories — Read",
        "Pipelines — Read",
    ]

    public static let requiredScopes = [
        "read:user:bitbucket",
        "read:workspace:bitbucket",
        "read:repository:bitbucket",
        "read:pipeline:bitbucket",
    ]

    /// This scope is deliberately optional. Pipeline monitoring works with the four
    /// required scopes above, while this adds pull-request context for tokens that
    /// choose to grant it.
    public static let optionalPullRequestPermission = "Pull requests — Read (optional)"
    public static let optionalPullRequestScope = "read:pullrequest:bitbucket"

    public static let permissionsClipboardText = requiredScopes.joined(separator: "\n")
}
