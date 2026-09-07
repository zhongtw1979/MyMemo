import XCTest
import MyMemoCore
@testable import MyMemoExperience

final class SetupTests: XCTestCase {
    func testNoDeviceCannotAdvanceButExplicitLaterCan() {
        var draft = SetupDraft()
        XCTAssertFalse(draft.canAdvance(from: .source))
        draft.source = .later
        XCTAssertTrue(draft.canAdvance(from: .source))
    }
    func testDeviceSelectionBuildsUsableConfigWithoutTypingUUID() throws {
        var draft = SetupDraft()
        draft.deviceName = "RECORDER"; draft.devicePath = "/Volumes/RECORDER"
        draft.destination = "/tmp/MyMemoRecordings"
        let config = try draft.configuration(modelReady: true)
        XCTAssertTrue(config.matches(name: "RECORDER", uuid: "any"))
        XCTAssertTrue(config.automaticImport)
        XCTAssertEqual(config.provider, .apple)
        XCTAssertFalse(config.cloudConsent)
    }
    func testDestinationCannotBeInsideDevice() {
        var draft = SetupDraft(); draft.deviceName = "REC"; draft.devicePath = "/Volumes/REC"
        draft.destination = "/Volumes/REC/output"
        XCTAssertFalse(draft.canAdvance(from: .destination))
        XCTAssertThrowsError(try draft.configuration(modelReady: true))
    }
    func testFolderImportRequiresSourceAndHasNoAutomaticDiskRule() throws {
        var draft = SetupDraft(); draft.source = .folder
        XCTAssertFalse(draft.canAdvance(from: .source))
        draft.sourceFolder = "/tmp/recordings"; draft.destination = "/tmp/output"
        let config = try draft.configuration(modelReady: true)
        XCTAssertFalse(config.automaticImport)
        XCTAssertTrue(config.devices.isEmpty)
    }
    func testTranscriptionNeedsModelButCopyOnlyDoesNot() throws {
        var draft = SetupDraft(); draft.source = .later; draft.destination = "/tmp/output"
        XCTAssertThrowsError(try draft.configuration(modelReady: false))
        draft.transcribe = false
        let config = try draft.configuration(modelReady: false)
        XCTAssertFalse(config.automaticTranscription)
    }
    func testRelativeOrRootDestinationIsRejected() {
        var draft = SetupDraft(); draft.source = .later
        for path in ["", "relative", "/"] {
            draft.destination = path
            XCTAssertFalse(draft.canAdvance(from: .destination))
        }
    }
    func testFreshExperienceDoesNotPermitWorkAndPersistsCompletedSetup() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        var preferences = try GuidedPreferences.load(from: file)
        XCTAssertFalse(preferences.completed)
        preferences.completed = true; preferences.paused = true
        try preferences.save(to: file)
        let restored = try GuidedPreferences.load(from: file)
        XCTAssertTrue(restored.completed); XCTAssertTrue(restored.paused)
    }
    func testCorruptExperienceIsNotReplaced() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("bad".utf8).write(to: file)
        XCTAssertThrowsError(try GuidedPreferences.load(from: file))
        XCTAssertEqual(try Data(contentsOf: file), Data("bad".utf8))
    }
}
