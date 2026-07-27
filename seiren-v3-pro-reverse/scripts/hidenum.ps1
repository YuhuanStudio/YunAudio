Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class Hid {
  [DllImport("hid.dll")] public static extern void HidD_GetHidGuid(out Guid g);
  [DllImport("hid.dll")] public static extern bool HidD_GetAttributes(IntPtr h, ref HIDD_ATTRIBUTES a);
  [DllImport("hid.dll")] public static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr pp);
  [DllImport("hid.dll")] public static extern bool HidD_FreePreparsedData(IntPtr pp);
  [DllImport("hid.dll")] public static extern int  HidP_GetCaps(IntPtr pp, ref HIDP_CAPS c);
  [DllImport("hid.dll", CharSet=CharSet.Unicode)] public static extern bool HidD_GetProductString(IntPtr h, byte[] b, int len);

  [StructLayout(LayoutKind.Sequential)]
  public struct HIDD_ATTRIBUTES { public int Size; public ushort VendorID, ProductID, VersionNumber; }

  [StructLayout(LayoutKind.Sequential)]
  public struct HIDP_CAPS {
    public ushort Usage, UsagePage;
    public ushort InputReportByteLength, OutputReportByteLength, FeatureReportByteLength;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst=17)] public ushort[] Reserved;
    public ushort NumberLinkCollectionNodes, NumberInputButtonCaps, NumberInputValueCaps, NumberInputDataIndices;
    public ushort NumberOutputButtonCaps, NumberOutputValueCaps, NumberOutputDataIndices;
    public ushort NumberFeatureButtonCaps, NumberFeatureValueCaps, NumberFeatureDataIndices;
  }

  [DllImport("setupapi.dll", CharSet=CharSet.Unicode)]
  public static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr enumr, IntPtr hwnd, int flags);
  [DllImport("setupapi.dll")]
  public static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr devInfo, ref Guid g, int idx, ref SP_DEVICE_INTERFACE_DATA d);
  [DllImport("setupapi.dll", CharSet=CharSet.Unicode)]
  public static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref SP_DEVICE_INTERFACE_DATA d, IntPtr detail, int size, ref int req, IntPtr devInfoData);
  [DllImport("setupapi.dll")] public static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);

  [StructLayout(LayoutKind.Sequential)]
  public struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid InterfaceClassGuid; public int Flags; public IntPtr Reserved; }

  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);

  public static string[] Enumerate() {
    Guid g; HidD_GetHidGuid(out g);
    IntPtr set = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, 0x12); // PRESENT|DEVICEINTERFACE
    var list = new System.Collections.Generic.List<string>();
    var did = new SP_DEVICE_INTERFACE_DATA();
    did.cbSize = Marshal.SizeOf(did);
    for (int i = 0; SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref did); i++) {
      int req = 0;
      SetupDiGetDeviceInterfaceDetail(set, ref did, IntPtr.Zero, 0, ref req, IntPtr.Zero);
      IntPtr buf = Marshal.AllocHGlobal(req);
      Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
      if (SetupDiGetDeviceInterfaceDetail(set, ref did, buf, req, ref req, IntPtr.Zero))
        list.Add(Marshal.PtrToStringUni(new IntPtr(buf.ToInt64() + 4)));
      Marshal.FreeHGlobal(buf);
    }
    SetupDiDestroyDeviceInfoList(set);
    return list.ToArray();
  }
}
'@

foreach ($path in [Hid]::Enumerate()) {
  if ($path -notmatch '(?i)vid_1532') { continue }
  # open with 0 access so we can query caps even on exclusive devices
  $h = [Hid]::CreateFile($path, 0, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
  if ($h -eq [IntPtr]::new(-1)) { "PATH: $path`n  <cannot open>"; continue }
  $a = New-Object Hid+HIDD_ATTRIBUTES; $a.Size = [Runtime.InteropServices.Marshal]::SizeOf($a)
  [void][Hid]::HidD_GetAttributes($h, [ref]$a)
  $pp = [IntPtr]::Zero
  $caps = New-Object Hid+HIDP_CAPS
  if ([Hid]::HidD_GetPreparsedData($h, [ref]$pp)) {
    [void][Hid]::HidP_GetCaps($pp, [ref]$caps)
    [void][Hid]::HidD_FreePreparsedData($pp)
  }
  $pb = New-Object byte[] 256
  $prod = ""
  if ([Hid]::HidD_GetProductString($h, $pb, 256)) { $prod = ([Text.Encoding]::Unicode.GetString($pb) -split "`0")[0] }
  [void][Hid]::CloseHandle($h)
  "PATH: $path"
  "  VID/PID   : {0:X4}/{1:X4}   Product: {2}" -f $a.VendorID, $a.ProductID, $prod
  "  UsagePage : 0x{0:X4}  Usage: 0x{1:X4}" -f $caps.UsagePage, $caps.Usage
  "  Report len: in={0} out={1} feature={2}" -f $caps.InputReportByteLength, $caps.OutputReportByteLength, $caps.FeatureReportByteLength
  ""
}
