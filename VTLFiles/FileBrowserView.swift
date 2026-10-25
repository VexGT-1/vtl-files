import SwiftUI

// MARK: - Model

struct FileItem: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64?

    var icon: String {
        guard !isDirectory else { return "folder.fill" }
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "plist":         return "doc.badge.gearshape.fill"
        case "txt", "md", "log", "conf": return "doc.text.fill"
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo.fill"
        case "mp4", "mov", "m4v": return "video.fill"
        case "mp3", "m4a", "aac", "wav", "flac": return "waveform"
        case "json":          return "curlybraces"
        case "dylib", "so":   return "gearshape.2.fill"
        case "ipa", "zip", "tar", "gz": return "archivebox.fill"
        default:              return "doc.fill"
        }
    }

    var iconColor: Color {
        guard !isDirectory else { return .yellow }
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "plist": return .orange
        case "json":  return .cyan
        case "dylib", "so": return .purple
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return .green
        case "mp4", "mov": return .pink
        default: return .secondary
        }
    }

    var sizeLabel: String {
        guard let s = size, !isDirectory else { return "" }
        return ByteCountFormatter.string(fromByteCount: s, countStyle: .file)
    }
}

@MainActor
final class DirectoryLoader: ObservableObject {
    @Published var items: [FileItem] = []
    @Published var isLoading = false
    @Published var error: String?

    private var handle: BadQueryHandle?

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
        // Try direct access first; on failure, unlock with bad_query
        let fm = FileManager.default
        func read() throws -> [FileItem] {
            try fm.contentsOfDirectory(atPath: path).sorted().map { name in
                let full = (path as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: full, isDirectory: &isDir)
                let attrs = try? fm.attributesOfItem(atPath: full)
                let size = attrs?[.size] as? Int64
                return FileItem(name: name, path: full, isDirectory: isDir.boolValue, size: size)
            }
        }

        do {
            return (try read(), nil)
        } catch {
            // Attempt sandbox escape
            if let _ = try? BadQuery.consume(path: path, create: false) {
                do {
                    return (try read(), nil)
                } catch let e2 {
                    return ([], e2.localizedDescription)
                }
            }
            return ([], error.localizedDescription)
        }
    }
}

// MARK: - Item Row

struct ItemRow: View {
    let item: FileItem

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                if !item.sizeLabel.isEmpty {
                    Text(item.sizeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: item.icon)
                .foregroundStyle(item.iconColor)
                .frame(width: 28)
        }
    }
}

// MARK: - Directory List

struct DirectoryList: View {
    let path: String
    @StateObject private var loader = DirectoryLoader()
    @State private var editingFile: FileItem?

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
            } else if loader.items.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            } else {
                List {
                    ForEach(loader.items) { item in
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
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .task { loader.load(path: path) }
        .refreshable { loader.load(path: path) }
        .sheet(item: $editingFile) { file in
            FileEditorView(file: file)
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
        ("/", "Root", "house.fill"),
        ("/private/var/mobile", "Home", "person.fill"),
        ("/private/var/mobile/Library/Preferences", "Preferences", "slider.horizontal.3"),
        ("/private/var/mobile/Library", "Library", "books.vertical.fill"),
        ("/private/var/mobile/Containers/Data/Application", "App Containers", "square.3.layers.3d"),
        ("/private/var/containers/Bundle/Application", "App Bundles", "archivebox.fill"),
        ("/private/var/mobile/Documents", "Documents", "doc.fill"),
        ("/private/var/mobile/Media", "Media", "photo.fill"),
        ("/private/var/Managed Preferences/mobile", "Managed Preferences", "gearshape.fill"),
        ("/usr/lib", "usr/lib", "gearshape.2.fill"),
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
                    .padding(.vertical, 2)
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
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.label)
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
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
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
