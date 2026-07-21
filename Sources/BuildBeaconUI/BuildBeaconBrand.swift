import BuildBeaconKit
import SwiftUI

public enum BuildBeaconBrand {
    public static let symbolName = "light.beacon.max.fill"
}

public struct BuildBeaconMenuBarLabel: View {
    private let state: AggregateState

    public init(state: AggregateState) {
        self.state = state
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: BuildBeaconBrand.symbolName)

            Circle()
                .fill(state.tint)
                .frame(width: 7, height: 7)
                .overlay {
                    Circle().stroke(.background, lineWidth: 1)
                }
                .offset(x: 3, y: 2)
        }
        .frame(width: 20, height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.title)
    }
}
