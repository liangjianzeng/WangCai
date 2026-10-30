<#
  make-logo.ps1 — renders the WangChai mascot to PNG with GDI+ (no external tooling).

  assets/wangchai.svg is the vector source of truth; this script renders the same artwork to
  assets/wangchai.png (1024) and assets/wangchai-avatar.png (256). It exists because neither
  `msedge --headless --screenshot` nor `chrome --headless --screenshot` works on this machine
  ("Multiple targets are not supported in headless mode", exit 13) and there is no Python on PATH.

  The artwork is a golden Shiba bust in the classic doge style: wide head with flaring cheeks,
  big cream muzzle, orange inner ears, bold dark outline. Shapes are flat coordinate strings in a
  512x512 design space — the same numbers as the SVG. Two PowerShell gotchas are designed out,
  both of which the first drafts of this script died on:
    * GraphicsPath.AddBeziers(Object[]) fails overload resolution, so PointF[] is built by index;
    * `method((New-Brush), $path)` mis-binds arguments through the comma, so every pen and brush is
      created once up front and passed as a plain variable.

  Usage:  powershell -File tools/make-logo.ps1
#>
[CmdletBinding()]
param([string]$OutDir = '')

if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets' }

Add-Type -AssemblyName System.Drawing
$D = 'System.Drawing'
$DD = 'System.Drawing.Drawing2D'

function Argb([int]$r, [int]$g, [int]$b) { [System.Drawing.Color]::FromArgb(255, $r, $g, $b) }
function MakePen([System.Drawing.Color]$c, [single]$w) {
    $p = New-Object "$D.Pen"($c, $w); $p.StartCap = 'Round'; $p.EndCap = 'Round'; $p.LineJoin = 'Round'; $p
}
function MakeBrush([System.Drawing.Color]$c) { New-Object "$D.SolidBrush"($c) }
function Dims([string]$s) { , ($s.Split(',') | ForEach-Object { [double]$_ }) }

# flat (x0,y0,x1,y1,...) -> PointF[], built by index so the array is really typed
function Pts([double[]]$xy) {
    $n = [int]($xy.Count / 2)
    $a = New-Object "$D.PointF[]" $n
    for ($i = 0; $i -lt $n; $i++) { $a[$i] = New-Object "$D.PointF" ([single]$xy[2 * $i], [single]$xy[2 * $i + 1]) }
    ,$a
}

# closed cubic chain: first point, then triples of (c1, c2, on-curve)
function Blob([double[]]$xy) {
    $a = Pts $xy
    if (($a.Count - 1) % 3 -ne 0) { throw "Blob: need 1 + 3n points, got $($a.Count)" }
    $p = New-Object "$DD.GraphicsPath"
    for ($i = 0; $i + 3 -lt $a.Count; $i += 3) { $p.AddBezier($a[$i], $a[$i + 1], $a[$i + 2], $a[$i + 3]) }
    $p.CloseFigure(); $p
}

# open cubic chain, for stroking (smile)
function Chain([double[]]$xy) {
    $a = Pts $xy
    $p = New-Object "$DD.GraphicsPath"
    for ($i = 0; $i + 3 -lt $a.Count; $i += 3) { $p.AddBezier($a[$i], $a[$i + 1], $a[$i + 2], $a[$i + 3]) }
    $p
}

function Poly([double[]]$xy) {
    $p = New-Object "$DD.GraphicsPath"; $p.AddPolygon((Pts $xy)); $p.CloseFigure(); $p
}

# ---- palette: the doge look — warm gold coat with a shaded rim, cream mask, heavy dark outline
$C_LINE = Argb 33 17 8; $C_COAT_A = Argb 253 217 107; $C_COAT_B = Argb 236 172 45
$C_COAT_EAR = Argb 243 189 64; $C_CREAM = Argb 251 243 212; $C_EAR = Argb 239 160 46
$C_BG = Argb 255 255 255

function Draw-Logo([System.Drawing.Graphics]$g, [single]$k) {
    $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'
    $g.Clear($C_BG)
    $g.ScaleTransform($k, $k) | Out-Null

    # pens and brushes, created once (see header note on method-argument binding)
    $brCream = MakeBrush $C_CREAM; $brInk = MakeBrush $C_LINE; $brEarCoat = MakeBrush $C_COAT_EAR
    $brEarIn = MakeBrush $C_EAR; $brBody = MakeBrush (Argb 248 203 78)
    $white = [System.Drawing.Color]::White; $brWhite = New-Object "$D.SolidBrush" $white
    $brWhiteSoft = New-Object "$D.SolidBrush" ([System.Drawing.Color]::FromArgb(230, 255, 255, 255))
    $pn11 = MakePen $C_LINE 11; $pn7 = MakePen $C_LINE 7

    # body: one gold mound cut by the bottom edge, cream bib over it
    $body = Blob (Dims '48,512,48,452,116,420,256,420,396,420,464,452,464,512')
    $g.FillPath($brBody, $body); $g.DrawPath($pn11, $body)
    $bib = Blob (Dims '144,512,144,454,196,422,256,422,316,422,368,454,368,512')
    $g.FillPath($brCream, $bib); $g.DrawPath($pn11, $bib)

    # the head path is built early: the coat gradient brush is anchored to it (SVG radial,
    # userSpaceOnUse, center 256/250 r 330), then reused to fill the head after the ears
    $head = Blob (Dims '256,118,342,114,408,142,428,210,446,274,444,342,404,390,366,432,314,452,256,452,198,452,146,432,108,390,68,342,66,274,84,210,104,142,170,114,256,118')
    $coat = New-Object "$DD.PathGradientBrush" $head
    $coat.CenterPoint = New-Object "$D.PointF" (256, 250)
    $coat.CenterColor = $C_COAT_A
    $surround = New-Object "$D.Color[]" 1; $surround[0] = $C_COAT_B
    $coat.SurroundColors = $surround

    # ears: outer edge anchored on the head corner, inner base tucked under the dome
    $earL = Blob (Dims '86,208,90,144,98,88,114,48,158,68,196,100,222,132')
    $earR = Blob (Dims '426,208,422,144,414,88,398,48,354,68,316,100,290,132')
    $g.FillPath($brEarCoat, $earL); $g.DrawPath($pn11, $earL)
    $g.FillPath($brEarCoat, $earR); $g.DrawPath($pn11, $earR)
    $g.FillPath($brEarIn, (Poly (Dims '111,72,119,112,128,146,139,172,166,156,196,140,221,130')))
    $g.FillPath($brEarIn, (Poly (Dims '401,72,393,112,384,146,373,172,346,156,316,140,291,130')))

    # head
    $g.FillPath($coat, $head); $g.DrawPath($pn11, $head)
    $coat.Dispose()

    # cream mask: eye rings merging into the big muzzle
    $ringL = Blob (Dims '152,168,186,160,210,176,212,204,214,228,210,254,200,276,190,298,164,306,140,294,116,282,106,254,110,228,113,210,118,176,152,168')
    $ringR = Blob (Dims '360,168,326,160,302,176,300,204,298,228,302,254,312,276,322,298,348,306,372,294,396,282,406,254,402,228,399,210,394,176,360,168')
    $muzzle = Blob (Dims '96,336,96,272,152,252,256,252,360,252,416,272,416,336,416,416,344,452,256,452,168,452,96,416,96,336')
    $g.FillPath($brCream, $ringL); $g.FillPath($brCream, $ringR); $g.FillPath($brCream, $muzzle)

    # eyes: big, dark, glossy
    $g.FillEllipse($brInk, 132.0, 184.0, 68.0, 76.0)
    $g.FillEllipse($brInk, 312.0, 184.0, 68.0, 76.0)
    $g.FillEllipse($brWhite, 140.0, 194.0, 26.0, 26.0)
    $g.FillEllipse($brWhite, 320.0, 194.0, 26.0, 26.0)
    $g.FillEllipse($brWhiteSoft, 173.0, 232.0, 10.0, 10.0)
    $g.FillEllipse($brWhiteSoft, 353.0, 232.0, 10.0, 10.0)

    # nose + mouth
    $nose = Blob (Dims '256,284,276,284,291,295,291,308,291,323,271,333,256,333,241,333,221,323,221,308,221,295,236,284,256,284')
    $g.FillPath($brInk, $nose)
    $g.DrawLine($pn7, 256.0, 333.0, 256.0, 349.0)
    $smile = Chain (Dims '194,351,230,370,282,370,318,351')
    $g.DrawPath($pn7, $smile)
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
foreach ($job in @(@{ n = 'wangchai.png'; s = 1024 }, @{ n = 'wangchai-avatar.png'; s = 256 })) {
    $size = [int]$job.s
    $bmp = New-Object "$D.Bitmap" ($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    Draw-Logo $g ([single]($size / 512.0))
    $g.Dispose()
    $path = Join-Path $OutDir $job.n
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Output "wrote $path ($size x $size, $((Get-Item $path).Length) bytes)"
}
