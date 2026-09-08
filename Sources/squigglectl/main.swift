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
    case .quote(let raw, let printRaw, _):
        guard let symbol = Symbol(raw) else {
            FileHandle.standardError.write(Data("not a usable symbol: \(raw)\n".utf8))
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
    }
}

let status = await run()
exit(status)
