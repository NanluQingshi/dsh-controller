/**
 * Generate the DSH Controller icons from Assets/whale.svg.
 *
 * Produces:
 *   Assets/AppIcon.icns       — app icon (rounded-squircle DeepSeek-blue
 *                               gradient, white whale)
 *   Assets/menubar-whale.png  — 32 px whale for the menu-bar template image
 *
 * Uses qlmanage (system) for SVG rasterization, CoreGraphics for compositing,
 * iconutil for the icns. Run from the repo root:  swift scripts/make-icon.swift
 */

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let repoRoot = URL(fileURLWithPath: CommandLine.arguments[0])
	.deletingLastPathComponent().deletingLastPathComponent()
let assets = repoRoot.appendingPathComponent("Assets")
let whaleSVG = assets.appendingPathComponent("whale.svg")

// MARK: - Helpers

func fail(_ message: String) -> Never {
	FileHandle.standardError.write(("make-icon: " + message + "\n").data(using: .utf8)!)
	exit(1)
}

/// Rasterize the SVG via QuickLook into `size` px PNG, return the CGImage.
func rasterizeWhale(size: Int) -> CGImage {
	let tmp = FileManager.default.temporaryDirectory
		.appendingPathComponent("dsh-icon-\(size)-\(UUID().uuidString).svg")
	try? FileManager.default.copyItem(at: whaleSVG, to: tmp)
	defer { try? FileManager.default.removeItem(at: tmp) }
	let outDir = tmp.deletingLastPathComponent()
	let process = Process()
	process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
	process.arguments = ["-t", "-s", "\(size)", "-o", outDir.path, tmp.path]
	process.standardOutput = FileHandle.nullDevice
	process.standardError = FileHandle.nullDevice
	try? process.run()
	process.waitUntilExit()
	guard process.terminationStatus == 0 else { fail("qlmanage failed") }
	let png = outDir.appendingPathComponent(tmp.lastPathComponent + ".png")
	guard let src = CGImageSourceCreateWithURL(png as CFURL, nil),
		let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
	else { fail("could not read rasterized PNG") }
	try? FileManager.default.removeItem(at: png)
	return image
}

func rgbaContext(width: Int, height: Int) -> CGContext {
	guard let ctx = CGContext(data: nil, width: width, height: height,
		bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
		bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
	else { fail("context creation failed") }
	return ctx
}

func writePNG(_ image: CGImage, to url: URL) {
	guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
	else { fail("png destination failed: \(url.path)") }
	CGImageDestinationAddImage(dest, image, nil)
	guard CGImageDestinationFinalize(dest) else { fail("png write failed: \(url.path)") }
}

/// The white whale silhouette (whale raster tinted flat white, alpha kept).
func whiteWhale(base: CGImage, canvas: Int) -> CGImage {
	let scale = Double(canvas) * 0.58 / Double(base.width)
	let w = Int(Double(base.width) * scale)
	let h = Int(Double(base.height) * scale)
	let ctx = rgbaContext(width: w, height: h)
	let rect = CGRect(x: 0, y: 0, width: w, height: h)
	ctx.interpolationQuality = .high
	ctx.draw(base, in: rect)
	ctx.setBlendMode(.sourceIn)
	ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
	ctx.fill(rect)
	guard let out = ctx.makeImage() else { fail("tint failed") }
	return out
}

/// Compose the master app-icon canvas: blue gradient squircle + white whale.
func composeMaster(size: Int, whale: CGImage) -> CGImage {
	let ctx = rgbaContext(width: size, height: size)
	let full = CGRect(x: 0, y: 0, width: size, height: size)
	// Rounded squircle (~22.5% radius).
	ctx.saveGState()
	let radius = CGFloat(size) * 0.225
	ctx.addPath(CGPath(roundedRect: full, cornerWidth: radius, cornerHeight: radius, transform: nil))
	ctx.clip()
	// Vertical gradient, DeepSeek blue range.
	let colors = [
		CGColor(red: 0.388, green: 0.533, blue: 1.0, alpha: 1), // #6388FF
		CGColor(red: 0.180, green: 0.310, blue: 0.910, alpha: 1), // #2E4FE8
	] as CFArray
	let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
	ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)),
		end: CGPoint(x: 0, y: 0), options: [])
	// White whale centered.
	let w = CGFloat(whale.width), h = CGFloat(whale.height)
	let rect = CGRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h)
	ctx.interpolationQuality = .high
	ctx.draw(whale, in: rect)
	ctx.restoreGState()
	guard let out = ctx.makeImage() else { fail("master compose failed") }
	return out
}

/// Scale a CGImage to `size` px (hard resize for iconset members).
func resized(_ image: CGImage, to size: Int) -> CGImage {
	let ctx = rgbaContext(width: size, height: size)
	ctx.interpolationQuality = .high
	ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
	guard let out = ctx.makeImage() else { fail("resize failed") }
	return out
}

// MARK: - Main

setbuf(stdout, nil)
try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
guard FileManager.default.fileExists(atPath: whaleSVG.path) else { fail("Assets/whale.svg missing") }

print("▸ rasterizing whale")
let whaleBase = rasterizeWhale(size: 1024)

print("▸ composing master icon")
let master = composeMaster(size: 1024, whale: whiteWhale(base: whaleBase, canvas: 1024))

print("▸ building iconset")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("DSHController.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
	writePNG(resized(master, to: size), to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
	let pixel = size * 2
	if pixel <= 1024, size != 1024 {
		writePNG(resized(master, to: pixel), to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
	}
}

print("▸ iconutil → Assets/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path]
try? iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }
try? FileManager.default.removeItem(at: iconset)

print("▸ menubar glyph → Assets/menubar-whale.png")
// Route through our context (2× supersampled) so the colorspace is ours.
writePNG(resized(rasterizeWhale(size: 64), to: 32), to: assets.appendingPathComponent("menubar-whale.png"))

print("✓ done")
