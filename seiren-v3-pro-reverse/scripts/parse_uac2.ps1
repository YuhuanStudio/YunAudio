# Parse a USB configuration descriptor blob, decoding USB Audio Class 2.0 structures.
param([string]$Path = "C:\Users\yuhuan\AppData\Local\Temp\claude\C--Users-yuhuan\8a3d7b2e-98b7-4904-b4d2-ce2ebbe5a086\scratchpad\config_desc_0.bin")

$b = [IO.File]::ReadAllBytes($Path)

function U16($a, $o) { [BitConverter]::ToUInt16($a, $o) }
function U32($a, $o) { [BitConverter]::ToUInt32($a, $o) }
function Hex($a) { ($a | ForEach-Object { $_.ToString('X2') }) -join ' ' }

$termTypes = @{
  0x0100='USB Undefined'; 0x0101='USB Streaming'; 0x0102='USB vendor specific'
  0x0200='Input Undefined'; 0x0201='Microphone'; 0x0202='Desktop microphone'; 0x0203='Personal microphone'
  0x0204='Omni-directional mic'; 0x0205='Microphone array'; 0x0206='Processing mic array'
  0x0300='Output Undefined'; 0x0301='Speaker'; 0x0302='Headphones'; 0x0303='Head Mounted Display Audio'
  0x0304='Desktop speaker'; 0x0305='Room speaker'; 0x0306='Communication speaker'; 0x0307='LFE speaker'
  0x0400='Bi-directional Undefined'; 0x0401='Handset'; 0x0402='Headset'
  0x0500='Telephony Undefined'; 0x0600='External Undefined'; 0x0601='Analog connector'
  0x0602='Digital audio interface'; 0x0603='Line connector'; 0x0604='Legacy audio connector'
  0x0605='S/PDIF interface'; 0x0700='Embedded Undefined'
}
$acSub = @{1='HEADER';2='INPUT_TERMINAL';3='OUTPUT_TERMINAL';4='MIXER_UNIT';5='SELECTOR_UNIT';6='FEATURE_UNIT';
           7='EFFECT_UNIT';8='PROCESSING_UNIT';9='EXTENSION_UNIT';10='CLOCK_SOURCE';11='CLOCK_SELECTOR';
           12='CLOCK_MULTIPLIER';13='SAMPLE_RATE_CONVERTER'}
$asSub = @{1='AS_GENERAL';2='FORMAT_TYPE';3='ENCODER';4='DECODER'}
$fuControls = @('Mute','Volume','Bass','Mid','Treble','Graphic EQ','Automatic Gain','Delay','Bass Boost','Loudness','Input Gain','Input Gain Pad','Phase Inverter','Underflow','Overflow')

# track interface context so CS_INTERFACE can be decoded correctly
$curClass = 0; $curSubClass = 0

$i = 0
while ($i -lt $b.Length) {
  $len = $b[$i]
  if ($len -eq 0) { "!! zero-length descriptor at $i - stopping"; break }
  $type = $b[$i+1]
  $d = $b[$i..($i+$len-1)]

  switch ($type) {
    0x02 {
      "CONFIGURATION  wTotalLength={0}  bNumInterfaces={1}  bConfigurationValue={2}  bmAttributes=0x{3:X2}  MaxPower={4} mA" -f (U16 $d 2), $d[4], $d[5], $d[7], ($d[8]*2)
    }
    0x0B {
      "  INTERFACE ASSOCIATION  firstIf={0} count={1} class=0x{2:X2} subclass=0x{3:X2} protocol=0x{4:X2}" -f $d[2],$d[3],$d[4],$d[5],$d[6]
    }
    0x04 {
      $curClass = $d[5]; $curSubClass = $d[6]
      $cn = switch ($d[5]) { 1 {'AUDIO'} 3 {'HID'} default {"0x{0:X2}" -f $d[5]} }
      $sn = if ($d[5] -eq 1) { switch ($d[6]) { 1 {'AudioControl'} 2 {'AudioStreaming'} 3 {'MIDIStreaming'} default {"0x{0:X2}" -f $d[6]} } } else { "0x{0:X2}" -f $d[6] }
      ""
      "  INTERFACE {0} alt {1}  numEndpoints={2}  class={3} subclass={4} protocol=0x{5:X2}" -f $d[2],$d[3],$d[4],$cn,$sn,$d[7]
    }
    0x05 {
      $addr = $d[2]
      $dir = if ($addr -band 0x80) { 'IN' } else { 'OUT' }
      $xfer = switch ($d[3] -band 0x03) { 0 {'Control'} 1 {'Isochronous'} 2 {'Bulk'} 3 {'Interrupt'} }
      $sync = switch (($d[3] -shr 2) -band 0x03) { 0 {'NoSync'} 1 {'Async'} 2 {'Adaptive'} 3 {'Sync'} }
      $usage= switch (($d[3] -shr 4) -band 0x03) { 0 {'Data'} 1 {'Feedback'} 2 {'ImplicitFeedbackData'} default {'?'} }
      $mps  = U16 $d 4
      $pkt  = $mps -band 0x7FF
      $mult = (($mps -shr 11) -band 0x3) + 1
      "    ENDPOINT 0x{0:X2} {1}  {2}/{3}/{4}  maxPacket={5} x{6}  bInterval={7}" -f $addr,$dir,$xfer,$sync,$usage,$pkt,$mult,$d[6]
    }
    0x21 {
      "    HID DESCRIPTOR  bcdHID=0x{0:X4}  countryCode={1}  numDescriptors={2}  reportType=0x{3:X2}  reportLength={4}" -f (U16 $d 2),$d[4],$d[5],$d[6],(U16 $d 7)
    }
    0x24 {
      $st = $d[2]
      if ($curSubClass -eq 1) {
        $name = if ($acSub.ContainsKey([int]$st)) { $acSub[[int]$st] } else { "0x{0:X2}" -f $st }
        switch ($st) {
          1 { "    AC_HEADER  bcdADC=0x{0:X4}  category=0x{1:X2}  wTotalLength={2}  bmControls=0x{3:X2}" -f (U16 $d 3),$d[5],(U16 $d 6),$d[8] }
          2 {
            $tt = U16 $d 4
            $ttn = if ($termTypes.ContainsKey([int]$tt)) { $termTypes[[int]$tt] } else { '?' }
            "    INPUT_TERMINAL  id={0}  type=0x{1:X4} ({2})  assocTerm={3}  clockSrc={4}  nrChannels={5}  chConfig=0x{6:X8}  bmControls=0x{7:X4}" -f $d[3],$tt,$ttn,$d[6],$d[7],$d[8],(U32 $d 9),(U16 $d 13)
          }
          3 {
            $tt = U16 $d 4
            $ttn = if ($termTypes.ContainsKey([int]$tt)) { $termTypes[[int]$tt] } else { '?' }
            "    OUTPUT_TERMINAL id={0}  type=0x{1:X4} ({2})  assocTerm={3}  sourceId={4}  clockSrc={5}  bmControls=0x{6:X4}" -f $d[3],$tt,$ttn,$d[6],$d[7],$d[8],(U16 $d 9)
          }
          6 {
            # FEATURE_UNIT: bUnitID, bSourceID, then (nCh+1) x 4-byte bmaControls, then iFeature
            $n = ($len - 6) / 4
            "    FEATURE_UNIT    id={0}  sourceId={1}  channels(incl master)={2}" -f $d[3],$d[4],$n
            for ($c = 0; $c -lt $n; $c++) {
              $ctl = U32 $d (5 + $c*4)
              $names = @()
              for ($k = 0; $k -lt $fuControls.Count; $k++) {
                $v = ($ctl -shr ($k*2)) -band 0x3
                if ($v -ne 0) { $names += ("{0}({1})" -f $fuControls[$k], $(if ($v -eq 1) {'ro'} elseif ($v -eq 3) {'rw'} else {"v$v"})) }
              }
              $label = if ($c -eq 0) { 'master' } else { "ch$c" }
              "        {0,-7} bmaControls=0x{1:X8}  {2}" -f $label, $ctl, ($names -join ', ')
            }
          }
          10 {
            $attr = $d[4]
            $ct = switch ($attr -band 0x3) { 0 {'External clock'} 1 {'Internal fixed'} 2 {'Internal variable'} 3 {'Internal programmable'} }
            $sof = if ($attr -band 0x4) { ', sync to SOF' } else { '' }
            "    CLOCK_SOURCE    id={0}  attributes=0x{1:X2} ({2}{3})  bmControls=0x{4:X2}  assocTerm={5}" -f $d[3],$attr,$ct,$sof,$d[5],$d[6]
          }
          11 {
            $np = $d[4]
            $pins = @()
            for ($c = 0; $c -lt $np; $c++) { $pins += $d[5+$c] }
            "    CLOCK_SELECTOR  id={0}  nrPins={1}  sources=[{2}]  bmControls=0x{3:X2}" -f $d[3],$np,($pins -join ','),$d[5+$np]
          }
          default { "    AC CS_INTERFACE {0}  : {1}" -f $name, (Hex $d) }
        }
      } elseif ($curSubClass -eq 2) {
        switch ($st) {
          1 {
            $fmt = U32 $d 6
            $fmtName = switch ($fmt) { 1 {'PCM'} 2 {'PCM8'} 4 {'IEEE_FLOAT'} default {"0x$($fmt.ToString('X8'))"} }
            "    AS_GENERAL  terminalLink={0}  bmControls=0x{1:X2}  formatType={2}  bmFormats={3} ({4})  nrChannels={5}  chConfig=0x{6:X8}" -f $d[3],$d[4],$d[5],$fmt,$fmtName,$d[10],(U32 $d 11)
          }
          2 {
            "    FORMAT_TYPE_I  subslotSize={0} bytes  bitResolution={1} bits" -f $d[4],$d[5]
          }
          default { "    AS CS_INTERFACE 0x{0:X2} : {1}" -f $st, (Hex $d) }
        }
      } else {
        "    CS_INTERFACE (class 0x{0:X2}) : {1}" -f $curClass, (Hex $d)
      }
    }
    0x25 {
      "    CS_ENDPOINT  subtype=0x{0:X2}  bmAttributes=0x{1:X2}  bmControls=0x{2:X2}  lockDelayUnits={3}  lockDelay={4}" -f $d[2],$d[3],$d[4],$d[5],(U16 $d 6)
    }
    default {
      "  UNKNOWN descriptor type 0x{0:X2} len={1} : {2}" -f $type, $len, (Hex $d)
    }
  }
  $i += $len
}
