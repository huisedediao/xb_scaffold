// 把生成的方形图标加工成 macOS 可用的圆角透明 PNG。
//
//   swift make_icon.swift <in.png> <out.png> [size]
//
// 做的事：去掉底部的水印条 → 找非白内容的外接框（自动贴合圆角图案的外沿，
// 顺带裁掉四周白边与阴影）→ 以 22% 圆角遮罩裁成透明外角 → 输出正方形 PNG。
// 用 CoreGraphics，不依赖第三方库（本机没有 PIL / ImageMagick）。
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let argv = CommandLine.arguments
guard argv.count >= 3 else {
  FileHandle.standardError.write("usage: make_icon.swift <in.png> <out.png> [size]\n".data(using: .utf8)!)
  exit(2)
}
let inURL = URL(fileURLWithPath: argv[1])
let outURL = URL(fileURLWithPath: argv[2])
let outSize = argv.count >= 4 ? (Int(argv[3]) ?? 1024) : 1024

guard let src = CGImageSourceCreateWithURL(inURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
  FileHandle.standardError.write("读不到输入图: \(inURL.path)\n".data(using: .utf8)!)
  exit(1)
}

let w = image.width, h = image.height
let bytesPerRow = w * 4
var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
guard let ctx = CGContext(
  data: &pixels, width: w, height: h, bitsPerComponent: 8,
  bytesPerRow: bytesPerRow,
  space: CGColorSpaceCreateDeviceRGB(),
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }
ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

// 1) 找非白内容的包围盒；底部 8% 视为水印区不参与（生成图右下角有「AI 生成」字样）。
let watermarkBand = Int(Double(h) * 0.08)
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<(h - watermarkBand) {
  for x in 0..<w {
    let i = y * bytesPerRow + x * 4
    let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
    if r < 244 || g < 244 || b < 244 {
      if x < minX { minX = x }
      if x > maxX { maxX = x }
      if y < minY { minY = y }
      if y > maxY { maxY = y }
    }
  }
}
if maxX <= minX || maxY <= minY {
  FileHandle.standardError.write("没找到内容，输入图可能全白\n".data(using: .utf8)!)
  exit(1)
}
// 2) 内缩几个像素，避开圆角外的投影。
let inset = max(2, Int(Double(w) * 0.006))
let box = CGRect(
  x: minX + inset, y: minY + inset,
  width: maxX - minX - inset * 2, height: maxY - minY - inset * 2)
guard let content = image.cropping(to: box) else { exit(1) }

// 3) 画到目标画布，用圆角矩形做遮罩（macOS Big Sur 风格 ~22%）。
let size = outSize
let side = CGFloat(size)
guard let out = CGContext(
  data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
  space: CGColorSpaceCreateDeviceRGB(),
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }
out.clear(CGRect(x: 0, y: 0, width: side, height: side))
let radius = side * 0.222
let rect = CGRect(x: 0, y: 0, width: side, height: side)
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
out.addPath(path)
out.clip()
out.interpolationQuality = .high
// 内容铺满画布（保持比例：外接框已是圆的图案，接近正方形，轻微拉伸不被察觉）。
out.draw(content, in: rect)

guard let outImage = out.makeImage() else { exit(1) }
guard let dest = CGImageDestinationCreateWithURL(
  outURL as CFURL, UTType.png.identifier as CFString, 1, nil
) else { exit(1) }
CGImageDestinationAddImage(dest, outImage, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
print("icon: \(outURL.path) (\(size)x\(size), 内容框 \(Int(box.width))x\(Int(box.height)))")
