# Reconstruct HID report structure (report IDs, usages, sizes) from preparsed data,
# and also try IOCTL_HID_GET_COLLECTION_DESCRIPTOR for the raw report descriptor.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public static class H2 {
  [DllImport("hid.dll")] public static extern void HidD_GetHidGuid(out Guid g);
  [DllImport("hid.dll")] public static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr pp);
  [DllImport("hid.dll")] public static extern bool HidD_FreePreparsedData(IntPtr pp);
  [DllImport("hid.dll")] public static extern int  HidP_GetCaps(IntPtr pp, ref CAPS c);
  [DllImport("hid.dll")] public static extern int  HidP_GetValueCaps(int rt, [Out] VALUE_CAPS[] vc, ref ushort len, IntPtr pp);
  [DllImport("hid.dll")] public static extern int  HidP_GetButtonCaps(int rt, [Out] BUTTON_CAPS[] bc, ref ushort len, IntPtr pp);
  [DllImport("hid.dll")] public static extern bool HidD_GetFeature(IntPtr h, byte[] b, int len);

  [StructLayout(LayoutKind.Sequential)]
  public struct CAPS {
    public ushort Usage, UsagePage, InputReportByteLength, OutputReportByteLength, FeatureReportByteLength;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst=17)] public ushort[] Reserved;
    public ushort NumberLinkCollectionNodes, NumberInputButtonCaps, NumberInputValueCaps, NumberInputDataIndices;
    public ushort NumberOutputButtonCaps, NumberOutputValueCaps, NumberOutputDataIndices;
    public ushort NumberFeatureButtonCaps, NumberFeatureValueCaps, NumberFeatureDataIndices;
  }

  // hidpi.h HIDP_VALUE_CAPS - 72 bytes, natural alignment
  [StructLayout(LayoutKind.Sequential)]
  public struct VALUE_CAPS {
    public ushort UsagePage;                                     // 0
    public byte ReportID;                                        // 2
    [MarshalAs(UnmanagedType.U1)] public bool IsAlias;           // 3
    public ushort BitField, LinkCollection, LinkUsage, LinkUsagePage;   // 4..11
    [MarshalAs(UnmanagedType.U1)] public bool IsRange, IsStringRange, IsDesignatorRange, IsAbsolute, HasNull; // 12..16
    public byte Reserved;                                        // 17
    public ushort BitSize, ReportCount;                          // 18,20
    [MarshalAs(UnmanagedType.ByValArray, SizeConst=5)] public ushort[] Reserved2;  // 22..31
    public uint UnitsExp, Units;                                 // 32,36
    public int LogicalMin, LogicalMax, PhysicalMin, PhysicalMax; // 40..55
    public ushort UsageMin, UsageMax, StringMin, StringMax, DesignatorMin, DesignatorMax, DataIndexMin, DataIndexMax; // 56..71
  }

  // hidpi.h HIDP_BUTTON_CAPS - 72 bytes, natural alignment
  [StructLayout(LayoutKind.Sequential)]
  public struct BUTTON_CAPS {
    public ushort UsagePage;                                     // 0
    public byte ReportID;                                        // 2
    [MarshalAs(UnmanagedType.U1)] public bool IsAlias;           // 3
    public ushort BitField, LinkCollection, LinkUsage, LinkUsagePage;   // 4..11
    [MarshalAs(UnmanagedType.U1)] public bool IsRange, IsStringRange, IsDesignatorRange, IsAbsolute; // 12..15
    public uint ReportCount;                                     // 16
    [MarshalAs(UnmanagedType.ByValArray, SizeConst=9)] public uint[] Reserved2;    // 20..55
    public ushort UsageMin, UsageMax, StringMin, StringMax, DesignatorMin, DesignatorMax, DataIndexMin, DataIndexMax; // 56..71
  }

  [DllImport("setupapi.dll", CharSet=CharSet.Unicode)]
  public static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr e, IntPtr w, int f);
  [DllImport("setupapi.dll")]
  public static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr di, ref Guid g, int i, ref SPDID d);
  [DllImport("setupapi.dll", CharSet=CharSet.Unicode)]
  public static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr s, ref SPDID d, IntPtr det, int sz, ref int req, IntPtr dd);
  [DllImport("setupapi.dll")] public static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);
  [StructLayout(LayoutKind.Sequential)] public struct SPDID { public int cbSize; public Guid g; public int Flags; public IntPtr Res; }

  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr CreateFile(string n, uint a, uint s, IntPtr sec, uint d, uint f, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool DeviceIoControl(IntPtr h, int code, IntPtr i, int il, byte[] o, int ol, ref int r, IntPtr ov);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);

  public static List<string> Paths() {
    Guid g; HidD_GetHidGuid(out g);
    IntPtr set = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, 0x12);
    var res = new List<string>();
    var d = new SPDID(); d.cbSize = Marshal.SizeOf(d);
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

$RT = @{0='Input'; 1='Output'; 2='Feature'}
$INVALID = [IntPtr]::new(-1)

foreach ($path in [H2]::Paths()) {
  if ($path -notmatch '(?i)vid_1532&pid_058e') { continue }
  "==================================================================="
  "PATH: $path"

  $h = [H2]::CreateFile($path, 0, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
  if ($h -eq $INVALID) { "  cannot open"; continue }

  $pp = [IntPtr]::Zero
  if (-not [H2]::HidD_GetPreparsedData($h, [ref]$pp)) { "  no preparsed data"; [void][H2]::CloseHandle($h); continue }

  $caps = New-Object H2+CAPS
  [void][H2]::HidP_GetCaps($pp, [ref]$caps)
  "  TopLevel UsagePage=0x{0:X4} Usage=0x{1:X4}   in={2} out={3} feature={4}  linkCollections={5}" -f `
     $caps.UsagePage,$caps.Usage,$caps.InputReportByteLength,$caps.OutputReportByteLength,$caps.FeatureReportByteLength,$caps.NumberLinkCollectionNodes

  "  capCounts: inVal={0} inBtn={1} outVal={2} outBtn={3} featVal={4} featBtn={5}" -f `
     $caps.NumberInputValueCaps,$caps.NumberInputButtonCaps,$caps.NumberOutputValueCaps,`
     $caps.NumberOutputButtonCaps,$caps.NumberFeatureValueCaps,$caps.NumberFeatureButtonCaps

  foreach ($rt in 0,1,2) {
    $nv = switch ($rt) { 0 {$caps.NumberInputValueCaps} 1 {$caps.NumberOutputValueCaps} 2 {$caps.NumberFeatureValueCaps} }
    $nb = switch ($rt) { 0 {$caps.NumberInputButtonCaps} 1 {$caps.NumberOutputButtonCaps} 2 {$caps.NumberFeatureButtonCaps} }
    if ($nv -gt 0) {
      $arr = New-Object H2+VALUE_CAPS[] $nv
      $n = [uint16]$nv
      if ([H2]::HidP_GetValueCaps($rt, $arr, [ref]$n, $pp) -eq 0x00110000) {
        foreach ($v in $arr[0..($n-1)]) {
          "    {0,-7} VALUE  reportId=0x{1:X2}  usagePage=0x{2:X4}  usage=0x{3:X4}{4}  bitSize={5} count={6}  logical[{7}..{8}]" -f `
            $RT[$rt], $v.ReportID, $v.UsagePage, $v.UsageMin, $(if ($v.IsRange) {"-0x{0:X4}" -f $v.UsageMax} else {""}), $v.BitSize, $v.ReportCount, $v.LogicalMin, $v.LogicalMax
        }
      }
    }
    if ($nb -gt 0) {
      $arr = New-Object H2+BUTTON_CAPS[] $nb
      $n = [uint16]$nb
      if ([H2]::HidP_GetButtonCaps($rt, $arr, [ref]$n, $pp) -eq 0x00110000) {
        foreach ($v in $arr[0..($n-1)]) {
          "    {0,-7} BUTTON reportId=0x{1:X2}  usagePage=0x{2:X4}  usage=0x{3:X4}{4}" -f `
            $RT[$rt], $v.ReportID, $v.UsagePage, $v.UsageMin, $(if ($v.IsRange) {"-0x{0:X4}" -f $v.UsageMax} else {""})
        }
      }
    }
  }
  [void][H2]::HidD_FreePreparsedData($pp)
  [void][H2]::CloseHandle($h)

  # try to read feature reports (read-only, safe)
  if ($caps.FeatureReportByteLength -gt 0) {
    $h2 = [H2]::CreateFile($path, [uint32]3221225472, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)   # GENERIC_READ|GENERIC_WRITE
    if ($h2 -eq $INVALID) {
      "    (feature read: cannot open R/W, err $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    } else {
      foreach ($rid in 0x00,0x01,0x02,0x03,0x04,0x05) {
        $buf = New-Object byte[] $caps.FeatureReportByteLength
        $buf[0] = $rid
        if ([H2]::HidD_GetFeature($h2, $buf, $buf.Length)) {
          "    FEATURE READ id=0x{0:X2} : {1}" -f $rid, (($buf | ForEach-Object { $_.ToString('X2') }) -join ' ')
        }
      }
      [void][H2]::CloseHandle($h2)
    }
  }
}

