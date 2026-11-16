import Foundation
import Testing
@testable import Reforge

@Suite("Addon search") @MainActor
struct SearchTests {
    /// Echo (42) is installable on Retail; Delta (7) is already tracked; Foxtrot (9) only has a Classic file.
    func env() throws -> TestEnv {
        let env = try TestEnv(key: "k", addons: [tracked(7, "Delta", fileId: 700)])
        env.api.add(cfMod(7, "Delta", files: [(701, 1, retail)]), cfFile(701, mod: 7, "Delta 7.1"))
        env.api.add(cfMod(9, "Foxtrot", files: [(900, 1, classicEra)]), cfFile(900, mod: 9, "Foxtrot 9"))
        env.api.add(cfMod(42, "Echo", files: [(4200, 1, retail)]), cfFile(4200, mod: 42, "Echo 1.2"))
        return env
    }

    @Test func emptyTextBrowsesPopularForTheGameVersion() async throws {
        let env = try env()
        let model = env.makeModel()
        model.config.gameVersionTypeId = classicEra
        let search = AddonSearch(model: model)
        await search.run()
        #expect(env.api.searches == [SearchQuery(text: "", sort: .popularity, categoryId: nil, gameVersionTypeId: classicEra)])
        #expect(search.results.map(\.id) == [7, 9, 42])
        #expect(search.total == 3)
        #expect(search.isInstalled(7) && !search.isInstalled(42))
    }

    @Test func textSortAndCategoryReachTheAPI() async throws {
        let env = try env()
        let search = AddonSearch(model: env.makeModel())
        search.text = "  ech "
        search.sort = .lastUpdated
        search.categoryId = 5
        await search.run()
        #expect(env.api.searches.last == SearchQuery(text: "ech", sort: .lastUpdated, categoryId: 5, gameVersionTypeId: retail))
        #expect(search.results.map(\.name) == ["Echo"])
    }

    @Test(arguments: ["42", " 42 ", "https://www.curseforge.com/wow/addons/echo"])
    func linksAndIdsInstallDirectlyInsteadOfSearching(input: String) async throws {
        let env = try env()
        let search = AddonSearch(model: env.makeModel())
        search.text = input
        #expect(search.directInput == input.trimmingCharacters(in: .whitespaces))
        await search.run()
        #expect(env.api.searches.isEmpty)
        #expect(search.results.isEmpty)
    }

    @Test func plainWordsSearch() throws {
        let search = AddonSearch(model: try env().makeModel())
        search.text = "details damage meter"
        #expect(search.directInput == nil)
    }

    @Test func loadMoreAppendsTheNextPage() async throws {
        let env = try TestEnv(key: "k")
        for id in 1...60 { env.api.add(cfMod(id, "Mod \(id)")) }
        let search = AddonSearch(model: env.makeModel())
        await search.run()
        #expect(search.results.count == 50 && search.total == 60 && search.canLoadMore)
        await search.loadMore()
        #expect(env.api.searches.last?.index == 50)
        #expect(search.results.map(\.id) == Array(1...60))
        #expect(!search.canLoadMore)
    }

    @Test func aSlowOlderSearchCantOverwriteANewerOne() async throws {
        let env = try env()
        let release = Gate()
        var first = true
        env.api.searchGate = {
            if first { first = false; await release.wait() }
        }
        let search = AddonSearch(model: env.makeModel())
        search.text = "o"                     // matches Foxtrot, Echo
        let slow = Task { await search.run() }
        while env.api.searches.isEmpty { await Task.yield() }
        search.text = "echo"
        await search.run()
        #expect(search.results.map(\.name) == ["Echo"])
        await release.open()
        await slow.value
        #expect(search.results.map(\.name) == ["Echo"], "the older response was dropped")
        #expect(!search.loading)
    }

    @Test func pagingStopsAtCurseForgesLimit() async throws {
        let env = try TestEnv(key: "k")
        for id in 1...3 { env.api.add(cfMod(id, "Mod \(id)")) }
        let search = AddonSearch(model: env.makeModel())
        await search.run()
        #expect(!search.canLoadMore)
        #expect(AddonSearch.maxResults == 10_000)
    }

    @Test func failedSearchShowsTheError() async throws {
        let env = try env()
        env.api.error = Reforge.CFError.http(500, "down")
        let search = AddonSearch(model: env.makeModel())
        await search.run()
        #expect(search.error?.contains("500") == true)
        #expect(search.results.isEmpty && !search.canLoadMore && !search.loading)
    }

    @Test func installingAResultTracksIt() async throws {
        let env = try env()
        let model = env.makeModel()
        let search = AddonSearch(model: model)
        await search.run()
        let echo = try #require(search.results.first { $0.id == 42 })
        await search.install(echo)
        #expect(search.isInstalled(42))
        #expect(search.installing.isEmpty && search.failures.isEmpty)
        #expect(env.installer.installs.map(\.fileId) == [4200])
        #expect(env.store.config?.addons.map(\.id).contains(42) == true)
        #expect(!env.api.calls.contains("mod(42)"), "a search result installs without looking the addon up again")

        // Already installed: a second press does nothing.
        await search.install(echo)
        #expect(env.installer.installs.count == 1)
    }

    @Test func aResultWithNoFileForThisVersionReportsWhy() async throws {
        let env = try env()
        let search = AddonSearch(model: env.makeModel())
        await search.run()
        await search.install(try #require(search.results.first { $0.id == 9 }))
        #expect(!search.isInstalled(9))
        #expect(search.failures[9] == "Foxtrot has no file for this game version.")
        #expect(env.installer.installs.isEmpty)
    }

    @Test func categoriesLeaveOutClassesAndAreSorted() async throws {
        let env = try env()
        env.api.categoryList = [CFCategory(id: 1, name: "Addons", isClass: true),
                                CFCategory(id: 3, name: "Unit Frames"), CFCategory(id: 2, name: "bags")]
        let search = AddonSearch(model: env.makeModel())
        await search.loadCategories()
        #expect(search.categories.map(\.id) == [2, 3])
        await search.loadCategories()
        #expect(env.api.calls.filter { $0 == "categories" }.count == 1, "loaded once")
    }
}

/// Decodes a real /v1/mods/search response (trimmed to one result, captured November 2026).
@Suite struct SearchDecodingTests {
    static let response = """
    {"data": [{"id": 1592, "gameId": 1, "name": "Bagnon", "slug": "bagnon",
      "summary": "See your inventory, bank, guild and alts from anywhere",
      "downloadCount": 172235999, "dateModified": "2026-11-15T22:24:09.393Z", "dateCreated": "2005-12-26T15:04:58Z",
      "isFeatured": false, "thumbsUpCount": 1, "classId": 1,
      "links": {"websiteUrl": "https://www.curseforge.com/wow/addons/bagnon"},
      "authors": [{"id": 291351, "name": "jaliborc", "url": "https://www.curseforge.com/members/jaliborc"}],
      "logo": {"id": 647705, "modId": 1592,
               "thumbnailUrl": "https://media.forgecdn.net/avatars/thumbnails/647/705/256/256/638048338012580367.png",
               "url": "https://media.forgecdn.net/avatars/647/705/638048338012580367.png"},
      "categories": [{"id": 1171, "gameId": 1, "name": "Transmogrification", "slug": "transmogrification",
                      "isClass": false, "classId": 1, "parentCategoryId": 1060}],
      "latestFilesIndexes": [
        {"gameVersion": "4.4.2", "fileId": 9638308, "filename": "Bagnon-12.1.11.zip", "releaseType": 1, "gameVersionTypeId": 77522},
        {"gameVersion": "3.4.4", "fileId": 9638308, "filename": "Bagnon-12.1.11.zip", "releaseType": 1, "gameVersionTypeId": 73713}]}],
     "pagination": {"index": 0, "pageSize": 1, "resultCount": 1, "totalCount": 27}}
    """

    @Test func decodesRealSearchResults() throws {
        let page = try Store.decoder.decode(CurseForgeAPI.SearchPage.self, from: Data(Self.response.utf8))
        #expect(page.total == 27)
        let mod = try #require(page.data.first)
        #expect(mod.name == "Bagnon" && mod.summary?.hasPrefix("See your inventory") == true)
        #expect(mod.downloadCount == 172_235_999)
        #expect(mod.dateModified != nil)
        #expect(mod.authors?.first?.name == "jaliborc")
        #expect(mod.logo?.thumbnailUrl?.hasSuffix(".png") == true)
        #expect(mod.categories?.first?.name == "Transmogrification")
        #expect(mod.latestFileId(gameVersionTypeId: 77522, allowPrerelease: false) == 9638308)
    }
}

/// Holds an async caller until `open()`.
actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
