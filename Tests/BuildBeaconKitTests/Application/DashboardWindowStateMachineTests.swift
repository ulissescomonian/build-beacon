import BuildBeaconKit
import XCTest

final class DashboardWindowStateMachineTests: XCTestCase {
    func testTenOpenRequestsDuringOpeningCreateOneWindow() {
        var subject = DashboardWindowStateMachine()

        let firstEffects = subject.requestOpen()
        let repeatedEffects = (0..<9).flatMap { _ in subject.requestOpen() }

        XCTAssertEqual(
            firstEffects,
            [
                .setActivationPolicy(.regular),
                .create(.init(rawValue: 1))
            ]
        )
        XCTAssertTrue(repeatedEffects.isEmpty)
        XCTAssertEqual(subject.phase, .opening(.init(rawValue: 1)))
    }

    func testVisibleDashboardIsFocusedInsteadOfCreatedAgain() {
        var subject = visibleSubject(token: .init(rawValue: 7))

        XCTAssertEqual(subject.requestOpen(), [.focus(.init(rawValue: 7))])
        XCTAssertEqual(
            subject.phase,
            .visible(generation: .init(rawValue: 1), token: .init(rawValue: 7), isMinimized: false)
        )
    }

    func testMinimizedDashboardRestoresThenFocuses() {
        var subject = visibleSubject(token: .init(rawValue: 7))
        subject.setMinimized(true, for: .init(rawValue: 7))

        XCTAssertEqual(subject.requestOpen(), [.restoreAndFocus(.init(rawValue: 7))])
        XCTAssertEqual(
            subject.phase,
            .visible(generation: .init(rawValue: 1), token: .init(rawValue: 7), isMinimized: false)
        )
    }

    func testCloseOfCurrentWindowHidesDockButObsoleteCloseIsIgnored() {
        var subject = visibleSubject(token: .init(rawValue: 7))

        XCTAssertTrue(subject.closeWindow(token: .init(rawValue: 99)).isEmpty)
        XCTAssertEqual(subject.closeWindow(token: .init(rawValue: 7)), [.setActivationPolicy(.accessory)])
        XCTAssertEqual(subject.phase, .hidden)
    }

    func testLateAttachmentAfterTimeoutIsClosedAndCannotBecomeVisible() {
        var subject = DashboardWindowStateMachine()
        let generation = requestedGeneration(&subject)

        XCTAssertEqual(subject.failOpening(generation: generation), [.setActivationPolicy(.accessory)])
        XCTAssertEqual(
            subject.attachWindow(token: .init(rawValue: 7), for: generation),
            [.closeObsolete(.init(rawValue: 7))]
        )
        XCTAssertEqual(subject.phase, .hidden)
    }

    func testSceneRestorationAdoptsSingletonWhileHidden() {
        var subject = DashboardWindowStateMachine()

        XCTAssertEqual(
            subject.adoptWindow(token: .init(rawValue: 7)),
            [.setActivationPolicy(.regular), .focus(.init(rawValue: 7))]
        )
        XCTAssertEqual(
            subject.phase,
            .visible(generation: .init(rawValue: 1), token: .init(rawValue: 7), isMinimized: false)
        )
    }

    func testAdoptionCannotReplaceOpeningOrVisibleSingleton() {
        var subject = DashboardWindowStateMachine()
        _ = subject.requestOpen()

        XCTAssertEqual(subject.adoptWindow(token: .init(rawValue: 8)), [.closeObsolete(.init(rawValue: 8))])

        let generation = openingGeneration(&subject)
        _ = subject.attachWindow(token: .init(rawValue: 7), for: generation)
        XCTAssertEqual(subject.adoptWindow(token: .init(rawValue: 8)), [.closeObsolete(.init(rawValue: 8))])
        XCTAssertEqual(subject.adoptWindow(token: .init(rawValue: 7)), [.focus(.init(rawValue: 7))])
    }

    func testOpenCloseOpenUsesNewGenerationAndRepeatsDockPolicy() {
        var subject = DashboardWindowStateMachine()
        let firstGeneration = requestedGeneration(&subject)
        _ = subject.attachWindow(token: .init(rawValue: 7), for: firstGeneration)
        _ = subject.closeWindow(token: .init(rawValue: 7))

        XCTAssertEqual(
            subject.requestOpen(),
            [
                .setActivationPolicy(.regular),
                .create(.init(rawValue: 2))
            ]
        )
        XCTAssertEqual(subject.phase, .opening(.init(rawValue: 2)))
    }

    func testFailedCurrentOpeningAllowsNewRequestButStaleFailureIsIgnored() {
        var subject = DashboardWindowStateMachine()
        let firstGeneration = requestedGeneration(&subject)
        _ = subject.failOpening(generation: firstGeneration)
        let secondGeneration = requestedGeneration(&subject)

        XCTAssertTrue(subject.failOpening(generation: firstGeneration).isEmpty)
        XCTAssertEqual(subject.phase, .opening(secondGeneration))
    }

    private func visibleSubject(token: DashboardWindowStateMachine.WindowToken) -> DashboardWindowStateMachine {
        var subject = DashboardWindowStateMachine()
        let generation = requestedGeneration(&subject)
        _ = subject.attachWindow(token: token, for: generation)
        return subject
    }

    private func requestedGeneration(
        _ subject: inout DashboardWindowStateMachine
    ) -> DashboardWindowStateMachine.Generation {
        let effects = subject.requestOpen()
        guard case let .create(generation) = effects.last else {
            return .init(rawValue: 0)
        }
        return generation
    }

    private func openingGeneration(
        _ subject: inout DashboardWindowStateMachine
    ) -> DashboardWindowStateMachine.Generation {
        guard case let .opening(generation) = subject.phase else {
            return .init(rawValue: 0)
        }
        return generation
    }
}
