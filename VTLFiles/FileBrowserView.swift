import SwiftUI

// MARK: - Model

struct FileItem: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let date: Date?
    let permissions: String?

    var icon: String {
        guard !isDirectory else { return "folder.fill" }
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "plist":                              return "doc.badge.gearshape.fill"
        case "txt", "md", "log", "conf", "cfg":   return "doc.text.fill"
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo.fill"
        case "mp4", "mov", "m4v":                 return "video.fill"
        case "mp3", "m4a", "aac", "wav", "flac":  return "waveform"
        case "json":                               return "curlybraces"
        case "dylib", "so":                        return "gearshape.2.fill"
        case "ipa", "zip", "tar", "gz", "bz2":    return "archivebox.fill"
        case "db", "sqlite", "sqlite3":            return "cylinder.fill"
        case "pem", "cer", "der":                  return "lock.doc.fill"
        default:                                   return "doc.fill"
        }
    }

    var iconColor: Color {
        guard !isDirectory else { return .yellow }
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "plist":                              return .orange
        case "json":                               return .cyan
        case "dylib", "so":                        return .purple
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return .green
        case "mp4", "mov":                         return .pink
        case "db", "sqlite", "sqlite3":            return .mint
        case "pem", "cer", "der":                  return .red
        default:                                   return .secondary
        }
    }

    var sizeLabel: String {
        guard let s = size, !isDirectory else { return "" }
        return ByteCountFormatter.string(fromByteCount: s, countStyle: .file)
    }

    var dateLabel: String {
        guard let d = date else { return "" }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case name = "Name"
    case date = "Date"
    case size = "Size"
    case kind = "Kind"
    var id: String { rawValue }
}

// MARK: - Loader

@MainActor
final class DirectoryLoader: ObservableObject {
    @Published var items: [FileItem] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var sortOrder: SortOrder = .name
    @Published var sortAsc: Bool = true
    @Published var searchText: String = ""

    var displayed: [FileItem] {
        var base = items
        if !searchText.isEmpty {
            base = base.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        base.sort {
            let asc = sortAsc
            switch sortOrder {
            case .name: return asc ? $0.name < $1.name : $0.name > $1.name
            case .date:
                let a = $0.date ?? .distantPast, b = $1.date ?? .distantPast
                return asc ? a < b : a > b
            case .size:
                let a = $0.size ?? 0, b = $1.size ?? 0
                return asc ? a < b : a > b
            case .kind:
                let a = $0.isDirectory ? "0" : $0.icon
                let b = $1.isDirectory ? "0" : $1.icon
                return asc ? a < b : a > b
            }
        }
        return base
    }

    func load(path: String) {
        isLoading = true
        error = nil
        Task { [weak self] in
            guard let self else { return }
            let (result, err) = await Self.readDirectory(path)
            self.items = result
            self.error = err
            self.isLoading = false
        }
    }

    private static func readDirectory(_ path: String) async -> ([FileItem], String?) {
        let fm = FileManager.default
        func read() throws -> [FileItem] {
            try fm.contentsOfDirectory(atPath: path).map { name in
                let full = (path as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: full, isDirectory: &isDir)
                let attrs = try? fm.attributesOfItem(atPath: full)
                let size = attrs?[.size] as? Int64
                let date = attrs?[.modificationDate] as? Date
                var perms: String? = nil
                if let p = attrs?[.posixPermissions] as? Int {
                    perms = String(format: "%04o", p)
                }
                return FileItem(name: name, path: full, isDirectory: isDir.boolValue, size: size, date: date, permissions: perms)
            }
        }

        do {
            return (try read(), nil)
        } catch {
            // Attempt 1a: class 13 bad_query (create:false)
            if (try? BadQuery.consume(path: path, create: false)) != nil {
                do { return (try read(), nil) } catch {}
            }
            // Attempt 1b: class 13 bad_query (create:true — skip lstat, needed for /var/containers paths)
            if (try? BadQuery.consume(path: path, create: true)) != nil {
                do { return (try read(), nil) } catch {}
            }
            // Attempt 1c: class 7 (appGroup) bad_query — iOS 27 doesn't check caller entitlements
            // ContainerManagerCommon.framework plist: no requiredEntitlement on class 7.
            for groupId in ["group.com.apple.notes", "group.com.apple.mail", "group.com.apple.mobilenotes", "group.com.apple.siri.parsec"] {
                if (try? BadQuery.consume(path: path, create: false, groupIdentifier: groupId)) != nil {
                    do { return (try read(), nil) } catch {}
                    break
                }
            }
            // Attempt 1d: sandbox_extension_issue_file (libsystem_sandbox.dylib, mond sbx.swift technique)
            if sandboxIssueAndConsume(path: path) {
                do { return (try read(), nil) } catch {}
            }
            // Attempt 2: bad_query_list (fsgetpath inode walk — no token needed, works for /var/containers etc.)
            let listed = BadQuery.list(path: path, maxInode: 5_000_000)
            if !listed.isEmpty {
                let items: [FileItem] = listed.compactMap { fullPath in
                    let name = (fullPath as NSString).lastPathComponent
                    guard !name.isEmpty else { return nil }
                    // Try stat; fall back to extension heuristic
                    var isDir: ObjCBool = false
                    let statted = fm.fileExists(atPath: fullPath, isDirectory: &isDir)
                    let attrs = try? fm.attributesOfItem(atPath: fullPath)
                    if !statted {
                        // Heuristic: no extension = likely directory (UUID containers, system dirs)
                        let ext = (name as NSString).pathExtension
                        let looksLikeDir = ext.isEmpty || ext == "app" || ext == "framework" || ext == "bundle"
                        return FileItem(name: name, path: fullPath, isDirectory: looksLikeDir, size: nil, date: nil, permissions: nil)
                    }
                    return FileItem(name: name, path: fullPath, isDirectory: isDir.boolValue,
                                   size: attrs?[.size] as? Int64,
                                   date: attrs?[.modificationDate] as? Date,
                                   permissions: (attrs?[.posixPermissions] as? Int).map { String(format: "%04o", $0) })
                }
                return (items.sorted { $0.name < $1.name }, nil)
            }
            return ([], error.localizedDescription)
        }
    }

    func delete(item: FileItem) async -> String? {
        let fm = FileManager.default
        do {
            if fm.isDeletableFile(atPath: item.path) {
                try fm.removeItem(atPath: item.path)
            } else {
                try? BadQuery.consume(path: (item.path as NSString).deletingLastPathComponent, create: false)
                try fm.removeItem(atPath: item.path)
            }
            await MainActor.run { items.removeAll { $0.id == item.id } }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Item Row

struct ItemRow: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(item.iconColor)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 15))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if !item.sizeLabel.isEmpty {
                        Text(item.sizeLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let p = item.permissions {
                        Text(p)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    if !item.dateLabel.isEmpty {
                        Text(item.dateLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Directory List

struct DirectoryList: View {
    let path: String
    @StateObject private var loader = DirectoryLoader()
    @State private var editingFile: FileItem?
    @State private var deleteTarget: FileItem?
    @State private var deleteError: String?
    @State private var showSortMenu = false

    var title: String {
        let last = URL(fileURLWithPath: path).lastPathComponent
        return last.isEmpty ? "/" : last
    }

    var body: some View {
        Group {
            if loader.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = loader.error {
                ContentUnavailableView {
                    Label("Can't Open", systemImage: "lock.slash.fill")
                } description: {
                    Text(err).font(.caption.monospaced())
                }
            } else if loader.displayed.isEmpty && !loader.searchText.isEmpty {
                ContentUnavailableView.search(text: loader.searchText)
            } else if loader.items.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            } else {
                List {
                    ForEach(loader.displayed) { item in
                        Group {
                            if item.isDirectory {
                                NavigationLink(value: item.path) {
                                    ItemRow(item: item)
                                }
                            } else {
                                Button { editingFile = item } label: {
                                    ItemRow(item: item)
                                }
                                .foregroundStyle(.primary)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deleteTarget = item
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                shareItem(item)
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                copyPath(item.path)
                            } label: {
                                Label("Copy Path", systemImage: "doc.on.doc")
                            }
                            .tint(.orange)
                        }
                        .contextMenu {
                            Button { copyPath(item.path) } label: {
                                Label("Copy Path", systemImage: "doc.on.doc")
                            }
                            if !item.isDirectory {
                                Button { shareItem(item) } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                            }
                            Divider()
                            Button(role: .destructive) {
                                deleteTarget = item
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $loader.searchText, placement: .automatic, prompt: "Search")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: $loader.sortOrder) {
                        ForEach(SortOrder.allCases) { o in
                            Text(o.rawValue).tag(o)
                        }
                    }
                    Divider()
                    Button {
                        loader.sortAsc.toggle()
                    } label: {
                        Label(loader.sortAsc ? "Ascending" : "Descending",
                              systemImage: loader.sortAsc ? "arrow.up" : "arrow.down")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
        .task { loader.load(path: path) }
        .refreshable { loader.load(path: path) }
        .sheet(item: $editingFile) { file in
            FileEditorView(file: file)
        }
        .alert("Delete \"\(deleteTarget?.name ?? "")\"?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let target = deleteTarget else { return }
                deleteTarget = nil
                Task {
                    if let err = await loader.delete(item: target) {
                        deleteError = err
                    }
                }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        }
        .alert("Delete failed", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    func copyPath(_ p: String) {
        UIPasteboard.general.string = p
    }

    func shareItem(_ item: FileItem) {
        let url = URL(fileURLWithPath: item.path)
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(av, animated: true)
        }
    }
}

// MARK: - Go To Path Sheet

struct GoToPathView: View {
    let currentPath: String
    let onNavigate: (String) -> Void

    @State private var text: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(currentPath: String, onNavigate: @escaping (String) -> Void) {
        self.currentPath = currentPath
        self.onNavigate = onNavigate
        _text = State(initialValue: currentPath)
    }

    let quickPaths: [(path: String, label: String, icon: String)] = [
        ("/", "Root /", "house.fill"),
        ("/private/var/mobile", "Home", "person.fill"),
        ("/private/var/mobile/Library/Preferences", "Preferences", "slider.horizontal.3"),
        ("/private/var/mobile/Library", "Library", "books.vertical.fill"),
        ("/private/var/mobile/Library/Caches", "Caches", "internaldrive.fill"),
        ("/private/var/mobile/Containers/Data/Application", "App Data", "square.3.layers.3d"),
        ("/private/var/containers/Bundle/Application", "App Bundles", "archivebox.fill"),
        ("/private/var/mobile/Documents", "Documents", "doc.fill"),
        ("/private/var/mobile/Media", "Media", "photo.fill"),
        ("/usr/lib", "usr/lib", "gearshape.2.fill"),
        ("/System/Library", "System Library", "building.2.fill"),
        ("/private/var/Managed Preferences/mobile", "Managed Prefs", "gearshape.fill"),
    ]

    var isValid: Bool { text.hasPrefix("/") && !text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right.circle.fill")
                            .foregroundStyle(.tint)
                            .font(.title3)
                        TextField("/", text: $text)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused)
                            .onSubmit { navigate() }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Path")
                } footer: {
                    if !isValid && !text.isEmpty {
                        Label("Must start with /", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                Section("Quick Access") {
                    ForEach(quickPaths, id: \.path) { item in
                        Button {
                            text = item.path
                            navigate()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.icon)
                                    .foregroundStyle(.tint)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.label)
                                        .font(.body)
                                    Text(item.path)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Go to Path")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go") { navigate() }
                        .disabled(!isValid)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    func navigate() {
        let p = text.trimmingCharacters(in: .whitespaces)
        guard p.hasPrefix("/") else { return }
        onNavigate(p)
    }
}

// MARK: - Root View

struct FileBrowserView: View {
    @State private var navPath: [String] = []
    @State private var showGoToPath = false

    var currentDir: String { navPath.last ?? "/" }

    var body: some View {
        NavigationStack(path: $navPath) {
            DirectoryList(path: "/")
                .navigationDestination(for: String.self) { path in
                    DirectoryList(path: path)
                }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Button { showGoToPath = true } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "folder.fill")
                                    .font(.caption)
                                Text(currentDir == "/" ? "/" : (currentDir as NSString).lastPathComponent)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .glassEffect(in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { showGoToPath = true } label: {
                            Image(systemName: "arrow.turn.right.up")
                        }
                    }
                }
        }
        .sheet(isPresented: $showGoToPath) {
            GoToPathView(currentPath: currentDir) { path in
                navPath.append(path)
                showGoToPath = false
            }
        }
    }
}
