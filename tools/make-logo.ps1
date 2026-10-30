<#
  make-logo.ps1 — renders the WangChai mascot to PNG with GDI+ (no external tooling).

  assets/wangchai.svg is the vector source of truth; this script renders the same artwork to
  assets/wangchai.png (1024) and assets/wangchai-avatar.png (256). It exists because neither
  `msedge --headless --screenshot` nor `chrome --headless --screenshot` works on this machine
  ("Multiple targets are not supported in headless mode", exit 13) and there is no Python on PATH.

  Shapes are flat coordinate strings in a 512x512 design space — the same numbers as the SVG.
  Two PowerShell gotchas are designed out, both of which the first drafts of this script died on:
    * GraphicsPath.AddBeziers(Object[]) fails overload resolution, so PointF[] is built by index;
    * `method((New-Brush), $path)` mis-binds arguments through the comma, so every pen and brush is
      created once up front and passed as a plain variable.

  Usage:  powershell -File tools/make-logo.ps1
#>
[CmdletBinding()]
param([string]$OutDir = '')

if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'assets' }

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

# open cubic chain, for stroking (tail, smile)
function Chain([double[]]$xy) {
    $a = Pts $xy
    $p = New-Object "$DD.GraphicsPath"
    for ($i = 0; $i + 3 -lt $a.Count; $i += 3) { $p.AddBezier($a[$i], $a[$i + 1], $a[$i + 2], $a[$i + 3]) }
    $p
}

function Poly([double[]]$xy) {
    $p = New-Object "$DD.GraphicsPath"; $p.AddPolygon((Pts $xy)); $p.CloseFigure(); $p
}

function RoundRect([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object "$DD.GraphicsPath"; $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure(); $p
}

# ---- palette: the 大黄 look — warm yellow coat, cream muzzle, heavy dark outline
$C_LINE = Argb 42 23 18; $C_COAT_A = Argb 251 217 119; $C_COAT_B = Argb 242 188 51
$C_EAR = Argb 200 130 15; $C_CREAM = Argb 247 239 220; $C_HALO = Argb 255 246 223
$C_STICK = Argb 138 90 43; $C_LEAF = Argb 123 175 76; $C_PCB = Argb 30 107 74
$C_DIE = Argb 18 63 46; $C_CORE = Argb 111 227 196; $C_PIN = Argb 233 185 73
$C_SPARK = Argb 255 216 77; $C_BG = Argb 255 255 255

function Draw-Logo([System.Drawing.Graphics]$g, [single]$k) {
    $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'
    $brBg = MakeBrush $C_BG; $g.Clear($brBg.Color)
    $g.ScaleTransform($k, $k) | Out-Null

    # pens and brushes, created once (see header note on method-argument binding)
    $brHalo = MakeBrush $C_HALO; $brCream = MakeBrush $C_CREAM; $brInk = MakeBrush $C_LINE
    $brEar = MakeBrush $C_EAR; $brStick = MakeBrush $C_STICK; $brLeaf = MakeBrush $C_LEAF
    $brPcb = MakeBrush $C_PCB; $brDie = MakeBrush $C_DIE; $brCore = MakeBrush $C_CORE
    $brPin = MakeBrush $C_PIN; $brSpark = MakeBrush $C_SPARK
    $white = [System.Drawing.Color]::White; $brWhite = New-Object "$D.SolidBrush" $white
    $pn10 = MakePen $C_LINE 10; $pn8 = MakePen $C_LINE 8; $pn7 = MakePen $C_LINE 7
    $pn6 = MakePen $C_LINE 6
    $pnTwig = MakePen $C_STICK 18; $pnTwig2 = MakePen $C_STICK 10; $pnGold = MakePen $C_PIN 6
    $coat = New-Object "$DD.LinearGradientBrush" ((New-Object "$D.RectangleF" (90, 40, 340, 450)), $C_COAT_A, $C_COAT_B, 90)

    $g.FillEllipse($brHalo, 30.0, 26.0, 452.0, 452.0)

    # (no tail: this is a head-and-shoulders portrait, and a stroked curl kept reading as a banana)

    # chest bib, drawn before the head so the chin covers its top edge — the composition is a
    # head-and-shoulders portrait (like the reference): a separate body made the head's lower outline
    # cut across the chest as a stray hoop.
    $g.FillEllipse($brCream, 176.0, 368.0, 160.0, 122.0)
    $g.DrawEllipse($pn10, 176.0, 368.0, 160.0, 122.0)

    # ears: erect triangles — the rural-dog silhouette, large and set wide
    foreach ($e in '186,132,134,18,252,92', '326,132,378,18,260,92') {
        $p = Poly (Dims $e); $g.FillPath($coat, $p); $g.DrawPath($pn10, $p)
    }
    foreach ($e in '190,120,158,50,232,94', '322,120,354,50,280,94') {
        $p = Poly (Dims $e); $g.FillPath($brEar, $p)
    }

    # head
    $head = Blob (Dims '256,76,332,76,394,128,404,206,414,288,372,356,300,376,272,384,240,384,212,376,140,356,98,288,108,206,118,128,180,76,256,76')
    $g.FillPath($coat, $head); $g.DrawPath($pn10, $head)

    # muzzle
    $g.FillEllipse($brCream, 162.0, 234.0, 188.0, 132.0)

    # eyes: big, dark, two highlights each
    $g.FillEllipse($brInk, 171.0, 192.0, 66.0, 76.0); $g.FillEllipse($brInk, 275.0, 192.0, 66.0, 76.0)
    $g.FillEllipse($brWhite, 182.0, 205.0, 22.0, 22.0); $g.FillEllipse($brWhite, 286.0, 205.0, 22.0, 22.0)
    $g.FillEllipse($brWhite, 209.0, 240.0, 10.0, 10.0); $g.FillEllipse($brWhite, 313.0, 240.0, 10.0, 10.0)

    # nose + mouth
    $nose = Blob (Dims '256,264,275,264,288,275,288,287,288,300,269,313,256,313,243,313,224,300,224,287,224,275,237,264,256,264')
    $g.FillPath($brInk, $nose)
    $g.DrawLine($pn8, 256.0, 313.0, 256.0, 324.0)
    $smile = Chain (Dims '222,332,244.7,350.7,267.3,350.7,290,332')
    $g.DrawPath($pn8, $smile)

    # the twig (chai) held across the chest — it has to stick out past both paws, the name is a pun
    # on it (汪柴); with the paws over the middle it otherwise disappears
    $g.DrawLine($pnTwig, 150.0, 456.0, 372.0, 440.0)
    $g.DrawLine($pnTwig2, 252.0, 448.0, 262.0, 428.0)
    $leaf = Blob (Dims '352,430,372,412,392,410,398,420,386,436,366,440,352,436')
    $g.FillPath($brLeaf, $leaf); $g.DrawPath($pn6, $leaf)
    foreach ($q in '172,414,60,48', '282,406,60,48') {
        $v = $q.Split(',') | ForEach-Object { [single]$_ }
        $g.FillEllipse($brCream, $v[0], $v[1], $v[2], $v[3])
        $g.DrawEllipse($pn10, $v[0], $v[1], $v[2], $v[3])
        # two toe lines per paw, so they read as paws and not as blobs
        $cx = $v[0] + $v[2] / 2.0; $cy = $v[1] + $v[3] * 0.42
        $g.DrawLine($pn6, ($cx - 10.0), ($v[1] + 8.0), ($cx - 13.0), ($cy + 6.0))
        $g.DrawLine($pn6, ($cx + 10.0), ($v[1] + 8.0), ($cx + 13.0), ($cy + 6.0))
    }

    # the NPU this project exists to wake up: glow, board, die, core, pins, traces
    for ($i = 12; $i -ge 1; $i--) {
        $al = [int](26 * (1 - ($i / 13)))
        $col = [System.Drawing.Color]::FromArgb($al, 111, 227, 196)
        $br = New-Object "$D.SolidBrush" $col
        $g.FillEllipse($br, [single](112 - $i * 8), [single](414 - $i * 8), [single]($i * 16), [single]($i * 16))
    }
    $board = RoundRect 58 364 106 106 12
    $die = RoundRect 86 392 50 50 7
    $core = RoundRect 97 403 28 28 5
    $g.FillPath($brPcb, $board); $g.DrawPath($pn7, $board)
    $g.FillPath($brDie, $die);   $g.DrawPath($pn6, $die)
    $g.FillPath($brCore, $core)
    foreach ($y in 382, 406, 430) {
        $g.FillRectangle($brPin, 42.0, [single]$y, 18.0, 10.0)
        $g.FillRectangle($brPin, 162.0, [single]$y, 18.0, 10.0)
    }
    foreach ($x in 76, 100, 124) { $g.FillRectangle($brPin, [single]$x, 468.0, 10.0, 18.0) }
    $g.DrawLine($pnGold, 136.0, 403.0, 152.0, 403.0)
    $g.DrawLine($pnGold, 152.0, 403.0, 152.0, 386.0)
    $g.DrawLine($pnGold, 111.0, 431.0, 111.0, 452.0)

    # sparkles: the dusty accelerator coming back to life
    foreach ($s in '440,206,446,220,460,226,446,232,440,246,434,232,420,226,434,220',
                   '424,316,429,328,441,333,429,338,424,350,419,338,407,333,419,328',
                   '58,350,62,360,72,364,62,368,58,378,54,368,44,364,54,360') {
        $p = Poly (Dims $s); $g.FillPath($brSpark, $p)
    }
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
