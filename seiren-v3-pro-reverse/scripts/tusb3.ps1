# Minimal, step-traced Thesycon query. Prints before each call so a crash is locatable.
$dll = "C:\Program Files (x86)\Razer\PID058EDrv\Driver_Setup\RazerSeirenV3Proapi_x64.dll"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class T3 {
  const string D = @"$dll";
  [DllImport(D)] public static extern uint TUSBAUDIO_GetApiVersion();
  [DllImport(D)] public static extern uint TUSBAUDIO_EnumerateDevices();
  [DllImport(D)] public static extern uint TUSBAUDIO_GetDeviceCount();
  [DllImport(D)] public static extern uint TUSBAUDIO_OpenDeviceByIndex(uint index, out IntPtr h);
  [DllImport(D)] public static extern uint TUSBAUDIO_CloseDevice(IntPtr h);
  [DllImport(D)] public static extern uint TUSBAUDIO_GetCurrentSampleRate(IntPtr h, out uint rate);
  [DllImport(D)] public static extern uint TUSBAUDIO_GetSupportedSampleRates(IntPtr h, uint max, [Out] uint[] rates, out uint count);
  [DllImport(D)] public static extern uint TUSBAUDIO_AudioControlRequestGet(IntPtr h, byte entityId, byte cs, byte cn,
      [Out] byte[] buf, uint bufSize, out uint transferred, uint timeoutMs, byte requestCode);
  [DllImport(D, CharSet=CharSet.Ansi)] public static extern IntPtr TUSBAUDIO_StatusCodeStringA(uint status);
}
"@

function S([uint32]$st) {
  $p = [T3]::TUSBAUDIO_StatusCodeStringA($st)
  $n = if ($p -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::PtrToStringAnsi($p) } else { '?' }
  "0x{0:X8} ({1})" -f $st, $n
}

$v = [T3]::TUSBAUDIO_GetApiVersion()
"API version : {0}.{1}" -f ($v -shr 16), ($v -band 0xFFFF)
[void][T3]::TUSBAUDIO_EnumerateDevices()
"DeviceCount : $([T3]::TUSBAUDIO_GetDeviceCount())"

$h = [IntPtr]::Zero
$r = [T3]::TUSBAUDIO_OpenDeviceByIndex(0, [ref]$h)
"Open : $(S $r)  handle=0x$($h.ToString('X'))"
if ($r -ne 0 -or $h -eq [IntPtr]::Zero) { exit }

try {
  "step: GetCurrentSampleRate"
  $rate = 0
  $r = [T3]::TUSBAUDIO_GetCurrentSampleRate($h, [ref]$rate)
  "  -> $(S $r)  $rate Hz"

  "step: GetSupportedSampleRates"
  $rates = New-Object uint32[] 64
  $n = 0
  $r = [T3]::TUSBAUDIO_GetSupportedSampleRates($h, 64, $rates, [ref]$n)
  "  -> $(S $r)  count=$n"
  if ($r -eq 0 -and $n -gt 0 -and $n -le 64) { "  rates: " + (($rates[0..($n-1)]) -join ', ') + " Hz" }

  "step: UAC2 control reads"
  $probes = @(
    @{e=1;  cs=0x01; cn=0x00; rc=0x01; d='ClockSrc1 SAM_FREQ CUR'},
    @{e=1;  cs=0x01; cn=0x00; rc=0x02; d='ClockSrc1 SAM_FREQ RANGE'},
    @{e=3;  cs=0x01; cn=0x00; rc=0x01; d='FU3  MUTE CUR'},
    @{e=3;  cs=0x02; cn=0x01; rc=0x02; d='FU3  VOLUME RANGE ch1'},
    @{e=7;  cs=0x01; cn=0x00; rc=0x01; d='FU7  MUTE CUR'},
    @{e=7;  cs=0x02; cn=0x01; rc=0x02; d='FU7  VOLUME RANGE ch1'},
    @{e=10; cs=0x01; cn=0x00; rc=0x01; d='FU10 MUTE CUR'},
    @{e=10; cs=0x02; cn=0x01; rc=0x02; d='FU10 VOLUME RANGE ch1'}
  )
  foreach ($p in $probes) {
    $buf = New-Object byte[] 64
    $got = 0
    $r = [T3]::TUSBAUDIO_AudioControlRequestGet($h, [byte]$p.e, [byte]$p.cs, [byte]$p.cn, $buf, 64, [ref]$got, 1000, [byte]$p.rc)
    if ($r -eq 0 -and $got -gt 0) {
      "  {0,-26} OK {1,2}B : {2}" -f $p.d, $got, (($buf[0..([Math]::Min([int]$got,24)-1)] | ForEach-Object { $_.ToString('X2') }) -join ' ')
    } else {
      "  {0,-26} {1}" -f $p.d, (S $r)
    }
  }
}
finally {
  [void][T3]::TUSBAUDIO_CloseDevice($h)
  "closed."
}
