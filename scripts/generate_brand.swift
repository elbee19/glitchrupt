#!/usr/bin/swift
import AppKit
import Foundation

// All SVG and bitmap assets share these editable vector primitives.
struct Ink { let hex: String; let alpha: CGFloat
    init(_ hex: String, _ alpha: CGFloat = 1) { self.hex=hex; self.alpha=alpha }
    var color: NSColor { let value=Int(hex,radix:16)!; return NSColor(calibratedRed:CGFloat((value>>16)&255)/255,green:CGFloat((value>>8)&255)/255,blue:CGFloat(value&255)/255,alpha:alpha) }
}
let paper=Ink("F5F0E7"), black=Ink("181817"), cyan=Ink("00C9DB"), pink=Ink("F23879")
struct Shape { var points:[CGPoint]; var ink:Ink }
func poly(_ p:[(CGFloat,CGFloat)],_ ink:Ink)->Shape { Shape(points:p.map{CGPoint(x:$0.0,y:$0.1)},ink:ink) }
func rect(_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat,_ ink:Ink)->Shape { poly([(x,y),(x+w,y),(x+w,y+h),(x,y+h)],ink) }
func moved(_ s:Shape,_ x:CGFloat,_ y:CGFloat,_ scale:CGFloat=1)->Shape { Shape(points:s.points.map{CGPoint(x:$0.x*scale+x,y:$0.y*scale+y)},ink:s.ink) }
func recolored(_ s:Shape,_ ink:Ink)->Shape { Shape(points:s.points,ink:ink) }
func line(_ a:CGPoint,_ b:CGPoint,_ width:CGFloat,_ ink:Ink)->Shape { let dx=b.x-a.x,dy=b.y-a.y,l=hypot(dx,dy),nx = -dy/l*width/2,ny=dx/l*width/2; return poly([(a.x+nx,a.y+ny),(b.x+nx,b.y+ny),(b.x-nx,b.y-ny),(a.x-nx,a.y-ny)],ink) }
// A standalone electrical jolt with an exclamation dot: a quick poke for attention.
func glyph(_ ink:Ink)->[Shape] {
    [poly([(205,63),(305,63),(246,177),(313,177),(151,335),(185,227),(120,227)],ink),
     poly([(161,348),(198,348),(190,385),(153,385)],ink)]
}
func iconShapes(menu:Bool=false)->[Shape] {
    if menu { return glyph(black) }
    var s=[rect(0,0,432,432,paper)]
    // Registration swatches and cropped printer's marks give the icon a print texture.
    s += [rect(26,35,40,5,cyan),rect(31,30,5,15,cyan),rect(365,389,40,5,pink),rect(384,383,5,17,pink)]
    s += glyph(cyan).map{moved($0,-8,1)}
    s += glyph(pink).map{moved($0,8,-3)}
    s += glyph(black)
    // A clean, displaced slice interrupts the whole mark at its midpoint.
    s += [poly([(45,225),(393,225),(393,233),(45,233)],paper)]
    s += [rect(67,226,69,4,cyan),rect(285,226,68,4,pink)]
    return s
}
func letter(_ c:Character)->(CGFloat,[Shape]) {
    let t:CGFloat=14,h:CGFloat=88,w:CGFloat=60
    var s:[Shape]=[]; var width=w
    func r(_ x:CGFloat,_ y:CGFloat,_ a:CGFloat,_ b:CGFloat){s.append(rect(x,y,a,b,black))}
    switch c {
    case "G": r(0,0,w,t);r(0,0,t,h);r(0,h-t,w,t);r(w-t,42,t,h-42);r(32,42,28,t)
    case "L": width=52;r(0,0,t,h);r(0,h-t,width,t)
    case "I": width=22;r(3,0,16,h)
    case "T": r(0,0,w,t);r(23,0,t,h)
    case "C": r(0,0,w,t);r(0,0,t,h);r(0,h-t,w,t)
    case "H": r(0,0,t,h);r(w-t,0,t,h);r(0,37,w,t)
    case "R": r(0,0,t,h);r(0,0,w,t);r(w-t,0,t,49);r(0,37,w,t);s.append(poly([(28,45),(44,45),(64,88),(47,88)],black))
    case "U": r(0,0,t,h);r(w-t,0,t,h);r(0,h-t,w,t)
    case "P": r(0,0,t,h);r(0,0,w,t);r(w-t,0,t,50);r(0,37,w,t)
    default: break
    }
    return (width,s)
}
func logoShapes()->[Shape] {
    var s=[rect(0,0,1600,460,paper)]
    s += iconShapes().dropFirst().map{moved($0,18,14,1)}
    var word:[Shape]=[],x:CGFloat=0
    for c in "GLITCHRUPT" { let(w,forms)=letter(c); word += forms.map{moved($0,x,0)};x += w+13 }
    // A slight shear is constructed in geometry, so it survives every renderer.
    word=word.map{shape in Shape(points:shape.points.map{CGPoint(x:$0.x+(88-$0.y)*0.10,y:$0.y)},ink:shape.ink)}
    let scale:CGFloat=1.53
    let placed=word.map{moved($0,482,165,scale)}
    s += placed.map{moved(recolored($0,cyan),-5,3)}
    s += placed.map{moved(recolored($0,pink),5,-2)}
    s += placed
    // The word and icon share one interrupted scanline.
    s += [rect(471,223,1065,5,paper),rect(482,226,97,3,cyan),rect(1321,218,215,4,pink)]
    // Underline is a torn, interrupted thread rather than a decorative tagline.
    s += [poly([(486,325),(1110,325),(1103,333),(485,333)],black),rect(1125,325,160,8,cyan),poly([(1301,325),(1508,325),(1493,333),(1301,333)],pink)]
    return s
}
func svg(_ shapes:[Shape],_ w:Int,_ h:Int)->String {
    let body=shapes.filter{$0.ink.alpha>0}.map { shape in
        let pts=shape.points.map{String(format:"%.3f,%.3f",Double($0.x),Double($0.y))}.joined(separator:" ")
        return "  <polygon points=\"\(pts)\" fill=\"#\(shape.ink.hex)\"/>"
    }.joined(separator:"\n")
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(w) \(h)" role="img" aria-label="Glitchrupt">
    <!-- Original editable geometry. Regenerate with scripts/generate_brand.swift. -->
    \(body)
    </svg>
    """
}
func png(_ shapes:[Shape],_ w:Int,_ h:Int,_ output:URL,_ canvas:CGSize?=nil)throws {
    let logical=canvas ?? CGSize(width:w,height:h)
    let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:w,pixelsHigh:h,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    let context=NSGraphicsContext(bitmapImageRep:rep)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
    let cg=context.cgContext;cg.setAllowsAntialiasing(true);cg.setShouldAntialias(true)
    cg.scaleBy(x:CGFloat(w)/logical.width,y:CGFloat(h)/logical.height)
    cg.translateBy(x:0,y:logical.height);cg.scaleBy(x:1,y:-1)
    for shape in shapes { guard let first=shape.points.first else{continue};cg.beginPath();cg.move(to:first);for p in shape.points.dropFirst(){cg.addLine(to:p)};cg.closePath()
        if shape.ink.alpha==0 {cg.setBlendMode(.clear);cg.fillPath();cg.setBlendMode(.normal)} else {cg.setFillColor(shape.ink.color.cgColor);cg.fillPath()}
    }
    context.flushGraphics();NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using:.png,properties:[:])!.write(to:output)
}
let out=URL(fileURLWithPath:CommandLine.arguments.dropFirst().first ?? "assets/brand",isDirectory:true)
let fm=FileManager.default
try fm.createDirectory(at:out,withIntermediateDirectories:true)
try svg(iconShapes(),432,432).write(to:out.appendingPathComponent("icon.svg"),atomically:true,encoding:.utf8)
try svg(logoShapes(),1600,460).write(to:out.appendingPathComponent("logo.svg"),atomically:true,encoding:.utf8)
try png(iconShapes(),1024,1024,out.appendingPathComponent("icon.png"),CGSize(width:432,height:432))
try png(logoShapes(),1600,460,out.appendingPathComponent("logo.png"))
// App icons use the same mark on a rounded paper tile, with transparent outer padding.
var appShapes=iconShapes().map{moved($0,40,40,CGFloat(944)/432)}
var corners:[CGPoint]=[]
let radius:CGFloat=184
for (cx,cy,start) in [(CGFloat(40)+radius,CGFloat(40)+radius,CGFloat(180)),(CGFloat(984)-radius,CGFloat(40)+radius,CGFloat(270)),(CGFloat(984)-radius,CGFloat(984)-radius,CGFloat(0)),(CGFloat(40)+radius,CGFloat(984)-radius,CGFloat(90))] {
    for step in 0...18 { let a=(start+CGFloat(step)*5)*CGFloat.pi/180;corners.append(CGPoint(x:cx+cos(a)*radius,y:cy+sin(a)*radius)) }
}
appShapes[0]=Shape(points:corners,ink:paper)
// Menu glyph has no colored field, so AppKit can use it as a monochrome template.
let menu=glyph(black)
try png(menu,36,36,out.appendingPathComponent("MenuIcon.png"),CGSize(width:432,height:432))
let iconset=out.appendingPathComponent("Glitchrupt.iconset",isDirectory:true)
try fm.createDirectory(at:iconset,withIntermediateDirectories:true)
for n in [16,32,128,256,512] {
    try png(appShapes,n,n,iconset.appendingPathComponent("icon_\(n)x\(n).png"),CGSize(width:1024,height:1024))
    try png(appShapes,n*2,n*2,iconset.appendingPathComponent("icon_\(n)x\(n)@2x.png"),CGSize(width:1024,height:1024))
}
let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/iconutil");p.arguments=["-c","icns",iconset.path,"-o",out.appendingPathComponent("AppIcon.icns").path];try p.run();p.waitUntilExit();guard p.terminationStatus==0 else{fatalError("iconutil failed")}
try fm.removeItem(at:iconset)
print("Generated Glitchrupt SVG, PNG, menu template, and app icon in \(out.path)")
