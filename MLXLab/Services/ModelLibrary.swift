import Foundation
import SwiftData
import SwiftUI

/// CRUD facade over SwiftData for `ModelEntry` + `BenchmarkRun`. Exposes a
/// shared container so views can `@Query` against it.
@MainActor
final class ModelLibrary: ObservableObject {
    static let shared = ModelLibrary()

    let container: ModelContainer

    private init() {
        let schema = Schema([ModelEntry.self, BenchmarkRun.self])
        let cfg = ModelConfiguration(
            schema: schema,
            url: AppPaths.appSupport.appendingPathComponent("library.store")
        )
        // crash-on-failure is acceptable here: if SwiftData can't open we have
        // no library to manage anyway, and surfacing it loudly aids debugging.
        self.container = try! ModelContainer(for: schema, configurations: cfg)
    }

    var context: ModelContext { container.mainContext }

    func insertEntry(displayName: String, hfRepoId: String, quantLabel: String,
                     directoryPath: String, sizeBytes: Int64,
                     architecture: String?, hiddenSize: Int?, numLayers: Int?,
                     vocabSize: Int?) -> ModelEntry {
        let entry = ModelEntry(
            displayName: displayName,
            hfRepoId: hfRepoId,
            quantLabel: quantLabel,
            directoryPath: directoryPath,
            sizeBytes: sizeBytes,
            architecture: architecture,
            hiddenSize: hiddenSize,
            numLayers: numLayers,
            vocabSize: vocabSize
        )
        context.insert(entry)
        try? context.save()
        return entry
    }

    func attachBenchmark(_ run: BenchmarkRun, to entry: ModelEntry) {
        run.model = entry
        context.insert(run)
        try? context.save()
    }

    func delete(_ entry: ModelEntry, removeFiles: Bool) {
        if removeFiles {
            try? FileManager.default.removeItem(at: entry.directoryURL)
        }
        context.delete(entry)
        try? context.save()
    }

    func allEntries() -> [ModelEntry] {
        let descriptor = FetchDescriptor<ModelEntry>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
