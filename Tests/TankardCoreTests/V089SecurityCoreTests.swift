import Foundation
import Testing
@testable import TankardCore

// 0.8.9: the 0.8.8 security review's follow-ups, core parts (the rest are in
// TankardAppModelTests/V089SecurityTests.swift).

/// F2: every package name Tankard puts after brew's options.
struct V089BrewOperandTests {
    @Test func oneNameGetsDoubleDashOnlyWhenItLooksLikeAnOption() {
        #expect(BrewOperand.one("homebrew/core/xz") == ["homebrew/core/xz"])
        #expect(BrewOperand.one("--force") == ["--", "--force"])
        #expect(BrewOperand.one("-x") == ["--", "-x"])
    }

    @Test func listGetsOneDoubleDashBeforeAllNames() {
        #expect(BrewOperand.list(["a/b/x", "a/b/y"]) == ["a/b/x", "a/b/y"])
        #expect(BrewOperand.list(["a/b/x", "--force"]) == ["--", "a/b/x", "--force"])
        #expect(BrewOperand.list([]) == [])
    }

    @Test func bottleReinstallAndAdoptUseIt() {
        #expect(BottleReplacement.arguments(qualifiedName: "homebrew/core/vim")
                == ["reinstall", "--force-bottle", "--formula", "homebrew/core/vim"])
        #expect(BottleReplacement.arguments(qualifiedName: "--HEAD")
                == ["reinstall", "--force-bottle", "--formula", "--", "--HEAD"])
        #expect(AdoptCommands.arguments(qualifiedName: "homebrew/cask/foo") == ["install", "--cask", "--adopt", "homebrew/cask/foo"])
        #expect(AdoptCommands.arguments(qualifiedName: "--force") == ["install", "--cask", "--adopt", "--", "--force"])
        #expect(AdoptCommands.replaceArguments(qualifiedName: "-n") == ["install", "--cask", "--force", "--", "-n"])
    }
}

/// F3: the native-architecture brew is tried first.
struct V089BrewLocationTests {
    @Test func appleSiliconTriesOptHomebrewFirst() {
        #expect(BrewInstallation.candidates(arm64: true) == ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"])
        #expect(BrewInstallation.candidates(arm64: false) == ["/usr/local/bin/brew", "/opt/homebrew/bin/brew"])
    }

    @Test func candidatesFollowThisMacsHardware() {
        #expect(BrewInstallation.candidates == BrewInstallation.candidates(arm64: BrewInstallation.hardwareIsArm64()))
        #if arch(arm64)
        #expect(BrewInstallation.hardwareIsArm64())
        #endif
    }
}
