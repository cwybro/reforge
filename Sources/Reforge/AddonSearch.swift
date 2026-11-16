import Foundation
import Observation

/// State behind the Add sheet: searching and browsing CurseForge's WoW addons, and installing
/// results. A link or project ID typed into the field installs directly instead of searching.
@MainActor @Observable
final class AddonSearch {
    var text = ""
    var sort = SearchSort.popularity
    var categoryId: Int?

    private(set) var results: [CFMod] = []
    private(set) var total = 0
    private(set) var loading = false
    private(set) var error: String?
    private(set) var categories: [CFCategory] = []
    private(set) var installing: Set<Int> = []
    /// Why installing a result failed, by project id.
    private(set) var failures: [Int: String] = [:]

    private let model: Model
    /// Bumped by every new search so a slow, outdated response can't overwrite a newer one.
    private var generation = 0

    init(model: Model) { self.model = model }

    /// The field holds a curseforge.com link or a project ID: install that instead of searching.
    var directInput: String? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if Int(s) != nil || s.contains("curseforge.com/") { return s }
        return nil
    }

    /// CurseForge pages through at most this many results (index + pageSize <= 10,000).
    static let maxResults = 10_000

    var canLoadMore: Bool { !loading && error == nil && results.count < min(total, Self.maxResults) }

    /// What a new search would ask for; the view re-runs the search whenever this changes.
    var query: SearchQuery {
        SearchQuery(text: text.trimmingCharacters(in: .whitespacesAndNewlines), sort: sort,
                    categoryId: categoryId, gameVersionTypeId: model.config.gameVersionTypeId)
    }

    func isInstalled(_ id: Int) -> Bool { model.config.addons.contains { $0.id == id } }

    /// Starts over with the first page for the current text, sort and category.
    func run() async {
        generation += 1
        let mine = generation
        guard directInput == nil else { results = []; total = 0; error = nil; loading = false; return }
        loading = true; error = nil
        do {
            let page = try await model.api.search(query)
            guard mine == generation else { return }
            results = page.mods
            total = page.total
        } catch {
            guard mine == generation else { return }
            results = []; total = 0
            self.error = error.localizedDescription
        }
        loading = false
    }

    /// Appends the next page.
    func loadMore() async {
        guard canLoadMore else { return }
        let mine = generation
        var q = query
        q.index = results.count
        q.pageSize = min(q.pageSize, Self.maxResults - q.index)
        loading = true
        do {
            let page = try await model.api.search(q)
            guard mine == generation else { return }
            let known = Set(results.map(\.id))
            results += page.mods.filter { !known.contains($0.id) }
            total = page.total
        } catch {
            guard mine == generation else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }

    /// Loads the category list once; failures just leave the menu at "All categories".
    func loadCategories() async {
        guard categories.isEmpty, let all = try? await model.api.categories() else { return }
        categories = all.filter { $0.isClass != true }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func install(_ mod: CFMod) async {
        guard !installing.contains(mod.id), !isInstalled(mod.id) else { return }
        installing.insert(mod.id)
        failures[mod.id] = nil
        await model.install(mod)
        installing.remove(mod.id)
        if !isInstalled(mod.id) { failures[mod.id] = model.message ?? "Couldn't install \(mod.name)." }
    }
}
