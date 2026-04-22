import XCTest
@testable import MuybridgePlayer

final class MuybridgePlayerTests: XCTestCase {

    // MARK: - Lifecycle

    func testInitialStateIsIdle() {
        let player = MuybridgePlayer()
        XCTAssertEqual(player.state, .idle)
    }

    func testInitialMetadataIsZero() {
        let player = MuybridgePlayer()
        XCTAssertEqual(player.duration, 0)
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(player.videoWidth, 0)
        XCTAssertEqual(player.videoHeight, 0)
    }

    func testReleaseTransitionsToIdle() {
        let player = MuybridgePlayer()
        player.release()
        XCTAssertEqual(player.state, .idle)
    }

    func testDoubleReleaseDoesNotCrash() {
        let player = MuybridgePlayer()
        player.release()
        player.release() // must not crash or double-free
        XCTAssertEqual(player.state, .idle)
    }

    // MARK: - load()

    func testLoadEmptyURLTransitionsToError() {
        let player = MuybridgePlayer()
        let result = player.load(url: "")
        XCTAssertFalse(result)
        XCTAssertEqual(player.state, .error)
    }

    func testLoadInvalidURLTransitionsToError() {
        let player = MuybridgePlayer()
        let result = player.load(url: "not-a-valid-url")
        XCTAssertFalse(result)
        XCTAssertEqual(player.state, .error)
    }

    func testLoadSetsLoadingBeforeResult() {
        // State passes through .loading during load(); we observe
        // the final state after the synchronous call returns.
        let player = MuybridgePlayer()
        _ = player.load(url: "")
        // After a failed load, state must be .error (not stuck in .loading)
        XCTAssertEqual(player.state, .error)
    }

    // MARK: - play / pause

    func testPlayAfterReleaseIsNoop() {
        let player = MuybridgePlayer()
        player.release()
        player.play() // must not crash
    }

    func testPauseAfterReleaseIsNoop() {
        let player = MuybridgePlayer()
        player.release()
        player.pause() // must not crash
    }

    func testSeekAfterReleaseIsNoop() {
        let player = MuybridgePlayer()
        player.release()
        player.seek(to: 1_000_000_000) // must not crash
    }

    // MARK: - Rendering

    func testInitRendererAfterReleaseReturnsFalse() {
        let player = MuybridgePlayer()
        player.release()
        XCTAssertFalse(player.initRenderer())
    }

    func testDeviceIsNilAfterRelease() {
        let player = MuybridgePlayer()
        player.release()
        XCTAssertNil(player.device)
    }
}
