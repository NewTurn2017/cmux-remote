import Testing
@testable import SharedKit

@Suite("KeyEncoder")
struct KeyEncoderTests {
    @Test func plainKeysAreNormalized() {
        #expect(KeyEncoder.encode(.enter) == "enter")
        #expect(KeyEncoder.encode(.tab)   == "tab")
        #expect(KeyEncoder.encode(.up)    == "up")
        #expect(KeyEncoder.encode(.esc)   == "esc")
    }

    @Test func modifiersAreLowerCasePlusJoined() {
        #expect(KeyEncoder.encode(.named("c", modifiers: [.ctrl]))           == "ctrl+c")
        #expect(KeyEncoder.encode(.named("c", modifiers: [.ctrl, .shift]))   == "ctrl+shift+c")
        #expect(KeyEncoder.encode(.named("[", modifiers: [.alt]))            == "alt+[")
    }

    @Test func directionWithModifier() {
        #expect(KeyEncoder.encode(.named("up", modifiers: [.shift])) == "shift+up")
    }

    @Test func parseRoundTripForKnown() throws {
        let encoded = "ctrl+shift+c"
        let key = try #require(KeyEncoder.decode(encoded))
        #expect(KeyEncoder.encode(key) == encoded)
    }

    @Test func parseRejectsEmpty() {
        #expect(KeyEncoder.decode("") == nil)
    }
}
