//
//  freewriteApp.swift
//  freewrite
//
//  Created by thorfinn on 2/14/25.
//

import SwiftUI

@main
struct freewriteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage(SettingsKey.colorScheme) private var colorSchemeString: String = "light"
    
    init() {
        // Register Lato (bold/italic faces are used by the editor's markdown styling)
        for face in ["Lato-Regular", "Lato-Bold", "Lato-Italic", "Lato-BoldItalic"] {
            if let fontURL = Bundle.main.url(forResource: face, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
            }
        }
    }
     
    var body: some Scene {
        WindowGroup(id: WritingWindow.id) {
            ContentView()
                .toolbar(.hidden, for: .windowToolbar)
                .preferredColorScheme(colorSchemeString == "dark" ? .dark : .light)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 600)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.contentSize)
        .commands {
            FreewriteCommands()
        }

        Settings {
            SettingsView()
                .preferredColorScheme(colorSchemeString == "dark" ? .dark : .light)
        }
    }
}

// Add AppDelegate to handle window configuration
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let window = NSApplication.shared.windows.first {
            // Ensure window starts in windowed mode
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            
            // Center the window on the screen
            window.center()
        }
    }
} 
