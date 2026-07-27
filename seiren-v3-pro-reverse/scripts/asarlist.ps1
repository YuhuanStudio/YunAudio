$f = "C:\Program Files\Razer\RazerAppEngine\app-4.0.698\resources\app.asar"
$fs = [IO.File]::OpenRead($f)
$br = New-Object IO.BinaryReader($fs)
$null = $br.ReadUInt32()          # 4
$null = $br.ReadUInt32()          # header pickle size
$null = $br.ReadUInt32()          # header string pickle size
$len  = $br.ReadUInt32()          # json length
$json = [Text.Encoding]::UTF8.GetString($br.ReadBytes([int]$len))
$br.Close(); $fs.Close()
"header json bytes: $len"
$obj = $json | ConvertFrom-Json

$paths = New-Object System.Collections.Generic.List[string]
function Walk($node, $prefix) {
  if ($null -eq $node.files) { return }
  foreach ($p in $node.files.PSObject.Properties) {
    $full = "$prefix/$($p.Name)"
    if ($p.Value.PSObject.Properties.Name -contains 'files') { Walk $p.Value $full }
    else { $paths.Add($full) }
  }
}
Walk $obj ""
"total files: $($paths.Count)"
$paths | Set-Content -Encoding utf8 "C:\Users\yuhuan\AppData\Local\Temp\claude\C--Users-yuhuan\8a3d7b2e-98b7-4904-b4d2-ce2ebbe5a086\scratchpad\asar_files.txt"
"--- entries matching device/hid/light/chroma/seiren ---"
$paths | Where-Object { $_ -match '(?i)device|hid|light|chroma|seiren|effect' } | Select-Object -First 60
