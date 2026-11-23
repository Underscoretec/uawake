import Foundation
import Testing

@testable import UAwakeCore

struct LockDimTests {
    let config = LockDimConfig(autoLock: 600, dim: 300)

    @Test func passwordRequirementParsing() {
        #expect(PasswordRequirement.parse("2026 sysadminctl[1:2] screenLock delay is immediate") == .immediate)
        #expect(PasswordRequirement.parse("screenLock delay is 300 seconds") == .delay(seconds: 300))
        #expect(PasswordRequirement.parse("screenLock delay is 5 minutes") == .delay(seconds: 300))
        #expect(PasswordRequirement.parse("screenLock is off") == .never)
        #expect(PasswordRequirement.parse("") == .unknown)
        #expect(PasswordRequirement.parse("exec failed") == .unknown)
    }

    @Test func promptnessThreshold() {
        #expect(PasswordRequirement.immediate.locksPromptly)
        #expect(PasswordRequirement.delay(seconds: 60).locksPromptly)
        #expect(PasswordRequirement.delay(seconds: 300).isKnownNotToLock)
        #expect(PasswordRequirement.never.isKnownNotToLock)
        #expect(!PasswordRequirement.unknown.locksPromptly && !PasswordRequirement.unknown.isKnownNotToLock)
    }

    @Test func dimThenLockThenInputResets() {
        var tracker = LockDimTracker()
        func step(_ idle: TimeInterval, locked: Bool = false) -> LockDimTracker.Output {
            tracker.update(config: config, idle: idle, sessionActive: true, locked: locked, othersHoldDisplay: false)
        }
        #expect(step(10) == .init())
        #expect(step(299).dimmed == false)
        #expect(step(300).dimmed)
        #expect(step(599).dimmed)
        let lock = step(600)
        #expect(lock.lockNow && !lock.dimmed)
        #expect(step(601) == .init())  // fires once
        #expect(step(700, locked: true) == .init())
        #expect(step(2) == .init())  // input
        #expect(step(600).lockNow)  // armed again
    }

    @Test func nothingHappensWithoutASession() {
        var tracker = LockDimTracker()
        let output = tracker.update(
            config: config, idle: 9999, sessionActive: false, locked: false, othersHoldDisplay: true)
        #expect(output == .init())
    }

    @Test func dimSkippedWhilePlayingButLockStillFires() {
        var tracker = LockDimTracker()
        let dim = tracker.update(config: config, idle: 400, sessionActive: true, locked: false, othersHoldDisplay: true)
        #expect(!dim.dimmed)
        let lock = tracker.update(
            config: config, idle: 600, sessionActive: true, locked: false, othersHoldDisplay: true)
        #expect(lock.lockNow)
    }

    @Test func dimNotSkippedWhenSettingOff() {
        var tracker = LockDimTracker()
        var loose = config
        loose.skipsWhenPlaying = false
        #expect(
            tracker.update(config: loose, idle: 400, sessionActive: true, locked: false, othersHoldDisplay: true).dimmed
        )
    }

    @Test func sessionStartingWhileIdleLocksAtOnce() {
        var tracker = LockDimTracker()
        #expect(
            tracker.update(config: config, idle: 5000, sessionActive: true, locked: false, othersHoldDisplay: false)
                .lockNow)
    }

    @Test func countdowns() {
        #expect(config.dimsIn(idle: 100) == 200)
        #expect(config.locksIn(idle: 100) == 500)
        #expect(config.dimsIn(idle: 300) == nil)
    }

    @Test func settingsKeepTheDimBelowTheLock() {
        let defaults = UserDefaults(suiteName: "lockdim-\(UUID().uuidString)")!
        let settings = UAwakeSettings(defaults: defaults)
        #expect(!settings.lockDimConfig.isArmed)
        settings.dimEnabled = true
        settings.dimMinutes = 5
        #expect(settings.lockDimConfig.dim == 300 && settings.lockDimConfig.autoLock == nil)
        settings.autoLockEnabled = true
        settings.autoLockMinutes = 4
        #expect(settings.lockDimConfig.dim == 180 && settings.lockDimConfig.autoLock == 240)
        settings.autoLockMinutes = 1
        #expect(settings.lockDimConfig.dim == nil)
        settings.dimDarkness = 500
        #expect(settings.dimDarkness == 90)
        defaults.set(0, forKey: SettingsKey.autoLockMinutes.rawValue)
        #expect(settings.autoLockMinutes == 1)
    }

    @Test func lockShortcutRoundTrips() {
        let settings = UAwakeSettings(defaults: UserDefaults(suiteName: "lockdim-\(UUID().uuidString)")!)
        #expect(settings.lockShortcut == nil)
        settings.lockShortcut = GlobalShortcut(keyCode: 37, carbonModifiers: 4352)
        #expect(settings.lockShortcut == GlobalShortcut(keyCode: 37, carbonModifiers: 4352))
    }
}
