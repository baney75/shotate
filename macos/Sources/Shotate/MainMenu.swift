import AppKit

/// The menu bar shown while an editor is open. The Edit menu gives text fields their usual
/// ⌘C, ⌘V, ⌘A and undo behavior.
enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "Shotate")
        app.addItem(withTitle: "About Shotate", action: #selector(AppDelegate.showAbout), keyEquivalent: "").target = target
        app.addItem(.separator())
        let settings = app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        settings.target = target
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Shotate", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Shotate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app))

        let file = NSMenu(title: "File")
        for (title, action, key) in [("Capture Area", #selector(AppDelegate.captureArea), ""),
                                     ("Capture Window", #selector(AppDelegate.captureWindow), ""),
                                     ("Capture Full Screen", #selector(AppDelegate.captureScreen), ""),
                                     ("Open Image…", #selector(AppDelegate.openImagePanel), "o")] {
            file.addItem(withTitle: title, action: action, keyEquivalent: key).target = target
        }
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(file))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
