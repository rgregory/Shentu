// Makes assets/AppIcon.png (1024x1024, transparent) from icon.jpg, whose "transparency" is a
// checkerboard painted into the JPEG. Flood-fills light, grey pixels reachable from the edges
// (the box has a dark outline, so the fill stops there), then centers the box on a square.
// usage: swift scripts/make-icon.swift icon.jpg assets/AppIcon.png (run once; the PNG is committed)
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]),
      let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("usage: make-icon <in.jpg> <out.png>")
}
let w = cg.width, h = cg.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let space = CGColorSpaceCreateDeviceRGB()
let info = CGImageAlphaInfo.premultipliedLast.rawValue
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

func background(_ i: Int) -> Bool {
    let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
    return min(r, g, b) > 165 && max(r, g, b) - min(r, g, b) < 24
}
var clear = [Bool](repeating: false, count: w * h)
var stack: [Int] = []
for x in 0..<w { stack += [x, (h - 1) * w + x] }
for y in 0..<h { stack += [y * w, y * w + w - 1] }
while let i = stack.popLast() {
    guard !clear[i], background(i) else { continue }
    clear[i] = true
    let x = i % w, y = i / w
    if x > 0 { stack.append(i - 1) }
    if x < w - 1 { stack.append(i + 1) }
    if y > 0 { stack.append(i - w) }
    if y < h - 1 { stack.append(i + w) }
}
// Keep only the largest shape (the box): stray squares of the painted checkerboard survive the fill.
var label = [Int32](repeating: 0, count: w * h)
var sizes: [Int] = [0]
for start in 0..<(w * h) where !clear[start] && label[start] == 0 {
    let id = Int32(sizes.count)
    var count = 0
    stack = [start]
    while let i = stack.popLast() {
        guard !clear[i], label[i] == 0 else { continue }
        label[i] = id
        count += 1
        let x = i % w, y = i / w
        if x > 0 { stack.append(i - 1) }
        if x < w - 1 { stack.append(i + 1) }
        if y > 0 { stack.append(i - w) }
        if y < h - 1 { stack.append(i + w) }
    }
    sizes.append(count)
}
let keep = Int32(sizes.indices.max { sizes[$0] < sizes[$1] }!)
for i in 0..<(w * h) where label[i] != keep { clear[i] = true }
var minX = w, minY = h, maxX = 0, maxY = 0
for i in 0..<(w * h) {
    if clear[i] { px[i * 4] = 0; px[i * 4 + 1] = 0; px[i * 4 + 2] = 0; px[i * 4 + 3] = 0; continue }
    let x = i % w, y = i / w
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
}
let cleaned = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info)!.makeImage()!

// The box fills about 88% of the icon, like Apple's own icons leave a margin.
let size = 1024, box = CGFloat(max(maxX - minX, maxY - minY) + 1)
let scale = CGFloat(size) * 0.88 / box
let out = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
out.interpolationQuality = .high
let drawW = CGFloat(w) * scale, drawH = CGFloat(h) * scale
// CG's origin is bottom-left; minY/maxY were counted from the top of the bitmap.
let cx = (CGFloat(minX + maxX) / 2) * scale, cy = (CGFloat(h) - CGFloat(minY + maxY) / 2) * scale
out.draw(cleaned, in: CGRect(x: CGFloat(size) / 2 - cx, y: CGFloat(size) / 2 - cy, width: drawW, height: drawH))
let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) (box \(maxX - minX + 1)x\(maxY - minY + 1) of \(w)x\(h))")
