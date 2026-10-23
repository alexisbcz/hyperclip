import Foundation

// The `hyperclip` command: drives the Hyperclip app, which does the work, so everything also shows in its window.
// Each command is a `Command` in Commands.swift; add yours to this table and `hyperclip --help` lists it.

let commands: [Command] = [
    // Videos
    .import, .list, .show, .transcribe, .transcript, .find,
    // Clips
    .clips, .clip, .export, .exports,
    // Publishing
    .publish, .accounts,
    // Setup
    .status, .settings, .models, .cancel, .delete, .open,
    // For AI agents and scripts
    .mcp, .api,
]

func usage() -> String {
    let width = commands.map(\.name.count).max() ?? 0
    return """
    Usage: hyperclip <command> [arguments]

    Turn long videos into short, captioned clips from a terminal. Hyperclip.app does the work, and starts
    in the background when it isn't open.

    Commands:
    \(commands.map { "  \($0.name.padding(toLength: width + 2, withPad: " ", startingAt: 0))\($0.summary)" }.joined(separator: "\n"))

    A video is its id (or the start of it), a word of its title, or latest. A clip is its number from
    `hyperclip clips` or its id. Times are seconds or 1:02:03.5. Add --json for output scripts can read.
    Run `hyperclip help <command>` for a command's arguments.

    Examples:
      hyperclip import https://www.youtube.com/watch?v=… --wait
      hyperclip export latest --best 3 --aspect vertical --captions bold --wait
      hyperclip clip add latest 12:04 12:41 --title "The one thing nobody tells you"
      hyperclip publish latest --to youtube,tiktok --caption "Worth 40 seconds" --tiktok-consent
    """
}

func help(_ command: Command) -> String {
    var text = "Usage: \(command.usage)\n\n\(command.summary.prefix(1).uppercased() + command.summary.dropFirst())."
    if !command.details.isEmpty { text += "\n\n\(command.details)" }
    if !command.aliases.isEmpty { text += "\n\nAlso: \(command.aliases.joined(separator: ", "))" }
    return text
}

func lookup(_ name: String) -> Command? {
    commands.first { $0.name == name || $0.aliases.contains(name) }
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let name = arguments.first else {
    print(usage())
    exit(0)
}
arguments.removeFirst()

switch name {
case "-h", "--help", "help":
    if let topic = arguments.first {
        guard let command = lookup(topic) else {
            printError("no command \(topic). Run `hyperclip --help` for the list.")
            exit(1)
        }
        print(help(command))
    } else {
        print(usage())
    }
case "-v", "--version", "version":
    print("hyperclip \(App.version)")
default:
    guard let command = lookup(name) else {
        printError("no command \(name). Run `hyperclip --help` for the list.")
        exit(1)
    }
    if arguments.contains(where: { $0 == "--help" || $0 == "-h" }) {
        print(help(command))
        exit(0)
    }
    var args = Arguments(arguments)
    do {
        try command.run(&args)
    } catch let failure as Failure {
        if let message = failure.errorDescription, !message.isEmpty { printError(message) }
        exit(failure.status)
    } catch {
        printError(error.localizedDescription)
        exit(1)
    }
}
