<#
  make-logo.ps1 — draws the WangChai mascot as PNG with GDI+ (no external tooling).

  The vector source of truth is assets/wangchai.svg; this script renders the same artwork to
  assets/wangchai.png (1024) and assets/wangchai-avatar.png (256). It exists because neither
  `msedge --headless --screenshot` nor `chrome --headless --screenshot` works on this machine
  ("Multiple targets are not supported in headless mode", exit 13) and there is no Python on PATH.

  Coordinates are in a 512x512 design space, scaled to the output size — the same numbers as the SVG.
  Requires Windows PowerShell 5.1 or pwsh with System.Drawing (Windows only).

  Usage:  powershell -File tools/make-logo.ps1
#>
[CmdletBinding()]
param(
    [string]$OutDir = ''
)

if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'assets' }

Add-Type -AssemblyName System.Drawing

# --- palette (matches the Chinese rural dog "Da Huang": warm yellow coat, cream muzzle, dark outline)
$C_LINE   = [System.Drawing.Color]::FromArgb(255, 42, 23, 18)
$C_COAT_A = [System.Drawing.Color]::FromArgb(255, 251, 217, 119)
$C_COAT_B = [System.Drawing.Color]::FromArgb(255, 242, 188, 51)
$C_EAR_IN = [System.Drawing.Color]::FromArgb(255, 200, 130, 15)
$C_CREAM  = [System.Drawing.Color]::FromArgb(255, 247, 239, 220)
$C_BG     = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)
$C_HALO   = [System.Drawing.Color]::FromArgb(255, 255, 246, 223)
$C_STICK  = [System.Drawing.Color]::FromArgb(255, 138, 90, 43)
$C_LEAF   = [System.Drawing.Color]::FromArgb(255, 123, 175, 76)
$C_PCB    = [System.Drawing.Color]::FromArgb(255, 30, 107, 74)
$C_DIE    = [System.Drawing.Color]::FromArgb(255, 18, 63, 46)
$C_CORE   = [System.Drawing.Color]::FromArgb(255, 111, 227, 196)
$C_PIN    = [System.Drawing.Color]::FromArgb(255, 233, 185, 73)
$C_SPARK  = [System.Drawing.Color]::FromArgb(255, 255, 216, 77)

function PT([single]$x, [single]$y) { New-Object System.Drawing.PointF($x, $y) }

function Path-Blob([object[]]$pts) {
    # pts: P0, then triples of (c1,c2,P) cubic segments; closed figure
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p0 = $pts[0]
    $rest = @($pts[1..($pts.Count - 1)])
    if ($rest.Count -eq 1) {
        $gp.AddLine($p0, $rest[0])
    } elseif ($rest.Count % 3 -ne 0) {
        throw "Path-Blob needs triples of control points, got $($rest.Count)"
    } else {
        $gp.AddBeziers([System.Drawing.PointF[]]$rest)
    }
    $gp.CloseFigure()
    $gp
}

function Rounded-Rect([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $gp.AddArc($x, $y, $d, $d, 180, 90)
    $gp.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $gp.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $gp.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $gp.CloseFigure()
    $gp
}

function Pen([System.Drawing.Color]$c, [single]$w) {
    $p = New-Object System.Drawing.Pen($c, $w)
    $p.StartCap = 'Round'; $p.EndCap = 'Round'; $p.LineJoin = 'Round'
    $p
}

function Draw-Logo([System.Drawing.Graphics]$g, [single]$k) {
    $g.SmoothingMode = 'AntiAlias'
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.Clear($C_BG)
    $g.ScaleTransform($k, $k) | Out-Null

    $halo = New-Object System.Drawing.SolidBrush($C_HALO)
    $g.FillEllipse($halo, 30, 26, 452, 452)

    # coat gradient reused for head / body / ears
    $coatBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.RectangleF(90, 40, 340, 450)), $C_COAT_A, $C_COAT_B, 90)

    # ---- tail curled over the back (dark under-stroke, then coat)
    $tail = @( (PT 318 428), (PT 384 442), (PT 408 396), (PT 388 366),
               (PT 374 346), (PT 344 352), (PT 342 376) )
    $tailPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $tailPath.AddBeziers([System.Drawing.PointF[]]$tail[1..3]); $tailPath.AddBeziers([System.Drawing.PointF[]]$tail[4..6])
    $g.DrawPath((Pen $C_LINE 42), $tailPath)
    $g.DrawPath((Pen $C_COAT_B 24), $tailPath)

    # ---- body + belly
    $body = Path-Blob @( (PT 198 344), (PT 174 396), (PT 174 452), (PT 198 482),
                         (PT 314 482), (PT 338 452), (PT 338 396), (PT 314 344) )
    $g.FillPath($coatBrush, $body)
    $g.DrawPath((Pen $C_LINE 10), $body)
    $cream = New-Object System.Drawing.SolidBrush($C_CREAM)
    $g.FillEllipse($cream, 210, 400, 92, 80)

    # ---- ears (erect triangles = the rural-dog silhouette)
    foreach ($tri in @(, @((PT 188 126), (PT 152 38), (PT 240 94)),
                          @((PT 324 126), (PT 360 38), (PT 272 94)))) {
        $g.FillPolygon($coatBrush, [System.Drawing.PointF[]]$tri); $g.DrawPolygon((Pen $C_LINE 10), [System.Drawing.PointF[]]$tri)
    }
    foreach ($tri in @(, @((PT 190 116), (PT 168 64), (PT 224 96)),
                          @((PT 322 116), (PT 344 64), (PT 288 96)))) {
        $g.FillPolygon((New-Object System.Drawing.SolidBrush($C_EAR_IN)), [System.Drawing.PointF[]]$tri)
    }

    # ---- head
    $head = Path-Blob @( (PT 256 76),  (PT 332 76),  (PT 394 128), (PT 404 206),
                         (PT 414 288), (PT 372 356), (PT 300 376), (PT 272 384),
                         (PT 240 384), (PT 212 376), (PT 140 356), (PT 98 288),
                         (PT 108 206), (PT 118 128), (PT 180 76),  (PT 256 76) )
    $g.FillPath($coatBrush, $head)
    $g.DrawPath((Pen $C_LINE 10), $head)

    # ---- muzzle
    $g.FillEllipse($cream, 162, 234, 188, 132)

    # ---- eyes: big, dark, two highlights each
    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $ink   = New-Object System.Drawing.SolidBrush($C_LINE)
    $g.FillEllipse($ink, 171, 192, 66, 76); $g.FillEllipse($ink, 275, 192, 66, 76)
    $g.FillEllipse($white, 182, 205, 22, 22); $g.FillEllipse($white, 286, 205, 22, 22)
    $g.FillEllipse($white, 209, 240, 10, 10); $g.FillEllipse($white, 313, 240, 10, 10)

    # ---- nose + mouth
    $nose = Path-Blob @( (PT 256 264), (PT 275 264), (PT 288 275), (PT 288 287),
                         (PT 288 300), (PT 269 313), (PT 256 313), (PT 243 313),
                         (PT 224 300), (PT 224 287), (PT 224 275), (PT 237 264), (PT 256 264) )
    $g.FillPath($ink, $nose)
    $g.DrawLine((Pen $C_LINE 8), 256, 313, 256, 324)
    $smile = New-Object System.Drawing.Drawing2D.GraphicsPath
    $smile.AddBeziers([System.Drawing.PointF[]]@((PT 222 332), (PT 244.7 350.7), (PT 267.3 350.7), (PT 290 332)))
    $g.DrawPath((Pen $C_LINE 8), $smile)

    # ---- the twig (chai) it is holding, and the paws over it
    $g.DrawLine((Pen $C_STICK 16), 204, 434, 312, 396)
    $g.DrawLine((Pen $C_STICK 10), 262, 414, 274, 396)
    $leaf = Path-Blob @( (PT 286 404), (PT 300 388), (PT 316 386), (PT 322 392),
                         (PT 318 404), (PT 300 412), (PT 288 410) )
    $g.FillPath((New-Object System.Drawing.SolidBrush($C_LEAF)), $leaf)
    $g.DrawPath((Pen $C_LINE 6), $leaf)
    $g.FillEllipse($cream, 188, 416, 52, 40); $g.FillEllipse($cream, 274, 380, 52, 40)
    $g.DrawEllipse((Pen $C_LINE 8), 188, 416, 52, 40); $g.DrawEllipse((Pen $C_LINE 8), 274, 380, 52, 40)

    # ---- the NPU this project exists to wake up: board, die, glowing core, pins, traces
    for ($i = 12; $i -ge 1; $i--) {
        $a = [int](28 * (1 - ($i / 13)))
        $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($a, 111, 227, 196))),
                       (116 - $i * 8), (432 - $i * 8), ($i * 16), ($i * 16))
    }
    $g.FillPath($coatBrush, (New-Object System.Drawing.Drawing2D.GraphicsPath)) | Out-Null
    $board = Rounded-Rect 62 382 106 106 12
    $die   = Rounded-Rect 90 410 50 50 7
    $core  = Rounded-Rect 101 421 28 28 5
    $g.FillPath((New-Object System.Drawing.SolidBrush($C_PCB)), $board)
    $g.DrawPath((Pen $C_LINE 7), $board)
    $g.FillPath((New-Object System.Drawing.SolidBrush($C_DIE)), $die)
    $g.DrawPath((Pen $C_LINE 6), $die)
    $g.FillPath((New-Object System.Drawing.SolidBrush($C_CORE)), $core)
    $pinBrush = New-Object System.Drawing.SolidBrush($C_PIN)
    foreach ($y in 400, 424, 448) { $g.FillRectangle($pinBrush, 46, $y, 18, 10); $g.FillRectangle($pinBrush, 166, $y, 18, 10) }
    foreach ($x in 80, 104, 128)  { $g.FillRectangle($pinBrush, $x, 486, 10, 18) }
    $gold = Pen $C_PIN 6
    $g.DrawLine($gold, 140, 421, 156, 421); $g.DrawLine($gold, 156, 421, 156, 404)
    $g.DrawLine($gold, 115, 449, 115, 470)

    # ---- sparkles: the "dusty accelerator wakes up" note
    $spark = New-Object System.Drawing.SolidBrush($C_SPARK)
    $stars = @(
        , @((PT 198 352), (PT 204 366), (PT 218 372), (PT 204 378), (PT 198 392), (PT 192 378), (PT 178 372), (PT 192 366))
        , @((PT 424 316), (PT 429 328), (PT 441 333), (PT 429 338), (PT 424 350), (PT 419 338), (PT 407 333), (PT 419 328))
        , @((PT 58 350),  (PT 62 360),  (PT 72 364),  (PT 62 368),  (PT 58 378),  (PT 54 368),  (PT 44 364),  (PT 54 360))
    )
    foreach ($s in $stars) { $g.FillPolygon($spark, [System.Drawing.PointF[]]$s) }
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

foreach ($job in @(@{ name = 'wangchai.png'; size = 1024 }, @{ name = 'wangchai-avatar.png'; size = 256 })) {
    $size = [int]$job.size
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    Draw-Logo $g ([single]($size / 512.0))
    $g.Dispose()
    $path = Join-Path $OutDir $job.name
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Output "wrote $path ($size x $size, $((Get-Item $path).Length) bytes)"
}
