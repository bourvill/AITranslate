//
//  AITranslateCommand.swift
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

    @Option(
        name: .shortAndLong,
        help: ArgumentHelp("Maximum number of parallel translations")
    )
    var maxParallel: Int = 4

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

    lazy var ollamaClient: OllamaClient = .init(baseURL: ollamaURL, model: Self.ollamaModel, timeout: 60.0)

    var numberOfTranslationsProcessed = 0

    mutating func run() async throws {
        do {
            let dict = try JSONDecoder().decode(
                StringsDict.self,
                from: Data(contentsOf: inputFile)
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
        } catch {
            throw error
        }
    }

    mutating func processEntry(
        key: String,
        localizationGroup: LocalizationGroup,
        sourceLanguage: String
    ) async throws {
        let localizationEntries = localizationGroup.localizations ?? [:]
        var languagesToTranslate: [String] = []

        for lang in languages {
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

            languagesToTranslate.append(lang)
        }

        if languagesToTranslate.isEmpty {
            return
        }

        // The source text can either be the key or an explicit value in the `localizations`
        // dictionary keyed by `sourceLanguage`.
        let sourceText = localizationEntries[sourceLanguage]?.stringUnit?.value ?? key
        let entryContext = localizationGroup.comment
        let globalContext = appContext
        let client = ollamaClient
        let isVerbose = verbose
        let sourceLang = sourceLanguage

        let semaphore = AsyncSemaphore(value: max(1, maxParallel))
        let results = try await withThrowingTaskGroup(of: (String, String?).self) { group in
            for lang in languagesToTranslate {
                group.addTask {
                    await semaphore.acquire()
                    do {
                        let result = try await AITranslate.performTranslation(
                            sourceText,
                            from: sourceLang,
                            to: lang,
                            context: entryContext,
                            appContext: globalContext,
                            verbose: isVerbose,
                            ollamaClient: client
                        )
                        await semaphore.release()
                        return (lang, result)
                    } catch {
                        await semaphore.release()
                        return (lang, nil)
                    }
                }
            }

            var collected: [(String, String?)] = []
            for try await item in group {
                collected.append(item)
            }
            return collected
        }

        var updatedLocalizations = localizationEntries
        for (lang, result) in results {
            updatedLocalizations[lang] = LocalizationUnit(
                stringUnit: StringUnit(
                    state: result == nil ? "error" : "translated",
                    value: result ?? ""
                )
            )
        }
        localizationGroup.localizations = updatedLocalizations
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

    static func performTranslation(
        _ text: String,
        from source: String,
        to target: String,
        context: String? = nil,
        appContext: String? = nil,
        verbose: Bool,
        ollamaClient: OllamaClient
    ) async throws -> String? {
        // Skip text that is generally not translated.
        if text.isEmpty ||
            text.trimmingCharacters(
                in: .whitespacesAndNewlines
                    .union(.symbols)
                    .union(.controlCharacters)
            ).isEmpty
        {
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
        } catch {
            print("[❌] Failed to translate \(text) into \(target)")

            if verbose {
                print("[💥]" + error.localizedDescription)
            }

            return nil
        }
    }
}
