# High-rate poller for feature report 0x07 — catches commands that a one-shot read misses
# because Synapse overwrites them with a follow-up frame command.
param(
  [int]$Seconds = 90,
  [string]$OutFile = "C:\Users\yuhuan\seiren-v3-pro-reverse\raw\feature_poll.txt"
)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FP {
  [DllImport("hid.dll")] public static extern bool HidD_GetFeature(IntPtr h, byte[] b, int len);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr CreateFile(string n, uint a, uint s, IntPtr sec, uint d, uint f, IntPtr t);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
'@

$path = '\\?\hid#vid_1532&pid_058e&mi_03&col05#8&16ed8a2c&0&0004#{4d1e55b2-f16f-11cf-88cb-001111000030}'
$h = [FP]::CreateFile($path, [uint32]3221225472, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
if ($h -eq [IntPtr]::new(-1)) { "cannot open device: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"; exit 1 }

$seen = New-Object 'System.Collections.Generic.HashSet[string]'
$log  = New-Object System.Collections.Generic.List[string]
$sw   = [Diagnostics.Stopwatch]::StartNew()
$reads = 0

function Decode([byte[]]$b) {
  $cls = $b[7]; $cmd = $b[8]; $size = $b[6]
  $args = if ($size -gt 0 -and $size -le 53) { ($b[9..(8+$size)] | ForEach-Object { $_.ToString('X2') }) -join ' ' } else { '' }
  "status=0x{0:X2} tid=0x{1:X2} size=0x{2:X2}({3}) class=0x{4:X2} cmd=0x{5:X2} crc=0x{6:X2}/0x{7:X2}" -f `
    $b[1], $b[2], $size, $size, $cls, $cmd, $b[62], $b[63]
  "        args: $args"
}

Write-Host "polling for $Seconds s -- operate Synapse now (brightness slider, Spectrum, off, colours)..."
while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
  $buf = New-Object byte[] 64
  $buf[0] = 0x07
  if ([FP]::HidD_GetFeature($h, $buf, 64)) {
    $reads++
    $hex = ($buf | ForEach-Object { $_.ToString('X2') }) -join ' '
    if ($seen.Add($hex)) {
      $t = $sw.Elapsed.TotalSeconds
      $hdr = "[{0,7:F3}s] class=0x{1:X2} cmd=0x{2:X2}  (unique #{3})" -f $t, $buf[7], $buf[8], $seen.Count
      Write-Host $hdr -ForegroundColor Cyan
      $d = Decode $buf
      $d | ForEach-Object { Write-Host "   $_" }
      $log.Add($hdr); $log.Add("  raw: $hex"); $d | ForEach-Object { $log.Add("  $_") }; $log.Add('')
    }
  }
  Start-Sleep -Milliseconds 3
}
[void][FP]::CloseHandle($h)

$summary = "done. $reads reads, $($seen.Count) unique frames in $([math]::Round($sw.Elapsed.TotalSeconds,1))s"
Write-Host $summary -ForegroundColor Green
$log.Insert(0, $summary)
$log | Set-Content -Encoding utf8 $OutFile
"written to $OutFile"
