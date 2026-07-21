@testable import BuildBeaconUI
import XCTest

final class TokenSetupGuideTests: XCTestCase {
    func testTokenManagementURLIsTheExactOfficialHTTPSDestination() {
        XCTAssertEqual(
            TokenSetupGuide.tokenManagementURL.absoluteString,
            "https://id.atlassian.com/manage-profile/security/api-tokens"
        )
        XCTAssertEqual(TokenSetupGuide.tokenManagementURL.scheme, "https")
        XCTAssertEqual(TokenSetupGuide.tokenManagementURL.host, "id.atlassian.com")
    }

    func testOfficialInstructionsURLUsesTheBitbucketScopedTokenGuide() {
        XCTAssertEqual(
            TokenSetupGuide.officialInstructionsURL.absoluteString,
            "https://support.atlassian.com/bitbucket-cloud/docs/create-an-api-token/"
        )
        XCTAssertEqual(TokenSetupGuide.officialInstructionsURL.scheme, "https")
        XCTAssertEqual(TokenSetupGuide.officialInstructionsURL.host, "support.atlassian.com")
        XCTAssertEqual(TokenSetupGuide.officialInstructionsURL.path, "/bitbucket-cloud/docs/create-an-api-token")
    }

    func testRequiredPermissionsAreExactlyTheFourReadOnlyPermissions() {
        XCTAssertEqual(
            TokenSetupGuide.requiredPermissions,
            [
                "User data — Read",
                "Workspaces — Read",
                "Repositories — Read",
                "Pipelines — Read",
            ]
        )
        XCTAssertEqual(TokenSetupGuide.requiredPermissions.count, 4)
    }

    func testRequiredPermissionsNeverRequestWriteOrAdminAccess() {
        let permissionText = TokenSetupGuide.requiredPermissions.joined(separator: " ").lowercased()

        XCTAssertFalse(permissionText.contains("write"))
        XCTAssertFalse(permissionText.contains("admin"))
    }

    func testRequiredScopesAreExactlyTheFourReadOnlyBitbucketScopesInOrder() {
        XCTAssertEqual(
            TokenSetupGuide.requiredScopes,
            [
                "read:user:bitbucket",
                "read:workspace:bitbucket",
                "read:repository:bitbucket",
                "read:pipeline:bitbucket",
            ]
        )
        XCTAssertEqual(TokenSetupGuide.requiredScopes.count, 4)
        XCTAssertEqual(TokenSetupGuide.requiredScopes.count, TokenSetupGuide.requiredPermissions.count)
    }

    func testRequiredScopesNeverRequestWriteOrAdminAccess() {
        let scopeText = TokenSetupGuide.requiredScopes.joined(separator: " ").lowercased()

        XCTAssertFalse(scopeText.contains("write"))
        XCTAssertFalse(scopeText.contains("admin"))
    }

    func testClipboardTextContainsOnlyRequiredScopesWithoutCredentialMaterial() {
        let clipboardText = TokenSetupGuide.permissionsClipboardText
        let normalizedClipboardText = clipboardText.lowercased()

        XCTAssertEqual(clipboardText, TokenSetupGuide.requiredScopes.joined(separator: "\n"))
        XCTAssertFalse(normalizedClipboardText.contains("token="))
        XCTAssertFalse(normalizedClipboardText.contains("secret="))
        XCTAssertFalse(normalizedClipboardText.contains("password="))
    }

    func testOptionalPullRequestScopeIsReadOnlyAndNeverChangesTheRequiredTokenContract() {
        XCTAssertEqual(TokenSetupGuide.optionalPullRequestScope, "read:pullrequest:bitbucket")
        XCTAssertEqual(TokenSetupGuide.optionalPullRequestPermission, "Pull requests — Read (optional)")
        XCTAssertFalse(TokenSetupGuide.requiredScopes.contains(TokenSetupGuide.optionalPullRequestScope))
        XCTAssertEqual(TokenSetupGuide.permissionsClipboardText, TokenSetupGuide.requiredScopes.joined(separator: "\n"))
        XCTAssertFalse(TokenSetupGuide.optionalPullRequestScope.lowercased().contains("write"))
        XCTAssertFalse(TokenSetupGuide.optionalPullRequestScope.lowercased().contains("admin"))
    }
}
