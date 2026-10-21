import AppKit
import Sparkle

/// Sparkle updates from the GitHub releases (SUFeedURL, SUPublicEDKey in Info.plist), checked once a day.
/// ANNOT has no Dock icon, so an update found in the background doesn't open a window over your work: the menu
/// shows "Update Available…" until you open it (Sparkle's gentle reminders). Right after launch it shows directly.
final class Updater: NSObject, SPUStandardUserDriverDelegate, NSMenuItemValidation {
    static let shared = Updater()

    /// Called when `pending` changes, to retitle the menu item.
    var onPendingChange: ((Bool) -> Void)?
    private(set) var pending = false { didSet { if pending != oldValue { onPendingChange?(pending) } } }

    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)

    func start() { controller.startUpdater() }

    @objc func checkForUpdates(_ sender: Any?) {
        NSApp.activate()
        controller.checkForUpdates(sender)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { controller.updater.canCheckForUpdates }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate { NSApp.activate() } else { pending = true }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { pending = false }

    func standardUserDriverWillFinishUpdateSession() { pending = false }
}
