import ArgumentParser
import Foundation
import LumenCore

@main
struct Lumen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Edit a photo by describing the change.",
        subcommands: [Edit.self]
    )
}

struct Edit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Plan and apply an edit to a photo.")

    @Argument(help: "The photo to edit.")
    var photo: String

    @Argument(help: "What to change, in plain words.")
    var instruction: String

    func run() async throws {
        throw LumenError.notBuilt("lumen edit")
    }
}
