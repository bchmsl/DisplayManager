import Foundation
import Testing
@testable import DisplayManagerCore

@Suite struct DisplayplacerVersionTests {
    @Test func parsesVersionOutput() {
        #expect(DisplayplacerVersion.parse("displayplacer v1.4.0") == DisplayplacerVersion(major: 1, minor: 4, patch: 0))
        #expect(DisplayplacerVersion.parse("displayplacer v1.5\n") == DisplayplacerVersion(major: 1, minor: 5, patch: 0))
        #expect(DisplayplacerVersion.parse("2.0.1") == DisplayplacerVersion(major: 2, minor: 0, patch: 1))
        #expect(DisplayplacerVersion.parse("displayplacer") == nil)
        #expect(DisplayplacerVersion.parse("") == nil)
    }

    @Test func supportsOnlyNewEnoughVersions() {
        #expect(DisplayplacerVersion(major: 1, minor: 4, patch: 0).isSupported)
        #expect(DisplayplacerVersion(major: 1, minor: 10, patch: 0).isSupported)
        #expect(!DisplayplacerVersion(major: 1, minor: 3, patch: 9).isSupported)
        #expect(DisplayplacerVersion(major: 1, minor: 4, patch: 0).description == "1.4.0")
    }
}

@Suite struct ExecutableLocatorTests {
    let home = "/Users/tester"

    @Test func candidateOrderAndDeduplication() {
        let candidates = ExecutableLocator.candidates(
            override: "~/tools/displayplacer",
            pathEnvironment: "/usr/local/bin:/usr/bin:relative/bin:/opt/homebrew/bin/",
            homeDirectory: home)
        let paths = candidates.map(\.0)
        #expect(paths.first == NSString(string: "~/tools/displayplacer").expandingTildeInPath)
        #expect(candidates.first?.1 == .userOverride)
        #expect(paths[1] == "/opt/homebrew/bin/displayplacer")
        #expect(paths[2] == "/usr/local/bin/displayplacer")
        #expect(paths.contains("/usr/bin/displayplacer"))
        #expect(!paths.contains { $0.contains("relative") })
        #expect(paths.contains("\(home)/.local/bin/displayplacer"))
        #expect(paths.contains("/opt/local/bin/displayplacer"))
        #expect(Set(paths).count == paths.count)
    }

    @Test func findsStandardLocation() {
        let result = ExecutableLocator.locate(
            override: nil, pathEnvironment: "/usr/bin", homeDirectory: home,
            isExecutable: { $0 == "/usr/local/bin/displayplacer" })
        #expect(result.path == "/usr/local/bin/displayplacer")
        #expect(result.source == .standardLocation)
        #expect(!result.overrideIsInvalid)
    }

    @Test func invalidOverrideFallsBackAndIsReported() {
        let result = ExecutableLocator.locate(
            override: "/nope/displayplacer", pathEnvironment: nil, homeDirectory: home,
            isExecutable: { $0 == "/opt/homebrew/bin/displayplacer" })
        #expect(result.path == "/opt/homebrew/bin/displayplacer")
        #expect(result.overrideIsInvalid)
    }

    @Test func validOverrideWins() {
        let result = ExecutableLocator.locate(
            override: "  /custom/displayplacer  ", pathEnvironment: nil, homeDirectory: home, isExecutable: { _ in true })
        #expect(result.path == "/custom/displayplacer")
        #expect(result.source == .userOverride)
    }

    @Test func reportsMissingExecutable() {
        let result = ExecutableLocator.locate(override: "", pathEnvironment: "/usr/bin", homeDirectory: home, isExecutable: { _ in false })
        #expect(result.path == nil)
        #expect(result.source == nil)
        #expect(!result.overrideIsInvalid)
    }
}

@Suite struct RunOutcomeTests {
    @Test func classifiesOutputs() {
        #expect(RunOutcome.classify(output()) == .success)
        #expect(RunOutcome.classify(output(exit: 0, stderr: "warning")) == .success)
        #expect(RunOutcome.classify(output(exit: 1, stdout: "Unable to find screen BBBB")) == .displayNotFound)
        #expect(RunOutcome.classify(output(exit: 1, stderr: "Argument parsing error")) == .invalidArguments)
        #expect(RunOutcome.classify(output(exit: 1, stderr: "Could not find res:9999x9999 for screen")) == .unsupportedMode)
        #expect(RunOutcome.classify(output(exit: 3)) == .failed(exitCode: 3))
        #expect(RunOutcome.classify(output(exit: 15, timedOut: true)) == .timedOut)
    }

    @Test func combinesTrimmedOutput() {
        #expect(output(stdout: " a \n", stderr: "").combinedOutput == "a")
        #expect(output(stdout: "a", stderr: "b\n").combinedOutput == "a\nb")
    }
}
