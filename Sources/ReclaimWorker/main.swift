import Foundation
import ReclaimCore

@main
struct ReclaimWorker {
    static func main() async {
        guard CommandLine.arguments == [CommandLine.arguments[0], "--scheduled"] else {
            print("ReclaimWorker is managed through Reclaim's Schedule settings.")
            return
        }
        do { try await ScheduledCleanup().run() }
        catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
