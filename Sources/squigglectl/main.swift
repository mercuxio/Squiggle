import Foundation
import TickerCore
import YahooFeed

// A top-level `await` needs a task; `main.swift` allows top-level code, and a
// semaphore keeps the process alive until the async work finishes.
func run() async -> Int32 {
    let command: Command
    do {
        command = try Command.parse(Array(CommandLine.arguments.dropFirst()))
    } catch let error as ParseError {
        FileHandle.standardError.write(Data((error.message + "\n").utf8))
        return 2
    } catch {
        FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
        return 2
    }

    switch command {
    case .help:
        print(Rendering.usage)
        return 0
    case .quote(let symbolText, let printRaw):
        guard let symbol = Symbol(symbolText) else {
            FileHandle.standardError.write(Data("not a usable symbol: \(symbolText)\n".utf8))
            return 2
        }
        do {
            let body = try await YahooClient().fetch(symbol)
            if printRaw {
                FileHandle.standardOutput.write(body)
                print()
            } else {
                print("\(body.count) bytes")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 1
        }

    case .search(let query, let limit):
        do {
            let results = try await YahooClient().searchResults(query: query, limit: limit)
            print(Rendering.render(results))
            return 0
        } catch let error as TickerError {
            FileHandle.standardError.write(Data((Rendering.diagnosis(error) + "\n").utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 1
        }

    case .watch(let symbolArgs, let intervalSeconds, let maxCycles):
        let store = FileWatchlistStore(url: FileWatchlistStore.defaultURL(applicationName: "Squiggle"))
        var symbols = symbolArgs
        if symbols.isEmpty {
            // No symbols on the command line: fall back to the watchlist on
            // disk, exactly as the app itself would show. A store that fails
            // to load (first launch, a quarantined file) is treated the same
            // as an empty one here — `doctor`, not `watch`, is where that
            // gets diagnosed.
            symbols = (try? store.load().symbols) ?? []
        }
        guard !symbols.isEmpty else {
            FileHandle.standardError.write(Data(
                "watch needs at least one symbol, either on the command line or in the watchlist\n"
                    .utf8))
            return 2
        }
        let loop = WatchLoop(client: YahooClient(), store: store, symbols: symbols,
                             intervalSeconds: intervalSeconds, maxCycles: maxCycles)
        return await loop.run()
    }
}

let status = await run()
exit(status)
