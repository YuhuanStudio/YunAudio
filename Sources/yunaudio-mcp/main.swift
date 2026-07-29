import Foundation
import YunAudioControl

// An MCP server for YunAudio, speaking JSON-RPC 2.0 over stdio.
//
// This process holds no state at all. Everything it is asked is forwarded to
// the running application over the control socket and the answer comes back the
// same way, which is why an MCP client may start and stop it as often as it
// likes, and why two agents driving the application at once see the same
// application rather than two views of it.

let arguments = Array(CommandLine.arguments.dropFirst())
var socketPath = ControlSocket.defaultPath

var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--socket":
        index += 1
        guard index < arguments.count else {
            FileHandle.standardError.write(Data("yunaudio-mcp: --socket needs a path\n".utf8))
            exit(2)
        }
        socketPath = arguments[index]
    case "--help", "-h":
        print(
            """
            yunaudio-mcp — a Model Context Protocol server for YunAudio.

            Speaks JSON-RPC 2.0 over stdin and stdout. It is meant to be spawned
            by an MCP client rather than run by hand; there is nothing to see if
            you do.

              --socket <path>   the application's control socket
                                (default: \(ControlSocket.defaultPath),
                                 or $\(ControlSocket.environmentKey))

            YunAudio must be running: this process only forwards. If it is not,
            every tool answers with that rather than hanging.
            """)
        exit(0)
    default:
        FileHandle.standardError.write(
            Data("yunaudio-mcp: unknown argument \(arguments[index])\n".utf8))
        exit(2)
    }
    index += 1
}

let server = MCPServer(transport: ControlClient(path: socketPath))

// Written straight to the descriptor rather than with `print`. stdout to a pipe
// is block-buffered, so `print` would leave a complete, correct response sitting
// in a 4 KB buffer while the client waited for it — a hang with nothing wrong
// anywhere that anyone could look.
let out = FileHandle.standardOutput
while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    guard let answer = server.respond(to: line) else { continue }
    out.write(Data((answer + "\n").utf8))
}
