$ErrorActionPreference = 'Stop'
$src = 'c:\Users\LT001\Project_2_V1\images\superman-placeholder.backup.PNG'
$dst = 'c:\Users\LT001\Project_2_V1\images\superman-placeholder.cleaned.png'
Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Bitmap]::FromFile($src)
$bmp = New-Object System.Drawing.Bitmap($img)
$img.Dispose()
$w = $bmp.Width
$h = $bmp.Height

function IsGrayMatte([System.Drawing.Color]$c) {
  $max = [Math]::Max($c.R, [Math]::Max($c.G, $c.B))
  $min = [Math]::Min($c.R, [Math]::Min($c.G, $c.B))
  if ($max -eq 0) { return $true }
  $sat = ($max - $min) / [double]$max
  return ($sat -lt 0.24 -and $max -gt 45 -and $max -lt 230)
}

for ($y = 0; $y -lt $h; $y++) {
  for ($x = 0; $x -lt $w; $x++) {
    $c = $bmp.GetPixel($x, $y)
    if (($c.R -ge 246 -and $c.G -ge 246 -and $c.B -ge 246) -or (IsGrayMatte $c)) {
      $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(0, $c.R, $c.G, $c.B))
      continue
    }

    # Blue signature cleanup in bottom-right area.
    $isBottomRight = ($x -gt [int]($w * 0.56) -and $y -gt [int]($h * 0.76))
    $isBlueSig = ($c.B -gt 95 -and ($c.B - $c.R) -gt 34 -and ($c.B - $c.G) -gt 18 -and $c.R -lt 150 -and $c.G -lt 180)
    if ($isBottomRight -and $isBlueSig) {
      $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(0, $c.R, $c.G, $c.B))
    }
  }
}

# Keep only largest connected opaque component (character), remove detached artifacts.
$visited = New-Object 'bool[]' ($w * $h)
$largest = New-Object 'System.Collections.Generic.List[int]'
$components = New-Object 'System.Collections.Generic.List[object]'

function CollectComponent([int]$sx, [int]$sy) {
  $stack = New-Object 'System.Collections.Generic.Stack[int]'
  $comp = New-Object 'System.Collections.Generic.List[int]'
  $stack.Push($sy * $w + $sx)
  while ($stack.Count -gt 0) {
    $n = $stack.Pop()
    if ($visited[$n]) { continue }
    $visited[$n] = $true
    $x = $n % $w
    $y = [int]($n / $w)
    $c = $bmp.GetPixel($x, $y)
    if ($c.A -le 12) { continue }
    $comp.Add($n)
    for ($dy = -1; $dy -le 1; $dy++) {
      for ($dx = -1; $dx -le 1; $dx++) {
        if ($dx -eq 0 -and $dy -eq 0) { continue }
        $nx = $x + $dx
        $ny = $y + $dy
        if ($nx -lt 0 -or $ny -lt 0 -or $nx -ge $w -or $ny -ge $h) { continue }
        $nn = $ny * $w + $nx
        if (-not $visited[$nn]) { $stack.Push($nn) }
      }
    }
  }
  return $comp
}

for ($y = 0; $y -lt $h; $y++) {
  for ($x = 0; $x -lt $w; $x++) {
    $n = $y * $w + $x
    if ($visited[$n]) { continue }
    $c = $bmp.GetPixel($x, $y)
    if ($c.A -le 12) { $visited[$n] = $true; continue }
    $comp = CollectComponent $x $y
    if ($comp.Count -gt 0) {
      $components.Add($comp) | Out-Null
      if ($comp.Count -gt $largest.Count) { $largest = $comp }
    }
  }
}

$keep = New-Object 'System.Collections.Generic.HashSet[int]'
foreach ($n in $largest) { $null = $keep.Add($n) }
foreach ($comp in $components) {
  foreach ($n in $comp) {
    if (-not $keep.Contains($n)) {
      $x = $n % $w
      $y = [int]($n / $w)
      $c = $bmp.GetPixel($x, $y)
      $bmp.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(0, $c.R, $c.G, $c.B))
    }
  }
}

$bmp.Save($dst, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "CLEANED:$dst"
