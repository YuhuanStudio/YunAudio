# Query the Seiren V3 Pro through Razer's own Thesycon TUSBAUDIO API (read-only calls).
$dll = "C:\Program Files (x86)\Razer\PID058EDrv\Driver_Setup\RazerSeirenV3Proapi_x64.dll"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class T {
  const string D = @"$dll";
  [DllImport(D)] public static extern uint TUSBAUDIO_GetApiVersion(out uint major, out uint minor);
  [DllImport(D)] public static extern uint TUSBAUDIO_EnumerateDevices();
  [DllImport(D)] public static extern uint TUSBAUDIO_GetDeviceCount(out uint count);
  [DllImport(D)] public static extern uint TUSBAUDIO_OpenDeviceByIndex(uint index, out IntPtr h);
  [DllImport(D)] public static extern uint TUSBAUDIO_CloseDevice(IntPtr h);
  [DllImport(D)] public static extern uint TUSBAUDIO_GetCurrentSampleRate(IntPtr h, out uint rate);
  [DllImport(D)] public static extern uint TUSBAUDIO_GetSupportedSampleRates(IntPtr h, uint max, [Out] uint[] rates, out uint count);
  [DllImport(D)] public static extern uint TUSBAUDIO_GetDriverInfo(IntPtr h, byte[] buf, uint size);
  [DllImport(D, CharSet=CharSet.Ansi)] public static extern IntPtr TUSBAUDIO_StatusCodeStringA(uint status);
}
"@

function S([uint32]$st) {
  $p = [T]::TUSBAUDIO_StatusCodeStringA($st)
  if ($p -ne [IntPtr]::Zero) { "0x{0:X8} ({1})" -f $st, [Runtime.InteropServices.Marshal]::PtrToStringAnsi($p) }
  else { "0x{0:X8}" -f $st }
}

$maj = 0; $min = 0
$r = [T]::TUSBAUDIO_GetApiVersion([ref]$maj, [ref]$min)
"GetApiVersion   -> $(S $r)   version $maj.$min"

$r = [T]::TUSBAUDIO_EnumerateDevices()
"EnumerateDevices-> $(S $r)"

$cnt = 0
$r = [T]::TUSBAUDIO_GetDeviceCount([ref]$cnt)
"GetDeviceCount  -> $(S $r)   count=$cnt"

if ($cnt -lt 1) { "no devices"; exit }

$h = [IntPtr]::Zero
$r = [T]::TUSBAUDIO_OpenDeviceByIndex(0, [ref]$h)
"OpenDeviceByIndex(0) -> $(S $r)   handle=0x$($h.ToString('X'))"
if ($h -eq [IntPtr]::Zero) { exit }

$rate = 0
$r = [T]::TUSBAUDIO_GetCurrentSampleRate($h, [ref]$rate)
"GetCurrentSampleRate -> $(S $r)   rate=$rate Hz"

$rates = New-Object uint32[] 32
$n = 0
$r = [T]::TUSBAUDIO_GetSupportedSampleRates($h, 32, $rates, [ref]$n)
"GetSupportedSampleRates -> $(S $r)   count=$n"
if ($n -gt 0 -and $n -le 32) {
  "  supported rates: " + (($rates[0..($n-1)]) -join ', ') + " Hz"
}

[void][T]::TUSBAUDIO_CloseDevice($h)
"closed."
