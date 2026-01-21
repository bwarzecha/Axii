#!/usr/bin/env swift

import SwiftUI
import AppKit

// MARK: - Radial Bar Indicator (copied from app)

struct RadialBarIndicator: View {
    let level: CGFloat
    var color: Color = Color(red: 0.3, green: 0.6, blue: 1.0)
    var size: CGFloat = 80

    private let barCount = 48

    var body: some View {
        ZStack {
            // Glow effect
            Circle()
                .fill(
                    RadialGradient(
                        colors: [color.opacity(0.2 + Double(level) * 0.15), .clear],
                        center: .center,
                        startRadius: size * 0.25,
                        endRadius: size * 0.55
                    )
                )
                .frame(width: size, height: size)

            // Radial bars
            ForEach(0..<barCount, id: \.self) { index in
                radialBar(index: index)
            }
        }
        .frame(width: size, height: size)
    }

    private func radialBar(index: Int) -> some View {
        let angle = Double(index) / Double(barCount) * 360.0
        let baseLength: CGFloat = size * 0.08
        let levelBoost = level * size * 0.06
        let barLength = baseLength + levelBoost
        let opacity = 0.5 + Double(level) * 0.5
        let innerRadius = size * 0.32
        // Scale bar width proportionally (2.5 at size 80 = 0.03125)
        let barWidth: CGFloat = size * 0.03

        return RoundedRectangle(cornerRadius: size * 0.0125)
            .fill(color.opacity(opacity))
            .frame(width: barWidth, height: barLength)
            .offset(y: -(innerRadius + barLength / 2))
            .rotationEffect(.degrees(angle))
    }
}

// MARK: - Icon Views

struct AppIconView: View {
    let size: CGFloat
    var color: Color = Color(red: 0.3, green: 0.6, blue: 1.0)

    var body: some View {
        ZStack {
            Color.clear
            RadialBarIndicator(level: 0.65, color: color, size: size * 0.85)
        }
        .frame(width: size, height: size)
    }
}

/// Menu bar template icon - radial bars with microphone in center
struct MenuBarIconView: View {
    let size: CGFloat

    private let barCount = 12  // Fewer bars for visibility at small sizes

    var body: some View {
        ZStack {
            Color.clear

            // Radial bars
            ForEach(0..<barCount, id: \.self) { index in
                let angle = Double(index) / Double(barCount) * 360.0
                let baseLength: CGFloat = size * 0.22
                let innerRadius = size * 0.28  // Push bars outward to make room for mic
                let barWidth: CGFloat = max(1.5, size * 0.08)

                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(Color.black)
                    .frame(width: barWidth, height: baseLength)
                    .offset(y: -(innerRadius + baseLength / 2))
                    .rotationEffect(.degrees(angle))
            }

            // Letter A in center
            Text("A")
                .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                .foregroundColor(.black)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Export Functions

@MainActor
func renderToImage<V: View>(_ view: V, size: CGFloat) -> NSImage? {
    let renderer = ImageRenderer(content: view.frame(width: size, height: size))
    renderer.scale = 1.0
    return renderer.nsImage
}

@MainActor
func saveImage(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ExportIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert to PNG"])
    }
    try png.write(to: url)
}

@MainActor
func exportAppIcons() {
    let projectRoot = FileManager.default.currentDirectoryPath
    let appIconDir = URL(fileURLWithPath: projectRoot)
        .appendingPathComponent("Axii/Assets.xcassets/AppIcon.appiconset")

    // macOS app icon sizes: size@scale
    let sizes: [(size: Int, scale: Int, filename: String)] = [
        (16, 1, "icon_16x16.png"),
        (16, 2, "icon_16x16@2x.png"),
        (32, 1, "icon_32x32.png"),
        (32, 2, "icon_32x32@2x.png"),
        (128, 1, "icon_128x128.png"),
        (128, 2, "icon_128x128@2x.png"),
        (256, 1, "icon_256x256.png"),
        (256, 2, "icon_256x256@2x.png"),
        (512, 1, "icon_512x512.png"),
        (512, 2, "icon_512x512@2x.png"),
    ]

    print("Exporting App Icons...")

    for (size, scale, filename) in sizes {
        let pixelSize = CGFloat(size * scale)
        let view = AppIconView(size: pixelSize)

        guard let image = renderToImage(view, size: pixelSize) else {
            print("  Failed to render \(filename)")
            continue
        }

        let outputURL = appIconDir.appendingPathComponent(filename)
        do {
            try saveImage(image, to: outputURL)
            print("  \(filename)")
        } catch {
            print("  Failed to save \(filename): \(error)")
        }
    }

    // Update Contents.json
    let contentsJSON = """
    {
      "images" : [
        {
          "filename" : "icon_16x16.png",
          "idiom" : "mac",
          "scale" : "1x",
          "size" : "16x16"
        },
        {
          "filename" : "icon_16x16@2x.png",
          "idiom" : "mac",
          "scale" : "2x",
          "size" : "16x16"
        },
        {
          "filename" : "icon_32x32.png",
          "idiom" : "mac",
          "scale" : "1x",
          "size" : "32x32"
        },
        {
          "filename" : "icon_32x32@2x.png",
          "idiom" : "mac",
          "scale" : "2x",
          "size" : "32x32"
        },
        {
          "filename" : "icon_128x128.png",
          "idiom" : "mac",
          "scale" : "1x",
          "size" : "128x128"
        },
        {
          "filename" : "icon_128x128@2x.png",
          "idiom" : "mac",
          "scale" : "2x",
          "size" : "128x128"
        },
        {
          "filename" : "icon_256x256.png",
          "idiom" : "mac",
          "scale" : "1x",
          "size" : "256x256"
        },
        {
          "filename" : "icon_256x256@2x.png",
          "idiom" : "mac",
          "scale" : "2x",
          "size" : "256x256"
        },
        {
          "filename" : "icon_512x512.png",
          "idiom" : "mac",
          "scale" : "1x",
          "size" : "512x512"
        },
        {
          "filename" : "icon_512x512@2x.png",
          "idiom" : "mac",
          "scale" : "2x",
          "size" : "512x512"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """

    let contentsURL = appIconDir.appendingPathComponent("Contents.json")
    try? contentsJSON.write(to: contentsURL, atomically: true, encoding: .utf8)
    print("  Contents.json updated")
}

@MainActor
func exportMenuBarIcons() {
    let projectRoot = FileManager.default.currentDirectoryPath
    let assetsDir = URL(fileURLWithPath: projectRoot)
        .appendingPathComponent("Axii/Assets.xcassets")

    // Create MenuBarIcon.imageset directory
    let menuBarDir = assetsDir.appendingPathComponent("MenuBarIcon.imageset")
    try? FileManager.default.createDirectory(at: menuBarDir, withIntermediateDirectories: true)

    print("\nExporting Menu Bar Icons...")

    // Menu bar icons: 18pt is common for macOS menu bar
    let sizes: [(size: Int, scale: Int, filename: String)] = [
        (18, 1, "menubar_18x18.png"),
        (18, 2, "menubar_18x18@2x.png"),
    ]

    for (size, scale, filename) in sizes {
        let pixelSize = CGFloat(size * scale)
        let view = MenuBarIconView(size: pixelSize)

        guard let image = renderToImage(view, size: pixelSize) else {
            print("  Failed to render \(filename)")
            continue
        }

        let outputURL = menuBarDir.appendingPathComponent(filename)
        do {
            try saveImage(image, to: outputURL)
            print("  \(filename)")
        } catch {
            print("  Failed to save \(filename): \(error)")
        }
    }

    // Contents.json for menu bar - template rendering mode
    let contentsJSON = """
    {
      "images" : [
        {
          "filename" : "menubar_18x18.png",
          "idiom" : "mac",
          "scale" : "1x"
        },
        {
          "filename" : "menubar_18x18@2x.png",
          "idiom" : "mac",
          "scale" : "2x"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      },
      "properties" : {
        "template-rendering-intent" : "template"
      }
    }
    """

    let contentsURL = menuBarDir.appendingPathComponent("Contents.json")
    try? contentsJSON.write(to: contentsURL, atomically: true, encoding: .utf8)
    print("  Contents.json created")
}

@MainActor
func exportGitHubSocialPreview() {
    let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

    print("\nExporting GitHub Social Preview...")

    // GitHub recommends 1280x640 for social preview
    let width: CGFloat = 1280
    let height: CGFloat = 640

    let view = ZStack {
        // Dark gradient background
        LinearGradient(
            colors: [
                Color(red: 0.08, green: 0.10, blue: 0.18),
                Color(red: 0.12, green: 0.15, blue: 0.25)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        HStack(spacing: 60) {
            RadialBarIndicator(level: 0.65, size: 280)

            VStack(alignment: .leading, spacing: 16) {
                Text("Axii")
                    .font(.system(size: 72, weight: .bold))
                    .foregroundColor(.white)

                Text("Your voice, your command, your privacy.")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
    }
    .frame(width: width, height: height)

    let renderer = ImageRenderer(content: view)
    renderer.scale = 1.0

    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        print("  Failed to render")
        return
    }

    let outputURL = desktop.appendingPathComponent("Axii-GitHub-Social.png")
    do {
        try png.write(to: outputURL)
        print("  Saved to Desktop/Axii-GitHub-Social.png")
    } catch {
        print("  Failed: \(error)")
    }
}

// MARK: - Main

@MainActor
func main() {
    exportAppIcons()
    exportMenuBarIcons()
    exportGitHubSocialPreview()

    print("\nDone!")
    print("\nNext steps:")
    print("1. App Icon: Already in Assets.xcassets - rebuild the app")
    print("2. Menu Bar: Update your menu bar code to use Image(\"MenuBarIcon\")")
    print("3. GitHub: Go to repo Settings > General > Social preview > Upload Axii-GitHub-Social.png")
}

// Run
if #available(macOS 13.0, *) {
    let semaphore = DispatchSemaphore(value: 0)
    Task { @MainActor in
        main()
        semaphore.signal()
    }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
    semaphore.wait()
} else {
    print("Requires macOS 13.0+")
    exit(1)
}
