//
//  AITranslate.swift
//
//
//  Created by Paul MacRory on 3/7/24.
//

import ArgumentParser
import Foundation

@main
struct AITranslate: AsyncParsableCommand {
  static func gatherLanguages(from input: String) -> [String] {
    input.split(separator: ",")
      .map { String($0).trimmingCharacters(in: .whitespaces) }
  }

  @Argument(transform: URL.init(fileURLWithPath:))
  var inputFile: URL

  @Option(
    name: .shortAndLong,
    help: ArgumentHelp("A comma separated list of language codes (must match the language codes used by xcstrings)"),
    transform: { @Sendable input in AITranslate.gatherLanguages(from: input) }
  )
  var languages: [String]

  @Option(
    name: .shortAndLong,
    help: ArgumentHelp("Ollama base URL (e.g. http://localhost:11434)")
  )
  var ollamaURL: String = "http://localhost:11434"

  @Option(
    name: .shortAndLong,
    help: ArgumentHelp("Additional application context to help translation quality")
  )
  var appContext: String?

  private static let ollamaModel = "translategemma:4b"

  @Flag(name: .shortAndLong)
  var verbose: Bool = false

  @Flag(
    name: .shortAndLong,
    help: ArgumentHelp("By default a backup of the input will be created. When this flag is provided, the backup is skipped.")
  )
  var skipBackup: Bool = false

  @Flag(
    name: .shortAndLong,
    help: ArgumentHelp("Forces all strings to be translated, even if an existing translation is present.")
  )
  var force: Bool = false

  lazy var ollamaClient: OllamaClient = {
    OllamaClient(baseURL: ollamaURL, model: Self.ollamaModel, timeout: 60.0)
  }()

  var numberOfTranslationsProcessed = 0

  mutating func run() async throws {
    do {
      let dict = try JSONDecoder().decode(
        StringsDict.self,
        from: try Data(contentsOf: inputFile)
      )

      let totalNumberOfTranslations = dict.strings.count * languages.count
      let start = Date()
      var previousPercentage: Int = -1

      for entry in dict.strings {
        try await processEntry(
          key: entry.key,
          localizationGroup: entry.value,
          sourceLanguage: dict.sourceLanguage
        )

        let fractionProcessed = (Double(numberOfTranslationsProcessed) / Double(totalNumberOfTranslations))
        let percentageProcessed = Int(fractionProcessed * 100)

        // Print the progress at 10% intervals.
        if percentageProcessed != previousPercentage, percentageProcessed % 10 == 0 {
          print("[⏳] \(percentageProcessed)%")
          previousPercentage = percentageProcessed
        }

        numberOfTranslationsProcessed += languages.count
      }

      try save(dict)

      let formatter = DateComponentsFormatter()
      formatter.allowedUnits = [.hour, .minute, .second]
      formatter.unitsStyle = .full
      let formattedString = formatter.string(from: Date().timeIntervalSince(start))!

      print("[✅] 100% \n[⏰] Translations time: \(formattedString)")
    } catch let error {
      throw error
    }
  }

  mutating func processEntry(
    key: String,
    localizationGroup: LocalizationGroup,
    sourceLanguage: String
  ) async throws {
    for lang in languages {
      let localizationEntries = localizationGroup.localizations ?? [:]
      let unit = localizationEntries[lang]

      // Nothing to do.
      if let unit, unit.hasTranslation, force == false {
        continue
      }

      // Skip the ones with variations/substitutions since they are not supported.
      if let unit, unit.isSupportedFormat == false {
        print("[⚠️] Unsupported format in entry with key: \(key)")
        continue
      }

      // The source text can either be the key or an explicit value in the `localizations`
      // dictionary keyed by `sourceLanguage`.
      let sourceText = localizationEntries[sourceLanguage]?.stringUnit?.value ?? key

      let result = try await performTranslation(
        sourceText,
        from: sourceLanguage,
        to: lang,
        context: localizationGroup.comment,
        ollamaClient: ollamaClient
      )

      localizationGroup.localizations = localizationEntries
      localizationGroup.localizations?[lang] = LocalizationUnit(
        stringUnit: StringUnit(
          state: result == nil ? "error" : "translated",
          value: result ?? ""
        )
      )
    }
  }

  func save(_ dict: StringsDict) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    let data = try encoder.encode(dict)

    try backupInputFileIfNecessary()
    try data.write(to: inputFile)
  }

  func backupInputFileIfNecessary() throws {
    if skipBackup == false {
      let backupFileURL = inputFile.appendingPathExtension("original")

      try? FileManager.default.trashItem(
        at: backupFileURL,
        resultingItemURL: nil
      )

      try FileManager.default.moveItem(
        at: inputFile,
        to: backupFileURL
      )
    }
  }

  func performTranslation(
    _ text: String,
    from source: String,
    to target: String,
    context: String? = nil,
    ollamaClient: OllamaClient
  ) async throws -> String? {

    // Skip text that is generally not translated.
    if text.isEmpty ||
        text.trimmingCharacters(
          in: .whitespacesAndNewlines
            .union(.symbols)
            .union(.controlCharacters)
        ).isEmpty {
      return text
    }

    var contexts: [String] = []
    if let context, context.isEmpty == false {
      contexts.append(context)
    }
    if let appContext, appContext.isEmpty == false {
      contexts.append(appContext)
    }
    let combinedContext = contexts.joined(separator: "\n")
    let contextSentence = combinedContext.isEmpty ? "" : " The context is \(combinedContext)."
    let translationRequest =
      """
      You are a professional \(source) (\(source)) to \(target) (\(target)) translator. Your goal is to accurately convey the meaning and nuances of the original \(source) text while adhering to \(target) grammar, vocabulary, and cultural sensitivities.
      Produce only the \(target) translation, without any additional explanations or commentary.\(contextSentence) Please translate the following \(source) text into \(target):


      \(text)
      """

    do {
      let translation = try await ollamaClient.translate(
        userPrompt: translationRequest,
        fallback: text
      )

      if verbose {
        print("[\(target)] " + text + " -> " + translation)
      }

      return translation
    } catch let error {
      print("[❌] Failed to translate \(text) into \(target)")

      if verbose {
        print("[💥]" + error.localizedDescription)
      }

      return nil
    }
  }
}

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
        Message(role: "user", content: userPrompt)
      ],
      stream: false
    )

    request.httpBody = try JSONEncoder().encode(payload)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    guard (200...299).contains(httpResponse.statusCode) else {
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
