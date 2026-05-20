import XCTest
@testable import Clawdmeter

/// v0.7.7 regression suite for `TmuxControlClient.validateArgs(_:)`.
/// P1-Mac-6 added control-byte rejection because the tmux control-mode
/// wire format joins args with spaces and terminates lines with `\n` —
/// a newline in any arg can split the line and inject an unrelated
/// tmux command. The validator throws `.invalidArgument(arg)` on the
/// offending arg; nothing in the existing test suite covers it.
final class TmuxControlClientValidationTests: XCTestCase {

    // MARK: - Happy path

    func test_validateArgs_acceptsClean() throws {
        XCTAssertNoThrow(try TmuxControlClient.validateArgs([]))
        XCTAssertNoThrow(try TmuxControlClient.validateArgs(["new-window"]))
        XCTAssertNoThrow(try TmuxControlClient.validateArgs(["send-keys", "-t", "session:1", "echo hi"]))
        XCTAssertNoThrow(try TmuxControlClient.validateArgs(["paste-buffer", "-d", "-t", "session:1.0"]))
    }

    // MARK: - Control byte rejection

    func test_validateArgs_rejectsNewline() {
        XCTAssertThrowsError(
            try TmuxControlClient.validateArgs(["new-window", "-t", "x\nkill-server"])
        ) { error in
            guard case TmuxControlClient.TmuxError.invalidArgument(let arg) = error else {
                XCTFail("expected TmuxError.invalidArgument, got \(error)"); return
            }
            XCTAssertEqual(arg, "x\nkill-server")
        }
    }

    func test_validateArgs_rejectsCarriageReturn() {
        XCTAssertThrowsError(
            try TmuxControlClient.validateArgs(["arg-with-cr\r-injection"])
        )
    }

    func test_validateArgs_rejectsNullByte() {
        XCTAssertThrowsError(
            try TmuxControlClient.validateArgs(["arg-with-null\u{00}byte"])
        )
    }

    func test_validateArgs_rejectsESC() {
        // ESC (0x1B) is what tmux uses for its own paste-mode escape
        // sequences. Letting it through would let an attacker emit a
        // CSI / OSC sequence into the agent terminal.
        XCTAssertThrowsError(
            try TmuxControlClient.validateArgs(["arg\u{1B}[2J"])
        )
    }

    func test_validateArgs_rejectsDEL() {
        XCTAssertThrowsError(
            try TmuxControlClient.validateArgs(["arg-with-del\u{7F}byte"])
        )
    }

    func test_validateArgs_throwsOnFirstOffender() {
        // First offending arg wins; the validator doesn't aggregate.
        XCTAssertThrowsError(
            try TmuxControlClient.validateArgs(["clean", "bad\nbad", "also-bad\r"])
        ) { error in
            guard case TmuxControlClient.TmuxError.invalidArgument(let arg) = error else {
                XCTFail("expected TmuxError.invalidArgument, got \(error)"); return
            }
            XCTAssertEqual(arg, "bad\nbad", "Validator should throw on the first offending arg.")
        }
    }

    // MARK: - Boundary

    func test_validateArgs_acceptsSpaceAndPrintable() throws {
        // Space (0x20) is the very first byte ABOVE the C0 range and
        // must be accepted; common args contain spaces.
        XCTAssertNoThrow(try TmuxControlClient.validateArgs([" hello ", "ascii-printable!@#$%^&*()_+"]))
    }

    func test_validateArgs_acceptsUnicode() throws {
        // Multi-byte UTF-8 has no C0/DEL representation in its bytes
        // beyond what unicodeScalars iteration sees; should pass.
        XCTAssertNoThrow(try TmuxControlClient.validateArgs(["日本語", "🦀 emoji"]))
    }
}
