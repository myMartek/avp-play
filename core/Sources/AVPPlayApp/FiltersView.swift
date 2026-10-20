import AVPPlayCore
import SwiftUI

// MARK: Eigene Filter

extension AppModel {
    /// Legt einen Filter an, gleich mit den genannten Spielen. `nil`, wenn der Name nicht taugt (siehe `CustomFilters.nameProblem`).
    @discardableResult
    func createFilter(named name: String, games: Set<String> = []) -> CustomFilter? {
        guard CustomFilters.nameProblem(name, in: customFilters) == nil else { return nil }
        let filter = CustomFilter(name: CustomFilters.cleanName(name), games: games)
        customFilters.append(filter)
        return filter
    }

    func renameFilter(_ id: String, to name: String) {
        guard CustomFilters.nameProblem(name, in: customFilters, except: id) == nil,
              let i = customFilters.firstIndex(where: { $0.id == id }) else { return }
        customFilters[i].name = CustomFilters.cleanName(name)
    }

    func deleteFilter(_ id: String) {
        customFilters.removeAll { $0.id == id }
        customFilterModes[id] = nil
    }

    /// Nimmt Spiele in einen Filter auf oder aus ihm heraus.
    func setMembership(_ ids: [String], in filterId: String, member: Bool) {
        guard let i = customFilters.firstIndex(where: { $0.id == filterId }) else { return }
        if member { customFilters[i].games.formUnion(ids) } else { customFilters[i].games.subtract(ids) }
    }

    func setFilterMode(_ id: String, _ mode: CustomFilterMode) {
        customFilterModes[id] = mode == .off ? nil : mode
    }

    func filterMode(_ id: String) -> CustomFilterMode { customFilterModes[id] ?? .off }

    /// Die Filter, in denen ein Spiel steht, in der Reihenfolge der Seite „Filter“.
    func filters(containing id: String) -> [CustomFilter] { customFilters.filter { $0.games.contains(id) } }

    /// Öffnet die Seite eines Spiels in der Übersicht.
    func openGame(_ id: String) {
        section = .games
        gamePath = [id]
    }
}

extension CustomFilterMode {
    var title: String {
        switch self {
        case .off: return L("Off", "Aus")
        case .only: return L("Show Only These", "Nur diese zeigen")
        case .hide: return L("Hide These", "Diese ausblenden")
        }
    }
    var symbol: String {
        switch self {
        case .off: return "square"
        case .only: return "checkmark.square.fill"
        case .hide: return "minus.square.fill"
        }
    }
    /// Der nächste Zustand beim Klick auf den Filter in der Übersicht: aus → nur diese → ausblenden → aus.
    var next: CustomFilterMode {
        switch self {
        case .off: return .only
        case .only: return .hide
        case .hide: return .off
        }
    }
}

/// Ein eigener Filter in der Leiste der Übersicht. Ein Klick schaltet weiter (aus, nur diese, ausblenden), das
/// Kontextmenü wählt direkt. Ein Knopf und kein Menü: Menüs zeichnet macOS einfarbig, und „ausblenden“ soll man sehen.
struct CustomFilterChip: View {
    @EnvironmentObject var model: AppModel
    let filter: CustomFilter

    var body: some View {
        let mode = model.filterMode(filter.id)
        Button { model.setFilterMode(filter.id, mode.next) } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.symbol)
                    .foregroundStyle(mode == .only ? Color.accentColor : mode == .hide ? Color.orange : Color.secondary)
                Text(filter.name)
                    .strikethrough(mode == .hide, color: .orange)
                    .foregroundStyle(mode == .hide ? Color.secondary : Color.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .contextMenu {
            Picker(filter.name, selection: Binding(get: { model.filterMode(filter.id) }, set: { model.setFilterMode(filter.id, $0) })) {
                ForEach(CustomFilterMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button(L("Manage Filters …", "Filter verwalten …")) { model.section = .filters }
        }
        .help(L("Your filter “\(filter.name)” (\(filter.games.count) games), now: \(mode.title). Click to switch: off, show only these, hide these. Right-click to choose directly.",
                "Dein Filter „\(filter.name)“ (\(filter.games.count) Spiele), jetzt: \(mode.title). Ein Klick schaltet weiter: aus, nur diese zeigen, diese ausblenden. Rechtsklick wählt direkt."))
        .accessibilityLabel(L("Filter \(filter.name): \(mode.title)", "Filter \(filter.name): \(mode.title)"))
    }
}

/// Das Menü, mit dem Spiele in eigene Filter kommen: auf der Seite eines Spiels für dieses, unter der Übersicht für
/// alle angehakten. Ein Haken heißt: Alle genannten Spiele stehen in dem Filter.
struct FilterMenu<Label: View>: View {
    @EnvironmentObject var model: AppModel
    let ids: [String]
    @ViewBuilder let label: () -> Label
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        Menu {
            if model.customFilters.isEmpty {
                Text(L("No filters yet", "Noch keine Filter"))
            }
            ForEach(model.customFilters) { filter in
                let inside = ids.filter { filter.games.contains($0) }.count
                Toggle(isOn: Binding(get: { !ids.isEmpty && inside == ids.count },
                                     set: { model.setMembership(ids, in: filter.id, member: $0) })) {
                    Text(inside > 0 && inside < ids.count
                         ? L("\(filter.name) (\(inside) of \(ids.count))", "\(filter.name) (\(inside) von \(ids.count))")
                         : filter.name)
                }
            }
            Divider()
            Button(L("New Filter …", "Neuer Filter …")) { newName = ""; naming = true }
            Button(L("Manage Filters …", "Filter verwalten …")) { model.section = .filters }
        } label: {
            label()
        }
        .disabled(ids.isEmpty)
        .alert(ids.count == 1 ? L("New Filter with This Game", "Neuer Filter mit diesem Spiel")
                              : L("New Filter with \(ids.count) Games", "Neuer Filter mit \(ids.count) Spielen"),
               isPresented: $naming) {
            TextField(L("Name, e.g. 32 Bit", "Name, z. B. 32 Bit"), text: $newName)
            Button(L("Create", "Anlegen")) { create() }
            Button(L("Cancel", "Abbrechen"), role: .cancel) {}
        } message: {
            Text(L("The filter then appears above the game list, where it can show only these games or hide them.",
                   "Der Filter steht dann über der Spieleliste; dort kann er nur diese Spiele zeigen oder sie ausblenden."))
        }
    }

    private func create() {
        if let why = CustomFilters.nameProblem(newName, in: model.customFilters) {
            model.notice = why
            return
        }
        model.createFilter(named: newName, games: Set(ids))
    }
}

/// Der Knopf auf der Seite eines Spiels: in welchen eigenen Filtern es steht, und ein Menü, um das zu ändern.
struct GameFilterButton: View {
    @EnvironmentObject var model: AppModel
    let game: Game

    var body: some View {
        let names = model.filters(containing: game.id).map(\.name)
        FilterMenu(ids: [game.id]) {
            SwiftUI.Label(names.isEmpty ? L("Filter", "Filter") : names.joined(separator: ", "),
                          systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("Add this game to a filter of your own, such as “32 Bit”, or take it out of one.",
                "Dieses Spiel einem eigenen Filter zuordnen, etwa „32 Bit“, oder es aus einem herausnehmen."))
    }
}

/// Die Seite „Filter“: eigene Filter anlegen, umbenennen und löschen, und sehen, welche Spiele in welchem stehen.
struct FiltersView: View {
    @EnvironmentObject var model: AppModel
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L("Group games the way you want – for example “32 Bit”, “For Guests” or “Finished”. Add a game on its page with the “Filter” button, or select several in the game list and use “Set Filter” in the bar below it. Above the game list, each filter can then show only its games or hide them – such as all favourites without the 32-bit ones.",
                       "Spiele so gruppieren, wie du willst – etwa „32 Bit“, „Für Gäste“ oder „Durchgespielt“. Ein Spiel kommt auf seiner Seite über den Knopf „Filter“ hinein, oder du hakst in der Spieleliste mehrere an und wählst in der Leiste darunter „Filter setzen“. Über der Spieleliste kann dann jeder Filter nur seine Spiele zeigen oder sie ausblenden – etwa alle Favoriten ohne die 32-Bit-Spiele."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField(L("Name of a new filter", "Name eines neuen Filters"), text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                        .onSubmit(create)
                    Button(L("Create Filter", "Filter anlegen"), action: create)
                        .disabled(CustomFilters.nameProblem(newName, in: model.customFilters) != nil)
                    if !newName.isEmpty, let why = CustomFilters.nameProblem(newName, in: model.customFilters) {
                        Text(why).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if model.customFilters.isEmpty {
                    ContentUnavailableView(L("No Filters Yet", "Noch keine Filter"), systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text(L("Create one above, or from the page of a game.", "Leg oben einen an, oder auf der Seite eines Spiels.")))
                        .padding(.top, 40)
                } else {
                    ForEach(model.customFilters) { filter in FilterBox(filter: filter) }
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(L("Filters", "Filter"))
        // Spiele eines Filters, die der Katalog noch nicht geladen hat, sollen mit Namen dastehen.
        .task(id: model.customFilters.flatMap(\.games).sorted()) { await model.loadMissing(model.customFilters.flatMap(\.games)) }
    }

    private func create() {
        guard model.createFilter(named: newName) != nil else { return }
        newName = ""
    }
}

/// Ein Filter auf der Seite „Filter“: Name und seine Spiele. Was er in der Übersicht bewirkt, wird dort geschaltet.
struct FilterBox: View {
    @EnvironmentObject var model: AppModel
    let filter: CustomFilter
    @State private var renaming = false
    @State private var name = ""
    @State private var confirmDelete = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    if renaming {
                        TextField(L("Name", "Name"), text: $name)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                            .onSubmit(rename)
                        Button(L("Done", "Fertig"), action: rename)
                            .disabled(CustomFilters.nameProblem(name, in: model.customFilters, except: filter.id) != nil)
                        Button(L("Cancel", "Abbrechen")) { renaming = false }
                    } else {
                        Text(filter.name).font(.title3.bold())
                        Text(filter.games.count == 1 ? L("1 game", "1 Spiel") : L("\(filter.games.count) games", "\(filter.games.count) Spiele"))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button(L("Rename …", "Umbenennen …")) { name = filter.name; renaming = true }
                        Button(L("Export List …", "Liste exportieren …")) { model.exportFilter(filter) }
                            .disabled(filter.games.isEmpty)
                        Divider()
                        Button(L("Delete Filter …", "Filter löschen …"), role: .destructive) { confirmDelete = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                if filter.games.isEmpty {
                    Text(L("No games yet. Add them on the page of a game, or select several in the game list.",
                           "Noch keine Spiele. Füge sie auf der Seite eines Spiels hinzu, oder hake in der Spieleliste mehrere an."))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(members, id: \.id) { member in
                            FilterMemberChip(filterId: filter.id, id: member.id, title: member.title, known: member.known)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .confirmationDialog(L("Delete the filter “\(filter.name)”?", "Den Filter „\(filter.name)“ löschen?"), isPresented: $confirmDelete) {
            Button(L("Delete", "Löschen"), role: .destructive) { model.deleteFilter(filter.id) }
        } message: {
            Text(L("Only the filter goes; the games stay as they are.", "Nur der Filter geht; die Spiele bleiben, wie sie sind."))
        }
    }

    /// Die Spiele des Filters nach Namen; eines, das der Katalog (noch) nicht geladen hat, mit seiner Kennung.
    private var members: [(id: String, title: String, known: Bool)] {
        let titles = Dictionary(model.allGames.map { ($0.id, $0.recipe.title) }, uniquingKeysWith: { a, _ in a })
        return filter.games.map { ($0, titles[$0] ?? $0, titles[$0] != nil) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func rename() {
        guard CustomFilters.nameProblem(name, in: model.customFilters, except: filter.id) == nil else { return }
        model.renameFilter(filter.id, to: name)
        renaming = false
    }
}

/// Ein Spiel in einem Filter: ein Klick öffnet seine Seite, das Kreuz nimmt es heraus.
struct FilterMemberChip: View {
    @EnvironmentObject var model: AppModel
    let filterId: String
    let id: String
    let title: String
    let known: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button(title) { model.openGame(id) }
                .buttonStyle(.plain)
                .disabled(!known)
                .help(known ? L("Open the page of this game", "Die Seite dieses Spiels öffnen")
                            : L("The catalogue has not loaded this game (yet).", "Der Katalog hat dieses Spiel (noch) nicht geladen."))
            Button { model.setMembership([id], in: filterId, member: false) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("Take out of this filter", "Aus diesem Filter nehmen"))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}
