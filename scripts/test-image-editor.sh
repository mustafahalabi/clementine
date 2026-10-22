#!/usr/bin/env bash
# The engines behind the interactive image editors (Crop, Redact, Annotate), driven headlessly with the JSON the
# editor windows produce: geometry and rotation, pixels inside/outside redaction boxes, drawn marks, bad input.
set -uo pipefail
cd "$(dirname "$0")/.."

swift build -q || exit 1
BIN="$(swift build --show-bin-path)/Clementine"
source scripts/test-lib.sh
test_setup editor
q() { ffmpeg -loglevel error -y "$@"; }

# ---------------------------------------------------------------- helper (fixtures and pixel checks, via ImageIO)
cat > "$WORK/h.swift" <<'SWIFT'
import AppKit; import ImageIO; import CoreGraphics
let args = CommandLine.arguments
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }
func context(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func load(_ path: String) -> CGContext {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("unreadable \(path)") }
    let c = context(img.width, img.height)
    c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return c
}
func save(_ c: CGContext, _ path: String) {
    let type = path.hasSuffix(".jpg") ? "public.jpeg" : "public.png"
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, type as CFString, 1, nil)!
    CGImageDestinationAddImage(d, c.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
    guard CGImageDestinationFinalize(d) else { fail("finalize \(path)") }
}
/// Fills a rect given with a top-left origin.
func fill(_ c: CGContext, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
    c.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
    c.fill(CGRect(x: x, y: c.height - y - h, width: w, height: h))
}
func pixel(_ c: CGContext, _ x: Int, _ y: Int) -> [Int] {
    let d = c.data!.assumingMemoryBound(to: UInt8.self), o = y * c.bytesPerRow + x * 4
    return (0..<4).map { Int(d[o + $0]) }
}
switch args[1] {
case "quad": // 200×100: red | green over blue | white
    let c = context(200, 100)
    fill(c, 0, 0, 100, 50, 1, 0, 0); fill(c, 100, 0, 100, 50, 0, 1, 0)
    fill(c, 0, 50, 100, 50, 0, 0, 1); fill(c, 100, 50, 100, 50, 1, 1, 1)
    save(c, args[2])
case "stripes": // 300×200 one-pixel black/white columns
    let c = context(300, 200)
    fill(c, 0, 0, 300, 200, 1, 1, 1)
    for x in stride(from: 0, to: 300, by: 2) { fill(c, x, 0, 1, 200, 0, 0, 0) }
    save(c, args[2])
case "text": // a white page with two lines of large text in the top half
    let c = context(900, 500)
    fill(c, 0, 0, 900, 500, 1, 1, 1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 54, weight: .medium), .foregroundColor: NSColor.black]
    NSAttributedString(string: "Account 4815 1623 4200", attributes: attrs).draw(at: CGPoint(x: 40, y: 400))
    NSAttributedString(string: "Jane Appleseed", attributes: attrs).draw(at: CGPoint(x: 40, y: 310))
    save(c, args[2])
case "pix": // pix file x y → r g b a (top-left origin)
    print(pixel(load(args[2]), Int(args[3])!, Int(args[4])!).map(String.init).joined(separator: " "))
case "diff": // diff a b x y w h → mean absolute RGB difference in the rect (same-sized images)
    let a = load(args[2]), b = load(args[3])
    guard a.width == b.width, a.height == b.height else { fail("size mismatch") }
    let x0 = Int(args[4])!, y0 = Int(args[5])!, w = Int(args[6])!, h = Int(args[7])!
    var total = 0
    for y in y0..<(y0 + h) { for x in x0..<(x0 + w) {
        let p = pixel(a, x, y), r = pixel(b, x, y); total += (0..<3).map { abs(p[$0] - r[$0]) }.reduce(0, +)
    } }
    print(String(format: "%.2f", Double(total) / Double(w * h * 3)))
case "spread": // spread file x y w h → max-min of red across the rect (how much detail survives)
    let c = load(args[2])
    var lo = 255, hi = 0
    for y in Int(args[4])!..<(Int(args[4])! + Int(args[6])!) { for x in Int(args[3])!..<(Int(args[3])! + Int(args[5])!) {
        let r = pixel(c, x, y)[0]; lo = min(lo, r); hi = max(hi, r)
    } }
    print(hi - lo)
case "frames":
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil)!
    print(CGImageSourceGetCount(src))
default: fail("unknown command")
}
SWIFT
swiftc -O -o "$WORK/h" "$WORK/h.swift" 2>/dev/null || { echo "helper failed to build"; exit 1; }
H="$WORK/h"

echo "Fixtures in $F"
"$H" quad "$F/quad.png"
"$H" stripes "$F/stripes.png"
"$H" text "$F/text.png"
cp "$F/quad.png" "$F/alpha quad.png"
q -f lavfi -i testsrc=size=640x480 -frames:v 1 -q:v 2 "$F/photo.jpg"
# Cut Out Subject: an orange ball (on an olive square) over a blue backdrop, which Vision lifts as a subject; and
# an evenly gray frame with nothing to lift.
q -f lavfi -i "color=c=0x3a6ea5:s=640x480,format=rgb24" -frames:v 1 \
  -vf "drawbox=x=220:y=140:w=200:h=200:color=0xffb000:t=fill,geq=r='if(lt(hypot(X-320\,Y-240)\,110)\,255\,r(X\,Y)*0.3+40)':g='if(lt(hypot(X-320\,Y-240)\,110)\,140\,g(X\,Y)*0.3+60)':b='if(lt(hypot(X-320\,Y-240)\,110)\,20\,b(X\,Y)*0.3+90)'" \
  "$F/ball.png"
q -i "$F/ball.png" -q:v 2 "$F/ball.jpg"
q -f lavfi -i "color=c=gray:s=640x480" -frames:v 1 "$F/plain.png"
q -f lavfi -i testsrc=size=200x150:rate=10 -t 1 "$F/anim.gif"
# JPEG with EXIF orientation 6: stored 400×200, shown upright as 200×400.
cat > "$WORK/exif.swift" <<'SWIFT'
import Foundation; import ImageIO
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil)!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL, "public.jpeg" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, CGImageSourceCreateImageAtIndex(src, 0, nil)!, [kCGImagePropertyOrientation: 6] as CFDictionary)
CGImageDestinationFinalize(dest)
SWIFT
q -f lavfi -i testsrc=size=400x200 -frames:v 1 "$WORK/wide.png"
swift "$WORK/exif.swift" "$WORK/wide.png" "$F/oriented.jpg"

pass=0; fail=0; failures=()
ok() { pass=$((pass + 1)); printf '  ✓ %s\n' "$1"; }
bad() { fail=$((fail + 1)); failures+=("$1"); printf '  ✗ %s — %s\n' "$1" "$2"; }

# expect <name> <assertion-command…> -- <action args…>: action must succeed and the assertion (given $OUT) must pass.
expect() {
  local name="$1"; shift
  local check=(); while [[ "$1" != "--" ]]; do check+=("$1"); shift; done; shift
  local out
  if ! out="$("$BIN" --run "$@" 2>&1)"; then bad "$name" "$out"; return; fi
  OUT="$(echo "$out" | head -1)"
  if eval "${check[*]}"; then ok "$name"; else bad "$name" "assertion failed: ${check[*]} (output: $OUT)"; fi
}
# expect_error <name> <substring> -- <action args…>: action must fail with a readable message containing substring.
expect_error() {
  local name="$1" needle="$2"; shift 3
  local out
  if out="$("$BIN" --run "$@" 2>&1)"; then bad "$name" "succeeded but should fail: $out"; return; fi
  if [[ "$out" == *"$needle"* ]]; then ok "$name"; else bad "$name" "unexpected message: $out"; fi
}
dims() { sips -g pixelWidth -g pixelHeight "$1" | awk '/pixel/{printf "%s ", $2}' | sed 's/ $//'; }
pix() { "$H" pix "$@"; }
rgb() { pix "$@" | cut -d" " -f1-3; }
# Same-sized images: mean difference in a rect is (at most / at least) a value.
same() { [[ "$("$H" diff "$@")" == "0.00" ]]; }
changed() { awk -v d="$("$H" diff "$1" "$2" "$3" "$4" "$5" "$6")" -v t="${7:-5}" 'BEGIN{exit !(d>=t)}'; }
between() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN{exit !(v>=lo && v<=hi)}'; }
list() { "$BIN" --list "$@" | sed -n '/Tools/,$p'; }

echo "Crop"
expect "rect sets the size" '[[ "$(dims "$OUT")" == "100 50" && "$OUT" == *"(cropped).png" ]]' -- tool.image.crop --set 'crop={"x":10,"y":20,"w":100,"h":50}' "$F/quad.png"
expect "rect is top-left based" '[[ "$(rgb "$OUT" 50 25)" == "0 255 0" ]]' -- tool.image.crop --set 'crop={"x":100,"y":0,"w":100,"h":50}' "$F/quad.png"
expect "bottom-right quadrant" '[[ "$(rgb "$OUT" 10 10)" == "255 255 255" ]]' -- tool.image.crop --set 'crop={"x":100,"y":50,"w":100,"h":50}' "$F/quad.png"
expect "fractional values round" '[[ "$(dims "$OUT")" == "100 50" ]]' -- tool.image.crop --set 'crop={"x":0.4,"y":0.4,"w":99.6,"h":49.6}' "$F/quad.png"
expect "rect past the edge is clipped" '[[ "$(dims "$OUT")" == "50 50" ]]' -- tool.image.crop --set 'crop={"x":150,"y":50,"w":500,"h":500}' "$F/quad.png"
expect "rotate 90 alone turns clockwise" '[[ "$(dims "$OUT")" == "100 200" && "$(rgb "$OUT" 5 5)" == "0 0 255" && "$OUT" == *"(rotated).png" ]]' -- tool.image.crop --set 'crop={"rotate":90}' "$F/quad.png"
expect "rotate 270 turns counterclockwise" '[[ "$(rgb "$OUT" 5 5)" == "0 255 0" ]]' -- tool.image.crop --set 'crop={"rotate":270}' "$F/quad.png"
expect "rotate -90 equals 270" '[[ "$(rgb "$OUT" 5 5)" == "0 255 0" ]]' -- tool.image.crop --set 'crop={"rotate":-90}' "$F/quad.png"
expect "rotate 180" '[[ "$(dims "$OUT")" == "200 100" && "$(rgb "$OUT" 5 5)" == "255 255 255" ]]' -- tool.image.crop --set 'crop={"rotate":180}' "$F/quad.png"
expect "rect is in the turned image" '[[ "$(dims "$OUT")" == "50 100" && "$(rgb "$OUT" 25 50)" == "0 0 255" ]]' -- tool.image.crop --set 'crop={"rotate":90,"x":0,"y":0,"w":50,"h":100}' "$F/quad.png"
expect "EXIF-rotated photo uses upright pixels" '[[ "$(dims "$OUT")" == "200 100" ]]' -- tool.image.crop --set 'crop={"x":0,"y":300,"w":200,"h":100}' "$F/oriented.jpg"
expect "jpg stays jpg" '[[ "$OUT" == *.jpg && "$(dims "$OUT")" == "320 240" ]]' -- tool.image.crop --set 'crop={"x":0,"y":0,"w":320,"h":240}' "$F/photo.jpg"
expect "animated gif stays animated" '[[ "$("$H" frames "$OUT")" -gt 1 && "$(dims "$OUT")" == "100 100" ]]' -- tool.image.crop --set 'crop={"x":50,"y":25,"w":100,"h":100}' "$F/anim.gif"
expect "no rect falls back to the aspect preset" '[[ "$(dims "$OUT")" == "100 100" ]]' -- tool.image.crop --set aspect=0 "$F/quad.png"
expect_error "rect outside the image" "outside" -- tool.image.crop --set 'crop={"x":500,"y":500,"w":10,"h":10}' "$F/quad.png"
expect_error "negative size" "positive" -- tool.image.crop --set 'crop={"x":0,"y":0,"w":-10,"h":10}' "$F/quad.png"
expect_error "odd rotation" "multiple of 90" -- tool.image.crop --set 'crop={"rotate":45}' "$F/quad.png"
expect_error "invalid JSON" "Expected JSON" -- tool.image.crop --set 'crop={x:1' "$F/quad.png"
expect_error "wrong JSON shape" "crop settings" -- tool.image.crop --set 'crop=[1,2,3]' "$F/quad.png"

echo "Redact"
BOX='boxes=[{"x":20,"y":20,"w":120,"h":80}]'
expect "black fills the box" '[[ "$(rgb "$OUT" 25 25)" == "0 0 0" && "$(rgb "$OUT" 139 99)" == "0 0 0" && "$OUT" == *"(redacted).png" ]]' -- tool.image.redact --set "$BOX" --set style=black "$F/stripes.png"
expect "black leaves the rest alone" 'same "$OUT" "$F/stripes.png" 150 0 150 200 && same "$OUT" "$F/stripes.png" 0 110 300 90' -- tool.image.redact --set "$BOX" --set style=black "$F/stripes.png"
expect "pixelate flattens detail" '(( $("$H" spread "$OUT" 30 30 10 10) < 40 )) && between "$(pix "$OUT" 50 50 | cut -d" " -f1)" 100 160' -- tool.image.redact --set "$BOX" --set style=pixelate "$F/stripes.png"
expect "pixelate leaves the rest alone" 'same "$OUT" "$F/stripes.png" 150 0 150 200 && same "$OUT" "$F/stripes.png" 0 110 300 90' -- tool.image.redact --set "$BOX" "$F/stripes.png"
expect "blur flattens detail" '(( $("$H" spread "$OUT" 30 30 100 60) < 60 )) && between "$(pix "$OUT" 80 60 | cut -d" " -f1)" 90 170' -- tool.image.redact --set "$BOX" --set style=blur "$F/stripes.png"
expect "blur leaves the rest alone" 'same "$OUT" "$F/stripes.png" 150 0 150 200 && same "$OUT" "$F/stripes.png" 0 110 300 90' -- tool.image.redact --set "$BOX" --set style=blur "$F/stripes.png"
expect "blur reaches the box edges" 'between "$(pix "$OUT" 20 20 | cut -d" " -f1)" 60 200 && [[ "$(pix "$OUT" 20 20 | cut -d" " -f4)" == 255 ]]' -- tool.image.redact --set "$BOX" --set style=blur "$F/stripes.png"
expect "several boxes" '[[ "$(rgb "$OUT" 5 5)" == "0 0 0" && "$(rgb "$OUT" 295 195)" == "0 0 0" ]] && same "$OUT" "$F/stripes.png" 100 80 100 40' -- tool.image.redact --set 'boxes=[{"x":0,"y":0,"w":10,"h":10},{"x":290,"y":190,"w":50,"h":50}]' --set style=2 "$F/stripes.png"
expect "jpg keeps format" '[[ "$OUT" == *.jpg && "$(dims "$OUT")" == "640 480" ]]' -- tool.image.redact --set 'boxes=[{"x":100,"y":100,"w":200,"h":100}]' "$F/photo.jpg"
expect "animated gif stays animated" '[[ "$("$H" frames "$OUT")" -gt 1 ]]' -- tool.image.redact --set 'boxes=[{"x":10,"y":10,"w":80,"h":60}]' "$F/anim.gif"
expect "auto finds and covers text" 'changed "$OUT" "$F/text.png" 40 30 600 60 10 && same "$OUT" "$F/text.png" 0 300 900 200' -- tool.image.redact --set boxes=auto --set style=black "$F/text.png"
expect_error "auto with nothing found" "Nothing to redact" -- tool.image.redact --set boxes=auto "$F/quad.png"
expect_error "no boxes" "Nothing to redact" -- tool.image.redact --set 'boxes=[]' "$F/stripes.png"
expect_error "default (no boxes given)" "Expected JSON" -- tool.image.redact "$F/stripes.png"
expect_error "invalid JSON" "Expected JSON" -- tool.image.redact --set 'boxes={"x":1}' "$F/stripes.png"
expect_error "zero-size box" "positive" -- tool.image.redact --set 'boxes=[{"x":1,"y":1,"w":0,"h":5}]' "$F/stripes.png"
expect_error "box outside the image" "outside" -- tool.image.redact --set 'boxes=[{"x":900,"y":900,"w":10,"h":10}]' "$F/stripes.png"

echo "Annotate"
ARROW='shapes=[{"kind":"arrow","points":[[20,150],[250,40]],"color":"#E5484D","width":8}]'
expect "arrow draws along its path" 'changed "$OUT" "$F/stripes.png" 120 85 20 20 20 && [[ "$OUT" == *"(annotated).png" ]]' -- tool.image.annotate --set "$ARROW" "$F/stripes.png"
expect "arrow leaves the rest alone" 'same "$OUT" "$F/stripes.png" 0 0 100 60 && same "$OUT" "$F/stripes.png" 150 120 150 80' -- tool.image.annotate --set "$ARROW" "$F/stripes.png"
expect "rectangle outline, hollow middle" '[[ "$(rgb "$OUT" 50 20)" == "0 0 255" ]] && same "$OUT" "$F/quad.png" 70 40 60 20' -- tool.image.annotate --set 'shapes=[{"kind":"rectangle","points":[[20,20],[180,80]],"color":"#0000FF","width":6}]' "$F/quad.png"
expect "ellipse" 'changed "$OUT" "$F/quad.png" 95 15 10 10 20 && same "$OUT" "$F/quad.png" 0 0 10 10' -- tool.image.annotate --set 'shapes=[{"kind":"ellipse","points":[[20,20],[180,80]],"color":"#000000","width":6}]' "$F/quad.png"
expect "pen and highlighter" 'changed "$OUT" "$F/text.png" 100 440 300 30 3' -- tool.image.annotate --set 'shapes=[{"kind":"pen","points":[[100,450],[200,460],[300,450],[400,460]],"color":"#34C77B","width":10},{"kind":"highlighter","points":[[40,90],[700,90]],"color":"#FFD43B","width":12}]' "$F/text.png"
expect "highlighter is translucent" '(( $(pix "$OUT" 50 470 | cut -d" " -f3) > 60 ))' -- tool.image.annotate --set 'shapes=[{"kind":"highlighter","points":[[20,470],[700,470]],"color":"#FFD43B","width":10}]' "$F/text.png"
expect "text" 'changed "$OUT" "$F/text.png" 300 300 400 80 5 && same "$OUT" "$F/text.png" 0 0 200 200' -- tool.image.annotate --set 'shapes=[{"kind":"text","points":[[300,300]],"text":"Look here","color":"#FF5E3A","width":60}]' "$F/text.png"
expect "defaults for color and width" '[[ -f "$OUT" ]]' -- tool.image.annotate --set 'shapes=[{"kind":"arrow","points":[[0,0],[100,100]]}]' "$F/photo.jpg"
expect "jpg keeps format" '[[ "$OUT" == *.jpg && "$(dims "$OUT")" == "640 480" ]]' -- tool.image.annotate --set "$ARROW" "$F/photo.jpg"
expect "EXIF-rotated photo keeps upright size" '[[ "$(dims "$OUT")" == "200 400" ]]' -- tool.image.annotate --set "$ARROW" "$F/oriented.jpg"
expect_error "no shapes" "no annotations" -- tool.image.annotate --set 'shapes=[]' "$F/quad.png"
expect_error "invalid JSON" "Expected JSON" -- tool.image.annotate --set 'shapes=[{"kind":"arrow",' "$F/quad.png"
expect_error "unknown kind" "Expected JSON" -- tool.image.annotate --set 'shapes=[{"kind":"star","points":[[1,1]]}]' "$F/quad.png"
expect_error "arrow with one point" "at least 2 points" -- tool.image.annotate --set 'shapes=[{"kind":"arrow","points":[[1,1]]}]' "$F/quad.png"
expect_error "bad color" "#RRGGBB" -- tool.image.annotate --set 'shapes=[{"kind":"pen","points":[[1,1]],"color":"orange"}]' "$F/quad.png"
expect_error "empty text" "needs some text" -- tool.image.annotate --set 'shapes=[{"kind":"text","points":[[1,1]],"text":""}]' "$F/quad.png"

echo "Cut Out Subject"
alpha() { pix "$@" | cut -d" " -f4; }
# Vision's subject model may be unavailable on CI's virtual Macs (no Neural Engine/GPU); skip there, never locally.
if probe="$("$BIN" --run tool.image.removebg "$F/ball.png" 2>&1)"; then vision=1; else vision=""; fi
if [[ -z "$vision" && -n "${GITHUB_ACTIONS:-}${CI:-}" ]]; then
  echo "  SKIP Vision subject lifting is unavailable on this machine: $probe"
else
  [[ -n "$vision" ]] || bad "subject lifting runs" "$probe"
  expect "PNG: same size, background clear, subject kept" \
    '[[ "$OUT" == *"ball (cut out)"*.png && "$(dims "$OUT")" == "640 480" && "$(alpha "$OUT" 5 5)" == 0 && "$(alpha "$OUT" 630 470)" == 0 && "$(pix "$OUT" 320 240)" == "255 140 20 255" ]]' \
    -- tool.image.removebg "$F/ball.png"
  expect "crop to subject hugs it" \
    'read -r w h <<<"$(dims "$OUT")"; between "$w" 200 240 && between "$h" 200 240 && [[ "$(alpha "$OUT" $((w / 2)) $((h / 2)))" == 255 ]]' \
    -- tool.image.removebg --set crop=On "$F/ball.png"
  expect "HEIC keeps transparency" \
    '[[ "$OUT" == *.heic && "$(alpha "$OUT" 5 5)" == 0 && "$(alpha "$OUT" 320 240)" -ge 250 ]]' \
    -- tool.image.removebg --set format=HEIC "$F/ball.jpg"
  expect "WebP keeps transparency" \
    '[[ "$OUT" == *.webp && "$(alpha "$OUT" 5 5)" == 0 && "$(alpha "$OUT" 320 240)" -ge 250 ]]' \
    -- tool.image.removebg --set format=webp "$F/ball.png"
fi
expect_error "nothing to lift" "No subject found in plain.png" -- tool.image.removebg "$F/plain.png"
expect_error "bad format" "not a valid choice" -- tool.image.removebg --set format=jpg "$F/ball.png"
if "$BIN" --list "$F/ball.png" | grep -q "^  tool.image.removebg  *Cut Out Subject$"; then
  ok "offered on the Tools wheel for images"
else bad "offered on the Tools wheel" "$("$BIN" --list "$F/ball.png")"; fi

echo "Shortcuts (the runner behind the App Intents)"
# shortcut <name> <assertion> -- <action-id> [--set k=v]… <files…>, like expect but through ShortcutRunner.
shortcut() {
  local name="$1"; shift
  local check=(); while [[ "$1" != "--" ]]; do check+=("$1"); shift; done; shift
  local out
  if ! out="$("$BIN" --shortcut-run "$@" 2>&1)"; then bad "$name" "$out"; return; fi
  OUT="$out"
  if eval "${check[*]}"; then ok "$name"; else bad "$name" "assertion failed: ${check[*]} (output: $OUT)"; fi
}
shortcut_error() {
  local name="$1" needle="$2"; shift 3
  local out
  if out="$("$BIN" --shortcut-run "$@" 2>&1)"; then bad "$name" "succeeded but should fail: $out"; return; fi
  if [[ "$out" == *"$needle"* ]]; then ok "$name"; else bad "$name" "unexpected message: $out"; fi
}
shortcut "converts a batch, outputs in input order" \
  '[[ "$(wc -l <<<"$OUT" | tr -d " ")" == 2 && "$(sed -n 1p <<<"$OUT")" == *"/quad.jpg" && "$(sed -n 2p <<<"$OUT")" == *"/stripes.jpg" ]]' \
  -- convert.image.jpeg "$F/quad.png" "$F/stripes.png"
shortcut "settings are key=value lines" '[[ "$(dims "$OUT")" == "100 50" ]]' -- tool.image.resize --set "size=50%" "$F/quad.png"
shortcut "text results come back" '[[ "$OUT" == "== quad.png =="* ]]' -- tool.image.qr "$F/quad.png"
if [[ -n "$vision" ]]; then
  shortcut "Remove Background's settings" '[[ "$OUT" == *.webp ]]' -- tool.image.removebg --set format=webp --set crop=On "$F/ball.png"
fi
shortcut_error "unknown setting" 'has no setting "level"' -- tool.image.resize --set level=1 "$F/quad.png"
shortcut_error "bad value" "not a valid choice" -- tool.image.resize --set size=huge "$F/quad.png"
shortcut_error "action that doesn't fit the file" "Convert to PDF doesn't work on quad.png" -- convert.document.pdf "$F/quad.png"
shortcut_error "too few files" "needs at least 2 files" -- tool.image.collage "$F/quad.png"
shortcut_error "one-file editor" "one file at a time" -- tool.image.redact "$F/quad.png" "$F/stripes.png"
shortcut_error "unknown action" 'no action "nope"' -- nope "$F/quad.png"

echo "Wheel"
LIST="$(list "$F/photo.jpg")"
if [[ $(grep -c '^  tool' <<<"$LIST") -eq 13 ]] && grep -q tool.image.redact <<<"$LIST" && grep -q tool.image.annotate <<<"$LIST" \
   && grep -q tool.metadata.strip <<<"$LIST" && grep -q tool.image.removebg <<<"$LIST"; then
  ok "one image: 13 tools incl. Redact, Annotate, Cut Out Subject, Remove Metadata"
else bad "one image: 13 tools" "$LIST"; fi
LIST="$(list "$F/photo.jpg" "$F/quad.png")"
if ! grep -qE 'tool.image.(redact|annotate)' <<<"$LIST" && grep -q tool.image.crop <<<"$LIST" && grep -q tool.image.collage <<<"$LIST" \
   && grep -q tool.image.pdf <<<"$LIST" && grep -q tool.metadata.strip <<<"$LIST"; then ok "two images: Crop, Collage, Make PDF, Remove Metadata, no single-image editors"
else bad "two images" "$LIST"; fi

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]] || { printf 'Failed:\n'; printf '  %s\n' "${failures[@]}"; exit 1; }
