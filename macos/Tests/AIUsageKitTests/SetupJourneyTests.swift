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
}
