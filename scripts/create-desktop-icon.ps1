$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$taskRoot = Split-Path $PSScriptRoot -Parent
$bitmap = New-Object Drawing.Bitmap 256,256
$g = [Drawing.Graphics]::FromImage($bitmap)
$g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
$shape = New-Object Drawing.Drawing2D.GraphicsPath
foreach ($arc in @(@(8,8,100,100,180,90),@(148,8,100,100,270,90),@(148,148,100,100,0,90),@(8,148,100,100,90,90))) {
    $shape.AddArc($arc[0],$arc[1],$arc[2],$arc[3],$arc[4],$arc[5])
}
$shape.CloseFigure()
$gradient = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.Point]::new(0,0)),([Drawing.Point]::new(256,256)),([Drawing.Color]::FromArgb(86,183,255)),([Drawing.Color]::FromArgb(0,94,235))
$g.FillPath($gradient,$shape)
$ring = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(65,255,255,255)),2
$g.DrawEllipse($ring,47,47,162,162)
$points = [Drawing.PointF[]]@([Drawing.PointF]::new(65,120),[Drawing.PointF]::new(191,65),[Drawing.PointF]::new(137,192),[Drawing.PointF]::new(119,138))
$g.FillPolygon([Drawing.Brushes]::White,$points)
$memory = New-Object IO.MemoryStream
$bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png)
$png = $memory.ToArray()
$iconPath = Join-Path $taskRoot 'FlutterApp\windows\runner\resources\app_icon.ico'
$stream = [IO.File]::Create($iconPath)
$writer = New-Object IO.BinaryWriter $stream
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]1)
    $writer.Write([byte]0); $writer.Write([byte]0); $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([uint16]1); $writer.Write([uint16]32); $writer.Write([uint32]$png.Length); $writer.Write([uint32]22); $writer.Write($png)
} finally { $writer.Dispose(); $memory.Dispose(); $g.Dispose(); $bitmap.Dispose(); $shape.Dispose(); $gradient.Dispose(); $ring.Dispose() }
Write-Output '已生成蓝色定位图标。'
