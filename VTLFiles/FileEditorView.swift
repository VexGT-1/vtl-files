import SwiftUI

struct FileEditorView: View {
    let file: FileItem
    @Environment(\.dismiss) private var dismiss

    @State private var content: String = ""
    @State private var plistDisplay: String = ""
    @State private var isLoading = true
    @State private var errorMsg: String?
    @State private var isDirty = false
    @State private var saveError: String?
    @State private var showSaveSuccess = false

    enum Mode { case text, plist, binary, image }
    @State private var mode: Mode = .binary

    var ext: String { URL(fileURLWithPath: file.name).pathExtension.lowercased() }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = errorMsg {
                    ContentUnavailableView {
                        Label("Can't Open", systemImage: "lock.slash.fill")
                    } description: {
                        Text(err).font(.caption.monospaced())
                    }
                } else {
                    switch mode {
                    case .text:
                        TextEditor(text: $content)
                            .font(.system(.caption, design: .monospaced))
                            .onChange(of: content) { isDirty = true }
                    case .plist:
                        ScrollView {
                            Text(plistDisplay)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .textSelection(.enabled)
                        }
                    case .image:
                        ScrollView {
                            if let uiImg = UIImage(contentsOfFile: file.path) {
                                Image(uiImage: uiImg)
                                    .resizable()
                                    .scaledToFit()
                                    .padding()
                            }
                        }
                    case .binary:
                        ContentUnavailableView("Binary File",
                            systemImage: "doc.fill",
                            description: Text("No preview available for this file type."))
                    }
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if mode == .text {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Save") { save() }
                            .disabled(!isDirty)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let e = saveError {
                    Text(e)
                        .font(.caption)
                        .padding(10)
                        .glassEffect(in: .rect(cornerRadius: 10))
                        .padding()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if showSaveSuccess {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .padding(10)
                        .glassEffect(in: .capsule)
                        .padding()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .presentationDetents([.large])
        .task { loadFile() }
    }

    func loadFile() {
        isLoading = true
        Task {
            // Attempt bad_query unlock if needed
            let dir = (file.path as NSString).deletingLastPathComponent
            try? BadQuery.consume(path: dir, create: false)

            let imageExts = ["jpg","jpeg","png","gif","heic","webp","bmp","tiff"]
            let textExts = ["txt","md","log","conf","json","js","ts","html","css","xml","yaml","yml","sh","py","rb","swift","c","h","m","mm"]
            let plistExts = ["plist"]

            if plistExts.contains(ext) {
                await loadPlist()
            } else if imageExts.contains(ext) {
                await MainActor.run {
                    mode = .image
                    isLoading = false
                }
            } else if textExts.contains(ext) {
                await loadText()
            } else {
                // Try as text, fallback to binary
                let data = try? Data(contentsOf: URL(fileURLWithPath: file.path))
                if let d = data, let str = String(data: d, encoding: .utf8) {
                    await MainActor.run {
                        content = str
                        mode = .text
                        isLoading = false
                    }
                } else {
                    await MainActor.run {
                        mode = .binary
                        isLoading = false
                    }
                }
            }
        }
    }

    func loadText() async {
        do {
            let str = try String(contentsOfFile: file.path, encoding: .utf8)
            await MainActor.run {
                content = str
                mode = .text
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMsg = error.localizedDescription
                isLoading = false
            }
        }
    }

    func loadPlist() async {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: file.path))
            let obj = try PropertyListSerialization.propertyList(from: data, format: nil)
            let jsonData = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            let jsonStr = String(data: jsonData, encoding: .utf8) ?? "(decode error)"
            await MainActor.run {
                plistDisplay = jsonStr
                mode = .plist
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMsg = error.localizedDescription
                isLoading = false
            }
        }
    }

    func save() {
        let dir = (file.path as NSString).deletingLastPathComponent
        try? BadQuery.consume(path: dir, create: false)
        do {
            try content.write(toFile: file.path, atomically: true, encoding: .utf8)
            isDirty = false
            withAnimation { showSaveSuccess = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run { withAnimation { showSaveSuccess = false } }
            }
        } catch {
            saveError = error.localizedDescription
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run { saveError = nil }
            }
        }
    }
}
