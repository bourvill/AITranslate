import Foundation

struct OllamaClient {
    struct Message: Codable {
        let role: String
        let content: String
    }

    struct ChatRequest: Codable {
        let model: String
        let messages: [Message]
        let stream: Bool
    }

    struct ChatResponse: Codable {
        let message: Message?
    }

    let baseURL: String
    let model: String
    let timeout: TimeInterval

    func translate(userPrompt: String, fallback: String) async throws -> String {
        guard let base = URL(string: baseURL) else {
            throw URLError(.badURL)
        }
        let url = base.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = ChatRequest(
            model: model,
            messages: [
                Message(role: "user", content: userPrompt),
            ],
            stream: false
        )

        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.http(statusCode: httpResponse.statusCode, body: errorBody)
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.message?.content ?? fallback
    }
}

enum OllamaError: LocalizedError {
    case http(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case let .http(statusCode, body):
            if body.isEmpty {
                return "HTTP error \(statusCode)"
            }
            return "HTTP error \(statusCode): \(body)"
        }
    }
}
