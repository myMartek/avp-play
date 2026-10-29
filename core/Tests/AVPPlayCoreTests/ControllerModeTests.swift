import XCTest
@testable import AVPPlayCore

final class ControllerModeTests: XCTestCase {
    func testDefaultPersistenceAndInvalidFallback() {
        let suite = "controller-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ControllerMode.load(defaults: defaults), .standard)
        ControllerMode.surreal.save(defaults: defaults)
        XCTAssertEqual(ControllerMode.load(defaults: UserDefaults(suiteName: suite)!), .surreal)
        ControllerMode.standard.save(defaults: defaults)
        XCTAssertEqual(ControllerMode.load(defaults: defaults), .standard)
        defaults.set("unknown", forKey: ControllerMode.preferenceKey)
        XCTAssertEqual(ControllerMode.load(defaults: defaults), .standard)
    }
    func testOldJobsAndNewJobsRoundTrip() throws {
        let old = InstallRequest(toolchain: "/custom/chosen")
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let oldData = try encoder.encode(old)
        XCTAssertFalse(String(decoding: oldData, as: UTF8.self).contains("controllerMode"))
        XCTAssertNil(try decoder.decode(InstallRequest.self, from: oldData).controllerMode)
        var new = old; new.controllerMode = .surreal
        let saved = try decoder.decode(InstallRequest.self, from: encoder.encode(new))
        XCTAssertEqual(saved.controllerMode, .surreal)
        XCTAssertEqual(saved.toolchain, "/custom/chosen")
        XCTAssertNil(saved.bundleId)
    }
    func testToolchainCapabilityAndExplicitEnvironment() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("surreal-toolchain-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("visionos/Sources"), withIntermediateDirectories: true)
        try "#!/bin/sh".write(to: dir.appendingPathComponent("visionos/run.sh"), atomically: true, encoding: .utf8)
        let tc = try Toolchain(root: dir)
        XCTAssertFalse(tc.supportsSurrealControllers)
        XCTAssertEqual(try tc.controllerEnvironment(.standard), ["KLEPTON_CONTROLLER_MODE": "standard"])
        XCTAssertThrowsError(try tc.controllerEnvironment(.surreal))
        try "KLEPTON_CONTROLLER_MODE".write(to: dir.appendingPathComponent("visionos/gen_xcodeproj.py"), atomically: true, encoding: .utf8)
        for name in ["KleptonControllerInput", "KleptonControllerMode", "KleptonSurrealInput", "KleptonSurrealBackend", "KleptonSurrealView", "KleptonSurrealAim", "KleptonSurrealAimView"] {
            try "// fixture".write(to: dir.appendingPathComponent("visionos/Sources/\(name).swift"), atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(tc.supportsSurrealControllers)
        XCTAssertEqual(try tc.controllerEnvironment(.surreal), ["KLEPTON_CONTROLLER_MODE": "surreal"])
    }
    func testSurrealSupportOffBuildsStandardOnly() throws {
        let suite = "surreal-support-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(ControllerMode.supportEnabled(defaults: defaults), "on unless switched off")
        defaults.set(false, forKey: ControllerMode.supportKey)
        XCTAssertFalse(ControllerMode.supportEnabled(defaults: defaults))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("surreal-off-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("visionos"), withIntermediateDirectories: true)
        try "#!/bin/sh".write(to: dir.appendingPathComponent("visionos/run.sh"), atomically: true, encoding: .utf8)
        let tc = try Toolchain(root: dir)
        XCTAssertFalse(tc.supportsSurrealSwitch)
        // Off: Standard whatever was asked, never refused – even by a toolchain without Surreal Touch.
        XCTAssertEqual(try tc.controllerEnvironment(.surreal, surrealSupport: false),
                       ["KLEPTON_CONTROLLER_MODE": "standard", "KLEPTON_SURREAL_SUPPORT": "0"])
        try "KLEPTON_CONTROLLER_MODE KLEPTON_SURREAL_SUPPORT".write(to: dir.appendingPathComponent("visionos/gen_xcodeproj.py"), atomically: true, encoding: .utf8)
        XCTAssertTrue(tc.supportsSurrealSwitch)
        var request = InstallRequest(toolchain: "/t")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(request), as: UTF8.self).contains("surrealSupport"))
        request.surrealSupport = false
        XCTAssertEqual(try JSONDecoder().decode(InstallRequest.self, from: JSONEncoder().encode(request)).surrealSupport, false)
    }
}

extension ToolchainPackageTests {
    func testControllerSourcesSurviveArchiveAndInstall() throws {
        let checkout = try makeCheckout()
        let sources = checkout.appendingPathComponent("visionos/Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let names = ["KleptonControllerInput", "KleptonControllerMode", "KleptonSurrealInput", "KleptonSurrealBackend", "KleptonSurrealView", "KleptonSurrealAim", "KleptonSurrealAimView"]
        for name in names {
            try "// packaged \(name)".write(to: sources.appendingPathComponent("\(name).swift"), atomically: true, encoding: .utf8)
        }
        try "KLEPTON_CONTROLLER_MODE".write(to: checkout.appendingPathComponent("visionos/gen_xcodeproj.py"), atomically: true, encoding: .utf8)
        try git(checkout, "add", "visionos")
        try git(checkout, "commit", "-m", "controller fixture")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("surreal-package-\(UUID())")
        defer { try? FileManager.default.removeItem(at: out) }
        let package = try ToolchainPackager.pack(checkout: checkout, to: out)
        let installed = try ToolchainPackager(root: out.appendingPathComponent("installed")).install(archive: package.archive)
        XCTAssertTrue(installed.supportsSurrealControllers)
        for name in names {
            XCTAssertEqual(try String(contentsOf: installed.root.appendingPathComponent("visionos/Sources/\(name).swift")), "// packaged \(name)")
        }
    }
}
