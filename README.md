# Find Yoshi IT

Pronounced **“find yo shit.”**

A native macOS launcher and local document search app. Find applications by name, then search filenames and the passages inside your documents. Your files stay where they are; extraction, OCR, embeddings, and the search index stay on your Mac.

## Quick Search

Press **Command–Space**, type a name or query, use the arrow keys to select a result, and press **Return** to open it. **Escape** closes the panel.

- **Command–1:** applications
- **Command–2:** documents
- **Command–3:** other files
- **Command–0:** everything

Applications appear first, common documents second, and other files last. Within a file category, filename matches precede content-only matches. Successful opens influence future ranking locally. Application discovery covers standard application folders, running apps, and exact-name macOS registration lookup.

Dependency folders such as `.venv` and `node_modules` are hidden from ordinary results. Explicit directory queries or exact filenames can reveal them. Custom source exclusions still prevent indexing.

If Spotlight already owns Command–Space, disable **Show Spotlight search** in System Settings → Keyboard → Keyboard Shortcuts → Spotlight. The app reports shortcut conflicts; it does not change system shortcuts itself.

## Your library

Use **Add a source** to choose folders, external drives, or mounted SMB shares. For a network share, enter your server address and connect through macOS. Credentials are handled by macOS, not stored by this app. Adding a connection alone does not start indexing.

Remembered SMB sources survive disconnects and app restarts. FindShit checks after Ethernet/Wi-Fi changes, wake, and mount changes, with a one-minute retry while running. Set the home Wi-Fi name in **Library → Home Network…** (also in the app menu). It defaults to **Gondor**, is saved across launches, and takes effect immediately; known other Wi-Fi networks suppress automatic reconnects. On Ethernet, or when macOS hides the Wi-Fi name, the saved NAS address must answer a bounded SMB reachability check before reconnecting. The home NAS is **UNAS-Pro** (shares shown in Finder: `16WestfieldStorage`, `Personal-Drive`, and `thebookvault`); only sources explicitly added to the library are reconnected and indexed.

Background reconnects use macOS-saved credentials without sign-in dialogs, allow at most two pending mounts, and cancel mount attempts after 20 seconds. Paused sources are excluded. Missing shares keep their catalog and offline-content settings; returning mounts must match the saved filesystem identity, including the account, before scanning resumes. If saved credentials cannot reconnect, use **Add a source → Connect** to sign in again. Network availability probes have a three-second caller deadline so an unresponsive mount does not block the search engine during routine checks.


Local changes use persistent filesystem-event checkpoints and a durable reconciliation queue. Network sources reconcile periodically and on reconnect. Closing the library window leaves the menu-bar app running. **Launch at Login** is optional.

**Source health** reports indexing progress, unsupported formats, failures, and local index size. Source settings control exclusions, OCR, and whether cached passages remain searchable offline. Removing a source removes its cached index, not the original files.

## Search and extraction

- Filename and full-text retrieval use SQLite FTS5, including an indexed filename substring lookup.
- **Names** puts filename matches first, followed by matching contents; macOS metadata supplements local filenames during indexing.
- **Exact**, **Hybrid**, and **Semantic** offer phrase, combined lexical/semantic, and meaning-based retrieval.
- Apple NaturalLanguage provides on-device English sentence embeddings. Eligible passages use an exact, streaming scan of compact int8 vectors, with a native vectorized scorer. Repeated passages are reduced to the strongest passage per content before ranking. Legacy bucket data is retained for compatibility but is not used for queries.
- Text, Markdown, source code, HTML, RTF, PDF, DOCX, XLSX, PPTX, CSV/TSV, and common images are supported. Vision provides local OCR.
- Results retain locations such as PDF pages, Markdown lines, slide numbers, and spreadsheet cells. Unsupported formats remain discoverable by filename.

No query or document telemetry, cloud inference, or bundled remote model service is used. Network access is needed when you connect to a share. The optional benchmark script separately downloads a model for local evaluation.

## Build and run

Requires Xcode with the macOS SDK and Swift 6. Targets macOS 14 or later.

```sh
./scripts/package-app.sh release
open 'build/Find Yoshi IT.app'
swift test --disable-sandbox
```

To build directly into your Applications folder:

```sh
./scripts/package-app.sh release "$HOME/Applications/Find Yoshi IT.app"
```

The package uses Apple frameworks and system SQLite without third-party Swift package dependencies. The script creates and verifies an ad-hoc signature. Developer ID signing and notarization are not configured.

Internal module names, the bundle identifier, and `~/Library/Application Support/FindAnything/` retain their original identifiers for compatibility with existing indexes and preferences. The executable is `FindYoshiIT`.

Development options include `--data-dir /absolute/path`, `--index-folder /absolute/path`, `--search 'query'`, and `--smoke-test`. Keep the index on local storage rather than SMB. Generated artifacts and runtime databases are excluded from version control.

## Limits and validation

This is an early implementation. Million-file performance and retrieval quality on representative user corpora are not validated. Slow or disconnected shares can delay filesystem work. Semantic search currently supports English; embedding relevance remains experimental and must be evaluated against representative queries.

Extraction has per-file size, passage, page, and OCR limits. Partial coverage is reported. Office embedded objects, iWork, archives, mail connectors, and audio/video transcription are not implemented. Offline excerpts reflect the last confirmed access state; reconnecting permits fresh permission checks.

Tests exercise indexing persistence, filesystem replay, extraction, access rules, metadata queries, application discovery, ranking, and keyboard opening. Fixtures are synthetic and created in temporary folders.

The optional retrieval benchmark uses `Tests/Fixtures/retrieval-benchmark.json`, `scripts/benchmark-apple.swift`, and `scripts/benchmark-retrieval.py`. It requires Python with `numpy` and `fastembed`; the app itself does not. The fixture is a small hand-authored sanity check, not a benchmark of private documents. Do not commit benchmark outputs from a real library.

Implementation references: [Apple sentence embeddings](https://developer.apple.com/documentation/naturallanguage/nlembedding/sentenceembedding(for:)), [Apple text recognition](https://developer.apple.com/documentation/vision/vnrecognizetextrequest), and [SQLite FTS5](https://www.sqlite.org/fts5.html).

## Search latency and accuracy tools

Names, contents, and metadata run independently and publish results as each channel finishes.
Dedicated read-only WAL connections keep name lookup, content search, and previews separate from
indexing. Query cancellation interrupts SQLite work; selecting a streamed result retains its identity
when metadata is replaced by an indexed result. App copies with the same bundle identifier are
collapsed, preferring the running copy.

Use a local SQLite backup for reproducible comparisons:

```sh
swift run -c release FindYoshiBenchmark /path/to/snapshot.sqlite --migrate --names-only
swift run -c release FindYoshiBenchmark /path/to/snapshot.sqlite
```

`--migrate` updates the snapshot schema; omit it for a read-only measurement of an up-to-date index.
The benchmark emits JSON lines for synthetic queries, with total time and per-stage durations.
These are engine timings, not end-to-end keyboard-to-paint measurements. First-call and repeated
warm timings should be reported separately. Store output under ignored `build/`.

`scripts/benchmark-vector-recall.py` compares the native packed scorer with a dense reference and
the legacy bucket lookup on a deterministic sample. Its output records numerical error and recall,
with an explicit tolerance for tied vectors. This tests lookup accuracy, not whether a passage answers
a user's question. The hand-authored embedding fixture is a separate relevance check; passing a
small synthetic set does not establish accuracy on a personal library.
