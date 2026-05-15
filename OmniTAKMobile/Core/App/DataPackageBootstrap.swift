//
//  DataPackageBootstrap.swift
//  OmniTAKMobile
//
//  DEBUG-only auto-import of TAK data packages dropped into the app's
//  Documents/import/ directory. Mirrors the Android client's
//  DataPackageBootstrap so simulator / CI interop tests can stage a
//  connection without driving the file-picker UI by hand.
//
//  Usage (simulator):
//    APP=$(xcrun simctl get_app_container <udid> com.engindearing.omnitak.mobile data)
//    mkdir -p "$APP/Documents/import"
//    cp tak57-mtls-sim.zip "$APP/Documents/import/"
//    xcrun simctl launch <udid> com.engindearing.omnitak.mobile
//
//  On launch the app will extract the package, import its certs +
//  server.pref, add the server (which auto-connects), then rename the
//  zip to `<name>.zip.imported` so re-launches are idempotent.
//
//  The whole file is wrapped in `#if DEBUG` — it is never compiled into
//  a Release / App Store build.
//

#if DEBUG
import Foundation

enum DataPackageBootstrap {
    private static let importDirName = "import"

    /// Scan `Documents/import/` for `.zip` data packages and import each one.
    /// Safe to call on every launch — already-imported packages are renamed
    /// to `.imported` and skipped thereafter.
    @MainActor
    static func runIfNeeded() async {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let importDir = docs.appendingPathComponent(importDirName, isDirectory: true)

        guard fm.fileExists(atPath: importDir.path) else { return }

        let zips: [URL]
        do {
            zips = try fm.contentsOfDirectory(at: importDir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "zip" }
        } catch {
            print("⚠️ DataPackageBootstrap: failed to list \(importDir.path): \(error)")
            return
        }

        guard !zips.isEmpty else { return }

        let importManager = DataPackageImportManager()
        for zip in zips {
            do {
                try await importManager.importPackage(from: zip) { _ in }
                let imported = zip.appendingPathExtension("imported")
                try? fm.removeItem(at: imported)
                try fm.moveItem(at: zip, to: imported)
                print("✅ DataPackageBootstrap: imported \(zip.lastPathComponent) → \(imported.lastPathComponent)")
            } catch {
                print("⚠️ DataPackageBootstrap: import of \(zip.lastPathComponent) failed: \(error)")
            }
        }
    }
}
#endif
