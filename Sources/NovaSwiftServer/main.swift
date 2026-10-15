import Foundation
import NovaSwiftServerCore

#if os(Windows)
setvbuf(stdout, nil, _IONBF, 0)   // the C runtime aborts on a zero-size line buffer; unbuffered shows lines immediately too
#else
setvbuf(stdout, nil, _IOLBF, 0)   // lines appear immediately even when piped to a file or journald
#endif
let options = ServerOptions.parse(Array(CommandLine.arguments.dropFirst()))
if options.showHelp { print(ServerOptions.helpText); exit(0) }
if options.showVersion { print("NovaSwift Dedicated Server \(ServerVersion.current) (protocol \(NovaSwiftServerCore.protocolNumber))"); exit(0) }
if !options.errors.isEmpty {
    FileHandle.standardError.write(Data((options.errors.joined(separator: "\n") + "\n").utf8))
    exit(2)
}
do {
    let app = try ServerApp(options: options)
    if options.resetAdminPassword {
        print("New admin password: \(app.generatedPassword ?? "?")")
        exit(0)
    }
    app.run()
} catch {
    FileHandle.standardError.write(Data("\n\((error as? ServerError)?.message ?? error.localizedDescription)\n".utf8))
    exit(1)
}
