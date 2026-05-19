import Foundation
import SwiftData

/// A single converted MLX model living on disk under
/// `~/Library/Application Support/MLXLab/models/<id>`.
@Model
final class ModelEntry {
    @Attribute(.unique) var id: String
    var displayName: String
    var hfRepoId: String
    var quantLabel: String
    var directoryPath: String
    var sizeBytes: Int64
    var createdAt: Date
    var architecture: String?
    var hiddenSize: Int?
    var numLayers: Int?
    var vocabSize: Int?

    @Relationship(deleteRule: .cascade, inverse: \BenchmarkRun.model)
    var benchmarks: [BenchmarkRun] = []

    init(id: String = UUID().uuidString,
         displayName: String,
         hfRepoId: String,
         quantLabel: String,
         directoryPath: String,
         sizeBytes: Int64,
         createdAt: Date = .now,
         architecture: String? = nil,
         hiddenSize: Int? = nil,
         numLayers: Int? = nil,
         vocabSize: Int? = nil) {
        self.id = id
        self.displayName = displayName
        self.hfRepoId = hfRepoId
        self.quantLabel = quantLabel
        self.directoryPath = directoryPath
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
        self.architecture = architecture
        self.hiddenSize = hiddenSize
        self.numLayers = numLayers
        self.vocabSize = vocabSize
    }

    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var directoryURL: URL { URL(fileURLWithPath: directoryPath) }
}

@Model
final class BenchmarkRun {
    @Attribute(.unique) var id: String
    var ranAt: Date
    var prefillTokens: Int
    var prefillTps: Double
    var decodeTokens: Int
    var decodeTps: Double
    var firstTokenMs: Double
    var peakMemoryGb: Double
    var activeMemoryGb: Double
    var perplexity: Double?
    var perplexityTokens: Int
    var elapsedSeconds: Double
    var model: ModelEntry?

    init(id: String = UUID().uuidString,
         ranAt: Date = .now,
         prefillTokens: Int,
         prefillTps: Double,
         decodeTokens: Int,
         decodeTps: Double,
         firstTokenMs: Double,
         peakMemoryGb: Double,
         activeMemoryGb: Double,
         perplexity: Double?,
         perplexityTokens: Int,
         elapsedSeconds: Double) {
        self.id = id
        self.ranAt = ranAt
        self.prefillTokens = prefillTokens
        self.prefillTps = prefillTps
        self.decodeTokens = decodeTokens
        self.decodeTps = decodeTps
        self.firstTokenMs = firstTokenMs
        self.peakMemoryGb = peakMemoryGb
        self.activeMemoryGb = activeMemoryGb
        self.perplexity = perplexity
        self.perplexityTokens = perplexityTokens
        self.elapsedSeconds = elapsedSeconds
    }
}
