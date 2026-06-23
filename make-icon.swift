// 把方形图案重排成符合苹果规范的圆角图标：
// 1024 画布中，圆角方块本体 824×824（四周留 100px 透明边距），圆角半径按苹果比例，角外透明。
//
// 源图为根目录 icon.png（满边方形设计），输出覆盖打包用的 Assets/AppIcon.png：
//     swift make-icon.swift icon.png Assets/AppIcon.png
//
// 通用用法： swift make-icon.swift <输入png> <输出png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("用法: swift make-icon.swift <输入png> <输出png>\n".data(using: .utf8)!)
    exit(1)
}
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

guard let src = NSImage(contentsOf: inURL),
      let srcCG = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("无法读取输入图片\n".data(using: .utf8)!)
    exit(1)
}

let canvas: CGFloat = 1024
let body: CGFloat = 824                 // 苹果规范：圆角方块本体边长
let margin = (canvas - body) / 2        // 四周留白 100
let radius: CGFloat = body * 0.2237     // 苹果超椭圆近似的圆角半径 ≈ 184

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas),
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write("无法创建画布\n".data(using: .utf8)!)
    exit(1)
}
ctx.interpolationQuality = .high
ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))   // 透明背景

// 圆角方块裁剪路径
let bodyRect = CGRect(x: margin, y: margin, width: body, height: body)
let path = CGPath(roundedRect: bodyRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.addPath(path)
ctx.clip()

// 原图案白色 squircle 外还有一圈浅灰背景；把图案放大、让白色本体正好填满圆角框，
// 多出来的灰边落到裁剪框外被切掉，避免“双层圆角”。
let overscan: CGFloat = 52
let drawRect = bodyRect.insetBy(dx: -overscan, dy: -overscan)
ctx.draw(srcCG, in: drawRect)

guard let out = ctx.makeImage() else {
    FileHandle.standardError.write("无法生成图像\n".data(using: .utf8)!)
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: out)
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("无法编码 PNG\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: outURL)
print("已生成: \(outURL.path)")
