#!/bin/zsh
# Regenerate every app icon from one 1024 x 1024 PNG drawn on the macOS icon
# grid: an 824 px rounded tile centred on a transparent canvas (100 px margin,
# the tile's shadow below it), the way the icon design files are made.
#
#   script/set_app_icon.sh path/to/icon-1024.png
#
# Writes, keeping every file name and Contents.json:
#   App/Assets.xcassets/AppIcon.appiconset/AppIcon-*.png
#       macOS, 16 to 1024 px: the canvas as it is (margin and shadow included).
#   iOS/App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
#       iPhone: the tile alone, full bleed and opaque (iOS draws its own mask).
#       The keyboard and share extensions show the app's icon.
#   iOS/App/Assets.xcassets/Mark.imageset/Mark.png, @2x, @3x
#       the in-app mark (pairing screen, home header): the tile, 96 pt.
# The Mac sidebar draws NSApplication.applicationIconImage, so it follows the
# macOS set without a file of its own.
#
# Tools: sips and iconutil, plus Xcode's swift to flatten the iPhone icon and to
# drop the metadata chunks sips writes.

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
source_png="${1:?usage: script/set_app_icon.sh path/to/icon-1024.png}"
[[ -f "$source_png" ]] || { print -u2 "error: $source_png not found"; exit 66; }

properties="$(/usr/bin/sips -g format -g pixelWidth -g pixelHeight "$source_png")"
if ! print -r -- "$properties" | /usr/bin/grep -q 'format: png' ||
   ! print -r -- "$properties" | /usr/bin/grep -q 'pixelWidth: 1024' ||
   ! print -r -- "$properties" | /usr/bin/grep -q 'pixelHeight: 1024'; then
  print -u2 "error: $source_png must be a 1024 x 1024 PNG"
  exit 65
fi

mac_set="$repository_root/App/Assets.xcassets/AppIcon.appiconset"
phone_set="$repository_root/iOS/App/Assets.xcassets/AppIcon.appiconset"
mark_set="$repository_root/iOS/App/Assets.xcassets/Mark.imageset"
work="$(mktemp -d "${TMPDIR:-/tmp}/set-app-icon.XXXXXX")"
trap '/bin/rm -rf "$work"' EXIT

resize() {  # resize <side> <input> <output>
  /usr/bin/sips -s format png -z "$1" "$1" "$2" --out "$3" >/dev/null
}

# macOS: the canvas at every size the set lists; an .iconset copy checks the
# set with iconutil.
/bin/mkdir "$work/AppIcon.iconset"
for name side iconset_name in \
  AppIcon-16.png 16 icon_16x16.png \
  AppIcon-16@2x.png 32 icon_16x16@2x.png \
  AppIcon-32.png 32 icon_32x32.png \
  AppIcon-32@2x.png 64 icon_32x32@2x.png \
  AppIcon-128.png 128 icon_128x128.png \
  AppIcon-128@2x.png 256 icon_128x128@2x.png \
  AppIcon-256.png 256 icon_256x256.png \
  AppIcon-256@2x.png 512 icon_256x256@2x.png \
  AppIcon-512.png 512 icon_512x512.png \
  AppIcon-512@2x.png 1024 icon_512x512@2x.png; do
  resize "$side" "$source_png" "$mac_set/$name"
  /bin/cp "$mac_set/$name" "$work/AppIcon.iconset/$iconset_name"
done
/usr/bin/iconutil -c icns -o "$work/AppIcon.icns" "$work/AppIcon.iconset"

# The tile without the margin: sips crops around the centre.
/usr/bin/sips -s format png -c 824 824 "$source_png" --out "$work/tile.png" >/dev/null

for name side in Mark.png 96 Mark@2x.png 192 Mark@3x.png 288; do
  resize "$side" "$work/tile.png" "$mark_set/$name"
done

# iPhone: the tile, 12 px inside its edge so the tile's 2 px rim stays out
# (iOS draws its own mask, and the rim's corners fall outside that mask), at
# 1024 on an opaque canvas. A 1.25x copy goes underneath so the corners are
# filled with the tile's own ground rather than a flat colour.
/usr/bin/sips -s format png -c 800 800 "$source_png" --out "$work/inner.png" >/dev/null
resize 1024 "$work/inner.png" "$work/tile-1024.png"
/bin/cat > "$work/icon_tool.swift" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// flatten <tile.png> <out.png>: the tile on an opaque canvas of its own size.
func flatten(_ input: String, _ output: String) {
  guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: input) as CFURL, nil),
    let tile = CGImageSourceCreateImageAtIndex(source, 0, nil),
    let context = CGContext(
      data: nil, width: tile.width, height: tile.height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
  else { fatalError("cannot read \(input)") }
  let canvas = CGRect(x: 0, y: 0, width: tile.width, height: tile.height)
  context.interpolationQuality = .high
  context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
  context.fill(canvas)
  context.draw(tile, in: canvas.insetBy(dx: -canvas.width / 8, dy: -canvas.height / 8))
  context.draw(tile, in: canvas)
  guard let flat = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
      URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { fatalError("cannot write \(output)") }
  CGImageDestinationAddImage(destination, flat, nil)
  guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(output)") }
}

// strip <png>...: keep only the image chunks. sips and ImageIO add eXIf and
// XMP (iTXt) chunks, which the public export refuses.
func strip(_ path: String) {
  let url = URL(fileURLWithPath: path)
  let bytes = [UInt8](try! Data(contentsOf: url))
  let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  guard bytes.count > 8, Array(bytes[0..<8]) == signature else { fatalError("\(path) is not a PNG") }
  let keep: Set<String> = ["IHDR", "PLTE", "tRNS", "sRGB", "IDAT", "IEND"]
  var output = signature
  var index = 8
  while index + 12 <= bytes.count {
    let length = bytes[index..<index + 4].reduce(0) { $0 << 8 | Int($1) }
    let end = index + 12 + length
    guard end <= bytes.count else { fatalError("\(path) is truncated") }
    if keep.contains(String(decoding: bytes[index + 4..<index + 8], as: UTF8.self)) {
      output += bytes[index..<end]
    }
    index = end
  }
  try! Data(output).write(to: url, options: .atomic)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "flatten" where arguments.count == 3: flatten(arguments[1], arguments[2])
case "strip": arguments.dropFirst().forEach(strip)
default: fatalError("usage: flatten <tile.png> <out.png> | strip <png>...")
}
SWIFT
/usr/bin/xcrun swift "$work/icon_tool.swift" flatten "$work/tile-1024.png" "$phone_set/AppIcon-1024.png"

if ! /usr/bin/sips -g hasAlpha "$phone_set/AppIcon-1024.png" | /usr/bin/grep -q 'hasAlpha: no'; then
  print -u2 "error: the iPhone icon still has an alpha channel"
  exit 70
fi

/usr/bin/xcrun swift "$work/icon_tool.swift" strip \
  "$mac_set"/AppIcon-*.png "$phone_set/AppIcon-1024.png" "$mark_set"/Mark*.png

print "macOS  $mac_set (10 sizes; iconutil accepted the set)"
print "iPhone $phone_set/AppIcon-1024.png (opaque)"
print "Mark   $mark_set (96, 192, 288 px)"
print "Metadata chunks removed from all 14 PNGs."
