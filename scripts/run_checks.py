#!/usr/bin/env python3
"""Run the existing Swift test methods with Command Line Tools, without XCTest.

The temporary package reuses production sources and the original test bodies;
only the XCTest assertions and runner are replaced. No dependencies are fetched.
"""
from pathlib import Path
import argparse
import os
import re
import shutil
import subprocess
import tempfile


ASSERTIONS = r'''
import Foundation
import Darwin
private var assertionCount = 0
private var failureCount = 0
private var testCount = 0

private func failCheck(_ message: String, _ file: StaticString, _ line: UInt) {
    failureCount += 1
    print("FAIL \(file):\(line): \(message)")
}
func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
                                 file: StaticString = #filePath, line: UInt = #line) {
    assertionCount += 1
    do { let a = try lhs(); let b = try rhs(); if a != b { failCheck("\(a) != \(b)", file, line) } }
    catch { failCheck("unexpected error: \(error)", file, line) }
}
func XCTAssertNotEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
                                    file: StaticString = #filePath, line: UInt = #line) {
    assertionCount += 1
    do { let a = try lhs(); let b = try rhs(); if a == b { failCheck("values unexpectedly equal", file, line) } }
    catch { failCheck("unexpected error: \(error)", file, line) }
}
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    assertionCount += 1
    do { if try !value() { failCheck("expected true", file, line) } }
    catch { failCheck("unexpected error: \(error)", file, line) }
}
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    assertionCount += 1
    do { if try value() { failCheck("expected false", file, line) } }
    catch { failCheck("unexpected error: \(error)", file, line) }
}
func XCTAssertNil<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) {
    assertionCount += 1
    do { if try value() != nil { failCheck("expected nil", file, line) } }
    catch { failCheck("unexpected error: \(error)", file, line) }
}
func XCTUnwrap<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    assertionCount += 1
    guard let result = try value() else {
        throw NSError(domain: "GPTMemoryChecks", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "expected non-nil at \(file):\(line)"])
    }
    return result
}
func XCTAssertThrowsError(_ value: @autoclosure () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
    assertionCount += 1
    do { _ = try value(); failCheck("expected error", file, line) } catch {}
}
func XCTAssertGreaterThan<T: Comparable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
                                       file: StaticString = #filePath, line: UInt = #line) {
    assertionCount += 1
    do { if try !(lhs() > rhs()) { failCheck("expected lhs > rhs", file, line) } }
    catch { failCheck("unexpected error: \(error)", file, line) }
}
func XCTAssertGreaterThanOrEqual<T: Comparable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
                                              file: StaticString = #filePath, line: UInt = #line) {
    assertionCount += 1
    do { if try !(lhs() >= rhs()) { failCheck("expected lhs >= rhs", file, line) } }
    catch { failCheck("unexpected error: \(error)", file, line) }
}
func XCTAssertLessThanOrEqual<T: Comparable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T,
                                           file: StaticString = #filePath, line: UInt = #line) {
    assertionCount += 1
    do { if try !(lhs() <= rhs()) { failCheck("expected lhs <= rhs", file, line) } }
    catch { failCheck("unexpected error: \(error)", file, line) }
}
private func runCheck(_ name: String, _ body: () throws -> Void) {
    testCount += 1
    let before = failureCount
    do { try body() } catch { failCheck("\(name): \(error)", #filePath, #line) }
    print("\(failureCount == before ? "PASS" : "FAIL") \(name)")
}
'''

MANIFEST = '''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "gpt-mem-checks", platforms: [.macOS(.v14)], targets: [
    .target(name: "CNative", linkerSettings: [.linkedLibrary("proc"), .linkedLibrary("sqlite3")]),
    .target(name: "GPTAnalysisKit", swiftSettings: [.unsafeFlags(["-enable-testing"])]),
    .target(name: "GPTSessionKit", dependencies: ["GPTAnalysisKit"], swiftSettings: [.unsafeFlags(["-enable-testing"])]),
    .target(name: "GPTMemoryCore", dependencies: ["CNative", "GPTAnalysisKit"], swiftSettings: [.unsafeFlags(["-enable-testing"])]),
    .executableTarget(name: "MemoryChecks", dependencies: ["GPTMemoryCore", "GPTAnalysisKit", "GPTSessionKit", "CNative"], path: "Checks")
], swiftLanguageModes: [.v5])
'''


def main():
    parser = argparse.ArgumentParser(description="使用 CLT 执行同源 Swift 测试，不需要安装 Xcode 或第三方包。")
    parser.add_argument("--filter", default="", help="仅执行名称包含指定字符串的测试")
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="gpt-mem-checks-") as temporary:
        temp = Path(temporary)
        (temp / "Sources").mkdir()
        for name in ["CNative", "GPTAnalysisKit", "GPTMemoryCore", "GPTSessionKit"]:
            shutil.copytree(project / "Sources" / name, temp / "Sources" / name)
        checks = temp / "Checks"
        checks.mkdir()
        calls = []
        suites = 0
        for source in sorted((project / "Tests").glob("*Tests/*.swift")):
            content = source.read_text()
            classes = re.findall(r"(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase", content)
            if len(classes) != 1:
                raise RuntimeError(f"测试文件必须包含一个 XCTestCase 类：{source.name}")
            class_name = classes[0]
            methods = re.findall(r"\bfunc\s+(test\w+)\s*\(\s*\)", content)
            selected = [name for name in methods if args.filter in name or args.filter in class_name]
            if not selected:
                continue
            content = re.sub(r"^\s*import\s+XCTest\s*$", "", content, flags=re.MULTILINE)
            content = re.sub(r":\s*XCTestCase\b", "", content)
            (checks / source.name).write_text(content)
            suite_name = f"suite{ suites }"
            suites += 1
            calls.append(f"let {suite_name} = {class_name}()")
            for method in selected:
                signature = re.search(rf"\bfunc\s+{re.escape(method)}\s*\(\s*\)\s*(throws)?", content)
                prefix = "try " if signature and signature.group(1) else ""
                calls.append(f'runCheck("{class_name}.{method}") {{ {prefix}{suite_name}.{method}() }}')
        count = sum(call.startswith("runCheck(") for call in calls)
        if count == 0:
            raise RuntimeError("没有匹配的测试。")
        footer = '\n'.join(calls)
        footer += '\nprint("RESULT tests=\\(testCount) assertions=\\(assertionCount) failures=\\(failureCount)")\n'
        footer += 'exit(failureCount == 0 ? 0 : 1)\n'
        (checks / "main.swift").write_text(ASSERTIONS + '\n' + footer)
        (temp / "Package.swift").write_text(MANIFEST)
        environment = os.environ.copy()
        environment["CLANG_MODULE_CACHE_PATH"] = str(temp / "clang-cache")
        environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(temp / "swift-cache")
        print(f"执行 {count} 个同源测试；临时构建与数据库用例自动清理。", flush=True)
        command = ["swift", "run", "--disable-sandbox", "--package-path", str(temp),
                   "--scratch-path", str(temp / "build"), "--cache-path", str(temp / "package-cache"), "MemoryChecks"]
        return subprocess.run(command, env=environment).returncode


if __name__ == "__main__":
    raise SystemExit(main())
