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

    func testRecommendedPermissionsAreExactlyAllBitbucketReadPermissions() {
        XCTAssertEqual(
            TokenSetupGuide.recommendedPermissions,
            [
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
        )
        XCTAssertEqual(TokenSetupGuide.recommendedPermissions.count, 18)
    }

    func testRecommendedPermissionsNeverRequestWriteOrAdminAccess() {
        let permissionText = TokenSetupGuide.recommendedPermissions.joined(separator: " ").lowercased()

        XCTAssertFalse(permissionText.contains("write"))
        XCTAssertFalse(permissionText.contains("admin"))
    }

    func testRecommendedScopesAreExactlyAllBitbucketReadScopesInOrder() {
        XCTAssertEqual(
            TokenSetupGuide.recommendedScopes,
            [
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
        )
        XCTAssertEqual(TokenSetupGuide.recommendedScopes.count, 18)
        XCTAssertEqual(TokenSetupGuide.recommendedScopes.count, TokenSetupGuide.recommendedPermissions.count)
    }

    func testRecommendedScopesNeverRequestWriteOrAdminAccess() {
        let scopeText = TokenSetupGuide.recommendedScopes.joined(separator: " ").lowercased()

        XCTAssertFalse(scopeText.contains("write"))
        XCTAssertFalse(scopeText.contains("admin"))
        XCTAssertTrue(TokenSetupGuide.recommendedScopes.allSatisfy { $0.hasPrefix("read:") })
    }

    func testClipboardTextContainsOnlyRequiredScopesWithoutCredentialMaterial() {
        let clipboardText = TokenSetupGuide.permissionsClipboardText
        let normalizedClipboardText = clipboardText.lowercased()

        XCTAssertEqual(clipboardText, TokenSetupGuide.recommendedScopes.joined(separator: "\n"))
        XCTAssertFalse(normalizedClipboardText.contains("token="))
        XCTAssertFalse(normalizedClipboardText.contains("secret="))
        XCTAssertFalse(normalizedClipboardText.contains("password="))
    }

    func testPullRequestScopeIsIncludedInTheRecommendedTokenContract() {
        XCTAssertTrue(TokenSetupGuide.recommendedScopes.contains("read:pullrequest:bitbucket"))
        XCTAssertEqual(TokenSetupGuide.permissionsClipboardText, TokenSetupGuide.recommendedScopes.joined(separator: "\n"))
    }
}
