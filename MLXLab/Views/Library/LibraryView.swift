import SwiftData
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var library: ModelLibrary
    @Query(sort: \ModelEntry.createdAt, order: .reverse) private var entries: [ModelEntry]
    @State private var selection: ModelEntry.ID?
    @State private var confirmDelete: ModelEntry?

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 320, idealWidth: 360)
            detail
                .frame(minWidth: 420)
        }
        .navigationTitle("Library")
        .confirmationDialog(
            "Delete model?",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            presenting: confirmDelete
        ) { entry in
            Button("Delete from library", role: .destructive) {
                library.delete(entry, removeFiles: false)
            }
            Button("Delete from library and disk", role: .destructive) {
                library.delete(entry, removeFiles: true)
            }
            Button("Cancel", role: .cancel) { }
        } message: { entry in
            Text("Remove \(entry.displayName)?")
        }
    }

    private var list: some View {
        List(selection: $selection) {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No converted models yet",
                    systemImage: "books.vertical",
                    description: Text("Use the Convert tab to bring an HF model in.")
                )
            } else {
                ForEach(entries) { entry in
                    LibraryRow(entry: entry)
                        .tag(entry.id)
                        .contextMenu {
                            Button("Reveal in Finder") { reveal(entry) }
                            Button("Delete…", role: .destructive) { confirmDelete = entry }
                        }
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = entries.first(where: { $0.id == selection }) {
            LibraryDetailView(entry: entry)
        } else {
            ContentUnavailableView("Select a model",
                                   systemImage: "sidebar.left",
                                   description: Text("Pick a converted model from the list."))
        }
    }

    private func reveal(_ entry: ModelEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.directoryURL])
    }
}

private struct LibraryRow: View {
    let entry: ModelEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.displayName).font(.headline)
            HStack(spacing: 8) {
                Label(entry.quantLabel.uppercased(), systemImage: "cpu")
                    .labelStyle(.titleAndIcon)
                Text(entry.sizeFormatted)
                if let arch = entry.architecture { Text(arch) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct LibraryDetailView: View {
    let entry: ModelEntry
    @EnvironmentObject var library: ModelLibrary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                metadata
                Divider()
                runs
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.displayName).font(.title2).bold()
            Text(entry.hfRepoId).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Tag(text: entry.quantLabel.uppercased())
                Tag(text: entry.sizeFormatted)
                if let arch = entry.architecture { Tag(text: arch) }
            }
        }
    }

    private var metadata: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow { Text("Path").foregroundStyle(.secondary); Text(entry.directoryPath).font(.system(.body, design: .monospaced)) }
            if let h = entry.hiddenSize  { GridRow { Text("Hidden").foregroundStyle(.secondary); Text("\(h)") } }
            if let n = entry.numLayers   { GridRow { Text("Layers").foregroundStyle(.secondary); Text("\(n)") } }
            if let v = entry.vocabSize   { GridRow { Text("Vocab").foregroundStyle(.secondary);  Text("\(v)") } }
            GridRow { Text("Created").foregroundStyle(.secondary); Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened)) }
        }
    }

    @ViewBuilder
    private var runs: some View {
        if entry.benchmarks.isEmpty {
            Text("No benchmark runs yet. Use the Benchmark tab.")
                .foregroundStyle(.secondary)
        } else {
            Text("Benchmarks").font(.headline)
            ForEach(entry.benchmarks.sorted(by: { $0.ranAt > $1.ranAt })) { run in
                HStack {
                    Text(run.ranAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Text("\(run.decodeTps, format: .number.precision(.fractionLength(1))) tok/s decode")
                    Text("\(run.peakMemoryGb, format: .number.precision(.fractionLength(2))) GB peak")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.15))
            .foregroundStyle(Color.accentColor)
            .clipShape(Capsule())
    }
}
