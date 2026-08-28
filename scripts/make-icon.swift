/**
 * Generate the DSH Controller icons from Assets/whale.svg.
 *
 * Produces:
 *   Assets/AppIcon.icns       — app icon (rounded-squircle DeepSeek-blue
 *                               gradient, white whale)
 *   Assets/menubar-whale.png  — 32 px whale for the menu-bar template image
 *
 * The SVG is rasterized by an built-in SVG-path parser + CoreGraphics fill
 * (non-zero winding, the SVG default). qlmanage/QuickLook is NOT used: it
 * renders this multi-subpath fill-rule-dependent SVG unreliably (full
 * bounding box on some invocations, empty on others).
 *
 * Supported path commands: M m L l H h V v C c S s Z z.
 * Run from the repo root:  swift scripts/make-icon.swift
 */

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let repoRoot = URL(fileURLWithPath: CommandLine.arguments[0])
	.deletingLastPathComponent().deletingLastPathComponent()
let assets = repoRoot.appendingPathComponent("Assets")
let whaleSVG = assets.appendingPathComponent("whale.svg")

// MARK: - SVG path parser

/// Token stream of an SVG path `d` attribute.
private enum PathToken {
	case command(Character)
	case number(Double)
}

private func tokenizePath(_ d: String) -> [PathToken] {
	var tokens: [PathToken] = []
	var index = d.startIndex
	let decimal = CharacterSet(charactersIn: "-+.eE0123456789")
	while index < d.endIndex {
		let char = d[index]
		if char.isWhitespace || char == "," {
			index = d.index(after: index)
		} else if char.isLetter {
			tokens.append(.command(char))
			index = d.index(after: index)
		} else if decimal.contains(d.unicodeScalars[index]) {
			var end = index
			while end < d.endIndex, decimal.contains(d.unicodeScalars[end]) { end = d.index(after: end) }
			tokens.append(.number(Double(d[index..<end]) ?? 0))
			index = end
		} else {
			index = d.index(after: index)
		}
	}
	return tokens
}

/**
 * Parses an SVG path `d` string into a CGMutablePath (SVG coordinates,
 * y-down). Handles M/m, L/l, H/h, V/v, C/c, S/s, Z/z with implicit
 * repetition; unsupported commands abort.
 */
struct SVGPathParser {

	private(set) var path = CGMutablePath()
	private var current = CGPoint.zero
	private var subpathStart = CGPoint.zero
	private var lastCubicControl: CGPoint?

	mutating func parse(_ d: String) {
		var tokens = tokenizePath(d)
		var index = 0
		var command: Character = "M"

		func nextNumber() -> Double {
			guard index < tokens.count, case .number(let value) = tokens[index] else { return 0 }
			index += 1
			return value
		}
		func nextPoint(_ relative: Bool, dx: Double = 0, dy: Double = 0) -> CGPoint {
			let x = nextNumber() + (relative ? Double(current.x) : dx)
			let y = nextNumber() + (relative ? Double(current.y) : dy)
			return CGPoint(x: x, y: y)
		}

		while index < tokens.count {
			if case .command(let c) = tokens[index] {
				command = c
				index += 1
			}
			let relative = command.isLowercase
			switch Character(command.uppercased()) {
			case "M":
				let point = nextPoint(relative)
				path.move(to: point)
				subpathStart = point
				current = point
				command = relative ? "l" : "L" // implicit line-to on repeats
			case "L":
				let point = nextPoint(relative)
				path.addLine(to: point)
				current = point
				lastCubicControl = nil
			case "H":
				let x = nextNumber() + (relative ? Double(current.x) : 0)
				let point = CGPoint(x: x, y: current.y)
				path.addLine(to: point)
				current = point
				lastCubicControl = nil
			case "V":
				let y = nextNumber() + (relative ? Double(current.y) : 0)
				let point = CGPoint(x: current.x, y: y)
				path.addLine(to: point)
				current = point
				lastCubicControl = nil
			case "C":
				let c1 = nextPoint(relative)
				let c2 = nextPoint(relative)
				let to = nextPoint(relative)
				path.addCurve(to: to, control1: c1, control2: c2)
				lastCubicControl = c2
				current = to
			case "S":
				let reflected = lastCubicControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
				let c2 = nextPoint(relative)
				let to = nextPoint(relative)
				path.addCurve(to: to, control1: reflected, control2: c2)
				lastCubicControl = c2
				current = to
			case "Z":
				path.closeSubpath()
				path.move(to: subpathStart)
				current = subpathStart
				lastCubicControl = nil
				command = "M" // a fresh subpath needs an explicit M after Z
			default:
				Swift.print("make-icon: unsupported path command \(command)")
				exit(1)
			}
		}
		tokens.removeAll()
	}
}

// MARK: - Helpers

func fail(_ message: String) -> Never {
	FileHandle.standardError.write(("make-icon: " + message + "\n").data(using: .utf8)!)
	exit(1)
}

/// The whale silhouette as a parsed path in SVG coordinates (50×50, y-down).
func whalePath() -> CGMutablePath {
	guard let svg = try? String(contentsOf: whaleSVG, encoding: .utf8),
		let open = svg.range(of: " d=\""),
		let close = svg.range(of: "\"", range: open.upperBound..<svg.endIndex)
	else { fail("could not extract the path data from whale.svg") }
	var parser = SVGPathParser()
	parser.parse(String(svg[open.upperBound..<close.lowerBound]))
	return parser.path
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

/// Rasterize the whale path to `size` px, filled black on transparent.
func renderWhale(size: Int) -> CGImage {
	let ctx = rgbaContext(width: size, height: size)
	let scale = CGFloat(size) / 50 // SVG viewBox is 50×50
	ctx.translateBy(x: 0, y: CGFloat(size)) // flip y: SVG is y-down
	ctx.scaleBy(x: scale, y: -scale)
	ctx.addPath(whalePath())
	ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
	ctx.drawPath(using: .fill) // non-zero winding — the SVG default
	guard let out = ctx.makeImage() else { fail("whale rasterization failed") }
	return out
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
	ctx.saveGState()
	let radius = CGFloat(size) * 0.225
	ctx.addPath(CGPath(roundedRect: full, cornerWidth: radius, cornerHeight: radius, transform: nil))
	ctx.clip()
	let colors = [
		CGColor(red: 0.388, green: 0.533, blue: 1.0, alpha: 1), // #6388FF
		CGColor(red: 0.180, green: 0.310, blue: 0.910, alpha: 1), // #2E4FE8
	] as CFArray
	let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
	ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)),
		end: CGPoint(x: 0, y: 0), options: [])
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

print("▸ rasterizing whale (CoreGraphics)")
let whaleBase = renderWhale(size: 1024)

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
writePNG(resized(renderWhale(size: 64), to: 32), to: assets.appendingPathComponent("menubar-whale.png"))

print("✓ done")
