# Read-only: pull the current feature report (id 0x07) from the Seiren V3 Pro vendor collection.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class F1 {
  [DllImport("hid.dll")] public static extern bool HidD_GetFeature(IntPtr h, byte[] b, int len);
  [DllImport("hid.dll")] public static extern bool HidD_GetInputReport(IntPtr h, byte[] b, int len);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr CreateFile(string n, uint a, uint s, IntPtr sec, uint d, uint f, IntPtr t);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
'@

$path = '\\?\hid#vid_1532&pid_058e&mi_03&col05#8&16ed8a2c&0&0004#{4d1e55b2-f16f-11cf-88cb-001111000030}'
$INVALID = [IntPtr]::new(-1)

foreach ($access in @(@{n='R/W'; v=[uint32]3221225472}, @{n='R'; v=[uint32]2147483648}, @{n='none'; v=[uint32]0})) {
  $h = [F1]::CreateFile($path, $access.v, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
  if ($h -eq $INVALID) {
    "open [$($access.n)] failed: err $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
    continue
  }
  "open [$($access.n)] OK"
  foreach ($rid in 0x07, 0x05) {
    $buf = New-Object byte[] 64
    $buf[0] = $rid
    if ([F1]::HidD_GetFeature($h, $buf, $buf.Length)) {
      "  GetFeature id=0x{0:X2}:" -f $rid
      for ($i = 0; $i -lt 64; $i += 16) {
        "    {0:X2}: {1}" -f $i, (($buf[$i..($i+15)] | ForEach-Object { $_.ToString('X2') }) -join ' ')
      }
    } else {
      "  GetFeature id=0x{0:X2} failed: err {1}" -f $rid, [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    }
  }
  [void][F1]::CloseHandle($h)
  break
}
