import Foundation

/// Thin Swift wrapper over the public HuggingFace Hub HTTP API. We only need
/// search + a basic detail probe to drive the Convert wizard.
struct HFClient {
    struct Model: Identifiable, Hashable, Codable {
        let modelId: String
        let pipelineTag: String?
        let downloads: Int?
        let likes: Int?
        let tags: [String]?
        let lastModified: String?

        var id: String { modelId }
    }

    struct ModelDetail: Codable {
        let modelId: String
        let pipelineTag: String?
        let library: String?
        let tags: [String]?
        let siblings: [Sibling]?

        struct Sibling: Codable, Hashable {
            let rfilename: String
        }
    }

    enum Compatibility: String {
        case supported
        case unknown
        case unsupported
    }

    /// Architectures the convert pipeline is known to handle.
    static let supportedArchitectures: Set<String> = [
        "llama", "qwen", "qwen2", "qwen3", "mistral", "gemma", "gemma2",
        "phi", "phi3", "phi4", "mixtral",
    ]

    static func compatibility(for tags: [String]) -> Compatibility {
        let lower = tags.map { $0.lowercased() }
        if lower.contains(where: { supportedArchitectures.contains($0) }) { return .supported }
        if lower.contains("text-generation") { return .unknown }
        return .unsupported
    }

    func search(query: String, limit: Int = 30) async throws -> [Model] {
        var comps = URLComponents(string: "https://huggingface.co/api/models")!
        comps.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "filter", value: "text-generation"),
        ]
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        try check(response)
        return try JSONDecoder().decode([Model].self, from: data)
    }

    func detail(repoId: String) async throws -> ModelDetail {
        let url = URL(string: "https://huggingface.co/api/models/\(repoId)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        try check(response)
        return try JSONDecoder().decode(ModelDetail.self, from: data)
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse,
                           userInfo: [NSLocalizedDescriptionKey: "HF API error \(http.statusCode)"])
        }
    }
}
