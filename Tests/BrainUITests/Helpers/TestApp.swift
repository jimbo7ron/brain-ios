// TestApp.swift
// brain-ios — BrainUITests
//
// Helpers for building an `XCUIApplication` configured for the Tier 2
// e2e harness. Centralises the launch-argument vocabulary so tests
// don't hand-spell `-uiTesting` and the seeding flags.
//
// The app reads these flags in `BrainApp.init`:
//   * `-uiTesting`                     — required; switches the app
//                                        into hermetic test mode (fake
//                                        server, in-memory store,
//                                        signed-in session).
//   * `-uiTestingSeedTodo "<title>"`   — seeds an inbox todo due
//                                        today (so it lands in
//                                        TodayView's "Due today"
//                                        section).
//   * `-uiTestingSeedProject "<name>"` — seeds a project with M26
//                                        default sections.
//
// Each call to `launch()` resets the in-memory `FakeBrainState`, so
// no fixtures leak between tests.

import XCTest

enum TestApp {

    /// Build a fresh `XCUIApplication` with `-uiTesting` already in
    /// `launchArguments`. Callers can append additional seed flags
    /// before calling `launch()` themselves, or use
    /// `launchSignedIn(seeding:)` for the common path.
    static func make() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        return app
    }

    /// Launch the app already signed in (the harness skips LoginView
    /// under `-uiTesting`) with optional pre-seeded fixtures. Pass
    /// `seedingTodosWithIDs` / `seedingProjectsWithIDs` when the test
    /// needs a deterministic id so it can locate `todo-row-<id>` /
    /// `project-row-<id>` elements directly.
    @discardableResult
    static func launchSignedIn(
        seedingTodos todos: [String] = [],
        seedingTodosWithIDs todoIDs: [(title: String, id: String)] = [],
        seedingProjects projects: [String] = [],
        seedingProjectsWithIDs projectIDs: [(name: String, id: String)] = []
    ) -> XCUIApplication {
        let app = make()
        for title in todos {
            app.launchArguments += ["-uiTestingSeedTodo", title]
        }
        for entry in todoIDs {
            app.launchArguments += ["-uiTestingSeedTodoWithID", entry.title, entry.id]
        }
        for name in projects {
            app.launchArguments += ["-uiTestingSeedProject", name]
        }
        for entry in projectIDs {
            app.launchArguments += ["-uiTestingSeedProjectWithID", entry.name, entry.id]
        }
        app.launch()
        return app
    }

    /// Stable test ids — UUID-shaped so the production validators
    /// (`BrainAPIClient.validateResourceId`) accept them when the
    /// harness exercises a mutation against a seeded record.
    enum TestID {
        static let editTodo     = "11111111-1111-1111-1111-111111111111"
        static let archiveTodo  = "22222222-2222-2222-2222-222222222222"
        static let completeTodo = "33333333-3333-3333-3333-333333333333"
        static let sectionProj  = "44444444-4444-4444-4444-444444444444"
    }
}

extension XCUIElement {

    /// Wait for the element to exist or fail the test with a clearer
    /// message than the default `XCTAssertTrue(exists)` would emit.
    /// Default timeout aligns with `Tests/BrainTests` async waits.
    @discardableResult
    func awaitExistence(timeout: TimeInterval = 5, file: StaticString = #file, line: UInt = #line) -> Bool {
        let exists = waitForExistence(timeout: timeout)
        if !exists {
            XCTFail("Expected element to exist: \(self)", file: file, line: line)
        }
        return exists
    }
}
