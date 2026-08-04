import CoreGraphics

enum DashboardRepositoryRowMetrics {
    static let minimumHeight: CGFloat = 64
    static let inlineActionMinimumHeight: CGFloat = 84
    static let metadataColumnWidth: CGFloat = 76
    static let favoriteReorderAnimationDuration = 0.18
    static let favoriteButtonHitTargetSize: CGFloat = 36

    static func minimumHeight(hasInlineAction: Bool) -> CGFloat {
        hasInlineAction ? inlineActionMinimumHeight : minimumHeight
    }

    /// Changes the content identity when an inline action appears or disappears,
    /// so List remeasures the row instead of retaining its compact layout.
    static func layoutRevision(hasInlineAction: Bool) -> Int {
        hasInlineAction ? 1 : 0
    }
}
