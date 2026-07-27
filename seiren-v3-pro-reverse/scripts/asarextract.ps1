param([string[]]$Want)

$f = "C:\Program Files\Razer\RazerAppEngine\app-4.0.698\resources\app.asar"
$out = "C:\Users\yuhuan\AppData\Local\Temp\claude\C--Users-yuhuan\8a3d7b2e-98b7-4904-b4d2-ce2ebbe5a086\scratchpad\asar_out"
New-Item -ItemType Directory -Force -Path $out | Out-Null

$fs = [IO.File]::OpenRead($f)
$br = New-Object IO.BinaryReader($fs)
$null = $br.ReadUInt32(); $null = $br.ReadUInt32(); $null = $br.ReadUInt32()
$len = $br.ReadUInt32()
$json = [Text.Encoding]::UTF8.GetString($br.ReadBytes([int]$len))
# data section starts at 16 + len, aligned to 4
$dataOffset = 16 + $len
if ($dataOffset % 4 -ne 0) { $dataOffset += 4 - ($dataOffset % 4) }
$obj = $json | ConvertFrom-Json

$entries = @{}
function Walk($node, $prefix) {
  if ($null -eq $node.files) { return }
  foreach ($p in $node.files.PSObject.Properties) {
    $full = "$prefix/$($p.Name)"
    if ($p.Value.PSObject.Properties.Name -contains 'files') { Walk $p.Value $full }
    else { $entries[$full] = $p.Value }
  }
}
Walk $obj ""

foreach ($w in $Want) {
  $hits = $entries.Keys | Where-Object { $_ -like $w }
  foreach ($k in $hits) {
    $e = $entries[$k]
    if ($null -eq $e.offset) { "SKIP (no offset): $k"; continue }
    $fs.Seek($dataOffset + [int64]$e.offset, 'Begin') | Out-Null
    $bytes = $br.ReadBytes([int]$e.size)
    $dest = Join-Path $out ($k.TrimStart('/') -replace '/', '__')
    [IO.File]::WriteAllBytes($dest, $bytes)
    "EXTRACTED {0}  ({1} bytes) -> {2}" -f $k, $e.size, $dest
  }
}
$br.Close(); $fs.Close()
