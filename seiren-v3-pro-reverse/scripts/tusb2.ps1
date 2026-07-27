# Query the Seiren V3 Pro through Razer's Thesycon TUSBAUDIO API. Read-only calls only.
$dll = "C:\Program Files (x86)\Razer\PID058EDrv\Driver_Setup\RazerSeirenV3Proapi_x64.dll"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class T2 {
  const string D = @"$dll";
  [DllImport(D)] public static extern uint TUSBAUDIO_GetApiVersion();
  [DllImport(D)] public static extern uint TUSBAUDIO_EnumerateDevices();
  [DllImport(D)] public static extern uint TUSBAUDIO_GetDeviceCount();
  [DllImport(D)] public static extern uint TUSBAUDIO_OpenDeviceByIndex(uint index, out IntPtr h);
  [DllImport(D)] public static extern uint TUSBAUDIO_CloseDevice(IntPtr h);
  [DllImport(D)] public static extern uint TUSBAUDIO_GetCurrentSampleRate(IntPtr h, out uint rate);
  [DllImport(D)] public static extern uint TUSBAUDIO_GetSupportedSampleRates(IntPtr h, uint max, [Out] uint[] rates, out uint count);
  [DllImport(D)] public static extern uint TUSBAUDIO_GetDeviceProperties(IntPtr h, [Out] byte[] props);
  [DllImport(D)] public static extern uint TUSBAUDIO_GetVolumeMuteInfo(IntPtr h, uint dir, uint ch, out int volMin, out int volMax, out int volRes, out uint muteSupported);
  [DllImport(D)] public static extern uint TUSBAUDIO_GetStreamChannelCount(IntPtr h, uint dir, out uint count);
  [DllImport(D)] public static extern uint TUSBAUDIO_GetDeviceUsbMode(IntPtr h, out uint mode);
  [DllImport(D)] public static extern uint TUSBAUDIO_GetDeviceStreamingMode(IntPtr h, out uint mode);
  [DllImport(D)] public static extern uint TUSBAUDIO_GetCurrentClockSource(IntPtr h, out uint cs);
  [DllImport(D)] public static extern uint TUSBAUDIO_GetClockSourceStatus(IntPtr h, uint cs, out uint status);
  [DllImport(D)] public static extern uint TUSBAUDIO_AudioControlRequestGet(IntPtr h, byte entityId, byte cs, byte cn,
      [Out] byte[] buf, uint bufSize, out uint transferred, uint timeoutMs, byte requestCode);
  [DllImport(D, CharSet=CharSet.Ansi)] public static extern IntPtr TUSBAUDIO_StatusCodeStringA(uint status);
}
"@

function S([uint32]$st) {
  $p = [T2]::TUSBAUDIO_StatusCodeStringA($st)
  $n = if ($p -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::PtrToStringAnsi($p) } else { '?' }
  "0x{0:X8} ({1})" -f $st, $n
}

$v = [T2]::TUSBAUDIO_GetApiVersion()
"API version : {0}.{1}  (raw 0x{2:X8})" -f ($v -shr 16), ($v -band 0xFFFF), $v
"EnumerateDevices : $(S ([T2]::TUSBAUDIO_EnumerateDevices()))"
$cnt = [T2]::TUSBAUDIO_GetDeviceCount()
"DeviceCount : $cnt"
if ($cnt -lt 1) { exit }

$h = [IntPtr]::Zero
$r = [T2]::TUSBAUDIO_OpenDeviceByIndex(0, [ref]$h)
"OpenDeviceByIndex(0) : $(S $r)  handle=0x$($h.ToString('X'))"
if ($r -ne 0 -or $h -eq [IntPtr]::Zero) { exit }

"`n===== SAMPLE RATES ====="
$rate = 0
"current : $(S ([T2]::TUSBAUDIO_GetCurrentSampleRate($h, [ref]$rate)))  -> $rate Hz"
$rates = New-Object uint32[] 64
$n = 0
$r = [T2]::TUSBAUDIO_GetSupportedSampleRates($h, 64, $rates, [ref]$n)
"supported : $(S $r)  count=$n"
if ($r -eq 0 -and $n -gt 0 -and $n -le 64) { "   " + (($rates[0..($n-1)]) -join ', ') + " Hz" }

"`n===== MODES / CLOCK ====="
foreach ($fn in 'TUSBAUDIO_GetDeviceUsbMode','TUSBAUDIO_GetDeviceStreamingMode','TUSBAUDIO_GetCurrentClockSource') {
  $val = 0
  $r = [T2]::$fn($h, [ref]$val)
  "{0,-34} : {1}  -> {2}" -f $fn.Replace('TUSBAUDIO_',''), (S $r), $val
}

"`n===== UAC2 CONTROL READS (entity, selector) ====="
# CUR request code = 0x01, RANGE = 0x02
# Clock Source 1: CS_SAM_FREQ_CONTROL = 0x01
# Feature Units 3/7/10: FU_VOLUME_CONTROL = 0x02, FU_MUTE_CONTROL = 0x01
$probes = @(
  @{e=1;  cs=0x01; cn=0x00; rc=0x01; d='ClockSrc1 SAM_FREQ CUR'},
  @{e=1;  cs=0x01; cn=0x00; rc=0x02; d='ClockSrc1 SAM_FREQ RANGE'},
  @{e=1;  cs=0x02; cn=0x00; rc=0x01; d='ClockSrc1 CLOCK_VALID CUR'},
  @{e=3;  cs=0x01; cn=0x00; rc=0x01; d='FU3  MUTE CUR (master)'},
  @{e=3;  cs=0x02; cn=0x01; rc=0x01; d='FU3  VOLUME CUR ch1'},
  @{e=3;  cs=0x02; cn=0x01; rc=0x02; d='FU3  VOLUME RANGE ch1'},
  @{e=7;  cs=0x01; cn=0x00; rc=0x01; d='FU7  MUTE CUR (master)'},
  @{e=7;  cs=0x02; cn=0x01; rc=0x01; d='FU7  VOLUME CUR ch1'},
  @{e=7;  cs=0x02; cn=0x01; rc=0x02; d='FU7  VOLUME RANGE ch1'},
  @{e=10; cs=0x01; cn=0x00; rc=0x01; d='FU10 MUTE CUR (master)'},
  @{e=10; cs=0x02; cn=0x01; rc=0x01; d='FU10 VOLUME CUR ch1'},
  @{e=10; cs=0x02; cn=0x01; rc=0x02; d='FU10 VOLUME RANGE ch1'},
  @{e=11; cs=0x01; cn=0x00; rc=0x01; d='Mixer11 MIXER_CONTROL CUR'}
)
foreach ($p in $probes) {
  $buf = New-Object byte[] 64
  $got = 0
  $r = [T2]::TUSBAUDIO_AudioControlRequestGet($h, [byte]$p.e, [byte]$p.cs, [byte]$p.cn, $buf, 64, [ref]$got, 1000, [byte]$p.rc)
  if ($r -eq 0 -and $got -gt 0) {
    "{0,-28} OK  {1,2}B : {2}" -f $p.d, $got, (($buf[0..([Math]::Min($got,32)-1)] | ForEach-Object { $_.ToString('X2') }) -join ' ')
  } else {
    "{0,-28} {1}" -f $p.d, (S $r)
  }
}

[void][T2]::TUSBAUDIO_CloseDevice($h)
"`nclosed."
