import AVFoundation
import Foundation

enum TTSProvider: String, CaseIterable, Identifiable {
    case system
    case googleCloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System Voice"
        case .googleCloud: return "Google Cloud"
        }
    }
}

struct SystemSpeechVoice: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
}

enum GoogleCloudTTS {
    static let voiceNames = [
        "Achernar", "Achird", "Algenib", "Algieba", "Alnilam", "Aoede", "Autonoe",
        "Callirrhoe", "Charon", "Despina", "Enceladus", "Erinome", "Fenrir", "Gacrux",
        "Iapetus", "Kore", "Laomedeia", "Leda", "Orus", "Puck", "Pulcherrima",
        "Rasalgethi", "Sadachbia", "Sadaltager", "Schedar", "Sulafat", "Umbriel",
        "Vindemiatrix", "Zephyr", "Zubenelgenubi",
    ]

    private struct RequestBody: Encodable {
        struct Input: Encodable { let text: String }
        struct Voice: Encodable {
            let languageCode: String
            let name: String
        }
        struct AudioConfig: Encodable { let audioEncoding: String }

        let input: Input
        let voice: Voice
        let audioConfig: AudioConfig
    }

    private struct SuccessBody: Decodable {
        let audioContent: String
    }

    private struct ErrorBody: Decodable {
        struct APIError: Decodable { let message: String }
        let error: APIError
    }

    struct ServiceError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func synthesize(
        text: String, language: String, voiceName: String, apiKey: String
    ) async throws -> Data {
        guard let url = URL(
            string: "https://texttospeech.googleapis.com/v1/text:synthesize"
        ) else {
            throw ServiceError(message: "Could not construct the Google Cloud request.")
        }

        let body = RequestBody(
            input: .init(text: text),
            voice: .init(
                languageCode: language,
                name: "\(language)-Chirp3-HD-\(voiceName)"
            ),
            audioConfig: .init(audioEncoding: "MP3")
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError(message: "Google Cloud returned an invalid response.")
        }
        guard 200 ..< 300 ~= http.statusCode else {
            let apiMessage = try? JSONDecoder().decode(ErrorBody.self, from: data).error.message
            throw ServiceError(
                message: apiMessage ?? "Google Cloud returned HTTP \(http.statusCode)."
            )
        }
        let responseBody = try JSONDecoder().decode(SuccessBody.self, from: data)
        guard let audio = Data(base64Encoded: responseBody.audioContent), !audio.isEmpty else {
            throw ServiceError(message: "Google Cloud returned empty audio.")
        }
        return audio
    }
}
