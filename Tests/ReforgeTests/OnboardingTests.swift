import Foundation
import Testing
@testable import Reforge

@Suite("Onboarding") @MainActor
struct OnboardingTests {
    @Test func freshInstallNeedsOnboarding() throws {
        let env = try TestEnv(config: nil)
        let model = env.makeModel()
        #expect(model.needsOnboarding)
        #expect(model.config.addons.isEmpty)
        #expect(model.config.gameVersionTypeId == retail)
        #expect(env.store.saveCount == 0)
    }

    @Test func finishOnboardingPersists() throws {
        let env = try TestEnv(config: nil)
        let model = env.makeModel()
        model.finishOnboarding()
        #expect(!model.needsOnboarding)
        #expect(env.store.config?.onboarded == true)
        // A relaunch with the saved config skips the welcome flow.
        #expect(!env.makeModel().needsOnboarding)
    }

    @Test func showOnboardingAgainPersists() throws {
        let env = try TestEnv()
        let model = env.makeModel()
        #expect(!model.needsOnboarding)
        model.showOnboardingAgain()
        #expect(model.needsOnboarding)
        #expect(env.store.config?.onboarded == false)
    }

    @Test func defaultAddonsPathPerFlavor() {
        #expect(Model.defaultAddonsPath(gameVersionTypeId: retail) == "/Applications/World of Warcraft/_retail_/Interface/AddOns")
        #expect(Model.defaultAddonsPath(gameVersionTypeId: classicEra) == "/Applications/World of Warcraft/_classic_era_/Interface/AddOns")
        #expect(Model.defaultAddonsPath(gameVersionTypeId: 1) == "/Applications/World of Warcraft/_retail_/Interface/AddOns")
    }

    @Test func legacyKeyInConfigMovesToKeyStore() throws {
        let env = try TestEnv()
        env.store.config?.legacyApiKey = "$2a$10$legacy"
        let model = env.makeModel()
        #expect(model.apiKey == "$2a$10$legacy")
        #expect(env.keys.stored == "$2a$10$legacy")
        #expect(env.store.config?.legacyApiKey == nil)
    }

    @Test func legacyKeyKeptInConfigIfKeyStoreFails() throws {
        let env = try TestEnv()
        env.store.config?.legacyApiKey = "$2a$10$legacy"
        env.keys.failWrites = true
        let model = env.makeModel()
        #expect(model.apiKey.isEmpty)
        #expect(env.store.saveCount == 0)
        #expect(env.store.config?.legacyApiKey == "$2a$10$legacy")
    }
}
