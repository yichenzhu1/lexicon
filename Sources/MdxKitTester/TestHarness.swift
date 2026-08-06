import Foundation

/// Minimal test harness: Xcode Command Line Tools ship neither XCTest nor
/// swift-testing, so MdxKit is verified by this standalone runner
/// (`swift run mdxkit-tests`).
final class TestHarness {
    private(set) var failures = 0
    private(set) var passed = 0
    private var currentTest = ""

    func run(_ name: String, _ body: () throws -> Void) {
        currentTest = name
        let before = failures
        do {
            try body()
        } catch {
            failures += 1
            print("  FAIL [\(name)] threw: \(error)")
        }
        if failures == before {
            passed += 1
            print("  ok   \(name)")
        }
    }

    func expect(
        _ condition: Bool, _ message: @autoclosure () -> String = "",
        file: String = #fileID, line: Int = #line
    ) {
        if !condition {
            failures += 1
            print("  FAIL [\(currentTest)] \(message()) (\(file):\(line))")
        }
    }

    func expectEqual<T: Equatable>(
        _ a: T, _ b: T, _ message: @autoclosure () -> String = "",
        file: String = #fileID, line: Int = #line
    ) {
        if a != b {
            failures += 1
            print("  FAIL [\(currentTest)] \(message()) — \"\(a)\" != \"\(b)\" (\(file):\(line))")
        }
    }

    func expectThrows(
        _ message: @autoclosure () -> String = "",
        file: String = #fileID, line: Int = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            failures += 1
            print("  FAIL [\(currentTest)] expected error, none thrown: \(message()) (\(file):\(line))")
        } catch {
            // expected
        }
    }

    func finish() -> Never {
        print("")
        if failures == 0 {
            print("All \(passed) tests passed.")
            exit(0)
        } else {
            print("\(failures) failure(s), \(passed) test(s) passed.")
            exit(1)
        }
    }
}

/// Prefer the current checkout so a previously built test executable keeps
/// working after the repository is moved or renamed. Fall back to the source
/// path for invocations launched from another working directory.
let fixturesURL: URL = {
    let workingCopy = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Tests/Fixtures", isDirectory: true)
    if FileManager.default.fileExists(
        atPath: workingCopy.appendingPathComponent("basic.mdx").path
    ) {
        return workingCopy
    }
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // MdxKitTester
        .deletingLastPathComponent() // Sources
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("Tests/Fixtures", isDirectory: true)
}()
