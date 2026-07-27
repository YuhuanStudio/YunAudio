# Fetch the raw HID report descriptor (type 0x22) from interface 3 via the parent hub.
$hub  = '\\?\usb#vid_0b05&pid_1bd6#5&2cf64626&0&7#{f18a0e88-c30c-11d0-8815-00a0c906bed8}'
$port = 2
$iface = 3
$len  = 273

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class U2 {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr CreateFile(string n, uint a, uint s, IntPtr sec, uint d, uint f, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool DeviceIoControl(IntPtr h, int code, byte[] i, int il, byte[] o, int ol, ref int r, IntPtr ov);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
'@

$h = [U2]::CreateFile($hub, 0x40000000, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
if ($h -eq [IntPtr]::new(-1)) { "cannot open hub: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"; exit 1 }

$inb = New-Object byte[] (12 + $len)
[BitConverter]::GetBytes([uint32]$port).CopyTo($inb, 0)
$inb[4]  = 0x81                 # dev-to-host, standard, recipient = INTERFACE
$inb[5]  = 0x06                 # GET_DESCRIPTOR
$inb[6]  = 0x00                 # descriptor index
$inb[7]  = 0x22                 # HID REPORT descriptor
[BitConverter]::GetBytes([uint16]$iface).CopyTo($inb, 8)
[BitConverter]::GetBytes([uint16]$len).CopyTo($inb, 10)

$outb = New-Object byte[] (12 + $len)
$ret = 0
$ok = [U2]::DeviceIoControl($h, 0x220410, $inb, $inb.Length, $outb, $outb.Length, [ref]$ret, [IntPtr]::Zero)
[void][U2]::CloseHandle($h)

if (-not $ok) { "IOCTL failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"; exit 1 }
"returned $ret bytes ($($ret-12) descriptor bytes)"
$desc = $outb[12..($ret-1)]
[IO.File]::WriteAllBytes("C:\Users\yuhuan\AppData\Local\Temp\claude\C--Users-yuhuan\8a3d7b2e-98b7-4904-b4d2-ce2ebbe5a086\scratchpad\hid_report_desc.bin", $desc)
for ($i = 0; $i -lt $desc.Length; $i += 16) {
  $e = [Math]::Min($i+15, $desc.Length-1)
  "{0:X4}: {1}" -f $i, (($desc[$i..$e] | ForEach-Object { $_.ToString('X2') }) -join ' ')
}
