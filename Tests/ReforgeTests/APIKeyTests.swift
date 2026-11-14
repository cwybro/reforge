import Foundation
import Testing
@testable import Reforge

@Suite("API key") @MainActor
struct APIKeyTests {
    @Test func verifySuccessSavesKey() async throws {
        let env = try TestEnv()
        let model = env.makeModel()
        let err = await model.verifyAndSaveKey("$2a$10$good")
        #expect(err == nil)
        #expect(env.api.calls == ["validateKey($2a$10$good)"])
        #expect(env.keys.stored == "$2a$10$good")
        #expect(model.apiKey == "$2a$10$good")
        #expect(model.hasKey)
    }

    @Test func rejectedKeyIsNotSaved() async throws {
        let env = try TestEnv()
        env.api.validateError = Reforge.CFError.http(403, "Forbidden")
        let model = env.makeModel()
        let err = await model.verifyAndSaveKey("cfc_wrongkind")
        #expect(err == "CurseForge didn't accept that key. It should start with $2a$10$.")
        #expect(env.keys.writes.isEmpty)
        #expect(model.apiKey.isEmpty)
        #expect(!model.hasKey)
    }

    @Test func otherErrorsAreReported() async throws {
        let env = try TestEnv(key: "$2a$10$old")
        env.api.validateError = Reforge.CFError.http(500, "oops")
        let model = env.makeModel()
        let err = await model.verifyAndSaveKey("$2a$10$new")
        #expect(err == "CurseForge API error 500: oops")
        #expect(env.keys.writes.isEmpty)
        #expect(model.apiKey == "$2a$10$old")
    }

    @Test func emptyKeyIsRejected() async throws {
        let env = try TestEnv()
        let model = env.makeModel()
        let err = await model.verifyAndSaveKey("")
        #expect(err == "No CurseForge API key set.")
        #expect(env.keys.writes.isEmpty)
    }

    /// The real client refuses an empty key before building any request.
    @Test func realClientRejectsEmptyKeyWithoutNetwork() async {
        await #expect(throws: Reforge.CFError.self) { try await CurseForgeAPI(apiKey: "").validateKey() }
    }

    @Test func saveTrimsAndReportsKeyStoreFailure() throws {
        let env = try TestEnv()
        env.keys.failWrites = true
        let model = env.makeModel()
        model.apiKey = "  $2a$10$x \n"
        model.saveAPIKey()
        #expect(model.apiKey == "$2a$10$x")
        #expect(env.keys.writes == ["$2a$10$x"])
        #expect(model.message == "Couldn't save the API key to the Keychain.")
    }

    @Test func whitespaceKeyCountsAsNoKey() throws {
        let env = try TestEnv(key: "   ")
        #expect(!env.makeModel().hasKey)
    }
}
