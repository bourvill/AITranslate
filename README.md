# AI Translate

This is a small, simple, utility that parses an Xcode `.xcstrings` file, asks a local Ollama model to translate each entry, and then saves the results back in the `xcstrings` JSON format.

Please note that it is **very strongly** recommended to have translations tested by a qualified human, as LLM output will not be perfect.

## Missing Features

This tool supports all the features that I currently use personally, which are not all of the features supported by `xcstrings` (for example, I have not tested plural strings, or strings that vary by device). Pull requests are welcome to add those missing features.

## Usage

Simply pull this repo, then run the following command from the repo root folder:

Make sure Ollama is running locally and the model is available (for example `ollama pull translategemma:4b`).

```
swift run ai-translate /path/to/your/Localizable.xcstrings -v -l de,es,fr,he,it,ru,hi,en-GB
```

Help output:

```
  USAGE: ai-translate <input-file> --languages <languages> [--ollama-url <ollama-url>] [--app-context <app-context>] [--verbose] [--skip-backup] [--force]

  ARGUMENTS:
    <input-file>

  OPTIONS:
    -l, --languages <languages> a comma separated list of language codes (must match the language codes used by xcstrings)
    -o, --ollama-url <ollama-url>
                            Ollama base URL (e.g. http://localhost:11434)
    -a, --app-context <app-context>
                            Additional application context to help translation quality
    -v, --verbose
    -s, --skip-backup       By default a backup of the input will be created. When this flag is provided, the backup is skipped.
    -f, --force             Forces all strings to be translated, even if an existing translation is present.
    -h, --help              Show help information.
```
