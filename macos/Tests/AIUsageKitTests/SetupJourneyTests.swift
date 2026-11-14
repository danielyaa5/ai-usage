import XCTest
@testable import AIUsageKit

final class SetupJourneyTests: XCTestCase {
    func testChoosesToolsInDisplayOrderAndResumesAtTheRightTool() throws {
        var journey = SetupJourney()
        journey.advance()
        XCTAssertEqual(journey.step, .tools)
        journey.toggle(.antigravity)
        journey.toggle(.codex)
        journey.toggle(.claude)
        journey.toggle(.codex)
        XCTAssertEqual(journey.tools, [.claude, .antigravity])
        journey.advance()
        XCTAssertEqual(journey.provider, .claude)
        journey.advance()
        let saved = try JSONEncoder().encode(journey)
        var restored = try XCTUnwrap(SetupJourney.restore(saved))
        XCTAssertEqual(restored.provider, .antigravity)
        restored.advance()
        XCTAssertEqual(restored.step, .widget)
        restored.back()
        XCTAssertEqual(restored.provider, .antigravity)
        restored.back()
        XCTAssertEqual(restored.provider, .claude)
        restored.back()
        XCTAssertEqual(restored.step, .tools)
        XCTAssertEqual(restored.tools, journey.tools)
    }

    func testOnlyValidProgressCanResume() throws {
        XCTAssertEqual(SetupJourney.restore(try JSONEncoder().encode(SetupJourney())), SetupJourney())
        for invalid in ["{}", #"{"step":"widget","tools":[],"index":0}"#,
                        #"{"step":"connections","tools":["codex","codex"],"index":0}"#,
                        #"{"step":"widget","tools":["antigravity"],"index":1}"#,
                        #"{"step":"tools","tools":["claude"],"index":-1}"#] {
            XCTAssertNil(SetupJourney.restore(Data(invalid.utf8)))
        }
    }

    func testClosingAndReopeningAfterConnectingSourceClearsSetupJourneyAndOpensWidgets() throws {
        let suite = "SetupJourneyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var state = SetupState(defaults: defaults, isConfigured: false)
        state.preparePresentation(
            requestedPage: nil,
            windowAlreadyOpen: false,
            source: .local,
            isConfigured: false,
            defaults: defaults
        )
        XCTAssertTrue(state.showsSetup)
        XCTAssertEqual(state.journey?.step, .tools)

        state.edit({ journey in
            journey.toggle(.claude)
            journey.toggle(.codex)
            journey.toggle(.antigravity)
            journey.advance()
        }, defaults: defaults)
        XCTAssertEqual(state.journey?.step, .connections)
        XCTAssertEqual(state.journey?.provider, .claude)
        XCTAssertNotNil(defaults.data(forKey: SetupState.journeyKey))

        // User connects a source on Step 2 and closes the window without clicking through to Step 3 "Done"
        XCTAssertTrue(state.handleWindowClose(isConfigured: true, defaults: defaults))
        XCTAssertNil(state.journey)
        XCTAssertFalse(state.showsSetup)
        XCTAssertEqual(state.settingsPage, .widgets)
        XCTAssertNil(defaults.data(forKey: SetupState.journeyKey))

        // Subsequent reopen lands on Widgets preview, never re-entering Guided Setup
        state.preparePresentation(
            requestedPage: nil,
            windowAlreadyOpen: false,
            source: .local,
            isConfigured: true,
            defaults: defaults
        )
        XCTAssertNil(state.journey)
        XCTAssertFalse(state.showsSetup)
        XCTAssertEqual(state.settingsPage, .widgets)
    }

    func testStartupAutoClearsStuckSetupJourneyWhenSourceIsAlreadyConfigured() throws {
        let suite = "SetupJourneyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let stuck = #"{"step":"connections","index":0,"tools":["claude","codex","antigravity"]}"#
        defaults.set(Data(stuck.utf8), forKey: SetupState.journeyKey)
        defaults.set(true, forKey: SetupState.shownKey)

        let state = SetupState(defaults: defaults, isConfigured: true)
        XCTAssertNil(state.journey)
        XCTAssertFalse(state.showsSetup)
        XCTAssertEqual(state.settingsPage, .widgets)
        XCTAssertNil(defaults.data(forKey: SetupState.journeyKey))
    }

    func testDefaultLandingPageResolvesByConfigurationAndExplicitPageOverride() throws {
        let suite = "SetupJourneyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(SetupState.isSourceConfigured(source: .local, hasLocalSources: false, hasDashboardServer: true))
        XCTAssertTrue(SetupState.isSourceConfigured(source: .local, hasLocalSources: true, hasDashboardServer: false))
        XCTAssertFalse(SetupState.isSourceConfigured(source: .dashboard, hasLocalSources: true, hasDashboardServer: false))
        XCTAssertTrue(SetupState.isSourceConfigured(source: .dashboard, hasLocalSources: false, hasDashboardServer: true))
        XCTAssertTrue(SetupState.isSourceConfigured(source: .demo, hasLocalSources: false, hasDashboardServer: false))

        var state = SetupState(defaults: defaults, isConfigured: false)
        state.preparePresentation(
            requestedPage: nil,
            windowAlreadyOpen: false,
            source: .local,
            isConfigured: false,
            defaults: defaults
        )
        XCTAssertTrue(state.showsSetup)
        XCTAssertEqual(state.settingsPage, .connections)

        // User clicks "Set up later" while still unconfigured: reopening stays out of wizard but opens .connections
        state.finish(defaults: defaults)
        state.preparePresentation(
            requestedPage: nil,
            windowAlreadyOpen: false,
            source: .local,
            isConfigured: false,
            defaults: defaults
        )
        XCTAssertFalse(state.showsSetup)
        XCTAssertEqual(state.settingsPage, .connections)

        // Once configured, default reopen resolves to .widgets, while explicit .connections opens .connections
        state.preparePresentation(
            requestedPage: nil,
            windowAlreadyOpen: false,
            source: .local,
            isConfigured: true,
            defaults: defaults
        )
        XCTAssertFalse(state.showsSetup)
        XCTAssertEqual(state.settingsPage, .widgets)

        state.preparePresentation(
            requestedPage: .connections,
            windowAlreadyOpen: false,
            source: .local,
            isConfigured: true,
            defaults: defaults
        )
        XCTAssertFalse(state.showsSetup)
        XCTAssertEqual(state.settingsPage, .connections)
    }

    func testAppURLRouteResolvesBundleSchemeAndSettingsSubpaths() throws {
        let accepted: Set<String> = ["aiusage-claude-fresh-test", "aiusage"]
        XCTAssertEqual(
            AppURLRoute.resolve(try XCTUnwrap(URL(string: "aiusage-claude-fresh-test://settings")), acceptedSchemes: accepted),
            .settings(nil)
        )
        XCTAssertEqual(
            AppURLRoute.resolve(try XCTUnwrap(URL(string: "aiusage-claude-fresh-test://settings/connections")), acceptedSchemes: accepted),
            .settings(.connections)
        )
        XCTAssertEqual(
            AppURLRoute.resolve(try XCTUnwrap(URL(string: "aiusage-claude-fresh-test://settings/widgets")), acceptedSchemes: accepted),
            .settings(.widgets)
        )
        XCTAssertEqual(
            AppURLRoute.resolve(try XCTUnwrap(URL(string: "aiusage-claude-fresh-test://refresh")), acceptedSchemes: accepted),
            .refresh
        )
        XCTAssertEqual(
            AppURLRoute.resolve(try XCTUnwrap(URL(string: "aiusage-claude-fresh-test://dashboard")), acceptedSchemes: accepted),
            .dashboard
        )
        XCTAssertEqual(
            AppURLRoute.resolve(try XCTUnwrap(URL(string: "aiusage://settings")), acceptedSchemes: accepted),
            .settings(nil)
        )
        XCTAssertNil(
            AppURLRoute.resolve(try XCTUnwrap(URL(string: "https://example.com/settings")), acceptedSchemes: accepted)
        )
    }
}
