# Dump full USB descriptors for a device by VID/PID via USB hub IOCTLs (no driver install needed).
param(
  [int]$Vid = 0x1532,
  [int]$ProductId = 0x058E
)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public static class UsbNat {
  public const uint GENERIC_WRITE = 0x40000000, GENERIC_READ = 0x80000000;
  public const uint FILE_SHARE_RW = 3, OPEN_EXISTING = 3;
  public const int IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX = 0x220448;
  public const int IOCTL_USB_GET_DESCRIPTOR_FROM_NODE_CONNECTION = 0x220410;
  public const int IOCTL_USB_GET_NODE_INFORMATION = 0x220408;

  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr CreateFile(string n, uint a, uint s, IntPtr sec, uint d, uint f, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool DeviceIoControl(IntPtr h, int code, byte[] inb, int inl, byte[] outb, int outl, ref int ret, IntPtr ov);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);

  [DllImport("setupapi.dll", CharSet=CharSet.Unicode)]
  public static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr e, IntPtr w, int f);
  [DllImport("setupapi.dll")]
  public static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr di, ref Guid g, int i, ref SP_DID d);
  [DllImport("setupapi.dll", CharSet=CharSet.Unicode)]
  public static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr s, ref SP_DID d, IntPtr det, int sz, ref int req, IntPtr dd);
  [DllImport("setupapi.dll")] public static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);

  [StructLayout(LayoutKind.Sequential)]
  public struct SP_DID { public int cbSize; public Guid g; public int Flags; public IntPtr Res; }

  public static List<string> HubPaths() {
    Guid g = new Guid("f18a0e88-c30c-11d0-8815-00a0c906bed8"); // GUID_DEVINTERFACE_USB_HUB
    IntPtr set = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, 0x12);
    var res = new List<string>();
    var d = new SP_DID(); d.cbSize = Marshal.SizeOf(d);
    for (int i = 0; SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref d); i++) {
      int req = 0;
      SetupDiGetDeviceInterfaceDetail(set, ref d, IntPtr.Zero, 0, ref req, IntPtr.Zero);
      IntPtr b = Marshal.AllocHGlobal(req);
      Marshal.WriteInt32(b, IntPtr.Size == 8 ? 8 : 6);
      if (SetupDiGetDeviceInterfaceDetail(set, ref d, b, req, ref req, IntPtr.Zero))
        res.Add(Marshal.PtrToStringUni(new IntPtr(b.ToInt64() + 4)));
      Marshal.FreeHGlobal(b);
    }
    SetupDiDestroyDeviceInfoList(set);
    return res;
  }
}
'@

function New-DescReq([int]$port, [byte]$type, [byte]$index, [int]$langid, [int]$len) {
  $b = New-Object byte[] (12 + $len)
  [BitConverter]::GetBytes([uint32]$port).CopyTo($b, 0)
  $b[4] = 0x80                       # bmRequestType: dev-to-host, standard, device
  $b[5] = 0x06                       # GET_DESCRIPTOR
  $b[6] = $index; $b[7] = $type      # wValue
  [BitConverter]::GetBytes([uint16]$langid).CopyTo($b, 8)   # wIndex
  [BitConverter]::GetBytes([uint16]$len).CopyTo($b, 10)     # wLength
  return $b
}

function Get-Desc($h, [int]$port, [byte]$type, [byte]$index, [int]$langid, [int]$len) {
  $inb = New-DescReq $port $type $index $langid $len
  $outb = New-Object byte[] (12 + $len)
  $ret = 0
  if (-not [UsbNat]::DeviceIoControl($h, [UsbNat]::IOCTL_USB_GET_DESCRIPTOR_FROM_NODE_CONNECTION, $inb, $inb.Length, $outb, $outb.Length, [ref]$ret, [IntPtr]::Zero)) { return $null }
  if ($ret -le 12) { return $null }
  return $outb[12..($ret - 1)]
}

$INVALID = [IntPtr]::new(-1)
$found = $false

foreach ($hub in [UsbNat]::HubPaths()) {
  $h = [UsbNat]::CreateFile($hub, [UsbNat]::GENERIC_WRITE, [UsbNat]::FILE_SHARE_RW, [IntPtr]::Zero, [UsbNat]::OPEN_EXISTING, 0, [IntPtr]::Zero)
  if ($h -eq $INVALID) { continue }

  # how many ports on this hub
  $ni = New-Object byte[] 76
  $ret = 0
  $nPorts = 0
  if ([UsbNat]::DeviceIoControl($h, [UsbNat]::IOCTL_USB_GET_NODE_INFORMATION, $ni, $ni.Length, $ni, $ni.Length, [ref]$ret, [IntPtr]::Zero)) {
    $nPorts = $ni[4]   # NodeType(4) then USB_HUB_INFORMATION.HubDescriptor.bNumberOfPorts at +2 -> offset 4+2=6? use safe upper bound
  }
  if ($nPorts -lt 1 -or $nPorts -gt 64) { $nPorts = 32 }

  for ($port = 1; $port -le $nPorts; $port++) {
    $ci = New-Object byte[] 1024
    [BitConverter]::GetBytes([uint32]$port).CopyTo($ci, 0)
    $ret = 0
    if (-not [UsbNat]::DeviceIoControl($h, [UsbNat]::IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX, $ci, $ci.Length, $ci, $ci.Length, [ref]$ret, [IntPtr]::Zero)) { continue }
    # DeviceDescriptor starts at offset 4 (struct is pack(1))
    $dd = $ci[4..21]
    $vid = [BitConverter]::ToUInt16($dd, 8)
    $pid2 = [BitConverter]::ToUInt16($dd, 10)
    if ($vid -ne $Vid -or $pid2 -ne $ProductId) { continue }

    $found = $true
    $speed = $ci[23]
    $addr  = [BitConverter]::ToUInt16($ci, 25)
    "############ FOUND ############"
    "Hub          : $hub"
    "Port         : $port"
    "USB address  : $addr"
    "Speed code   : $speed  (0=low 1=full 2=high 3=super)"
    ""
    "=== DEVICE DESCRIPTOR (raw) ==="
    ($dd | ForEach-Object { $_.ToString('X2') }) -join ' '
    "bcdUSB          : 0x{0:X4}" -f [BitConverter]::ToUInt16($dd,2)
    "bDeviceClass    : 0x{0:X2}" -f $dd[4]
    "bDeviceSubClass : 0x{0:X2}" -f $dd[5]
    "bDeviceProtocol : 0x{0:X2}" -f $dd[6]
    "bMaxPacketSize0 : {0}" -f $dd[7]
    "idVendor        : 0x{0:X4}" -f $vid
    "idProduct       : 0x{0:X4}" -f $pid2
    "bcdDevice       : 0x{0:X4}" -f [BitConverter]::ToUInt16($dd,12)
    "iManufacturer/iProduct/iSerial : {0} / {1} / {2}" -f $dd[14],$dd[15],$dd[16]
    "bNumConfigurations : {0}" -f $dd[17]
    ""

    # string descriptors
    "=== STRING DESCRIPTORS ==="
    foreach ($si in 0..8) {
      $s = Get-Desc $h $port 3 ([byte]$si) 0x0409 255
      if ($null -eq $s -or $s.Length -lt 3) { continue }
      if ($si -eq 0) { "  [0] LANGIDs: " + (($s[2..($s.Length-1)] | ForEach-Object { $_.ToString('X2') }) -join ' ') }
      else { "  [{0}] {1}" -f $si, [Text.Encoding]::Unicode.GetString($s, 2, $s.Length - 2) }
    }
    ""

    # configuration descriptors (full)
    for ($ci2 = 0; $ci2 -lt $dd[17]; $ci2++) {
      $head = Get-Desc $h $port 2 ([byte]$ci2) 0 9
      if ($null -eq $head) { continue }
      $total = [BitConverter]::ToUInt16($head, 2)
      $full = Get-Desc $h $port 2 ([byte]$ci2) 0 $total
      if ($null -eq $full) { continue }
      "=== CONFIGURATION DESCRIPTOR $ci2  (wTotalLength=$total, got $($full.Length)) ==="
      # emit as hex, 16 bytes per line
      for ($i = 0; $i -lt $full.Length; $i += 16) {
        $end = [Math]::Min($i + 15, $full.Length - 1)
        "{0:X4}: {1}" -f $i, (($full[$i..$end] | ForEach-Object { $_.ToString('X2') }) -join ' ')
      }
      ""
      # also save raw
      [IO.File]::WriteAllBytes("C:\Users\yuhuan\AppData\Local\Temp\claude\C--Users-yuhuan\8a3d7b2e-98b7-4904-b4d2-ce2ebbe5a086\scratchpad\config_desc_$ci2.bin", $full)
    }

    # BOS descriptor (USB 2.1/3.x)
    $bos = Get-Desc $h $port 0x0F 0 0 5
    if ($null -ne $bos -and $bos.Length -ge 5) {
      $btot = [BitConverter]::ToUInt16($bos, 2)
      $bfull = Get-Desc $h $port 0x0F 0 0 $btot
      if ($null -ne $bfull) {
        "=== BOS DESCRIPTOR ==="
        ($bfull | ForEach-Object { $_.ToString('X2') }) -join ' '
        ""
      }
    }
  }
  [void][UsbNat]::CloseHandle($h)
}

if (-not $found) { "Device VID=0x{0:X4} PID=0x{1:X4} not found on any hub." -f $Vid, $ProductId }

