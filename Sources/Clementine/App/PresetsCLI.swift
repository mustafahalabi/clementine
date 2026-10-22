import Foundation

/// `--list-presets`, `--save-preset`, `--rename-preset`, `--delete-preset`. (`--preset` itself is in CLI.swift.)
extension CLI {
    static func presetCommand(_ command: String, _ arguments: [String]) -> Int32 {
        let store = PresetStore.shared
        switch command {
        case "--list-presets":
            // id, name, action, values: tab-separated like --history. Skipped presets go to stderr with the reason.
            PresetStore.warn = { _ in } // said below, once
            let snapshot = store.snapshot
            if let error = snapshot.readError { fputs("\(error)\n", stderr) }
            for slice in snapshot.valid {
                let values = slice.preset.values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
                print("\(slice.preset.id)\t\(slice.preset.name)\t\(slice.preset.action)\t\(values)")
            }
            for problem in snapshot.problems {
                fputs("skipped preset “\(problem.preset.name)”: \(problem.reason)\n", stderr)
            }
            return 0

        case "--save-preset":
            var arguments = arguments[...]
            guard let name = arguments.popFirst(), !name.hasPrefix("--") else {
                return usageError("--save-preset needs a name, then --action <id> [--set key=value]...")
            }
            var actionID: String?
            var sets: [String] = []
            while let argument = arguments.popFirst() {
                switch argument {
                case "--action": actionID = arguments.popFirst()
                case "--set":
                    guard let pair = arguments.popFirst() else { return usageError("--set needs key=value") }
                    sets.append(pair)
                default: return usageError("unexpected \(argument) (use --action <id> and --set key=value)")
                }
            }
            guard let actionID, let action = ActionRegistry.all.first(where: { $0.id == actionID }) else {
                return usageError("--save-preset needs --action <id> naming an action (see --list)")
            }
            var values = action.defaults
            for pair in sets {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2 else { return usageError("--set needs key=value, got \"\(pair)\"") }
                guard let parameter = action.parameters.first(where: { $0.key == parts[0] }) else {
                    let known = action.parameters.map(\.key)
                    let hint = known.isEmpty ? "it takes no parameters" : "valid keys: \(known.joined(separator: ", "))"
                    return usageError("unknown parameter \(parts[0]) for \(action.id) (\(hint))")
                }
                switch PresetStore.checked(parts[1], for: parameter) {
                case .success(let value): values.storage[parameter.key] = value
                case .failure(let problem): return usageError("\(parameter.key)=\(parts[1]): \(problem.message)")
                }
            }
            do {
                // Stored in the canonical form (choices by label), whatever form --set used.
                let preset = try store.add(name: name, action: action.id, values: PresetStore.encode(values, for: action))
                print(preset.id)
                return 0
            } catch {
                return usageError(error.localizedDescription)
            }

        case "--rename-preset", "--delete-preset":
            let needed = command == "--rename-preset" ? 2 : 1
            guard arguments.count == needed else {
                return usageError(command == "--rename-preset" ? "--rename-preset needs <name> <new name>" : "--delete-preset needs <name>")
            }
            guard let preset = store.find(arguments[0]) else { return usageError("no preset called “\(arguments[0])”") }
            do {
                if needed == 2 { try store.rename(preset.id, to: arguments[1]) } else { try store.delete(preset.id) }
                return 0
            } catch {
                return usageError(error.localizedDescription)
            }

        default:
            return 2
        }
    }
}
