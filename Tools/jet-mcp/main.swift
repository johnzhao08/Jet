import Foundation
import JetKit

// MCP helper bundled in Jet.app (Contents/MacOS/jet-mcp). AI apps launch it as
// `jet-mcp --vault <folder>` and talk to it over stdin/stdout.
exit(MCPServer.main(arguments: CommandLine.arguments))
