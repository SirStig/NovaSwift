import SwiftUI
import UniformTypeIdentifiers
import NovaSwiftKit
import NovaSwiftPluginStore

/// Plugins: browse the catalog, install and update, enable and disable, check
/// load order, import your own files. Modern layout only, full screen on every
/// platform (the Classic/Enhanced/Nova Swift modes do not restyle it).
struct PluginsView: View {
    @EnvironmentObject private var model: AppModel
    /// Closes this screen (injected by the full-screen overlay presenter).
    var onClose: () -> Void = {}

    enum Tab: String, CaseIterable, Identifiable {
        case browse = "Browse", installed = "Installed", loadOrder = "Load order"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .browse
    @State private var filter: PluginFilter = .popular
    @State private var query = ""
    @State private var selected: PluginCatalogEntry?
    @State private var showingImporter = false
    @State private var importMessage: String?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.06), Color(white: 0.11)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                if selected == nil { tabBar }
                content
            }
        }
        .foregroundStyle(.primary)
        .task {
            await model.store.loadCatalog()
            model.store.refresh(data: model.data)
        }
        .onReceive(model.data.$plugins) { _ in model.store.refresh(data: model.data) }
        .novaFileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [.zip, .folder, .data, .item],
                          allowsMultipleSelection: true,
                          onCompletion: handleImport)
        .alert("Import", isPresented: Binding(get: { importMessage != nil },
                                              set: { if !$0 { importMessage = nil } }),
               presenting: importMessage) { _ in
            Button("OK") { importMessage = nil }
        } message: { Text($0) }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: 12) {
            if selected != nil {
                Button { selected = nil } label: { Label("Back", systemImage: "chevron.left") }
                    .novaBorderedButton()
            }
            Text(selected?.name ?? "Plugins").font(.title2.weight(.bold)).lineLimit(1)
            Spacer()
            if model.store.isRefreshing { ProgressView() }
            #if !os(tvOS)
            Button { showingImporter = true } label: { Label("Import", systemImage: "square.and.arrow.down.on.square") }
                .novaBorderedButton()
            #endif
            Button { Task { await model.store.loadCatalog(force: true) } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .novaBorderedButton().accessibilityLabel("Refresh catalog")
            Button("Done", action: onClose).novaProminentButton()
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var tabBar: some View {
        HStack {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        if let entry = selected {
            PluginDetailView(entry: entry)
        } else {
            switch tab {
            case .browse: browse
            case .installed: InstalledPluginsView(onImport: { showingImporter = true },
                                                  onOpen: { selected = $0 })
            case .loadOrder: LoadOrderView()
            }
        }
    }

    // MARK: Browse

    private var results: [PluginCatalogEntry] { model.store.browser.results(filter: filter, query: query) }

    private var browse: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                searchField
                filterChips
                if let notice = catalogNotice {
                    Label(notice, systemImage: "wifi.slash").font(.footnote).foregroundStyle(.secondary)
                }
                let updates = model.store.browser.updatesAvailable
                if !updates.isEmpty && filter != .updates && !model.store.isOffline {
                    Button { model.store.updateAll(data: model.data) } label: {
                        Label("Update all (\(updates.count))", systemImage: "arrow.triangle.2.circlepath")
                    }.novaBorderedButton()
                }
                if results.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: gridMinimum), spacing: 16, alignment: .top)],
                              spacing: 16) {
                        ForEach(results) { entry in
                            PluginCard(entry: entry) { selected = entry }
                        }
                    }
                }
                Text("Plug-in files download straight from each author's own site. NovaSwift doesn't host or change them, and you need your own copy of EV Nova to play any of them.")
                    .font(.footnote).foregroundStyle(.tertiary).padding(.top, 8)
            }
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
    }

    private var gridMinimum: CGFloat {
        #if os(tvOS)
        return 420
        #else
        return 290
        #endif
    }

    private var catalogNotice: String? {
        guard model.store.isOffline else { return nil }
        let which = model.store.source == .cache ? "the last catalog downloaded" : "the catalog that came with the app"
        return "You're offline. Showing \(which); downloads and updates are off until you reconnect."
    }

    @ViewBuilder private var searchField: some View {
        #if os(tvOS)
        EmptyView()
        #else
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search plug-ins, authors, tags", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.novaPlain).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        #endif
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PluginFilter.allCases) { f in
                    let count = f == .updates ? model.store.browser.updatesAvailable.count : 0
                    Button { filter = f } label: {
                        Text(count > 0 ? "\(f.title) (\(count))" : f.title)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(filter == f ? Color.accentColor : Color.primary.opacity(0.1), in: Capsule())
                            .foregroundStyle(filter == f ? Color.white : Color.primary)
                    }
                    .buttonStyle(.novaPlain)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension").font(.largeTitle).foregroundStyle(.secondary)
            Text(filter == .updates ? "Everything is up to date" : "Nothing here").font(.headline)
            Text(query.isEmpty ? "Try a different filter." : "No plug-ins match \u{201C}\(query)\u{201D}.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 50)
    }

    // MARK: Import

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            var done: [String] = []
            for url in urls { done.append(try model.data.importPlugin(from: url)) }
            guard !done.isEmpty else { return }
            let list = done.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
            importMessage = model.data.manualPluginOrder
                ? "Imported \(list). Switch it on under Installed."
                : "Imported \(list). It loads with your other plug-ins next time you start a game."
            tab = .installed
        } catch {
            importMessage = "That didn't work: \(error.localizedDescription)"
        }
    }
}
