import XCTest
@testable import AVPPlayCore

final class WorkshopTests: XCTestCase {
    let sha = String(repeating: "a", count: 64)

    func alyx() throws -> Recipe {
        try RecipeStore(directory: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")).load(id: "alyx")
    }

    func item(_ id: String, title: String = "Map", folder: String? = nil) -> WorkshopItem {
        WorkshopItem(id: id, title: title, folder: folder ?? Workshop.folder(title: title, id: id), manifest: "5218681684364488477",
                     size: 27228558, sha256: sha, updated: 1669326281)
    }

    func testShippedAlyxRecipeHasAWorkshop() throws {
        let r = try alyx()
        XCTAssertEqual(r.workshop, WorkshopSupport(app: "546560", dest: "lx/game/hlvr_addons"))
        XCTAssertEqual(r.workshop?.browseURL.absoluteString, "https://steamcommunity.com/app/546560/workshop/")
    }

    func testFolderNamesAreReadableAndSafe() {
        XCTAssertEqual(Workshop.folder(title: "Sandbox NPC Arena", id: "2333868769"), "sandbox_npc_arena_2333868769")
        XCTAssertEqual(Workshop.folder(title: "LEVITATION (Part 1)", id: "2880785403"), "levitation_part_1_2880785403")
        XCTAssertEqual(Workshop.folder(title: "Café – Über ../../etc", id: "7"), "cafe_uber_etc_7")
        XCTAssertEqual(Workshop.folder(title: "日本語", id: "9"), "9")
        let long = Workshop.folder(title: String(repeating: "abc ", count: 30), id: "123")
        XCTAssertLessThanOrEqual(long.count, 32 + 4)
        XCTAssertTrue(Workshop.isFolderName(long))
        XCTAssertFalse(long.contains("__"))
    }

    func testItemIdFromLinksAndIds() {
        XCTAssertEqual(Workshop.itemId(from: "https://steamcommunity.com/sharedfiles/filedetails/?id=2333868769"), "2333868769")
        XCTAssertEqual(Workshop.itemId(from: " https://steamcommunity.com/workshop/filedetails/?id=42&searchtext=x \n"), "42")
        XCTAssertEqual(Workshop.itemId(from: "2333868769"), "2333868769")
        XCTAssertNil(Workshop.itemId(from: "https://evil.example/sharedfiles/filedetails/?id=1"))
        XCTAssertNil(Workshop.itemId(from: "https://steamcommunity.com/app/546560/workshop/"))
        XCTAssertNil(Workshop.itemId(from: "https://steamcommunity.com/sharedfiles/filedetails/?id=1;rm"))
        XCTAssertNil(Workshop.itemId(from: "-1"))
    }

    func testApplyAddsAnOptionalClearableFilePerItem() throws {
        let r = try alyx()
        let list = WorkshopList(apps: ["546560": [item("2333868769", title: "Sandbox NPC Arena")]])
        let applied = list.apply(to: r)
        XCTAssertEqual(applied.files.count, r.files.count + 1)
        let f = try XCTUnwrap(applied.files.last)
        XCTAssertEqual(f.name, "2333868769.vpk")
        XCTAssertEqual(f.role, Workshop.role)
        XCTAssertFalse(f.required)
        XCTAssertEqual(f.clearable, true)
        XCTAssertEqual(f.dest, "lx/game/hlvr_addons/sandbox_npc_arena_2333868769")
        XCTAssertEqual(f.localName, "pak01_dir.vpk")
        XCTAssertEqual(StagePlan.destination(for: f), "Documents/lx/game/hlvr_addons/sandbox_npc_arena_2333868769/pak01_dir.vpk")
        XCTAssertEqual(f.source?.kind, .user)
        XCTAssertEqual(f.source?.steam?.app, "546560")
        XCTAssertEqual(f.source?.steam?.depots.first?.id, "546560")
        XCTAssertEqual(f.source?.steam?.depots.first?.manifest, "5218681684364488477")
        XCTAssertNotNil(f.title)
        // Das Ergebnis besteht die Prüfung, die jedes Rezept besteht, und Steam weiß, wie es zu holen ist.
        try applied.validate()
        XCTAssertTrue(SteamFetcher.usesSteam(applied))
        // Ein Rezept ohne Workshop bleibt, wie es ist.
        var plain = r
        plain.workshop = nil
        XCTAssertEqual(list.apply(to: plain).files.count, r.files.count)
    }

    func testApplySkipsCollisionsAndBrokenEntries() throws {
        let r = try alyx()
        // Die Sprachausgabe steht schon im Rezept (3478102838.vpk); dasselbe Item aus der Liste beißt sich damit.
        var broken = item("5")
        broken.sha256 = "nothex"
        let list = WorkshopList(apps: ["546560": [item("3478102838"), broken, item("6", folder: "same"), item("7", folder: "same")]])
        let applied = list.apply(to: r)
        XCTAssertEqual(applied.files.map(\.name).filter { $0.hasSuffix(".vpk") && $0 != "3478102838.vpk" }, ["6.vpk"])
        try applied.validate()
    }

    func testPutKeepsFolderAndRemoveKeepsTheFileForWithdrawal() throws {
        var list = WorkshopList()
        list.put(item("1", title: "Old Name"), app: "546560")
        list.put(item("1", title: "New Name"), app: "546560")
        XCTAssertEqual(list.items(app: "546560").count, 1)
        XCTAssertEqual(list.items(app: "546560").first?.folder, "old_name_1")
        XCTAssertEqual(list.items(app: "546560").first?.title, "New Name")

        list.remove(id: "1", app: "546560")
        XCTAssertTrue(list.shown(app: "546560").isEmpty)
        // Weggenommen bleibt es im Rezept – nie gewählt – damit der Abgleich es auf dem Gerät leert.
        let r = try alyx()
        let applied = list.apply(to: r)
        let f = try XCTUnwrap(applied.files.first { $0.name == "1.vpk" })
        let remote = ["Documents/lx/game/hlvr_addons/old_name_1/pak01_dir.vpk": Int64(27228558)]
        XCTAssertEqual(StagePlan.withdrawals(recipe: applied, wanted: [], remote: remote).map(\.file.name), [f.name])

        list.put(item("1"), app: "546560")
        XCTAssertEqual(list.shown(app: "546560").count, 1)
        XCTAssertNil(list.items(app: "546560").first?.removed)
    }

    func testRequiredByStaysOnlyWhileNobodyChoseItThemselves() {
        var list = WorkshopList()
        var needed = item("2")
        needed.requiredBy = ["1"]
        list.put(needed, app: "a")
        needed.requiredBy = ["3"]
        list.put(needed, app: "a")
        XCTAssertEqual(list.items(app: "a").first?.requiredBy, ["1", "3"])
        list.put(item("2"), app: "a")
        XCTAssertNil(list.items(app: "a").first?.requiredBy)
    }

    func testListRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("workshop.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(WorkshopList.load(from: url), WorkshopList())
        let list = WorkshopList(apps: ["546560": [item("1")]])
        try list.save(to: url)
        XCTAssertEqual(WorkshopList.load(from: url), list)
    }

    func testParsesSteamsAnswers() throws {
        let details = #"""
        {"response":{"result":1,"resultcount":3,"publishedfiledetails":[
         {"publishedfileid":"2333868769","result":1,"consumer_app_id":546560,"title":"Sandbox NPC Arena","file_size":"27228558",
          "hcontent_file":"5218681684364488477","time_updated":1669326281,"banned":0},
         {"publishedfileid":"900","result":1,"consumer_app_id":546560,"title":"My Collection","file_size":0,"banned":0},
         {"publishedfileid":"901","result":9}]}}
        """#
        let parsed = try WorkshopDetails.parse(Data(details.utf8))
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0], WorkshopDetails(id: "2333868769", found: true, app: "546560", title: "Sandbox NPC Arena", size: 27228558,
                                                  manifest: "5218681684364488477", updated: 1669326281, banned: false))
        XCTAssertTrue(parsed[1].isCollection)
        XCTAssertFalse(parsed[2].found)

        let children = #"""
        {"response":{"result":1,"resultcount":2,"collectiondetails":[
         {"publishedfileid":"900","result":1,"children":[{"publishedfileid":"12","sortorder":2,"filetype":0},{"publishedfileid":"11","sortorder":1,"filetype":0}]},
         {"publishedfileid":"2333868769","result":1}]}}
        """#
        XCTAssertEqual(try WorkshopDetails.parseChildren(Data(children.utf8)), ["900": ["11", "12"]])
        XCTAssertThrowsError(try WorkshopDetails.parse(Data("{}".utf8)))
    }

    func detail(_ id: String, app: String = "546560", manifest: String? = "1", found: Bool = true) -> WorkshopDetails {
        WorkshopDetails(id: id, found: found, app: app, title: "T\(id)", size: 10, manifest: manifest, updated: nil, banned: false)
    }

    func testResolveExpandsCollectionsAndDependencies() async throws {
        let all = ["900": detail("900", manifest: nil), "11": detail("11"), "12": detail("12"), "1": detail("1"), "2": detail("2"),
                   "13": detail("13", found: false)]
        let kids = ["900": ["11", "12", "13"], "1": ["2"]]
        let (items, requiredBy) = try await WorkshopDetails.resolve(["900", "1"], app: "546560",
                                                                     details: { ids in ids.compactMap { all[$0] } },
                                                                     children: { ids in kids.filter { ids.contains($0.key) } })
        // Ein Item der Sammlung, das es nicht mehr gibt, fällt weg.
        XCTAssertEqual(items.map(\.id), ["11", "12", "1", "2"])
        XCTAssertEqual(requiredBy, ["2": ["1"]])
    }

    func testResolveRefusesOtherGamesAndMissingDependencies() async {
        do {
            _ = try await WorkshopDetails.resolve(["1"], app: "546560", details: { _ in [self.detail("1", app: "620")] }, children: { _ in [:] })
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? WorkshopError, .otherGame("T1")) }
        do {
            _ = try await WorkshopDetails.resolve(["1"], app: "546560",
                                                  details: { ids in ids.map { $0 == "2" ? self.detail("2", found: false) : self.detail($0) } },
                                                  children: { _ in ["1": ["2"]] })
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? WorkshopError, .notAvailable("2")) }
        do {
            _ = try await WorkshopDetails.resolve(["1"], app: "546560", details: { _ in [self.detail("1", found: false)] }, children: { _ in [:] })
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? WorkshopError, .notAvailable("1")) }
    }

    func testRecipeRejectsAnInsaneWorkshopEntry() throws {
        var r = try alyx()
        r.workshop = WorkshopSupport(app: "546560", dest: "../outside")
        XCTAssertThrowsError(try r.validate())
        r.workshop = WorkshopSupport(app: "5465x", dest: "lx/game/hlvr_addons")
        XCTAssertThrowsError(try r.validate())
    }
}
