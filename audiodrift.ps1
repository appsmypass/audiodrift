#requires -version 3
<#
    audiodrift - measure the TRUE sample rate of every Windows audio endpoint.

    Windows shows you the endpoint FORMAT ("48000 Hz"). That is the rate the
    audio engine is configured for, not the rate the hardware actually runs at.
    Every audio device is clocked by its own crystal, and crystals are not
    exact. Two devices on two crystals drift apart for the entire length of a
    recording, which is why long streams lose lip sync.

    This tool measures each endpoint's real rate against the system performance
    counter, reports the error in parts per million, and works out which
    endpoints share a clock (safe to record together) and which do not.

    Read-only. It opens its own audio streams and reads clocks. It changes no
    device setting, no registry value and no file.

    Execution policy note: run it as
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File audiodrift.ps1
    which is process-scoped and changes nothing on your machine.
#>
[CmdletBinding()]
param(
    [int]$Seconds = 60,
    [string[]]$Fps = @(),
    [switch]$NoMic,
    [switch]$SkipMeasure,
    [switch]$Json,
    [switch]$Quiet,
    [switch]$Info,
    [string]$FromJson = '',
    [switch]$NoRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:AudioDriftVersion = '1.0.0'
$script:Silent            = $false
$script:DefaultFps        = @(24, 30, 60)
# Batch means. The series is split into this many sub-windows and the scatter
# of their individual rates estimates the uncertainty empirically. More
# batches give a better estimate of the scatter; too many and each batch is
# too short to see the slow wander that is the whole point of measuring it.
$script:Windows           = 8
# A measurement is reported when its uncertainty is small enough to answer the
# question the tool exists for: do these two endpoints share a crystal?
# Separate crystals differ by tens to hundreds of ppm, so an uncertainty under
# 5 ppm decides that comfortably. Above it the number is not refused for being
# wrong - it is refused for being useless.
$script:MaxUsableSePpm    = 5.0
# Floor on the systematic difference between the two measurement techniques.
# Overridden at runtime by the disagreement actually observed - see
# Get-SystematicFloor.
$script:DefaultFloorPpm   = 2.0
# Above this the reading is not a crystal tolerance. Consumer crystals are
# tens of ppm; a Bluetooth or resampled endpoint can read in the thousands.
$script:MaxCrystalPpm     = 1000.0
# The note the native layer attaches to every endpoint under -SkipMeasure.
# A skip the USER asked for is not a fault, so it must not be printed with the
# warning glyph - that is the cry-wolf trap. Pinned by selftest so the two
# sides cannot drift apart silently.
$script:SkipMeasureNote   = 'not measured (-SkipMeasure)'

# ---------------------------------------------------------------------------
# OUTPUT HELPERS
# Every human line goes through one of these so that -Json emits nothing but
# JSON on stdout. Warnings go to stderr instead of being swallowed.
# ---------------------------------------------------------------------------
function Write-Line { param([string]$Text)
    if (-not $script:Silent) { Write-Host $Text }
}
function Write-Head { param([string]$Text)
    if (-not $script:Silent) { Write-Host $Text -ForegroundColor Cyan }
}
function Write-Good { param([string]$Text)
    if (-not $script:Silent) { Write-Host $Text -ForegroundColor Green }
}
function Write-Warn { param([string]$Text)
    if (-not $script:Silent) { Write-Host $Text -ForegroundColor Yellow }
}
function Write-Bad { param([string]$Text)
    if (-not $script:Silent) { Write-Host $Text -ForegroundColor Red }
}
function Write-Err { param([string]$Text)
    [Console]::Error.WriteLine($Text)
}

# Source stays pure ASCII; glyphs are built from code points and verified to
# survive the console encoding before use.
function Get-Glyphs {
    $want = [ordered]@{
        ok   = 0x2713
        warn = 0x21
        dash = 0x2014
        arrow= 0x2192
        pm   = 0xB1
    }
    $fallback = @{ ok = '+'; warn = '!'; dash = '-'; arrow = '->'; pm = '+/-' }
    $out = @{}
    $enc = $null
    try { $enc = [Console]::OutputEncoding } catch { $enc = $null }
    foreach ($k in $want.Keys) {
        $ch = [string][char]$want[$k]
        $ok = $false
        if ($null -ne $enc) {
            try {
                $bytes = $enc.GetBytes($ch)
                $back  = $enc.GetString($bytes)
                if ($back -eq $ch) { $ok = $true }
            } catch { $ok = $false }
        }
        if ($ok) { $out[$k] = $ch } else { $out[$k] = $fallback[$k] }
    }
    return $out
}

# ---------------------------------------------------------------------------
# PURE FUNCTIONS
# Everything below is free of I/O so ground-truth tests can drive it directly.
# ---------------------------------------------------------------------------

# Ordinary least squares of Y on X, plus the standard error of the slope.
# The slope of device-seconds against host-seconds IS the clock ratio, so its
# standard error is the honest uncertainty of the whole measurement.
function Get-LinearFit {
    param([double[]]$X, [double[]]$Y)
    $xs = @($X); $ys = @($Y)
    $n = $xs.Count
    if ($n -ne $ys.Count) { throw 'Get-LinearFit: X and Y differ in length' }
    if ($n -lt 3) { return $null }
    $sx = 0.0; $sy = 0.0
    for ($i = 0; $i -lt $n; $i++) { $sx += $xs[$i]; $sy += $ys[$i] }
    $mx = $sx / $n; $my = $sy / $n
    $sxx = 0.0; $sxy = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        $dx = $xs[$i] - $mx
        $sxx += $dx * $dx
        $sxy += $dx * ($ys[$i] - $my)
    }
    if ($sxx -le 0.0) { return $null }
    $slope = $sxy / $sxx
    $icept = $my - $slope * $mx
    $ss = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        $r = $ys[$i] - ($icept + $slope * $xs[$i])
        $ss += $r * $r
    }
    $se = 0.0
    if ($n -gt 2) { $se = [math]::Sqrt(($ss / ($n - 2)) / $sxx) }
    return @{
        Slope     = $slope
        Intercept = $icept
        StdErr    = $se
        N         = $n
        SpanX     = $xs[$n - 1] - $xs[0]
    }
}

# A clock ratio of 1.0000016 is +1.6 parts per million.
function ConvertTo-Ppm { param([double]$Slope)
    return ($Slope - 1.0) * 1000000.0
}
function ConvertFrom-Ppm { param([double]$Ppm)
    return 1.0 + ($Ppm / 1000000.0)
}

# ppm is microseconds of error per second, so milliseconds per hour is
# ppm * 3600 / 1000 = ppm * 3.6. Kept as its own function so the constant is
# asserted once against a hand-computed ground truth.
function Get-DriftMsPerHour { param([double]$Ppm)
    return $Ppm * 3.6
}

# Seconds until the two clocks slip by one video frame at the given rate.
# This is the number that matters to anyone recording: it converts an abstract
# ppm into "your audio is a frame out after N minutes".
function Get-SecondsPerFrameSlip {
    param([double]$Ppm, [double]$Fps)
    $a = [math]::Abs($Ppm)
    if ($a -le 0.0) { return [double]::PositiveInfinity }
    if ($Fps -le 0.0) { return [double]::PositiveInfinity }
    return (1.0 / $Fps) / ($a / 1000000.0)
}

# Two endpoints share a crystal when their measured rates agree inside the
# combined uncertainty. The floor matters: statistical error alone can be far
# smaller than the systematic difference between the two techniques, and
# demanding agreement tighter than the tool's own resolution would split a
# single codec into two phantom clock domains.
function Test-SameClockDomain {
    param([double]$PpmA, [double]$SeA, [double]$PpmB, [double]$SeB,
          [double]$FloorPpm, [double]$K = 3.0)
    $stat = $K * [math]::Sqrt(($SeA * $SeA) + ($SeB * $SeB))
    $tol  = $stat
    if ($FloorPpm -gt $tol) { $tol = $FloorPpm }
    $d = [math]::Abs($PpmA - $PpmB)
    return @{
        Same      = ($d -le $tol)
        DeltaPpm  = $d
        Tolerance = $tol
        Statistical = $stat
    }
}

# The tool's own resolution, derived from data it already has. The two methods
# measure the same hardware clock, so a gap between them is systematic error -
# but ONLY the part of the gap that noise cannot explain. Counting the whole
# gap would let the noisier method inflate the tolerance until every endpoint
# on the machine looked like it shared one crystal.
function Get-SystematicFloor {
    param($Endpoints, [double]$Default = 2.0, [double]$K = 2.0)
    $worst = 0.0
    foreach ($e in @($Endpoints)) {
        if (-not $e.MethodsComparable) { continue }
        # A resampled endpoint - Bluetooth, or any device whose clock the driver
        # reconstructs - is not a crystal, and its two techniques can disagree by
        # hundreds of thousands of ppm. Letting it set the floor would widen the
        # tolerance until every real crystal on the machine looked identical,
        # which is the exact failure this function exists to prevent. Only
        # endpoints whose reading is a plausible crystal tolerance get a vote.
        if (-not (Test-PpmPlausible -Ppm $e.PacketPpm)) { continue }
        if (-not (Test-PpmPlausible -Ppm $e.ClockPpm))  { continue }
        $d = [math]::Abs($e.PacketPpm - $e.ClockPpm)
        $noise = $K * [math]::Sqrt(($e.SePpm * $e.SePpm) + ($e.ClockSePpm * $e.ClockSePpm))
        $excess = $d - $noise
        if ($excess -gt $worst) { $worst = $excess }
    }
    # A floor at or above the crystal ceiling would call every endpoint on the
    # machine one clock domain. That is not a measurement, so refuse to widen
    # past it and let the per-endpoint uncertainty gate do the refusing instead.
    if ($worst -gt $script:MaxCrystalPpm) { $worst = $script:MaxCrystalPpm }
    if ($worst -lt $Default) { return $Default }
    return $worst
}

# A crystal is off by tens of ppm. A reading in the thousands is not a crystal
# tolerance at all - it is a resampled endpoint (Bluetooth, or a device whose
# clock is reconstructed by the driver), or a broken measurement. Classify it
# rather than reporting it as a hardware fault.
function Test-PpmPlausible { param([double]$Ppm)
    if ([double]::IsNaN($Ppm)) { return $false }
    if ([double]::IsInfinity($Ppm)) { return $false }
    return ([math]::Abs($Ppm) -le $script:MaxCrystalPpm)
}

# Split the sample series into equal sub-windows and fit each. A single fit
# over one window can average away arbitrary behaviour; requiring every window
# to agree is the only check a plausible-looking mean cannot fake.
function Get-WindowFits {
    param([double[]]$X, [double[]]$Y, [int]$Windows = 4)
    $xs = @($X); $ys = @($Y)
    $n = $xs.Count
    $out = New-Object Collections.Generic.List[object]
    if ($Windows -lt 1) { return ,$out.ToArray() }
    if ($n -lt ($Windows * 3)) { return ,$out.ToArray() }
    $per = [int][math]::Floor($n / $Windows)
    for ($w = 0; $w -lt $Windows; $w++) {
        $a = $w * $per
        $b = $a + $per - 1
        if ($w -eq ($Windows - 1)) { $b = $n - 1 }
        $sx = New-Object Collections.Generic.List[double]
        $sy = New-Object Collections.Generic.List[double]
        for ($i = $a; $i -le $b; $i++) { [void]$sx.Add($xs[$i]); [void]$sy.Add($ys[$i]) }
        $f = Get-LinearFit -X $sx.ToArray() -Y $sy.ToArray()
        if ($null -ne $f) { [void]$out.Add($f) }
    }
    return ,$out.ToArray()
}

# The gate itself. An OLS standard error assumes independent residuals. Real
# audio timestamps are autocorrelated - the engine's scheduling wanders over
# seconds - so the OLS figure is optimistic. The scatter of the sub-window
# rates around the overall rate measures that wander directly, which makes the
# reported uncertainty self-calibrating instead of assumed.
function Get-EmpiricalError {
    param($Fits, [double]$Ppm)
    $f = @($Fits)
    if ($f.Count -lt 2) {
        return @{ SeEmpirical = 0.0; SpreadPpm = 0.0; Ppms = @(); Usable = $false }
    }
    $ppms = New-Object Collections.Generic.List[double]
    foreach ($w in $f) { [void]$ppms.Add((ConvertTo-Ppm -Slope $w.Slope)) }
    $arr = $ppms.ToArray()
    $n = @($arr).Count
    $sum = 0.0
    foreach ($p in $arr) { $sum += $p }
    $mean = $sum / $n
    $ss = 0.0
    foreach ($p in $arr) { $d = $p - $mean; $ss += $d * $d }
    $sd = 0.0
    if ($n -gt 1) { $sd = [math]::Sqrt($ss / ($n - 1)) }
    $seEmp = $sd / [math]::Sqrt($n)
    $spread = 0.0
    foreach ($p in $arr) {
        $d = [math]::Abs($p - $Ppm)
        if ($d -gt $spread) { $spread = $d }
    }
    return @{ SeEmpirical = $seEmp; SpreadPpm = $spread; Ppms = $arr; Usable = $true }
}

# -Fps arrives as strings because powershell.exe -File passes every argument as
# one. Casting "24,60" straight to [double] yields 2460, because .NET's default
# number style treats the comma as a digit-group separator. Split first, then
# parse each piece with a style that has no AllowThousands.
function ConvertTo-FpsList {
    param($Raw, [double[]]$Default)
    $out = New-Object Collections.Generic.List[double]
    $bad = New-Object Collections.Generic.List[string]
    foreach ($item in @($Raw)) {
        if ($null -eq $item) { continue }
        foreach ($piece in ([string]$item).Split(',')) {
            $s = $piece.Trim()
            if ($s.Length -eq 0) { continue }
            $v = 0.0
            $ok = [double]::TryParse($s,
                    [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$v)
            if ($ok -and $v -gt 0 -and -not [double]::IsInfinity($v) -and -not [double]::IsNaN($v)) {
                if (-not $out.Contains($v)) { [void]$out.Add($v) }
            } else {
                [void]$bad.Add($s)
            }
        }
    }
    $vals = $out.ToArray()
    if (@($vals).Count -eq 0) { $vals = @($Default) }
    return @{ Values = @($vals); Rejected = @($bad.ToArray()) }
}

# PadRight emits no separator at all when the value is wider than the column,
# which silently fuses two fields into one unreadable token.
function Format-Col {
    param([string]$Text, [int]$Width)
    if ($Text.Length -ge $Width) { return $Text + ' ' }
    return $Text.PadRight($Width)
}

function Format-Ppm { param([double]$Ppm, [int]$Decimals = 3)
    if ([double]::IsNaN($Ppm)) { return 'n/a' }
    if ([double]::IsInfinity($Ppm)) { return 'inf' }
    $fmt = '{0:F' + [string]$Decimals + '}'
    return ($fmt -f $Ppm)
}
function Format-Rate { param([double]$Hz, [int]$Decimals = 4)
    if ([double]::IsNaN($Hz)) { return 'n/a' }
    $fmt = '{0:F' + [string]$Decimals + '}'
    return ($fmt -f $Hz)
}
# 'N' inserts a thousands separator, which breaks any exact string comparison.
function Format-Ms { param([double]$Ms)
    return ('{0:F1}' -f $Ms)
}
function Format-Duration {
    param([double]$Seconds)
    if ([double]::IsInfinity($Seconds)) { return 'never' }
    if ([double]::IsNaN($Seconds)) { return 'n/a' }
    if ($Seconds -lt 0) { return 'n/a' }
    if ($Seconds -lt 1.0)    { return ('{0:F3} s' -f $Seconds) }
    if ($Seconds -lt 90.0)   { return ('{0:F1} s' -f $Seconds) }
    if ($Seconds -lt 5400.0) { return ('{0:F1} min' -f ($Seconds / 60.0)) }
    if ($Seconds -lt 172800.0) { return ('{0:F1} hr' -f ($Seconds / 3600.0)) }
    return ('{0:F1} days' -f ($Seconds / 86400.0))
}

# The native layer returns flat "key=value" lines because PowerShell cannot
# late-bind to a ComImport interface method - the whole COM walk has to happen
# in C#, and flat text is the only shape that crosses back cleanly.
function ConvertFrom-AdRecords {
    param([string]$Text)
    $map = @{}
    if ($null -eq $Text) { return $map }
    $lines = $Text -split "`r?`n"
    foreach ($ln in $lines) {
        if ($ln.Length -eq 0) { continue }
        $i = $ln.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $ln.Substring(0, $i)
        $v = $ln.Substring($i + 1)
        $map[$k] = $v
    }
    return $map
}

# Series arrive as one comma-joined line per axis. Parsed piece by piece with
# an invariant Float style so a decimal comma or a group separator can never
# fuse two samples into one number.
function ConvertFrom-Series {
    param([string]$Text)
    $out = New-Object Collections.Generic.List[double]
    if ([string]::IsNullOrEmpty($Text)) { return ,$out.ToArray() }
    foreach ($piece in $Text.Split(',')) {
        if ($piece.Length -eq 0) { continue }
        $v = 0.0
        $ok = [double]::TryParse($piece,
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$v)
        if ($ok) { [void]$out.Add($v) }
    }
    return ,$out.ToArray()
}

function Get-SubFormatName { param([int]$Code)
    if ($Code -eq 1) { return 'PCM' }
    if ($Code -eq 3) { return 'IEEE float' }
    return 'unknown'
}

# WAVEFORMATEX carries redundant fields: nAvgBytesPerSec and nBlockAlign are
# both derived from rate, channels and bits. If they do not agree the parse is
# wrong and no number from it should be reported.
function Test-FormatRedundancy {
    param([long]$Rate, [int]$Channels, [int]$Bits, [int]$BlockAlign, [long]$AvgBytes)
    $expBlk = [int](($Channels * $Bits) / 8)
    $expAvg = [long]$Rate * [long]$expBlk
    # The derived fields depend only on the PRODUCT of channels and bits, so
    # they cannot tell 2ch/32-bit apart from 32ch/2-bit - both give block
    # align 8. Bound each field independently against what PCM audio can
    # actually carry, or a transposed pair sails through the arithmetic.
    $bitsOk = (@(8, 16, 24, 32, 64) -contains $Bits)
    $chOk   = (($Channels -ge 1) -and ($Channels -le 64))
    $rateOk = (($Rate -ge 4000) -and ($Rate -le 768000))
    return @{
        Ok            = (($expBlk -eq $BlockAlign) -and ($expAvg -eq $AvgBytes) -and $bitsOk -and $chOk -and $rateOk)
        ExpectedBlock = $expBlk
        ExpectedAvg   = $expAvg
        BitsValid     = $bitsOk
        ChannelsValid = $chOk
        RateValid     = $rateOk
    }
}

# For shared-mode PCM the audio clock ticks in bytes, so GetFrequency must
# equal nAvgBytesPerSec exactly. A mismatch means the clock is counting
# something other than what the caller assumes, and the ratio would be wrong
# by that factor without ever looking implausible.
function Test-ClockFrequency {
    param([long]$ClockFreq, [long]$AvgBytes, [long]$Rate)
    return @{
        MatchesAvgBytes = ($ClockFreq -eq $AvgBytes)
        MatchesRate     = ($ClockFreq -eq $Rate)
        Ok              = (($ClockFreq -eq $AvgBytes) -or ($ClockFreq -eq $Rate))
    }
}

function ConvertTo-ClockDomains {
    param($Endpoints, [double]$FloorPpm, [double]$K = 3.0)
    $eps = @($Endpoints)
    $usable = New-Object Collections.Generic.List[object]
    foreach ($e in $eps) {
        if ($e.Measured) { [void]$usable.Add($e) }
    }
    $list = $usable.ToArray()
    foreach ($e in @($list)) { $e.ClockDomain = -1 }
    $domain = 0
    foreach ($e in @($list)) {
        if ($e.ClockDomain -ge 0) { continue }
        $e.ClockDomain = $domain
        foreach ($f in @($list)) {
            if ($f.ClockDomain -ge 0) { continue }
            $t = Test-SameClockDomain -PpmA $e.Ppm -SeA $e.SePpm -PpmB $f.Ppm -SeB $f.SePpm -FloorPpm $FloorPpm -K $K
            if ($t.Same) { $f.ClockDomain = $domain }
        }
        $domain++
    }
    return $domain
}

function Get-EndpointPairs {
    param($Endpoints, [double]$FloorPpm, [double[]]$FpsList, [double]$K = 3.0)
    $eps = @($Endpoints)
    $out = New-Object Collections.Generic.List[object]
    for ($i = 0; $i -lt $eps.Count; $i++) {
        for ($j = $i + 1; $j -lt $eps.Count; $j++) {
            $a = $eps[$i]; $b = $eps[$j]
            if (-not ($a.Measured -and $b.Measured)) { continue }
            $t = Test-SameClockDomain -PpmA $a.Ppm -SeA $a.SePpm -PpmB $b.Ppm -SeB $b.SePpm -FloorPpm $FloorPpm -K $K
            $rel = $a.Ppm - $b.Ppm
            $slips = New-Object Collections.Generic.List[object]
            foreach ($f in @($FpsList)) {
                [void]$slips.Add([pscustomobject][ordered]@{
                    Fps            = $f
                    SecondsPerSlip = (Get-SecondsPerFrameSlip -Ppm $rel -Fps $f)
                })
            }
            [void]$out.Add([pscustomobject][ordered]@{
                AIndex        = $a.Index
                BIndex        = $b.Index
                AName         = $a.Name
                BName         = $b.Name
                RelativePpm   = $rel
                AbsPpm        = [math]::Abs($rel)
                Tolerance     = $t.Tolerance
                SameClock     = $t.Same
                MsPerHour     = (Get-DriftMsPerHour -Ppm ([math]::Abs($rel)))
                FrameSlip     = @($slips.ToArray())
            })
        }
    }
    return ,$out.ToArray()
}

# ---------------------------------------------------------------------------
# NATIVE LAYER
# ---------------------------------------------------------------------------
$script:NativeReady = $false
function Initialize-AudioDriftNative {
    if ($script:NativeReady) { return $true }
    if ('AudioDriftNative.Engine' -as [type]) { $script:NativeReady = $true; return $true }
    $code = @'
using System;
using System.Text;
using System.Globalization;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace AudioDriftNative {

[StructLayout(LayoutKind.Sequential)]
public struct WAVEFORMATEX {
    public ushort wFormatTag; public ushort nChannels; public uint nSamplesPerSec;
    public uint nAvgBytesPerSec; public ushort nBlockAlign; public ushort wBitsPerSample;
    public ushort cbSize;
}

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceEnumerator {
    [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection dev);
    [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice dev);
    [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice dev);
    [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr c);
    [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr c);
}
[ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceCollection {
    [PreserveSig] int GetCount(out uint n);
    [PreserveSig] int Item(uint i, out IMMDevice dev);
}
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDevice {
    [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr act, [MarshalAs(UnmanagedType.IUnknown)] out object o);
    [PreserveSig] int OpenPropertyStore(int access, out IPropertyStore ps);
    [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    [PreserveSig] int GetState(out int state);
}
[StructLayout(LayoutKind.Sequential)]
public struct PROPERTYKEY { public Guid fmtid; public int pid; }
[StructLayout(LayoutKind.Sequential)]
public struct PROPVARIANT { public ushort vt; public ushort r1; public ushort r2; public ushort r3; public IntPtr p; public IntPtr p2; }
[ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPropertyStore {
    [PreserveSig] int GetCount(out uint n);
    [PreserveSig] int GetAt(uint i, out PROPERTYKEY k);
    [PreserveSig] int GetValue(ref PROPERTYKEY k, out PROPVARIANT v);
    [PreserveSig] int SetValue(ref PROPERTYKEY k, ref PROPVARIANT v);
    [PreserveSig] int Commit();
}
[ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioClient {
    [PreserveSig] int Initialize(int mode, int flags, long buf, long period, IntPtr fmt, IntPtr sess);
    [PreserveSig] int GetBufferSize(out uint n);
    [PreserveSig] int GetStreamLatency(out long l);
    [PreserveSig] int GetCurrentPadding(out uint n);
    [PreserveSig] int IsFormatSupported(int mode, IntPtr fmt, IntPtr closest);
    [PreserveSig] int GetMixFormat(out IntPtr fmt);
    [PreserveSig] int GetDevicePeriod(out long def, out long min);
    [PreserveSig] int Start();
    [PreserveSig] int Stop();
    [PreserveSig] int Reset();
    [PreserveSig] int SetEventHandle(IntPtr h);
    [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object o);
}
[ComImport, Guid("CD63314F-3FBA-4a1b-812C-EF96358728E7"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioClock {
    [PreserveSig] int GetFrequency(out ulong f);
    [PreserveSig] int GetPosition(out ulong pos, out ulong qpc);
    [PreserveSig] int GetCharacteristics(out uint c);
}
[ComImport, Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioRenderClient {
    [PreserveSig] int GetBuffer(uint frames, out IntPtr data);
    [PreserveSig] int ReleaseBuffer(uint frames, uint flags);
}
[ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioCaptureClient {
    [PreserveSig] int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong pos, out ulong qpc);
    [PreserveSig] int ReleaseBuffer(uint frames);
    [PreserveSig] int GetNextPacketSize(out uint frames);
}
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
public class MMDeviceEnumeratorComObject { }

public class Endpoint {
    public int Index;
    public string Id = "";
    public string Name = "";
    public string Hw = "";             // device instance path: the physical device
    public string Flow = "";
    public int State;
    public bool IsDefault;
    public WAVEFORMATEX Fmt;
    public int SubFormat = -1;         // 1 = PCM, 3 = IEEE float, -1 = unknown
    public byte[] Fill;
    public ulong ClockFreq;
    public string Error = "";
    public bool Opened;
    public IAudioClient Feed;          // render only: keeps the engine running
    public IAudioRenderClient Rc;
    public IAudioClient Cap;           // capture, or loopback capture on render
    public IAudioCaptureClient Cc;
    public IAudioClock Clk;
    public uint FeedBufFrames;
    public List<double> PktX = new List<double>();
    public List<double> PktY = new List<double>();
    public List<double> ClkX = new List<double>();
    public List<double> ClkY = new List<double>();
    public ulong Pp0, Pq0, Cp0, Cq0;
    public bool PktFirst = true, ClkFirst = true;
    public int Packets, SilentPackets, Discont, TsError;
    public bool Ready;
}

public static class Engine {
    [DllImport("kernel32.dll")] public static extern bool QueryPerformanceCounter(out long v);
    [DllImport("kernel32.dll")] public static extern bool QueryPerformanceFrequency(out long v);

    static Guid CLI = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
    static Guid CLK = new Guid("CD63314F-3FBA-4a1b-812C-EF96358728E7");
    static Guid REN = new Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2");
    static Guid CAP = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");

    const int LOOPBACK = 131072;       // AUDCLNT_STREAMFLAGS_LOOPBACK
    const uint SILENT  = 2;            // AUDCLNT_BUFFERFLAGS_SILENT
    const int SHARED   = 0;
    // Buffer duration and the clock timestamp unit are both 100ns quantities.
    const long BUF_100NS = 20000000L;
    const double HNS_PER_SEC = 10000000.0;

    static string F(double v) { return v.ToString("R", CultureInfo.InvariantCulture); }

    // WAVE_FORMAT_EXTENSIBLE does not say whether the samples are integers or
    // floats in wFormatTag - it says 0xFFFE and hides the answer in a GUID
    // after the WAVEFORMATEX header. Writing a float bit pattern into an
    // integer stream would be full-scale noise through the user's speakers,
    // so this must be read, never assumed.
    static int ReadSubFormat(IntPtr pfmt, WAVEFORMATEX f) {
        if (f.wFormatTag == 1) return 1;
        if (f.wFormatTag == 3) return 3;
        if (f.wFormatTag != 0xFFFE) return -1;
        if (f.cbSize < 22) return -1;
        // WAVEFORMATEX is 18 bytes, then wValidBitsPerSample (2) and
        // dwChannelMask (4); the SubFormat GUID begins at offset 24 and its
        // first DWORD carries the format code.
        int code = Marshal.ReadInt32(pfmt, 24);
        if (code == 1 || code == 3) return code;
        return -1;
    }

    // A buffer of digital silence keeps the stream alive but lets Windows
    // treat the endpoint as idle. The fill is therefore the smallest non-zero
    // signal the format can carry, alternating sign so it is not DC: one LSB
    // for integer formats, 1e-7 (about -140 dBFS) for float. Both are far
    // below the noise floor of any real converter and are inaudible.
    static byte[] MakeFill(Endpoint e, int bytes) {
        byte[] b = new byte[bytes];
        int blk = e.Fmt.nBlockAlign;
        int ch  = e.Fmt.nChannels;
        int bits = e.Fmt.wBitsPerSample;
        if (blk <= 0 || ch <= 0) return b;
        int bytesPerSample = blk / ch;
        byte[] pos = null, neg = null;
        if (e.SubFormat == 3 && bits == 32) {
            pos = BitConverter.GetBytes(1e-7f);
            neg = BitConverter.GetBytes(-1e-7f);
        } else if (e.SubFormat == 1 && bits == 16) {
            pos = BitConverter.GetBytes((short)1);
            neg = BitConverter.GetBytes((short)-1);
        } else if (e.SubFormat == 1 && bits == 32) {
            pos = BitConverter.GetBytes((int)1);
            neg = BitConverter.GetBytes((int)-1);
        } else {
            return b;   // unknown layout: stay with true zeros, never guess
        }
        if (pos.Length != bytesPerSample) return b;
        int frames = bytes / blk;
        for (int i = 0; i < frames; i++) {
            byte[] src = ((i & 1) == 0) ? pos : neg;
            for (int c = 0; c < ch; c++) {
                Buffer.BlockCopy(src, 0, b, i * blk + c * bytesPerSample, bytesPerSample);
            }
        }
        return b;
    }

    static string GetStringProp(IMMDevice d, string fmtid, int pid) {
        try {
            IPropertyStore ps;
            if (d.OpenPropertyStore(0, out ps) != 0) return "";
            PROPERTYKEY k = new PROPERTYKEY();
            k.fmtid = new Guid(fmtid); k.pid = pid;
            PROPVARIANT pv;
            if (ps.GetValue(ref k, out pv) != 0) return "";
            if (pv.p == IntPtr.Zero) return "";
            return Marshal.PtrToStringUni(pv.p);
        } catch { return ""; }
    }

    static string GetName(IMMDevice d) {
        return GetStringProp(d, "a45c254e-df1c-4efd-8020-67d146a850e0", 14);
    }

    // PKEY_Device_DeviceDesc's sibling: the device instance path. Two endpoints
    // reporting the same one are two interfaces of a single physical device, so
    // they are driven by a single crystal. Two different paths that measure as
    // locked are locked for some other reason - resampling, almost always - and
    // saying "same crystal" about them would be an over-claim.
    static string GetHw(IMMDevice d) {
        return GetStringProp(d, "b3f8fa53-0004-438e-9003-51a46e139bfc", 2);
    }

    // Enumerate only. Opens no stream, so this is the safe path for a machine
    // with no audio hardware or a caller that only wants the inventory.
    // One emitter for both entry points. -SkipMeasure used to have a schema of
    // its own ("all.N.*") that nothing downstream parsed, so the mode printed a
    // header and zero endpoints. Sharing the emitter makes that class of drift
    // impossible: the enumerate path cannot diverge from the measure path.
    static void EmitEndpoints(StringBuilder sb, List<Endpoint> eps) {
        foreach (Endpoint e in eps) {
            string p = "ep." + e.Index + ".";
            sb.AppendLine(p + "id=" + e.Id);
            sb.AppendLine(p + "name=" + e.Name);
            sb.AppendLine(p + "hw=" + e.Hw);
            sb.AppendLine(p + "flow=" + e.Flow);
            sb.AppendLine(p + "state=" + e.State.ToString(CultureInfo.InvariantCulture));
            sb.AppendLine(p + "default=" + (e.IsDefault ? "1" : "0"));
            sb.AppendLine(p + "opened=" + (e.Opened ? "1" : "0"));
            sb.AppendLine(p + "error=" + e.Error);
            sb.AppendLine(p + "rate=" + e.Fmt.nSamplesPerSec.ToString(CultureInfo.InvariantCulture));
            sb.AppendLine(p + "channels=" + e.Fmt.nChannels.ToString(CultureInfo.InvariantCulture));
            sb.AppendLine(p + "bits=" + e.Fmt.wBitsPerSample.ToString(CultureInfo.InvariantCulture));
            sb.AppendLine(p + "blockalign=" + e.Fmt.nBlockAlign.ToString(CultureInfo.InvariantCulture));
            sb.AppendLine(p + "avgbytes=" + e.Fmt.nAvgBytesPerSec.ToString(CultureInfo.InvariantCulture));
            sb.AppendLine(p + "formattag=" + e.Fmt.wFormatTag.ToString(CultureInfo.InvariantCulture));
            sb.AppendLine(p + "subformat=" + e.SubFormat.ToString(CultureInfo.InvariantCulture));
            sb.AppendLine(p + "clockfreq=" + e.ClockFreq.ToString(CultureInfo.InvariantCulture));
            sb.AppendLine(p + "packets=" + e.Packets.ToString(CultureInfo.InvariantCulture));
            sb.AppendLine(p + "silentpackets=" + e.SilentPackets.ToString(CultureInfo.InvariantCulture));
            sb.AppendLine(p + "discont=" + e.Discont.ToString(CultureInfo.InvariantCulture));
            sb.AppendLine(p + "tserror=" + e.TsError.ToString(CultureInfo.InvariantCulture));
            sb.AppendLine(p + "pkt.x=" + string.Join(",", e.PktX.ConvertAll<string>(F).ToArray()));
            sb.AppendLine(p + "pkt.y=" + string.Join(",", e.PktY.ConvertAll<string>(F).ToArray()));
            sb.AppendLine(p + "clk.x=" + string.Join(",", e.ClkX.ConvertAll<string>(F).ToArray()));
            sb.AppendLine(p + "clk.y=" + string.Join(",", e.ClkY.ConvertAll<string>(F).ToArray()));
        }
    }

    // Format only: Activate hands back an IAudioClient, and GetMixFormat reads
    // the engine format off it WITHOUT Initialize. No stream is created, so on
    // a capture endpoint the microphone indicator never lights.
    //
    // stateMask is the DEVICE_STATE mask: 1 = ACTIVE (what the tool shows),
    // 15 = every state including unplugged and disabled (what realcheck walks
    // so it can cross-check far more endpoints than are currently live).
    public static string Enumerate() { return EnumerateCore(1); }
    public static string EnumerateAll() { return EnumerateCore(15); }

    static string EnumerateCore(int stateMask) {
        StringBuilder sb = new StringBuilder();
        long qf; QueryPerformanceFrequency(out qf);
        sb.AppendLine("qpcfreq=" + qf.ToString(CultureInfo.InvariantCulture));

        IMMDeviceEnumerator en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
        string defRender = "", defCapture = "";
        IMMDevice dr;
        if (en.GetDefaultAudioEndpoint(0, 0, out dr) == 0) dr.GetId(out defRender);
        IMMDevice dc;
        if (en.GetDefaultAudioEndpoint(1, 0, out dc) == 0) dc.GetId(out defCapture);

        IMMDeviceCollection act;
        int hr = en.EnumAudioEndpoints(2, stateMask, out act);
        if (hr != 0) { sb.AppendLine("enumerror=0x" + hr.ToString("X8")); return sb.ToString(); }
        uint n; act.GetCount(out n);
        sb.AppendLine("endpoints=" + n.ToString(CultureInfo.InvariantCulture));

        List<Endpoint> eps = new List<Endpoint>();
        for (uint i = 0; i < n; i++) {
            IMMDevice d; act.Item(i, out d);
            Endpoint e = new Endpoint();
            e.Index = (int)i;
            d.GetId(out e.Id);
            e.Name = GetName(d);
            e.Hw = GetHw(d);
            d.GetState(out e.State);
            e.Flow = e.Id.StartsWith("{0.0.1.", StringComparison.Ordinal) ? "capture" : "render";
            e.IsDefault = (e.Id == defRender) || (e.Id == defCapture);
            e.Opened = false;
            e.Error = "not measured (-SkipMeasure)";
            // Only probe ACTIVE endpoints. Activating a client on an unplugged
            // or disabled device achieves nothing and stirs up the audio
            // service right before a measurement - which is exactly how an
            // endpoint intermittently failed to open in the suite that came
            // after it. DEVICE_STATE_ACTIVE is 1.
            IAudioClient probe = null;
            if (e.State != 1) { e.Error = "endpoint is not active (state " + e.State.ToString(CultureInfo.InvariantCulture) + ")"; }
            else {
            try {
                object o;
                int ahr = d.Activate(ref CLI, 1, IntPtr.Zero, out o);
                if (ahr != 0) { e.Error = "activate 0x" + ahr.ToString("X8"); }
                else {
                    probe = (IAudioClient)o;
                    IntPtr pfmt;
                    int fhr = probe.GetMixFormat(out pfmt);
                    if (fhr != 0) { e.Error = "mixformat 0x" + fhr.ToString("X8"); }
                    else {
                        e.Fmt = (WAVEFORMATEX)Marshal.PtrToStructure(pfmt, typeof(WAVEFORMATEX));
                        e.SubFormat = ReadSubFormat(pfmt, e.Fmt);
                    }
                }
            } catch (Exception ex) { e.Error = ex.GetType().Name + ": " + ex.Message; }
            }
            if (probe != null) { try { Marshal.ReleaseComObject(probe); } catch { } }
            eps.Add(e);
        }

        EmitEndpoints(sb, eps);
        return sb.ToString();
    }

    static void Service(Endpoint e) {
        if (e.Rc != null && e.Feed != null) {
            uint pad;
            if (e.Feed.GetCurrentPadding(out pad) == 0) {
                uint want = e.FeedBufFrames - pad;
                if (want > 0) {
                    IntPtr data;
                    if (e.Rc.GetBuffer(want, out data) == 0) {
                        int bytes = (int)want * (int)e.Fmt.nBlockAlign;
                        if (bytes > 0 && e.Fill != null && e.Fill.Length >= bytes) {
                            Marshal.Copy(e.Fill, 0, data, bytes);
                        }
                        e.Rc.ReleaseBuffer(want, 0);
                    }
                }
            }
        }
        if (e.Cc != null) {
            uint pkt;
            while (e.Cc.GetNextPacketSize(out pkt) == 0 && pkt > 0) {
                IntPtr dd; uint fr, fl; ulong dpos, dqpc;
                if (e.Cc.GetBuffer(out dd, out fr, out fl, out dpos, out dqpc) != 0) break;
                if ((fl & 1) != 0) e.SilentPackets++;
                if ((fl & 2) != 0) e.Discont++;
                if ((fl & 4) != 0) e.TsError++;
                if (fr > 0) {
                    e.Packets++;
                    if (e.PktFirst) { e.Pp0 = dpos; e.Pq0 = dqpc; e.PktFirst = false; }
                    else {
                        e.PktX.Add((double)(dqpc - e.Pq0) / HNS_PER_SEC);
                        e.PktY.Add((double)(dpos - e.Pp0) / (double)e.Fmt.nSamplesPerSec);
                    }
                }
                e.Cc.ReleaseBuffer(fr);
            }
        }
    }

    static void SampleClock(Endpoint e) {
        if (e.Clk == null) return;
        ulong p, q;
        if (e.Clk.GetPosition(out p, out q) != 0) return;
        // The very first read after Start() returns position 0 with a zero
        // timestamp - the stream has not begun flowing. Treating that as a
        // real sample produces a large, entirely plausible, wrong answer.
        if (p == 0 || q == 0) return;
        if (e.ClkFirst) { e.Cp0 = p; e.Cq0 = q; e.ClkFirst = false; return; }
        e.ClkX.Add((double)(q - e.Cq0) / HNS_PER_SEC);
        e.ClkY.Add((double)(p - e.Cp0) / (double)e.ClockFreq);
    }

    static bool OpenOne(IMMDevice d, Endpoint e, bool wantMic) {
        object o;
        int hr = d.Activate(ref CLI, 1, IntPtr.Zero, out o);
        if (hr != 0) { e.Error = "activate 0x" + hr.ToString("X8"); return false; }
        IAudioClient probe = (IAudioClient)o;
        IntPtr pfmt;
        hr = probe.GetMixFormat(out pfmt);
        if (hr != 0) { e.Error = "mixformat 0x" + hr.ToString("X8"); return false; }
        e.Fmt = (WAVEFORMATEX)Marshal.PtrToStructure(pfmt, typeof(WAVEFORMATEX));
        e.SubFormat = ReadSubFormat(pfmt, e.Fmt);

        try {
            if (e.Flow == "render") {
                // A render stream that is not fed runs dry and its clock stops
                // dead, which reads as an enormous but perfectly well-formed
                // drift. The feeder pushes digital silence so the engine keeps
                // running; loopback capture on the same endpoint then supplies
                // per-packet device and host timestamps.
                e.Feed = probe;
                hr = e.Feed.Initialize(SHARED, 0, BUF_100NS, 0, pfmt, IntPtr.Zero);
                if (hr != 0) { e.Error = "init render 0x" + hr.ToString("X8"); return false; }
                object orc;
                if (e.Feed.GetService(ref REN, out orc) != 0) { e.Error = "no render client"; return false; }
                e.Rc = (IAudioRenderClient)orc;
                e.Feed.GetBufferSize(out e.FeedBufFrames);
                e.Fill = MakeFill(e, (int)e.FeedBufFrames * (int)e.Fmt.nBlockAlign);
                object ock;
                if (e.Feed.GetService(ref CLK, out ock) == 0) {
                    e.Clk = (IAudioClock)ock;
                    e.Clk.GetFrequency(out e.ClockFreq);
                }
                object o2;
                if (d.Activate(ref CLI, 1, IntPtr.Zero, out o2) == 0) {
                    IAudioClient lp = (IAudioClient)o2;
                    IntPtr pf2;
                    if (lp.GetMixFormat(out pf2) == 0) {
                        int lhr = lp.Initialize(SHARED, LOOPBACK, BUF_100NS, 0, pf2, IntPtr.Zero);
                        Marshal.FreeCoTaskMem(pf2);
                        if (lhr == 0) {
                            object olc;
                            if (lp.GetService(ref CAP, out olc) == 0) { e.Cap = lp; e.Cc = (IAudioCaptureClient)olc; }
                        }
                    }
                }
            } else {
                if (!wantMic) { e.Error = "skipped (-NoMic)"; return false; }
                e.Cap = probe;
                hr = e.Cap.Initialize(SHARED, 0, BUF_100NS, 0, pfmt, IntPtr.Zero);
                if (hr != 0) { e.Error = "init capture 0x" + hr.ToString("X8"); return false; }
                object olc;
                if (e.Cap.GetService(ref CAP, out olc) != 0) { e.Error = "no capture client"; return false; }
                e.Cc = (IAudioCaptureClient)olc;
                object ock;
                if (e.Cap.GetService(ref CLK, out ock) == 0) {
                    e.Clk = (IAudioClock)ock;
                    e.Clk.GetFrequency(out e.ClockFreq);
                }
            }
        } finally {
            Marshal.FreeCoTaskMem(pfmt);
        }
        e.Opened = true;
        return true;
    }

    public static string Measure(int seconds, int stepMs, bool wantMic) {
        StringBuilder sb = new StringBuilder();
        long qf; QueryPerformanceFrequency(out qf);
        sb.AppendLine("qpcfreq=" + qf.ToString(CultureInfo.InvariantCulture));

        IMMDeviceEnumerator en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
        string defRender = "", defCapture = "";
        IMMDevice dr;
        if (en.GetDefaultAudioEndpoint(0, 0, out dr) == 0) dr.GetId(out defRender);
        IMMDevice dc;
        if (en.GetDefaultAudioEndpoint(1, 0, out dc) == 0) dc.GetId(out defCapture);

        IMMDeviceCollection act;
        int hr = en.EnumAudioEndpoints(2, 1, out act);
        if (hr != 0) { sb.AppendLine("enumerror=0x" + hr.ToString("X8")); return sb.ToString(); }
        uint n; act.GetCount(out n);
        sb.AppendLine("endpoints=" + n.ToString(CultureInfo.InvariantCulture));

        List<Endpoint> eps = new List<Endpoint>();
        for (uint i = 0; i < n; i++) {
            IMMDevice d; act.Item(i, out d);
            Endpoint e = new Endpoint();
            e.Index = (int)i;
            d.GetId(out e.Id);
            e.Name = GetName(d);
            e.Hw = GetHw(d);
            d.GetState(out e.State);
            // The endpoint id encodes the data flow: {0.0.0.x} is render,
            // {0.0.1.x} is capture. Confirmed below by which service the
            // client actually hands back.
            e.Flow = e.Id.StartsWith("{0.0.1.", StringComparison.Ordinal) ? "capture" : "render";
            e.IsDefault = (e.Id == defRender) || (e.Id == defCapture);
            try { OpenOne(d, e, wantMic); }
            catch (Exception ex) { e.Error = ex.GetType().Name + ": " + ex.Message; e.Opened = false; }
            eps.Add(e);
        }

        foreach (Endpoint e in eps) {
            if (!e.Opened) continue;
            try {
                Service(e);
                if (e.Feed != null) e.Feed.Start();
                if (e.Cap != null) e.Cap.Start();
            } catch (Exception ex) { e.Error = "start: " + ex.Message; e.Opened = false; }
        }

        // Readiness, not a fixed head start: wait until each stream is really
        // producing before the first sample is taken.
        for (int spin = 0; spin < 1000; spin++) {
            bool all = true;
            foreach (Endpoint e in eps) {
                if (!e.Opened) continue;
                Service(e);
                if (e.Packets > 1) { e.Ready = true; } else { all = false; }
            }
            if (all) break;
            System.Threading.Thread.Sleep(5);
        }
        // Discard everything gathered during warm-up so the fit starts from a
        // running stream.
        foreach (Endpoint e in eps) {
            e.PktX.Clear(); e.PktY.Clear(); e.PktFirst = true;
            e.ClkX.Clear(); e.ClkY.Clear(); e.ClkFirst = true;
        }

        long t0; QueryPerformanceCounter(out t0);
        while (true) {
            long now; QueryPerformanceCounter(out now);
            if ((double)(now - t0) / (double)qf >= seconds) break;
            foreach (Endpoint e in eps) {
                if (!e.Opened) continue;
                Service(e);
                SampleClock(e);
            }
            System.Threading.Thread.Sleep(stepMs);
        }

        foreach (Endpoint e in eps) {
            if (!e.Opened) continue;
            try {
                if (e.Feed != null) e.Feed.Stop();
                if (e.Cap != null) e.Cap.Stop();
            } catch { }
        }

        EmitEndpoints(sb, eps);

        foreach (Endpoint e in eps) {
            try {
                if (e.Rc  != null) Marshal.ReleaseComObject(e.Rc);
                if (e.Cc  != null) Marshal.ReleaseComObject(e.Cc);
                if (e.Clk != null) Marshal.ReleaseComObject(e.Clk);
                if (e.Cap != null) Marshal.ReleaseComObject(e.Cap);
                if (e.Feed!= null) Marshal.ReleaseComObject(e.Feed);
            } catch { }
        }
        return sb.ToString();
    }
}
}
'@
    try {
        Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop
        $script:NativeReady = $true
        return $true
    } catch {
        $msg = $_.Exception.Message
        $nl = $msg.IndexOf("`n")
        if ($nl -gt 0) { $msg = $msg.Substring(0, $nl) }
        Write-Bad ('audiodrift: cannot build the audio layer: ' + $msg.Trim())
        return $false
    }
}

# ---------------------------------------------------------------------------
# REPORT
# ---------------------------------------------------------------------------
# Schema template. Every computed field must appear here or -Info and
# -FromJson break while the normal path keeps working.
function New-EndpointRecord {
    return [ordered]@{
        Index             = 0
        Id                = ''
        Name              = ''
        Hw                = ''
        Flow              = ''
        State             = 0
        IsDefault         = $false
        Opened            = $false
        Error             = ''
        NominalRate       = 0
        Channels          = 0
        Bits              = 0
        BlockAlign        = 0
        AvgBytesPerSec    = 0
        FormatTag         = 0
        SubFormat         = -1
        SubFormatName     = ''
        ClockFreq         = 0
        FormatConsistent  = $false
        ClockFreqOk       = $false
        Packets           = 0
        SilentPackets     = 0
        Discontinuities   = 0
        TimestampErrors   = 0
        PacketPpm         = 0.0
        PacketSePpm       = 0.0
        PacketSamples     = 0
        PacketSpanSec     = 0.0
        ClockPpm          = 0.0
        ClockSePpm        = 0.0
        ClockSamples      = 0
        MethodsComparable = $false
        MethodDeltaPpm    = 0.0
        Measured          = $false
        MeasureNote       = ''
        Method            = ''
        Ppm               = 0.0
        SePpm             = 0.0
        SeOlsPpm          = 0.0
        SeEmpiricalPpm    = 0.0
        Samples           = 0
        SpanSec           = 0.0
        TrueRate          = 0.0
        Plausible         = $false
        Usable            = $false
        UsabilityNote     = ''
        WindowPpms        = @()
        WindowSpreadPpm   = 0.0
        MsPerHour         = 0.0
        ClockDomain       = -1
    }
}

function New-AudioDriftReport {
    return [ordered]@{
        Tool            = 'audiodrift'
        Version         = $script:AudioDriftVersion
        GeneratedUtc    = ''
        Machine         = ''
        QpcFrequency    = 0
        RequestedSeconds= 0
        EndpointCount   = 0
        MeasuredCount   = 0
        InactiveCount   = 0
        Endpoints       = @()
        ClockDomainCount= 0
        SystematicFloorPpm = 0.0
        Pairs           = @()
        FpsList         = @()
        RejectedFps     = @()
        Warnings        = @()
    }
}

function ConvertTo-EndpointRecords {
    param($Map, [double[]]$FpsList)
    $out = New-Object Collections.Generic.List[object]
    $count = 0
    if ($Map.ContainsKey('endpoints')) { $count = [int]$Map['endpoints'] }
    for ($i = 0; $i -lt $count; $i++) {
        $p = 'ep.' + [string]$i + '.'
        if (-not $Map.ContainsKey(($p + 'id'))) { continue }
        $r = New-EndpointRecord
        $r.Index      = $i
        $r.Id         = $Map[$p + 'id']
        $r.Name       = $Map[$p + 'name']
        $r.Hw         = [string]$Map[$p + 'hw']
        $r.Flow       = $Map[$p + 'flow']
        $r.State      = [int]$Map[$p + 'state']
        $r.IsDefault  = ($Map[$p + 'default'] -eq '1')
        $r.Opened     = ($Map[$p + 'opened'] -eq '1')
        $r.Error      = $Map[$p + 'error']
        # A 32-bit audio field must be carried as [long]: [int] THROWS on any
        # UInt32 above Int32.MaxValue, and a real format blob on the author's
        # machine holds 4294967032 in this slot. Let the bounds check reject
        # the value instead of crashing before it can be judged.
        $r.NominalRate    = [long]$Map[$p + 'rate']
        $r.Channels       = [int]$Map[$p + 'channels']
        $r.Bits           = [int]$Map[$p + 'bits']
        $r.BlockAlign     = [int]$Map[$p + 'blockalign']
        $r.AvgBytesPerSec = [long]$Map[$p + 'avgbytes']
        $r.FormatTag      = [int]$Map[$p + 'formattag']
        $r.SubFormat      = [int]$Map[$p + 'subformat']
        $r.SubFormatName  = Get-SubFormatName -Code $r.SubFormat
        $r.ClockFreq      = [long]$Map[$p + 'clockfreq']
        $r.Packets        = [int]$Map[$p + 'packets']
        $r.SilentPackets  = [int]$Map[$p + 'silentpackets']
        $r.Discontinuities= [int]$Map[$p + 'discont']
        $r.TimestampErrors= [int]$Map[$p + 'tserror']

        $fr = Test-FormatRedundancy -Rate $r.NominalRate -Channels $r.Channels -Bits $r.Bits `
                                    -BlockAlign $r.BlockAlign -AvgBytes $r.AvgBytesPerSec
        $r.FormatConsistent = $fr.Ok
        $cf = Test-ClockFrequency -ClockFreq $r.ClockFreq -AvgBytes $r.AvgBytesPerSec -Rate $r.NominalRate
        $r.ClockFreqOk = $cf.Ok

        $px = ConvertFrom-Series -Text $Map[$p + 'pkt.x']
        $py = ConvertFrom-Series -Text $Map[$p + 'pkt.y']
        $cx = ConvertFrom-Series -Text $Map[$p + 'clk.x']
        $cy = ConvertFrom-Series -Text $Map[$p + 'clk.y']

        $rec = Set-EndpointMeasurement -Record $r -PktX $px -PktY $py -ClkX $cx -ClkY $cy
        [void]$out.Add($rec)
    }
    return ,$out.ToArray()
}

# One method's numbers, with both an assumed and an observed uncertainty.
function Measure-Series {
    param([double[]]$X, [double[]]$Y, [string]$Name)
    $xs = @($X); $ys = @($Y)
    if ($xs.Count -lt 3) { return $null }
    $fit = Get-LinearFit -X $xs -Y $ys
    if ($null -eq $fit) { return $null }
    $ppm = ConvertTo-Ppm -Slope $fit.Slope
    $ols = $fit.StdErr * 1000000.0
    $wf  = Get-WindowFits -X $xs -Y $ys -Windows $script:Windows
    $emp = Get-EmpiricalError -Fits $wf -Ppm $ppm
    # Never report the smaller of the two. The regression error assumes the
    # residuals are independent; where the batch scatter is larger they are
    # not, and the regression error is a fiction.
    $se = $ols
    if ($emp.Usable -and ($emp.SeEmpirical -gt $se)) { $se = $emp.SeEmpirical }
    return @{
        Name      = $Name
        Slope     = $fit.Slope
        Ppm       = $ppm
        SeOls     = $ols
        SeEmp     = $emp.SeEmpirical
        Se        = $se
        N         = $fit.N
        SpanSec   = $fit.SpanX
        WindowPpms= @($emp.Ppms)
        Spread    = $emp.SpreadPpm
        HasEmp    = $emp.Usable
    }
}

# Pulled out of the collection path so ground-truth tests can drive the whole
# decision with planted series instead of racing a real audio stream.
function Set-EndpointMeasurement {
    param($Record, [double[]]$PktX, [double[]]$PktY, [double[]]$ClkX, [double[]]$ClkY)
    $r = $Record
    $pm = Measure-Series -X $PktX -Y $PktY -Name 'packet timestamps'
    $cm = Measure-Series -X $ClkX -Y $ClkY -Name 'IAudioClock polling'

    if ($null -ne $pm) {
        $r.PacketPpm     = $pm.Ppm
        $r.PacketSePpm   = $pm.Se
        $r.PacketSamples = $pm.N
        $r.PacketSpanSec = $pm.SpanSec
    }
    if ($null -ne $cm) {
        $r.ClockPpm     = $cm.Ppm
        $r.ClockSePpm   = $cm.Se
        $r.ClockSamples = $cm.N
    }
    $r.MethodsComparable = (($null -ne $pm) -and ($null -ne $cm))
    if ($r.MethodsComparable) {
        $r.MethodDeltaPpm = [math]::Abs($r.PacketPpm - $r.ClockPpm)
    }

    # Neither method wins everywhere, and assuming one does is how a confident
    # wrong number gets printed. On a capture endpoint the per-packet device
    # timestamps are ~1000x tighter than polling the clock; on a render
    # endpoint the loopback tap that supplies those packets reports the engine
    # mix rather than the converter, and polling wins by a similar margin.
    # So measure both ways and report whichever DEMONSTRATES the lower
    # uncertainty on this run, rather than whichever theory prefers.
    $use = $null
    if (($null -ne $pm) -and ($null -ne $cm)) {
        $use = $pm
        if ($cm.Se -lt $pm.Se) { $use = $cm }
    } elseif ($null -ne $pm) { $use = $pm }
    elseif ($null -ne $cm) { $use = $cm }

    if ($null -eq $use) {
        $r.Measured = $false
        if (-not $r.Opened) {
            $note = $r.Error
            if ([string]::IsNullOrEmpty($note)) { $note = 'endpoint could not be opened' }
            $r.MeasureNote = $note
        } else {
            $r.MeasureNote = 'no usable samples collected'
        }
        return $r
    }

    $r.Method          = $use.Name
    $r.Ppm             = $use.Ppm
    $r.SeOlsPpm        = $use.SeOls
    $r.SeEmpiricalPpm  = $use.SeEmp
    $r.SePpm           = $use.Se
    $r.Samples         = $use.N
    $r.SpanSec         = $use.SpanSec
    $r.WindowPpms      = @($use.WindowPpms)
    $r.WindowSpreadPpm = $use.Spread
    $r.TrueRate        = $r.NominalRate * $use.Slope
    $r.MsPerHour       = Get-DriftMsPerHour -Ppm $r.Ppm
    $r.Plausible       = Test-PpmPlausible -Ppm $r.Ppm
    $r.Usable          = ($r.SePpm -le $script:MaxUsableSePpm)

    if (-not $r.FormatConsistent) {
        $r.Measured = $false
        $r.MeasureNote = 'format fields are not self-consistent; refusing to report a rate'
    } elseif (-not $r.ClockFreqOk) {
        $r.Measured = $false
        $r.MeasureNote = 'audio clock frequency does not match the stream format'
    } elseif (-not $r.Plausible) {
        $r.Measured = $false
        $r.MeasureNote = 'reading of ' + (Format-Ppm -Ppm $r.Ppm -Decimals 0) + ' ppm is not a crystal tolerance (resampled or virtual endpoint)'
    } elseif (-not $r.Usable) {
        $r.Measured = $false
        $r.UsabilityNote = 'uncertainty ' + (Format-Ppm -Ppm $r.SePpm) + ' ppm exceeds the ' +
                           (Format-Ppm -Ppm $script:MaxUsableSePpm -Decimals 1) + ' ppm needed to be worth reporting'
        $r.MeasureNote = $r.UsabilityNote
    } else {
        $r.Measured = $true
        $r.MeasureNote = ''
    }
    return $r
}

function Get-AudioDriftReport {
    param($Map, [double[]]$FpsList, [int]$RequestedSeconds)
    $rep = New-AudioDriftReport
    $rep.GeneratedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $rep.Machine      = $env:COMPUTERNAME
    $rep.RequestedSeconds = $RequestedSeconds
    $rep.FpsList      = @($FpsList)
    if ($Map.ContainsKey('qpcfreq')) { $rep.QpcFrequency = [long]$Map['qpcfreq'] }

    $eps = ConvertTo-EndpointRecords -Map $Map -FpsList $FpsList
    $rep.Endpoints     = @($eps)
    $rep.EndpointCount = @($eps).Count

    $warn = New-Object Collections.Generic.List[string]
    $measured = 0
    foreach ($e in @($eps)) {
        if ($e.Measured) { $measured++ }
        if ($e.Opened -and -not $e.FormatConsistent) {
            [void]$warn.Add('Endpoint ' + [string]($e.Index + 1) + ': WAVEFORMATEX fields do not agree with each other')
        }
        if ($e.Opened -and -not $e.ClockFreqOk) {
            [void]$warn.Add('Endpoint ' + [string]($e.Index + 1) + ': audio clock frequency ' + [string]$e.ClockFreq + ' matches neither the byte rate nor the sample rate')
        }
        if ($e.Discontinuities -gt 0) {
            [void]$warn.Add('Endpoint ' + [string]($e.Index + 1) + ': ' + [string]$e.Discontinuities + ' glitch(es) reported by the driver during the run')
        }
    }
    $rep.MeasuredCount = $measured

    $floor = Get-SystematicFloor -Endpoints $eps -Default $script:DefaultFloorPpm
    $rep.SystematicFloorPpm = $floor
    $rep.ClockDomainCount = ConvertTo-ClockDomains -Endpoints $eps -FloorPpm $floor
    # A function returning ",$array" emits it as ONE pipeline object, so
    # @(f()) would build a 1-element array CONTAINING the array. Assign first.
    $pairs = Get-EndpointPairs -Endpoints $eps -FloorPpm $floor -FpsList $FpsList
    $rep.Pairs = @($pairs)
    $rep.Warnings = @($warn.ToArray())
    return [pscustomobject]$rep
}

# ---------------------------------------------------------------------------
# HUMAN OUTPUT
# ---------------------------------------------------------------------------
function Show-AudioDriftReport {
    param($Report)
    $g = Get-Glyphs
    Write-Line ''
    Write-Head ('audiodrift ' + $Report.Version + '  ' + $g.dash + '  the sample rate your hardware actually runs at')
    Write-Line ''

    foreach ($e in @($Report.Endpoints)) {
        $tag = $e.Flow
        if ($e.IsDefault) { $tag = $tag + ', default' }
        Write-Line ('  [' + [string]($e.Index + 1) + '] ' + $e.Name)
        Write-Line ('      ' + $tag + '   nominal ' + [string]$e.NominalRate + ' Hz, ' +
                    [string]$e.Channels + ' ch, ' + [string]$e.Bits + '-bit ' + $e.SubFormatName)
        if ($e.Measured) {
            $sign = ''
            if ($e.Ppm -ge 0) { $sign = '+' }
            Write-Good ('      measured ' + (Format-Rate -Hz $e.TrueRate) + ' Hz   ' +
                        $sign + (Format-Ppm -Ppm $e.Ppm) + ' ppm  ' +
                        $g.pm + ' ' + (Format-Ppm -Ppm $e.SePpm) + ' ppm')
            Write-Line ('      that is ' + (Format-Ms -Ms ([math]::Abs($e.MsPerHour))) +
                        ' ms of drift per hour against the system clock')
            if ($e.Method -eq 'packet timestamps') {
                Write-Line ('      via ' + $e.Method + ', ' + [string]$e.Samples + ' packets over ' +
                            ('{0:F1}' -f $e.SpanSec) + ' s')
            } else {
                Write-Line ('      via ' + $e.Method + ', ' + [string]$e.Samples + ' samples over ' +
                            ('{0:F1}' -f $e.SpanSec) + ' s')
            }
            if ($e.MethodsComparable) {
                $other = 'IAudioClock polling'
                $otherPpm = $e.ClockPpm
                $otherSe = $e.ClockSePpm
                if ($e.Method -ne 'packet timestamps') {
                    $other = 'loopback packet timestamps'
                    $otherPpm = $e.PacketPpm
                    $otherSe = $e.PacketSePpm
                }
                Write-Line ('      cross-check: ' + $other + ' gives ' + (Format-Ppm -Ppm $otherPpm) +
                            ' ' + $g.pm + ' ' + (Format-Ppm -Ppm $otherSe) +
                            ' ppm, a difference of ' + (Format-Ppm -Ppm $e.MethodDeltaPpm) + ' ppm')
            }
            Write-Line ('      uncertainty: regression ' + (Format-Ppm -Ppm $e.SeOlsPpm) +
                        ' ppm, batch scatter ' + (Format-Ppm -Ppm $e.SeEmpiricalPpm) +
                        ' ppm; the larger is reported')
        } else {
            $note = $e.MeasureNote
            if ([string]::IsNullOrEmpty($note)) { $note = 'not measured' }
            if ([String]::Equals($note, $script:SkipMeasureNote, [StringComparison]::Ordinal)) {
                Write-Line ('      ' + $note)
            } else {
                Write-Warn ('      ' + $g.warn + ' ' + $note)
            }
        }
        Write-Line ''
    }

    if (@($Report.Endpoints).Count -gt 0 -and $Report.MeasuredCount -gt 0) {
        Write-Head '  CLOCK DOMAINS'
        Write-Line ('    endpoints whose measured rates agree within ' +
                    (Format-Ppm -Ppm $Report.SystematicFloorPpm) + ' ppm are locked to the same clock')
        $groups = @{}
        $hwsets = @{}
        foreach ($e in @($Report.Endpoints)) {
            if ($e.ClockDomain -lt 0) { continue }
            $k = [string]$e.ClockDomain
            if (-not $groups.ContainsKey($k)) {
                $groups[$k] = New-Object Collections.Generic.List[string]
                $hwsets[$k] = @{}
            }
            [void]$groups[$k].Add('[' + [string]($e.Index + 1) + '] ' + $e.Name)
            $hwsets[$k][[string]$e.Hw] = $true
        }
        foreach ($k in ($groups.Keys | Sort-Object)) {
            Write-Line ('    domain ' + ([string]([int]$k + 1)) + ': ' + (($groups[$k].ToArray()) -join '  +  '))
            # Measuring as locked is not the same as sharing a crystal. Two
            # interfaces of one physical device share an oscillator. Two
            # separate devices that still read as locked are locked because
            # something resamples one of them onto the other's clock - which is
            # just as safe to record, but it is a different fact, and the tool
            # knows which is which from the device instance path rather than
            # from the measurement.
            $paths = @($hwsets[$k].Keys | Where-Object { -not [string]::IsNullOrEmpty($_) })
            $unknown = @($hwsets[$k].Keys | Where-Object { [string]::IsNullOrEmpty($_) }).Count
            if (@($groups[$k]).Count -lt 2) { continue }
            if ($unknown -gt 0) {
                # Windows did not name the hardware behind at least one of these.
                # One known path plus one unknown is not agreement, and claiming
                # a shared crystal from it would be inventing the evidence.
                Write-Line '          Windows does not name the hardware behind all of these, so neither claim is made'
            } elseif (@($paths).Count -eq 1) {
                Write-Line '          one physical device, so this is one crystal'
            } elseif (@($paths).Count -gt 1) {
                Write-Line ('          ' + [string]@($paths).Count + ' separate physical devices: locked, but by resampling, not by a shared crystal')
            }
        }
        Write-Line ''
    }

    if (@($Report.Pairs).Count -gt 0) {
        Write-Head '  WILL THESE TWO DRIFT APART?'
        Write-Line ''
        $hdr = '    ' + (Format-Col -Text 'pair' -Width 13) +
               (Format-Col -Text 'relative' -Width 14) +
               (Format-Col -Text 'apart per hour' -Width 17) +
               'verdict'
        Write-Line $hdr
        foreach ($p in @($Report.Pairs)) {
            $pairTxt = '[' + [string]($p.AIndex + 1) + '] vs [' + [string]($p.BIndex + 1) + ']'
            $verdict = 'DRIFTS APART'
            if ($p.SameClock) { $verdict = 'same clock, locked' }
            $line = '    ' + (Format-Col -Text $pairTxt -Width 13) +
                    (Format-Col -Text ((Format-Ppm -Ppm $p.RelativePpm) + ' ppm') -Width 14) +
                    (Format-Col -Text ((Format-Ms -Ms $p.MsPerHour) + ' ms') -Width 17) +
                    $verdict
            if ($p.SameClock) { Write-Good $line } else { Write-Warn $line }
            foreach ($s in @($p.FrameSlip)) {
                $txt = '        at ' + ('{0:0.###}' -f $s.Fps) + ' fps, one frame out of sync after ' +
                       (Format-Duration -Seconds $s.SecondsPerSlip)
                Write-Line $txt
            }
        }
        Write-Line ''
    }

    $rfProp = $Report.PSObject.Properties['RejectedFps']
    if ($null -ne $rfProp) {
        foreach ($rf in @($rfProp.Value)) {
            Write-Warn ('  ' + $g.warn + ' ignored -Fps value "' + [string]$rf + '"')
        }
    }
    foreach ($w in @($Report.Warnings)) { Write-Warn ('  ' + $g.warn + ' ' + $w) }
}

function Show-Quiet {
    param($Report)
    foreach ($e in @($Report.Endpoints)) {
        if ($e.Measured) {
            $sign = ''
            if ($e.Ppm -ge 0) { $sign = '+' }
            Write-Host ([string]($e.Index + 1) + '  ' + (Format-Rate -Hz $e.TrueRate) + ' Hz  ' +
                        $sign + (Format-Ppm -Ppm $e.Ppm) + ' ppm  ' + $e.Flow + '  ' + $e.Name)
        } else {
            Write-Host ([string]($e.Index + 1) + '  -  ' + $e.Flow + '  ' + $e.Name)
        }
    }
}

# ---------------------------------------------------------------------------
function Invoke-Main {
    if ($NoRun) { return }

    if ($Json -or $Quiet) { $script:Silent = $true }

    if ($Info) {
        $script:Silent = $false
        Write-Head ('audiodrift ' + $script:AudioDriftVersion)
        Write-Line 'Measures the true sample rate of every Windows audio endpoint.'
        Write-Line ''
        Write-Line 'Read-only. It opens its own audio streams and reads clocks.'
        Write-Line 'No device setting, registry value or file is changed.'
        Write-Line ''
        Write-Line 'Endpoint fields:'
        $tpl = New-EndpointRecord
        foreach ($k in $tpl.Keys) { Write-Line ('  ' + $k) }
        return
    }

    if ($FromJson.Length -gt 0) {
        if (-not (Test-Path -LiteralPath $FromJson)) {
            $script:Silent = $false
            Write-Bad ('audiodrift: file not found: ' + $FromJson)
            return
        }
        $txt = ''
        try { $txt = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $FromJson).ProviderPath) }
        catch { $script:Silent = $false; Write-Bad ('audiodrift: cannot read ' + $FromJson); return }
        $obj = $null
        try { $obj = ConvertFrom-Json -InputObject $txt }
        catch { $script:Silent = $false; Write-Bad ('audiodrift: not valid JSON: ' + $FromJson); return }
        $script:Silent = $false
        Show-AudioDriftReport -Report $obj
        return
    }

    $fpsParsed = ConvertTo-FpsList -Raw $Fps -Default $script:DefaultFps
    foreach ($badFps in @($fpsParsed.Rejected)) {
        # stderr, so the user still sees it when stdout must stay parseable
        Write-Err ('audiodrift: ignoring unusable -Fps value "' + $badFps + '"')
    }

    if ($Seconds -lt 3) {
        Write-Err 'audiodrift: -Seconds below 3 cannot produce a usable fit; using 3'
        $Seconds = 3
    }

    if (-not (Initialize-AudioDriftNative)) { return }

    $raw = ''
    try {
        if ($SkipMeasure) { $raw = [AudioDriftNative.Engine]::Enumerate() }
        else {
            if (-not $script:Silent) {
                Write-Line ''
                Write-Line ('  measuring for ' + [string]$Seconds + ' s ...')
            }
            $raw = [AudioDriftNative.Engine]::Measure($Seconds, 5, (-not $NoMic))
        }
    } catch {
        $m = $_.Exception.Message
        $nl = $m.IndexOf("`n")
        if ($nl -gt 0) { $m = $m.Substring(0, $nl) }
        Write-Bad ('audiodrift: audio subsystem call failed: ' + $m.Trim())
        return
    }

    $map = ConvertFrom-AdRecords -Text $raw
    $report = Get-AudioDriftReport -Map $map -FpsList @($fpsParsed.Values) -RequestedSeconds $Seconds
    $report.RejectedFps = @($fpsParsed.Rejected)

    if ($Json) {
        $script:Silent = $true
        ($report | ConvertTo-Json -Depth 8)
        return
    }
    if ($Quiet) { Show-Quiet -Report $report; return }
    Show-AudioDriftReport -Report $report
}

Invoke-Main
