<#
    selftest.ps1 - hermetic ground-truth tests for audiodrift.

    Every test here drives the tool's pure functions with synthetic data whose
    correct answer is known in advance. Nothing here touches audio hardware,
    so the result does not depend on what the machine is doing.

    Run:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File selftest.ps1
#>
[CmdletBinding()]
param([switch]$Detail)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Locals are prefixed t_ throughout. Dot-sourcing the tool imports its
# param() type constraints into this scope, so a local named $Json would be
# forced to [switch] and throw on assignment with a message naming THIS file.
$t_here = Split-Path -Parent $MyInvocation.MyCommand.Path
$t_tool = Join-Path $t_here 'audiodrift.ps1'
if (-not (Test-Path -LiteralPath $t_tool)) { Write-Host 'cannot find audiodrift.ps1'; exit 1 }
. $t_tool -NoRun

$t_pass = 0
$t_fail = 0
$t_msgs = New-Object Collections.Generic.List[string]

function t_Ok { param([string]$Name, [bool]$Cond, [string]$Info = '')
    if ($Cond) {
        $script:t_pass++
        if ($Detail -and $Info.Length -gt 0) { Write-Host ('  [ok]   ' + $Name + '  ' + $Info) -ForegroundColor DarkGray }
        elseif ($Detail) { Write-Host ('  [ok]   ' + $Name) -ForegroundColor DarkGray }
    } else {
        $script:t_fail++
        Write-Host ('  [FAIL] ' + $Name + '  ' + $Info) -ForegroundColor Red
        [void]$script:t_msgs.Add($Name + ': ' + $Info)
    }
}
function t_Eq { param([string]$Name, $Expected, $Actual)
    $t_e = [string]$Expected; $t_a = [string]$Actual
    t_Ok -Name $Name -Cond ($t_e -eq $t_a) -Info ('expected "' + $t_e + '" got "' + $t_a + '"')
}
function t_Near { param([string]$Name, [double]$Expected, [double]$Actual, [double]$Tol)
    $t_d = [math]::Abs($Expected - $Actual)
    t_Ok -Name $Name -Cond ($t_d -le $Tol) -Info ('expected ' + ('{0:F9}' -f $Expected) + ' got ' + ('{0:F9}' -f $Actual) + ' (tol ' + ('{0:F9}' -f $Tol) + ')')
}
function t_Section { param([string]$Name)
    Write-Host ''
    Write-Host ('== ' + $Name) -ForegroundColor Cyan
}

# Build a device-seconds / host-seconds series for a clock running at a known
# ppm offset. This is the ground truth the regression must recover.
function t_MakeSeries {
    param([double]$Ppm, [int]$N, [double]$StepSec, [double]$Jitter = 0.0, [int]$Seed = 1234)
    $t_rnd = New-Object Random($Seed)
    $t_x = New-Object Collections.Generic.List[double]
    $t_y = New-Object Collections.Generic.List[double]
    $t_slope = 1.0 + ($Ppm / 1000000.0)
    for ($t_i = 0; $t_i -lt $N; $t_i++) {
        $t_hx = $t_i * $StepSec
        $t_j = 0.0
        if ($Jitter -gt 0.0) { $t_j = ($t_rnd.NextDouble() - 0.5) * 2.0 * $Jitter }
        [void]$t_x.Add($t_hx)
        [void]$t_y.Add(($t_hx * $t_slope) + $t_j)
    }
    return @{ X = $t_x.ToArray(); Y = $t_y.ToArray() }
}

Write-Host ''
Write-Host 'audiodrift selftest - hermetic ground truth' -ForegroundColor Cyan

# ---------------------------------------------------------------------------
t_Section 'regression recovers a planted rate exactly'
# A noiseless series has one exact answer, so this is a pure arithmetic check.
# Each planted value is distinct, so a function that returns a constant or
# mixes two cases up cannot pass.
foreach ($t_p in @(0.0, 1.0, -1.0, 2.5, -7.25, 123.75, -999.5)) {
    $t_s = t_MakeSeries -Ppm $t_p -N 400 -StepSec 0.01
    $t_f = Get-LinearFit -X $t_s.X -Y $t_s.Y
    $t_got = ConvertTo-Ppm -Slope $t_f.Slope
    t_Near -Name ('recovers planted ' + ('{0:F2}' -f $t_p) + ' ppm') -Expected $t_p -Actual $t_got -Tol 0.000001
}
$t_s = t_MakeSeries -Ppm 5.0 -N 400 -StepSec 0.01
$t_f = Get-LinearFit -X $t_s.X -Y $t_s.Y
t_Eq -Name 'fit reports the sample count it was given' -Expected 400 -Actual $t_f.N
t_Near -Name 'fit reports the span it was given' -Expected 3.99 -Actual $t_f.SpanX -Tol 0.000001
t_Near -Name 'noiseless fit has zero standard error' -Expected 0.0 -Actual $t_f.StdErr -Tol 0.000000001

# ---------------------------------------------------------------------------
t_Section 'regression is robust to an offset and to noise'
# A device position series starts at an arbitrary offset; the SLOPE must not
# care. If the code ever computed (last-first)/(last-first) this would still
# pass, so the noisy case below is the one that separates them.
$t_s = t_MakeSeries -Ppm 12.0 -N 500 -StepSec 0.01
$t_shift = New-Object Collections.Generic.List[double]
foreach ($t_v in $t_s.Y) { [void]$t_shift.Add($t_v + 987.654) }
$t_f = Get-LinearFit -X $t_s.X -Y $t_shift.ToArray()
t_Near -Name 'a constant offset does not change the rate' -Expected 12.0 -Actual (ConvertTo-Ppm -Slope $t_f.Slope) -Tol 0.000001
t_Near -Name 'the offset is recovered as the intercept' -Expected 987.654 -Actual $t_f.Intercept -Tol 0.000001

# With symmetric noise the least-squares answer stays close, while a
# first-vs-last estimator would be at the mercy of two samples.
$t_s = t_MakeSeries -Ppm 30.0 -N 2000 -StepSec 0.01 -Jitter 0.00002 -Seed 99
$t_f = Get-LinearFit -X $t_s.X -Y $t_s.Y
$t_fitPpm = ConvertTo-Ppm -Slope $t_f.Slope
t_Ok -Name 'least squares survives noise' -Cond ([math]::Abs($t_fitPpm - 30.0) -lt 2.0) -Info ('got ' + ('{0:F4}' -f $t_fitPpm))
$t_n = @($t_s.X).Count
$t_endToEnd = ConvertTo-Ppm -Slope (($t_s.Y[$t_n-1] - $t_s.Y[0]) / ($t_s.X[$t_n-1] - $t_s.X[0]))
t_Ok -Name 'least squares beats a first-vs-last estimate on the same data' `
     -Cond ([math]::Abs($t_fitPpm - 30.0) -lt [math]::Abs($t_endToEnd - 30.0)) `
     -Info ('fit err ' + ('{0:F4}' -f [math]::Abs($t_fitPpm - 30.0)) + ' vs end-to-end err ' + ('{0:F4}' -f [math]::Abs($t_endToEnd - 30.0)))
t_Ok -Name 'noisy fit reports a non-zero uncertainty' -Cond ($t_f.StdErr -gt 0) -Info ([string]$t_f.StdErr)

# ---------------------------------------------------------------------------
t_Section 'degenerate input is refused, not guessed'
t_Ok -Name 'fewer than 3 points returns null' -Cond ($null -eq (Get-LinearFit -X @(1.0,2.0) -Y @(1.0,2.0)))
t_Ok -Name 'zero variance in x returns null' -Cond ($null -eq (Get-LinearFit -X @(5.0,5.0,5.0,5.0) -Y @(1.0,2.0,3.0,4.0)))
$t_threw = $false
try { [void](Get-LinearFit -X @(1.0,2.0,3.0) -Y @(1.0,2.0)) } catch { $t_threw = $true }
t_Ok -Name 'mismatched series lengths throw rather than silently truncate' -Cond $t_threw

# ---------------------------------------------------------------------------
t_Section 'ppm conversions'
t_Near -Name 'slope 1.0 is 0 ppm' -Expected 0.0 -Actual (ConvertTo-Ppm -Slope 1.0) -Tol 1e-12
t_Near -Name 'slope 1.000001 is 1 ppm' -Expected 1.0 -Actual (ConvertTo-Ppm -Slope 1.000001) -Tol 1e-9
t_Near -Name 'ppm round-trips through slope' -Expected 43.5 -Actual (ConvertTo-Ppm -Slope (ConvertFrom-Ppm -Ppm 43.5)) -Tol 1e-9
# Hand-computed: 1 ppm is 1 microsecond per second, so 3600 s x 1 us = 3600 us
# = 3.6 ms. Distinct values so a transposed constant cannot pass.
t_Near -Name '1 ppm is 3.6 ms per hour' -Expected 3.6 -Actual (Get-DriftMsPerHour -Ppm 1.0) -Tol 1e-9
t_Near -Name '10 ppm is 36 ms per hour' -Expected 36.0 -Actual (Get-DriftMsPerHour -Ppm 10.0) -Tol 1e-9
t_Near -Name '-2.5 ppm is -9 ms per hour' -Expected -9.0 -Actual (Get-DriftMsPerHour -Ppm -2.5) -Tol 1e-9

# ---------------------------------------------------------------------------
t_Section 'frame slip arithmetic'
# At 1 ppm the clocks separate by 1 us per second. One 30fps frame is
# 33333.33 us, so that takes 33333.33 s. Independently computed here.
t_Near -Name '1 ppm at 30 fps slips a frame in 33333.33 s' -Expected 33333.333333 -Actual (Get-SecondsPerFrameSlip -Ppm 1.0 -Fps 30.0) -Tol 0.001
t_Near -Name '1 ppm at 60 fps slips a frame in 16666.67 s' -Expected 16666.666667 -Actual (Get-SecondsPerFrameSlip -Ppm 1.0 -Fps 60.0) -Tol 0.001
t_Near -Name '100 ppm at 24 fps slips a frame in 416.67 s' -Expected 416.666667 -Actual (Get-SecondsPerFrameSlip -Ppm 100.0 -Fps 24.0) -Tol 0.001
# Direction must not matter: a clock that is slow drifts just as far as one
# that is fast.
t_Near -Name 'slip is symmetric in sign' -Expected (Get-SecondsPerFrameSlip -Ppm 7.0 -Fps 60.0) -Actual (Get-SecondsPerFrameSlip -Ppm -7.0 -Fps 60.0) -Tol 1e-9
t_Ok -Name 'zero drift never slips' -Cond ([double]::IsInfinity((Get-SecondsPerFrameSlip -Ppm 0.0 -Fps 60.0)))
t_Ok -Name 'zero fps is refused rather than dividing by zero' -Cond ([double]::IsInfinity((Get-SecondsPerFrameSlip -Ppm 5.0 -Fps 0.0)))

# ---------------------------------------------------------------------------
t_Section 'format redundancy gate'
# Real values from this machine: 48000 Hz, 2 ch, 32-bit -> blockAlign 8,
# avgBytes 384000. Every field gets a DIFFERENT wrong value below so a gate
# that only checks one of them cannot pass.
$t_good = Test-FormatRedundancy -Rate 48000 -Channels 2 -Bits 32 -BlockAlign 8 -AvgBytes 384000
t_Ok -Name 'a self-consistent format is accepted' -Cond $t_good.Ok
t_Eq -Name 'expected block align is derived correctly' -Expected 8 -Actual $t_good.ExpectedBlock
t_Eq -Name 'expected byte rate is derived correctly' -Expected 384000 -Actual $t_good.ExpectedAvg
t_Ok -Name 'wrong block align is rejected' -Cond (-not (Test-FormatRedundancy -Rate 48000 -Channels 2 -Bits 32 -BlockAlign 7 -AvgBytes 384000).Ok)
t_Ok -Name 'wrong byte rate is rejected' -Cond (-not (Test-FormatRedundancy -Rate 48000 -Channels 2 -Bits 32 -BlockAlign 8 -AvgBytes 383999).Ok)
t_Ok -Name 'channels swapped with bits is rejected' -Cond (-not (Test-FormatRedundancy -Rate 48000 -Channels 32 -Bits 2 -BlockAlign 8 -AvgBytes 384000).Ok)
# That swap preserves block align exactly (32 x 2 = 2 x 32), so the derived
# fields alone cannot catch it. Confirm it is the independent bit-depth bound
# doing the work, not the arithmetic.
$t_swap = Test-FormatRedundancy -Rate 48000 -Channels 32 -Bits 2 -BlockAlign 8 -AvgBytes 384000
t_Eq -Name 'and the swap does satisfy the derived block align' -Expected 8 -Actual $t_swap.ExpectedBlock
t_Eq -Name 'and the derived byte rate too' -Expected 384000 -Actual $t_swap.ExpectedAvg
t_Ok -Name 'so it is the bit-depth bound that catches it' -Cond (-not $t_swap.BitsValid)
t_Ok -Name 'a 2-bit depth is not a real PCM depth' -Cond (-not (Test-FormatRedundancy -Rate 48000 -Channels 2 -Bits 2 -BlockAlign 0 -AvgBytes 0).BitsValid)
t_Ok -Name '24-bit is accepted as a real depth' -Cond (Test-FormatRedundancy -Rate 48000 -Channels 2 -Bits 24 -BlockAlign 6 -AvgBytes 288000).Ok
t_Ok -Name 'zero channels is rejected' -Cond (-not (Test-FormatRedundancy -Rate 48000 -Channels 0 -Bits 32 -BlockAlign 0 -AvgBytes 0).ChannelsValid)
t_Ok -Name 'an absurd channel count is rejected' -Cond (-not (Test-FormatRedundancy -Rate 48000 -Channels 4096 -Bits 16 -BlockAlign 8192 -AvgBytes 393216000).Ok)
t_Ok -Name 'an absurd sample rate is rejected' -Cond (-not (Test-FormatRedundancy -Rate 2000000 -Channels 2 -Bits 32 -BlockAlign 8 -AvgBytes 16000000).RateValid)
t_Ok -Name 'a zero sample rate is rejected' -Cond (-not (Test-FormatRedundancy -Rate 0 -Channels 2 -Bits 32 -BlockAlign 8 -AvgBytes 0).Ok)
t_Ok -Name 'rate off by a factor of two is rejected' -Cond (-not (Test-FormatRedundancy -Rate 96000 -Channels 2 -Bits 32 -BlockAlign 8 -AvgBytes 384000).Ok)
# 16-bit stereo at 44100 is a completely different consistent set; it must
# also pass, so the gate is not merely hard-coded to one machine's numbers.
t_Ok -Name 'a different consistent format also passes' -Cond (Test-FormatRedundancy -Rate 44100 -Channels 2 -Bits 16 -BlockAlign 4 -AvgBytes 176400).Ok
t_Ok -Name 'mono 8-bit also passes' -Cond (Test-FormatRedundancy -Rate 8000 -Channels 1 -Bits 8 -BlockAlign 1 -AvgBytes 8000).Ok

# ---------------------------------------------------------------------------
t_Section 'audio clock frequency gate'
$t_cf = Test-ClockFrequency -ClockFreq 384000 -AvgBytes 384000 -Rate 48000
t_Ok -Name 'clock ticking in bytes is accepted' -Cond $t_cf.Ok
t_Ok -Name 'and is identified as the byte rate' -Cond $t_cf.MatchesAvgBytes
t_Ok -Name 'and not as the sample rate' -Cond (-not $t_cf.MatchesRate)
$t_cf = Test-ClockFrequency -ClockFreq 48000 -AvgBytes 384000 -Rate 48000
t_Ok -Name 'clock ticking in frames is also accepted' -Cond $t_cf.Ok
t_Ok -Name 'and is identified as the sample rate' -Cond $t_cf.MatchesRate
t_Ok -Name 'a clock matching neither is rejected' -Cond (-not (Test-ClockFrequency -ClockFreq 10000000 -AvgBytes 384000 -Rate 48000).Ok)
t_Ok -Name 'a zero clock frequency is rejected' -Cond (-not (Test-ClockFrequency -ClockFreq 0 -AvgBytes 384000 -Rate 48000).Ok)

# ---------------------------------------------------------------------------
t_Section 'implausible readings are classified, not reported'
t_Ok -Name 'a few ppm is plausible' -Cond (Test-PpmPlausible -Ppm 2.5)
t_Ok -Name 'a large but real crystal error is plausible' -Cond (Test-PpmPlausible -Ppm 250.0)
t_Ok -Name 'exactly at the limit is plausible' -Cond (Test-PpmPlausible -Ppm 1000.0)
t_Ok -Name 'just past the limit is not' -Cond (-not (Test-PpmPlausible -Ppm 1000.1))
# This is the dead-clock signature: a stopped counter divided by a running
# one. It is a well-formed number, which is exactly why it must be caught.
t_Ok -Name 'a stopped clock (-1000000 ppm) is rejected' -Cond (-not (Test-PpmPlausible -Ppm -1000000.0))
t_Ok -Name 'NaN is rejected' -Cond (-not (Test-PpmPlausible -Ppm ([double]::NaN)))
t_Ok -Name 'infinity is rejected' -Cond (-not (Test-PpmPlausible -Ppm ([double]::PositiveInfinity)))

# ---------------------------------------------------------------------------
t_Section 'batch-means uncertainty'
# A perfectly steady series has no batch scatter; a wandering one does. This
# is the property the tool relies on to tell an honest error bar from the
# regression's optimistic one.
$t_steady = t_MakeSeries -Ppm 5.0 -N 800 -StepSec 0.01
$t_wf = Get-WindowFits -X $t_steady.X -Y $t_steady.Y -Windows 8
t_Eq -Name 'eight windows are produced from a long series' -Expected 8 -Actual (@($t_wf).Count)
$t_emp = Get-EmpiricalError -Fits $t_wf -Ppm 5.0
t_Near -Name 'a steady series has no batch scatter' -Expected 0.0 -Actual $t_emp.SeEmpirical -Tol 0.000001
t_Ok -Name 'and every window agrees with the whole' -Cond ($t_emp.SpreadPpm -lt 0.000001) -Info ([string]$t_emp.SpreadPpm)

# Now plant a KNOWN oscillation: alternating halves at +20 and -20 ppm about
# a mean of 0. The whole-series slope is ~0 but the batch means must expose
# the swing, which is exactly the render behaviour observed on real hardware.
$t_ox = New-Object Collections.Generic.List[double]
$t_oy = New-Object Collections.Generic.List[double]
$t_dev = 0.0
for ($t_i = 0; $t_i -lt 800; $t_i++) {
    $t_hx = $t_i * 0.01
    $t_seg = [int][math]::Floor($t_i / 100)
    $t_rate = 1.0 + (20.0 / 1000000.0)
    if (($t_seg % 2) -eq 1) { $t_rate = 1.0 - (20.0 / 1000000.0) }
    $t_dev += 0.01 * $t_rate
    [void]$t_ox.Add($t_hx)
    [void]$t_oy.Add($t_dev)
}
$t_wf = Get-WindowFits -X $t_ox.ToArray() -Y $t_oy.ToArray() -Windows 8
$t_emp = Get-EmpiricalError -Fits $t_wf -Ppm 0.0
t_Ok -Name 'a planted 20 ppm oscillation is exposed by the batch means' -Cond ($t_emp.SeEmpirical -gt 5.0) -Info ('se ' + ('{0:F3}' -f $t_emp.SeEmpirical))
$t_hi = 0; $t_lo = 0
foreach ($t_w in $t_emp.Ppms) {
    if ([math]::Abs($t_w - 20.0) -lt 0.5) { $t_hi++ }
    if ([math]::Abs($t_w + 20.0) -lt 0.5) { $t_lo++ }
}
t_Eq -Name 'four windows recover the +20 ppm half' -Expected 4 -Actual $t_hi
t_Eq -Name 'four windows recover the -20 ppm half' -Expected 4 -Actual $t_lo
$t_whole = Get-LinearFit -X $t_ox.ToArray() -Y $t_oy.ToArray()
t_Ok -Name 'while the whole-series fit alone would have hidden it' `
     -Cond ([math]::Abs((ConvertTo-Ppm -Slope $t_whole.Slope)) -lt 2.0) `
     -Info ('whole-series reads ' + ('{0:F3}' -f (ConvertTo-Ppm -Slope $t_whole.Slope)) + ' ppm')
t_Ok -Name 'the regression error would have understated it' -Cond (($t_whole.StdErr * 1000000.0) -lt $t_emp.SeEmpirical) `
     -Info ('ols ' + ('{0:F3}' -f ($t_whole.StdErr * 1000000.0)) + ' vs batch ' + ('{0:F3}' -f $t_emp.SeEmpirical))
# Assign first, then wrap. Get-WindowFits returns ",$array", which the
# pipeline emits as ONE object - so @(Get-WindowFits ...) would be a
# one-element array CONTAINING the empty array and would count as 1.
$t_few = Get-WindowFits -X @(1.0,2.0,3.0) -Y @(1.0,2.0,3.0) -Windows 8
t_Ok -Name 'too few points for windows returns no windows' -Cond ((@($t_few)).Count -eq 0) -Info ('got ' + [string](@($t_few)).Count)
$t_fewEmp = Get-EmpiricalError -Fits $t_few -Ppm 5.0
t_Ok -Name 'and the empirical error declines to make one up' -Cond (-not $t_fewEmp.Usable)
t_Near -Name 'and reports zero rather than a guess' -Expected 0.0 -Actual $t_fewEmp.SeEmpirical -Tol 1e-12

# The sub-window PARTITION itself, pinned exactly. Mutation testing found
# these four lines were reachable but unasserted: rounding the window size
# up, dropping the final window's tail, or relaxing the minimum sample count
# all produced numbers that looked fine and no test noticed.
$t_partX = New-Object Collections.Generic.List[double]
$t_partY = New-Object Collections.Generic.List[double]
for ($t_i = 0; $t_i -lt 101; $t_i++) {
    [void]$t_partX.Add($t_i * 0.01)
    [void]$t_partY.Add($t_i * 0.01 * (1.0 + (7.0 / 1000000.0)))
}
$t_part = Get-WindowFits -X $t_partX.ToArray() -Y $t_partY.ToArray() -Windows 4
t_Eq -Name '101 samples split into exactly 4 windows' -Expected 4 -Actual (@($t_part)).Count
$t_counts = New-Object Collections.Generic.List[int]
foreach ($t_w in @($t_part)) { [void]$t_counts.Add($t_w.N) }
# 101 / 4 rounds DOWN to 25 and the remainder goes to the last window.
# Rounding up would give 26,26,26,23; dropping the tail would give 25,25,25,25.
t_Eq -Name 'windows are 25,25,25,26 - the size rounds down and the tail absorbs the remainder' `
     -Expected '25,25,25,26' -Actual ((@($t_counts.ToArray())) -join ',')
$t_sumN = 0
foreach ($t_c in $t_counts) { $t_sumN += $t_c }
t_Eq -Name 'and every sample lands in exactly one window' -Expected 101 -Actual $t_sumN
$t_lastW = @($t_part)[3]
t_Near -Name 'the final window really reaches the last sample' `
       -Expected ($t_partX[100] - $t_partX[75]) -Actual $t_lastW.SpanX -Tol 1e-12

# A window needs enough samples for a regression to mean anything. One below
# the threshold must yield NOTHING rather than a fit built from two points.
$t_justUnderX = New-Object Collections.Generic.List[double]
$t_justUnderY = New-Object Collections.Generic.List[double]
for ($t_i = 0; $t_i -lt 11; $t_i++) { [void]$t_justUnderX.Add($t_i * 1.0); [void]$t_justUnderY.Add($t_i * 1.0) }
$t_under = Get-WindowFits -X $t_justUnderX.ToArray() -Y $t_justUnderY.ToArray() -Windows 4
t_Eq -Name '11 samples across 4 windows is below the minimum and yields no windows' -Expected 0 -Actual (@($t_under)).Count
$t_justOverX = New-Object Collections.Generic.List[double]
$t_justOverY = New-Object Collections.Generic.List[double]
for ($t_i = 0; $t_i -lt 12; $t_i++) { [void]$t_justOverX.Add($t_i * 1.0); [void]$t_justOverY.Add($t_i * 1.0) }
$t_over = Get-WindowFits -X $t_justOverX.ToArray() -Y $t_justOverY.ToArray() -Windows 4
t_Eq -Name 'one more sample crosses the threshold and yields all 4' -Expected 4 -Actual (@($t_over)).Count

# The batch-means divisor, against arithmetic done by hand. Window rates of
# 10, 20, 30 and 40 ppm have mean 25 and squared deviations 225+25+25+225=500.
# The SAMPLE standard deviation divides by N-1=3: sqrt(500/3)=12.90994449,
# and the standard error of the mean divides that by sqrt(4): 6.45497224.
# Using the population divisor N=4 would give 5.59016994 instead - close
# enough to look right, which is precisely why it needs pinning.
$t_handFits = @(
    @{ Slope = (ConvertFrom-Ppm -Ppm 10.0) },
    @{ Slope = (ConvertFrom-Ppm -Ppm 20.0) },
    @{ Slope = (ConvertFrom-Ppm -Ppm 30.0) },
    @{ Slope = (ConvertFrom-Ppm -Ppm 40.0) }
)
$t_hand = Get-EmpiricalError -Fits $t_handFits -Ppm 25.0
t_Near -Name 'batch-means error matches the hand-computed sample standard error' `
       -Expected 6.454972243679 -Actual $t_hand.SeEmpirical -Tol 0.000001
t_Ok -Name 'and is NOT the population-divisor value (a plausible wrong answer)' `
     -Cond ([math]::Abs($t_hand.SeEmpirical - 5.590169943749) -gt 0.001) `
     -Info ('got ' + ('{0:F9}' -f $t_hand.SeEmpirical))
t_Near -Name 'and the spread is the furthest window from the reported rate' `
       -Expected 15.0 -Actual $t_hand.SpreadPpm -Tol 0.000001

# ---------------------------------------------------------------------------
t_Section 'method selection picks the demonstrably better technique'
# Two series measuring the SAME planted rate: one steady, one wandering. The
# tool must pick the steady one no matter which slot it is in, because the
# real machine puts the good method in a different slot for capture than for
# render.
$t_rec = New-EndpointRecord
$t_rec.Opened = $true
$t_rec.NominalRate = 48000; $t_rec.Channels = 2; $t_rec.Bits = 32
$t_rec.BlockAlign = 8; $t_rec.AvgBytesPerSec = 384000; $t_rec.ClockFreq = 384000
$t_calm = t_MakeSeries -Ppm 3.0 -N 800 -StepSec 0.01
$t_noisy = t_MakeSeries -Ppm 3.0 -N 800 -StepSec 0.01 -Jitter 0.0004 -Seed 7
$t_out = Set-EndpointMeasurement -Record $t_rec -PktX $t_calm.X -PktY $t_calm.Y -ClkX $t_noisy.X -ClkY $t_noisy.Y
t_Eq -Name 'picks packets when packets are the steady series' -Expected 'packet timestamps' -Actual $t_out.Method
t_Near -Name 'and reports the planted rate' -Expected 3.0 -Actual $t_out.Ppm -Tol 0.001

$t_rec2 = New-EndpointRecord
$t_rec2.Opened = $true
$t_rec2.NominalRate = 48000; $t_rec2.Channels = 2; $t_rec2.Bits = 32
$t_rec2.BlockAlign = 8; $t_rec2.AvgBytesPerSec = 384000; $t_rec2.ClockFreq = 384000
$t_out2 = Set-EndpointMeasurement -Record $t_rec2 -PktX $t_noisy.X -PktY $t_noisy.Y -ClkX $t_calm.X -ClkY $t_calm.Y
t_Eq -Name 'picks the clock when the clock is the steady series' -Expected 'IAudioClock polling' -Actual $t_out2.Method
t_Near -Name 'and still reports the planted rate' -Expected 3.0 -Actual $t_out2.Ppm -Tol 0.001
t_Ok -Name 'the two orderings agree on the answer' -Cond ([math]::Abs($t_out.Ppm - $t_out2.Ppm) -lt 0.001)
t_Ok -Name 'the discarded method is still reported for cross-check' -Cond $t_out.MethodsComparable
t_Near -Name 'true rate is nominal times the slope' -Expected (48000.0 * (1.0 + 3.0/1000000.0)) -Actual $t_out.TrueRate -Tol 0.0001

# ---------------------------------------------------------------------------
t_Section 'the report refuses numbers it cannot stand behind'
function t_Meas { param([double]$Ppm, [double]$Jit, [int]$Rate = 48000, [int]$Blk = 8, [long]$Avg = 384000, [long]$Clk = 384000)
    $t_r = New-EndpointRecord
    $t_r.Opened = $true
    $t_r.NominalRate = $Rate; $t_r.Channels = 2; $t_r.Bits = 32
    $t_r.BlockAlign = $Blk; $t_r.AvgBytesPerSec = $Avg; $t_r.ClockFreq = $Clk
    $t_r.FormatConsistent = (Test-FormatRedundancy -Rate $Rate -Channels 2 -Bits 32 -BlockAlign $Blk -AvgBytes $Avg).Ok
    $t_r.ClockFreqOk = (Test-ClockFrequency -ClockFreq $Clk -AvgBytes $Avg -Rate $Rate).Ok
    $t_ser = t_MakeSeries -Ppm $Ppm -N 800 -StepSec 0.01 -Jitter $Jit -Seed 42
    return (Set-EndpointMeasurement -Record $t_r -PktX $t_ser.X -PktY $t_ser.Y -ClkX @() -ClkY @())
}
$t_m = t_Meas -Ppm 4.0 -Jit 0.0
t_Ok -Name 'a clean endpoint reports measured' -Cond $t_m.Measured -Info $t_m.MeasureNote
t_Eq -Name 'and carries no complaint' -Expected '' -Actual $t_m.MeasureNote
t_Near -Name 'and the right rate' -Expected 4.0 -Actual $t_m.Ppm -Tol 0.001

$t_m = t_Meas -Ppm 4.0 -Jit 0.0 -Blk 7
t_Ok -Name 'an inconsistent format blocks the report' -Cond (-not $t_m.Measured)
t_Ok -Name 'and says why' -Cond ($t_m.MeasureNote -like '*not self-consistent*') -Info $t_m.MeasureNote
$t_m = t_Meas -Ppm 4.0 -Jit 0.0 -Clk 999
t_Ok -Name 'a wrong clock frequency blocks the report' -Cond (-not $t_m.Measured)
t_Ok -Name 'and says why' -Cond ($t_m.MeasureNote -like '*clock frequency*') -Info $t_m.MeasureNote
$t_m = t_Meas -Ppm -1000000.0 -Jit 0.0
t_Ok -Name 'a dead clock blocks the report' -Cond (-not $t_m.Measured)
t_Ok -Name 'and is named as a resampled or virtual endpoint' -Cond ($t_m.MeasureNote -like '*not a crystal tolerance*') -Info $t_m.MeasureNote
$t_m = t_Meas -Ppm 4.0 -Jit 0.002
t_Ok -Name 'an endpoint too noisy to be useful blocks the report' -Cond (-not $t_m.Measured) -Info ('se ' + ('{0:F3}' -f $t_m.SePpm))
t_Ok -Name 'and says the uncertainty was the reason' -Cond ($t_m.MeasureNote -like '*uncertainty*') -Info $t_m.MeasureNote
# Bracket the usability threshold from BOTH sides so it is a real boundary
# and not just a value that happens to be above everything tested.
$t_lo = t_Meas -Ppm 4.0 -Jit 0.00005
$t_hi = t_Meas -Ppm 4.0 -Jit 0.002
t_Ok -Name 'the usability threshold is bracketed from below' -Cond ($t_lo.SePpm -le $script:MaxUsableSePpm) -Info ('se ' + ('{0:F4}' -f $t_lo.SePpm))
t_Ok -Name 'the usability threshold is bracketed from above' -Cond ($t_hi.SePpm -gt $script:MaxUsableSePpm) -Info ('se ' + ('{0:F4}' -f $t_hi.SePpm))
t_Ok -Name 'the quiet side is reported and the noisy side is not' -Cond ($t_lo.Measured -and (-not $t_hi.Measured))

# ---------------------------------------------------------------------------
t_Section 'clock domain grouping'
function t_Ep { param([int]$Idx, [double]$Ppm, [double]$Se, [string]$Name = 'ep')
    $t_r = New-EndpointRecord
    $t_r.Index = $Idx; $t_r.Name = $Name; $t_r.Ppm = $Ppm; $t_r.SePpm = $Se
    $t_r.Measured = $true; $t_r.Plausible = $true; $t_r.NominalRate = 48000
    $t_r.MsPerHour = Get-DriftMsPerHour -Ppm $Ppm
    return $t_r
}
# Two endpoints 0.3 ppm apart with 0.1 ppm errors: same crystal.
$t_a = t_Ep -Idx 0 -Ppm 2.5 -Se 0.10 -Name 'speakers'
$t_b = t_Ep -Idx 1 -Ppm 2.8 -Se 0.10 -Name 'mic'
$t_n = ConvertTo-ClockDomains -Endpoints @($t_a, $t_b) -FloorPpm 2.0
t_Eq -Name 'two agreeing endpoints form one domain' -Expected 1 -Actual $t_n
t_Eq -Name 'and both carry the same domain id' -Expected $t_a.ClockDomain -Actual $t_b.ClockDomain
# 40 ppm apart is far outside any tolerance: two crystals.
$t_c = t_Ep -Idx 0 -Ppm 2.5 -Se 0.10 -Name 'speakers'
$t_d = t_Ep -Idx 1 -Ppm 42.5 -Se 0.10 -Name 'usb mic'
$t_n = ConvertTo-ClockDomains -Endpoints @($t_c, $t_d) -FloorPpm 2.0
t_Eq -Name 'two disagreeing endpoints form two domains' -Expected 2 -Actual $t_n
t_Ok -Name 'and carry different domain ids' -Cond ($t_c.ClockDomain -ne $t_d.ClockDomain)
# An unmeasured endpoint must not be grouped at all, or it would silently
# claim to share a crystal on the strength of a default zero.
$t_e = t_Ep -Idx 0 -Ppm 2.5 -Se 0.10
$t_bad = New-EndpointRecord
$t_bad.Index = 1; $t_bad.Measured = $false
$t_n = ConvertTo-ClockDomains -Endpoints @($t_e, $t_bad) -FloorPpm 2.0
t_Eq -Name 'an unmeasured endpoint joins no domain' -Expected -1 -Actual $t_bad.ClockDomain
t_Eq -Name 'and does not create one' -Expected 1 -Actual $t_n

# ---------------------------------------------------------------------------
t_Section 'same-clock tolerance'
$t_t = Test-SameClockDomain -PpmA 2.0 -SeA 0.1 -PpmB 2.1 -SeB 0.1 -FloorPpm 2.0
t_Ok -Name 'a 0.1 ppm gap is the same clock' -Cond $t_t.Same
t_Near -Name 'and the gap is reported' -Expected 0.1 -Actual $t_t.DeltaPpm -Tol 1e-9
$t_t = Test-SameClockDomain -PpmA 2.0 -SeA 0.1 -PpmB 12.0 -SeB 0.1 -FloorPpm 2.0
t_Ok -Name 'a 10 ppm gap with tight errors is not' -Cond (-not $t_t.Same)
# The floor must be able to rescue a comparison the statistics alone would
# split, because two methods that disagree systematically are not evidence of
# two crystals.
$t_t = Test-SameClockDomain -PpmA 2.0 -SeA 0.01 -PpmB 3.5 -SeB 0.01 -FloorPpm 2.0
t_Ok -Name 'the systematic floor prevents a phantom second crystal' -Cond $t_t.Same -Info ('tol ' + ('{0:F3}' -f $t_t.Tolerance))
t_Near -Name 'and the tolerance equals the floor when statistics are tiny' -Expected 2.0 -Actual $t_t.Tolerance -Tol 1e-9
# ... but must not be able to swallow a genuinely different crystal.
$t_t = Test-SameClockDomain -PpmA 2.0 -SeA 0.01 -PpmB 60.0 -SeB 0.01 -FloorPpm 2.0
t_Ok -Name 'the floor does not swallow a real second crystal' -Cond (-not $t_t.Same)
# Large errors legitimately widen the tolerance: an imprecise measurement
# cannot be used to claim two devices differ.
$t_t = Test-SameClockDomain -PpmA 2.0 -SeA 5.0 -PpmB 12.0 -SeB 5.0 -FloorPpm 2.0
t_Ok -Name 'large uncertainties refuse to claim a difference' -Cond $t_t.Same -Info ('tol ' + ('{0:F3}' -f $t_t.Tolerance))

# ---------------------------------------------------------------------------
t_Section 'systematic floor ignores disagreement that noise explains'
function t_FloorEp { param([double]$Pkt, [double]$PktSe, [double]$Clk, [double]$ClkSe)
    $t_r = New-EndpointRecord
    $t_r.MethodsComparable = $true
    $t_r.PacketPpm = $Pkt; $t_r.SePpm = $PktSe
    $t_r.ClockPpm = $Clk; $t_r.ClockSePpm = $ClkSe
    return $t_r
}
# A 12 ppm gap between a tight method and one with a 25 ppm error is entirely
# explained by noise, so it must not widen the tolerance. This is the exact
# situation observed on the real capture endpoint.
$t_fl = Get-SystematicFloor -Endpoints @((t_FloorEp -Pkt 2.5 -PktSe 0.2 -Clk 14.3 -ClkSe 25.0)) -Default 2.0
t_Near -Name 'noise-explained disagreement leaves the floor at its default' -Expected 2.0 -Actual $t_fl -Tol 1e-9
# A 12 ppm gap between two tight methods is NOT explained by noise and is
# real systematic error, so it must widen the floor.
$t_fl = Get-SystematicFloor -Endpoints @((t_FloorEp -Pkt 2.5 -PktSe 0.2 -Clk 14.5 -ClkSe 0.2)) -Default 2.0
t_Ok -Name 'unexplained disagreement does widen the floor' -Cond ($t_fl -gt 10.0) -Info ('floor ' + ('{0:F3}' -f $t_fl))
$t_fl = Get-SystematicFloor -Endpoints @() -Default 2.0
t_Near -Name 'no comparable endpoints leaves the default' -Expected 2.0 -Actual $t_fl -Tol 1e-9

# A resampled endpoint - real Bluetooth hardware reads -666671 ppm on one
# technique and near zero on the other - must not be allowed to set the
# resolution for the real crystals. Before this was gated, one connected
# headset pushed the clock-domain tolerance to 665887 ppm, which would call
# every endpoint on the machine one clock domain: a verdict that cannot fail.
$t_bt = t_FloorEp -Pkt -666671.0 -PktSe 0.5 -Clk 1.2 -ClkSe 0.5
$t_fl = Get-SystematicFloor -Endpoints @($t_bt) -Default 2.0
t_Near -Name 'a resampled endpoint cannot inflate the systematic floor' -Expected 2.0 -Actual $t_fl -Tol 1e-9
# Either technique can be the one that goes wild on a resampled endpoint, so
# each reading needs its own gate. Testing only one leaves the other unguarded
# and, worse, untested - the mutation harness proved exactly that.
$t_bt2 = t_FloorEp -Pkt 1.2 -PktSe 0.5 -Clk -666671.0 -ClkSe 0.5
$t_fl = Get-SystematicFloor -Endpoints @($t_bt2) -Default 2.0
t_Near -Name 'and neither can it when the clock technique is the wild one' -Expected 2.0 -Actual $t_fl -Tol 1e-9
# ... and it must not drag a genuine crystal's floor up with it either.
$t_fl = Get-SystematicFloor -Endpoints @($t_bt, (t_FloorEp -Pkt 2.5 -PktSe 0.2 -Clk 14.5 -ClkSe 0.2)) -Default 2.0
t_Ok -Name 'a real endpoint still sets the floor when a resampled one is present' `
     -Cond (($t_fl -gt 10.0) -and ($t_fl -lt 20.0)) -Info ('floor ' + ('{0:F3}' -f $t_fl))
# NEGATIVE CONTROL: the gate must key on implausibility, not just on being big.
# A large-but-plausible disagreement still has to widen the floor.
$t_fl = Get-SystematicFloor -Endpoints @((t_FloorEp -Pkt -900.0 -PktSe 0.2 -Clk 1.0 -ClkSe 0.2)) -Default 2.0
t_Ok -Name 'NEGATIVE CONTROL: a large but plausible disagreement is not gated out' `
     -Cond ($t_fl -gt 800.0) -Info ('floor ' + ('{0:F3}' -f $t_fl))
# The floor can never reach the crystal ceiling, or every endpoint matches.
$t_fl = Get-SystematicFloor -Endpoints @((t_FloorEp -Pkt -999.0 -PktSe 0.2 -Clk 999.0 -ClkSe 0.2)) -Default 2.0
t_Ok -Name 'the floor is capped at the crystal ceiling so the verdict can still fail' `
     -Cond ($t_fl -le $script:MaxCrystalPpm) -Info ('floor ' + ('{0:F3}' -f $t_fl) + ' ceiling ' + [string]$script:MaxCrystalPpm)

# ---------------------------------------------------------------------------
t_Section 'fps parsing'
# -File hands every argument over as a string, and .NET will happily read
# "30,60" as the single number 30060 because its default style allows a
# thousands separator. Fixture values 11 and 13 are used as the default so a
# rejected value can never coincidentally equal an expected one.
$t_r = ConvertTo-FpsList -Raw @('30,60') -Default @(11.0, 13.0)
t_Eq -Name 'a comma-separated list yields two values' -Expected 2 -Actual (@($t_r.Values).Count)
t_Eq -Name 'first is 30 and not 3060' -Expected 30 -Actual $t_r.Values[0]
t_Eq -Name 'second is 60' -Expected 60 -Actual $t_r.Values[1]
$t_r = ConvertTo-FpsList -Raw @('23.976') -Default @(11.0, 13.0)
t_Near -Name 'a fractional rate survives' -Expected 23.976 -Actual $t_r.Values[0] -Tol 1e-9
$t_r = ConvertTo-FpsList -Raw @('60','60','30') -Default @(11.0, 13.0)
t_Eq -Name 'duplicates are collapsed' -Expected 2 -Actual (@($t_r.Values).Count)
$t_r = ConvertTo-FpsList -Raw @('abc') -Default @(11.0, 13.0)
t_Eq -Name 'a junk value falls back to the default' -Expected 2 -Actual (@($t_r.Values).Count)
t_Eq -Name 'and the junk is reported rather than swallowed' -Expected 'abc' -Actual $t_r.Rejected[0]
t_Ok -Name 'and never silently becomes a real fps value' -Cond ((@($t_r.Values) -contains 30) -eq $false)
$t_r = ConvertTo-FpsList -Raw @('0') -Default @(11.0, 13.0)
t_Eq -Name 'zero fps is rejected' -Expected 1 -Actual (@($t_r.Rejected).Count)
$t_r = ConvertTo-FpsList -Raw @('-30') -Default @(11.0, 13.0)
t_Eq -Name 'a negative fps is rejected' -Expected 1 -Actual (@($t_r.Rejected).Count)
$t_r = ConvertTo-FpsList -Raw @('') -Default @(11.0, 13.0)
t_Eq -Name 'an empty string falls back without complaint' -Expected 2 -Actual (@($t_r.Values).Count)
t_Eq -Name 'and reports nothing rejected' -Expected 0 -Actual (@($t_r.Rejected).Count)
$t_r = ConvertTo-FpsList -Raw @('30, 60 , 24') -Default @(11.0, 13.0)
t_Eq -Name 'whitespace around entries is tolerated' -Expected 3 -Actual (@($t_r.Values).Count)
# The currency symbol under InvariantCulture is U+00A4, not a dollar sign.
$t_r = ConvertTo-FpsList -Raw @(([string][char]0x00A4) + '60') -Default @(11.0, 13.0)
t_Eq -Name 'a currency-prefixed value is rejected' -Expected 1 -Actual (@($t_r.Rejected).Count)

# ---------------------------------------------------------------------------
t_Section 'series parsing'
$t_v = ConvertFrom-Series -Text '1.5,2.5,3.5'
t_Eq -Name 'three values parse' -Expected 3 -Actual (@($t_v).Count)
t_Near -Name 'and keep their values' -Expected 2.5 -Actual $t_v[1] -Tol 1e-9
$t_v = ConvertFrom-Series -Text ''
t_Eq -Name 'an empty series yields no values' -Expected 0 -Actual (@($t_v).Count)
$t_v = ConvertFrom-Series -Text '1E-07,2.5E+02'
t_Eq -Name 'scientific notation parses' -Expected 2 -Actual (@($t_v).Count)
t_Near -Name 'and is exact' -Expected 250.0 -Actual $t_v[1] -Tol 1e-9

# ---------------------------------------------------------------------------
t_Section 'record parsing'
$t_m = ConvertFrom-AdRecords -Text "a=1`r`nb=two`r`nc=3=4"
t_Eq -Name 'a simple key parses' -Expected '1' -Actual $t_m['a']
t_Eq -Name 'a text value parses' -Expected 'two' -Actual $t_m['b']
t_Eq -Name 'only the first equals splits the line' -Expected '3=4' -Actual $t_m['c']
$t_m = ConvertFrom-AdRecords -Text "ep.0.name=Speakers (2- Realtek)`nep.0.rate=48000"
t_Eq -Name 'a device name with punctuation survives' -Expected 'Speakers (2- Realtek)' -Actual $t_m['ep.0.name']
t_Eq -Name 'both line ending styles work' -Expected '48000' -Actual $t_m['ep.0.rate']
$t_m = ConvertFrom-AdRecords -Text "=novalue`nnoequals"
t_Eq -Name 'malformed lines are skipped' -Expected 0 -Actual $t_m.Count

# ---------------------------------------------------------------------------
t_Section 'subformat naming'
t_Eq -Name 'code 1 is PCM' -Expected 'PCM' -Actual (Get-SubFormatName -Code 1)
t_Eq -Name 'code 3 is IEEE float' -Expected 'IEEE float' -Actual (Get-SubFormatName -Code 3)
t_Eq -Name 'an unrecognised code is not guessed' -Expected 'unknown' -Actual (Get-SubFormatName -Code 65534)
t_Eq -Name 'the unset value is not guessed either' -Expected 'unknown' -Actual (Get-SubFormatName -Code -1)

# ---------------------------------------------------------------------------
t_Section 'formatting'
# N inserts a thousands separator; F does not. Any exact comparison needs F.
t_Eq -Name 'a four figure value has no thousands separator' -Expected '2650.0' -Actual (Format-Ms -Ms 2650.0)
t_Eq -Name 'ppm formats to three places' -Expected '2.557' -Actual (Format-Ppm -Ppm 2.5567)
t_Eq -Name 'a rate formats to four places' -Expected '48000.1228' -Actual (Format-Rate -Hz 48000.12284)
t_Eq -Name 'NaN ppm prints as n/a' -Expected 'n/a' -Actual (Format-Ppm -Ppm ([double]::NaN))
t_Eq -Name 'infinite ppm prints as inf' -Expected 'inf' -Actual (Format-Ppm -Ppm ([double]::PositiveInfinity))
t_Eq -Name 'seconds format as seconds' -Expected '45.0 s' -Actual (Format-Duration -Seconds 45.0)
t_Eq -Name 'minutes format as minutes' -Expected '10.0 min' -Actual (Format-Duration -Seconds 600.0)
t_Eq -Name 'hours format as hours' -Expected '2.8 hr' -Actual (Format-Duration -Seconds 10000.0)
t_Eq -Name 'days format as days' -Expected '2.3 days' -Actual (Format-Duration -Seconds 200000.0)
t_Eq -Name 'an infinite duration reads never' -Expected 'never' -Actual (Format-Duration -Seconds ([double]::PositiveInfinity))
# PadRight emits nothing at all when the value is wider than the column,
# which would fuse two fields into one token.
t_Eq -Name 'a narrow value is padded to width' -Expected 'ab   ' -Actual (Format-Col -Text 'ab' -Width 5)
t_Eq -Name 'an over-wide value still gets a separator' -Expected 'abcdefgh ' -Actual (Format-Col -Text 'abcdefgh' -Width 5)
t_Ok -Name 'no column output ever runs two fields together' `
     -Cond (((Format-Col -Text 'abcdefgh' -Width 5) + 'next') -like '* next')

# ---------------------------------------------------------------------------
t_Section 'glyphs survive or fall back'
$t_g = Get-Glyphs
t_Ok -Name 'every glyph key is present' -Cond ($t_g.ContainsKey('ok') -and $t_g.ContainsKey('warn') -and $t_g.ContainsKey('dash') -and $t_g.ContainsKey('pm'))
foreach ($t_k in @('ok','warn','dash','arrow','pm')) {
    t_Ok -Name ('glyph ' + $t_k + ' is non-empty') -Cond ($t_g[$t_k].Length -gt 0)
}

# ---------------------------------------------------------------------------
t_Section 'report shape and JSON round trip'
$t_map = @{}
$t_map['qpcfreq'] = '10000000'
$t_map['endpoints'] = '2'
# Every field gets a DIFFERENT distinctive value, so a parser that reads one
# field into another cannot pass this.
$t_map['ep.0.id'] = '{0.0.0.00000000}.{aaaaaaaa-1111-2222-3333-444444444444}'
$t_map['ep.0.name'] = 'Fixture Render'
$t_map['ep.0.flow'] = 'render'
$t_map['ep.0.state'] = '1'
$t_map['ep.0.default'] = '1'
$t_map['ep.0.opened'] = '1'
$t_map['ep.0.error'] = ''
$t_map['ep.0.rate'] = '48000'
$t_map['ep.0.channels'] = '2'
$t_map['ep.0.bits'] = '32'
$t_map['ep.0.blockalign'] = '8'
$t_map['ep.0.avgbytes'] = '384000'
$t_map['ep.0.formattag'] = '65534'
$t_map['ep.0.subformat'] = '3'
$t_map['ep.0.clockfreq'] = '384000'
$t_map['ep.0.packets'] = '5998'
$t_map['ep.0.silentpackets'] = '7'
$t_map['ep.0.discont'] = '0'
$t_map['ep.0.tserror'] = '0'
$t_ser = t_MakeSeries -Ppm 3.0 -N 800 -StepSec 0.01
$t_map['ep.0.pkt.x'] = ($t_ser.X -join ',')
$t_map['ep.0.pkt.y'] = ($t_ser.Y -join ',')
$t_map['ep.0.clk.x'] = ''
$t_map['ep.0.clk.y'] = ''
# Second endpoint: a DIFFERENT rate (44100), DIFFERENT channels, DIFFERENT
# bits and a DIFFERENT planted drift, so any cross-contamination shows up.
$t_map['ep.1.id'] = '{0.0.1.00000000}.{bbbbbbbb-5555-6666-7777-888888888888}'
$t_map['ep.1.name'] = 'Fixture Capture'
$t_map['ep.1.flow'] = 'capture'
$t_map['ep.1.state'] = '1'
$t_map['ep.1.default'] = '0'
$t_map['ep.1.opened'] = '1'
$t_map['ep.1.error'] = ''
$t_map['ep.1.rate'] = '44100'
$t_map['ep.1.channels'] = '1'
$t_map['ep.1.bits'] = '16'
$t_map['ep.1.blockalign'] = '2'
$t_map['ep.1.avgbytes'] = '88200'
$t_map['ep.1.formattag'] = '1'
$t_map['ep.1.subformat'] = '1'
$t_map['ep.1.clockfreq'] = '88200'
$t_map['ep.1.packets'] = '4321'
$t_map['ep.1.silentpackets'] = '2'
$t_map['ep.1.discont'] = '0'
$t_map['ep.1.tserror'] = '0'
$t_ser2 = t_MakeSeries -Ppm 47.0 -N 800 -StepSec 0.01
$t_map['ep.1.pkt.x'] = ($t_ser2.X -join ',')
$t_map['ep.1.pkt.y'] = ($t_ser2.Y -join ',')
$t_map['ep.1.clk.x'] = ''
$t_map['ep.1.clk.y'] = ''

$t_rep = Get-AudioDriftReport -Map $t_map -FpsList @(30.0, 60.0) -RequestedSeconds 60
t_Eq -Name 'both endpoints are parsed' -Expected 2 -Actual $t_rep.EndpointCount
t_Eq -Name 'the qpc frequency is carried through' -Expected 10000000 -Actual $t_rep.QpcFrequency
$t_e0 = $t_rep.Endpoints[0]; $t_e1 = $t_rep.Endpoints[1]
t_Eq -Name 'endpoint 0 keeps its own name' -Expected 'Fixture Render' -Actual $t_e0.Name
t_Eq -Name 'endpoint 1 keeps its own name' -Expected 'Fixture Capture' -Actual $t_e1.Name
t_Eq -Name 'endpoint 0 keeps its own rate' -Expected 48000 -Actual $t_e0.NominalRate
t_Eq -Name 'endpoint 1 keeps its own rate' -Expected 44100 -Actual $t_e1.NominalRate
t_Eq -Name 'endpoint 0 keeps its own channel count' -Expected 2 -Actual $t_e0.Channels
t_Eq -Name 'endpoint 1 keeps its own channel count' -Expected 1 -Actual $t_e1.Channels
t_Eq -Name 'endpoint 0 keeps its own bit depth' -Expected 32 -Actual $t_e0.Bits
t_Eq -Name 'endpoint 1 keeps its own bit depth' -Expected 16 -Actual $t_e1.Bits
t_Eq -Name 'endpoint 0 keeps its own packet count' -Expected 5998 -Actual $t_e0.Packets
t_Eq -Name 'endpoint 1 keeps its own packet count' -Expected 4321 -Actual $t_e1.Packets
t_Eq -Name 'endpoint 0 keeps its own silent count' -Expected 7 -Actual $t_e0.SilentPackets
t_Eq -Name 'endpoint 1 keeps its own silent count' -Expected 2 -Actual $t_e1.SilentPackets
t_Eq -Name 'endpoint 0 is float' -Expected 'IEEE float' -Actual $t_e0.SubFormatName
t_Eq -Name 'endpoint 1 is PCM' -Expected 'PCM' -Actual $t_e1.SubFormatName
t_Eq -Name 'endpoint 0 is flagged default' -Expected $true -Actual $t_e0.IsDefault
t_Eq -Name 'endpoint 1 is not' -Expected $false -Actual $t_e1.IsDefault
t_Near -Name 'endpoint 0 recovers its planted 3 ppm' -Expected 3.0 -Actual $t_e0.Ppm -Tol 0.001
t_Near -Name 'endpoint 1 recovers its planted 47 ppm' -Expected 47.0 -Actual $t_e1.Ppm -Tol 0.001
t_Ok -Name 'both formats validate' -Cond ($t_e0.FormatConsistent -and $t_e1.FormatConsistent)
t_Ok -Name 'both clock frequencies validate' -Cond ($t_e0.ClockFreqOk -and $t_e1.ClockFreqOk)
t_Eq -Name 'both are measured' -Expected 2 -Actual $t_rep.MeasuredCount
# 3 ppm and 47 ppm are 44 ppm apart with tiny errors: two crystals.
t_Eq -Name 'two different rates are two clock domains' -Expected 2 -Actual $t_rep.ClockDomainCount
t_Eq -Name 'one pair is produced' -Expected 1 -Actual (@($t_rep.Pairs).Count)
$t_pr = $t_rep.Pairs[0]
t_Near -Name 'the relative drift is the difference of the two' -Expected -44.0 -Actual $t_pr.RelativePpm -Tol 0.01
t_Ok -Name 'and they are correctly called separate clocks' -Cond (-not $t_pr.SameClock)
t_Eq -Name 'both requested fps appear in the slip table' -Expected 2 -Actual (@($t_pr.FrameSlip).Count)
# 44 ppm at 60 fps: (1/60)/(44e-6) = 378.8 s. Computed by hand here.
t_Near -Name 'the 60 fps slip time is right' -Expected 378.7878788 -Actual (@($t_pr.FrameSlip)[1].SecondsPerSlip) -Tol 0.001
t_Near -Name 'ms per hour matches 44 ppm x 3.6' -Expected 158.4 -Actual $t_pr.MsPerHour -Tol 0.001

# JSON must survive a full round trip, because -FromJson replays it.
$t_text = $t_rep | ConvertTo-Json -Depth 8
$t_back = $null
$t_threw = $false
try { $t_back = ConvertFrom-Json -InputObject $t_text } catch { $t_threw = $true }
t_Ok -Name 'the report serialises to valid JSON' -Cond (-not $t_threw)
t_Eq -Name 'and survives the round trip intact' -Expected 2 -Actual $t_back.EndpointCount
t_Near -Name 'and keeps endpoint 0 to full precision' -Expected $t_e0.Ppm -Actual $t_back.Endpoints[0].Ppm -Tol 1e-9
t_Near -Name 'and keeps endpoint 1 to full precision' -Expected $t_e1.Ppm -Actual $t_back.Endpoints[1].Ppm -Tol 1e-9
t_Eq -Name 'and keeps the pair' -Expected 1 -Actual (@($t_back.Pairs).Count)

# The schema template must contain every field the builder writes, or -Info
# and -FromJson break while the normal path keeps working.
$t_tpl = New-EndpointRecord
$t_missing = New-Object Collections.Generic.List[string]
foreach ($t_prop in $t_e0.Keys) {
    if (-not $t_tpl.Contains($t_prop)) { [void]$t_missing.Add($t_prop) }
}
t_Eq -Name 'the schema template covers every emitted field' -Expected '' -Actual (($t_missing.ToArray()) -join ',')

# ---------------------------------------------------------------------------
t_Section 'bounds check on the tool own output'
# Re-read every number the report produced and assert it is self-consistent.
# An aggregate can be wrong while every individual value looks fine.
foreach ($t_e in $t_rep.Endpoints) {
    t_Ok -Name ('rate ' + $t_e.Name + ' is positive') -Cond ($t_e.NominalRate -gt 0)
    t_Ok -Name ('uncertainty ' + $t_e.Name + ' is not negative') -Cond ($t_e.SePpm -ge 0)
    t_Ok -Name ('reported error ' + $t_e.Name + ' is the larger of the two') `
         -Cond ($t_e.SePpm -ge $t_e.SeOlsPpm -and $t_e.SePpm -ge $t_e.SeEmpiricalPpm) `
         -Info ('se ' + [string]$t_e.SePpm + ' ols ' + [string]$t_e.SeOlsPpm + ' emp ' + [string]$t_e.SeEmpiricalPpm)
    $t_impliedPpm = (($t_e.TrueRate / $t_e.NominalRate) - 1.0) * 1000000.0
    t_Near -Name ('true rate for ' + $t_e.Name + ' agrees with its own ppm') -Expected $t_e.Ppm -Actual $t_impliedPpm -Tol 0.000001
    t_Near -Name ('ms per hour for ' + $t_e.Name + ' agrees with its own ppm') -Expected ($t_e.Ppm * 3.6) -Actual $t_e.MsPerHour -Tol 1e-9
    t_Ok -Name ('measured endpoint ' + $t_e.Name + ' is within crystal bounds') -Cond ((-not $t_e.Measured) -or ([math]::Abs($t_e.Ppm) -le 1000.0))
}
foreach ($t_pr2 in $t_rep.Pairs) {
    $t_a2 = $t_rep.Endpoints[$t_pr2.AIndex]
    $t_b2 = $t_rep.Endpoints[$t_pr2.BIndex]
    t_Near -Name 'a pair relative drift equals the difference of its members' `
           -Expected ($t_a2.Ppm - $t_b2.Ppm) -Actual $t_pr2.RelativePpm -Tol 1e-9
    t_Ok -Name 'a pair tolerance is positive' -Cond ($t_pr2.Tolerance -gt 0)
    foreach ($t_sl in $t_pr2.FrameSlip) {
        t_Ok -Name ('slip at ' + [string]$t_sl.Fps + ' fps is positive') -Cond ($t_sl.SecondsPerSlip -gt 0)
        $t_expect = (1.0 / $t_sl.Fps) / ([math]::Abs($t_pr2.RelativePpm) / 1000000.0)
        t_Near -Name ('slip at ' + [string]$t_sl.Fps + ' fps recomputes') -Expected $t_expect -Actual $t_sl.SecondsPerSlip -Tol 0.000001
    }
}

# ---------------------------------------------------------------------------
t_Section 'an all-good machine reports clean (no crying wolf)'
# Two endpoints on one crystal, both quiet. Nothing must be flagged.
$t_map2 = @{}
$t_map2['qpcfreq'] = '10000000'
$t_map2['endpoints'] = '2'
foreach ($t_i in 0,1) {
    $t_pfx = 'ep.' + [string]$t_i + '.'
    $t_map2[$t_pfx + 'id'] = '{0.0.' + [string]$t_i + '.00000000}.{cccccccc-0000-0000-0000-00000000000' + [string]$t_i + '}'
    $t_map2[$t_pfx + 'name'] = 'Clean ' + [string]$t_i
    $t_map2[$t_pfx + 'flow'] = 'render'
    $t_map2[$t_pfx + 'state'] = '1'
    $t_map2[$t_pfx + 'default'] = '0'
    $t_map2[$t_pfx + 'opened'] = '1'
    $t_map2[$t_pfx + 'error'] = ''
    $t_map2[$t_pfx + 'rate'] = '48000'
    $t_map2[$t_pfx + 'channels'] = '2'
    $t_map2[$t_pfx + 'bits'] = '32'
    $t_map2[$t_pfx + 'blockalign'] = '8'
    $t_map2[$t_pfx + 'avgbytes'] = '384000'
    $t_map2[$t_pfx + 'formattag'] = '65534'
    $t_map2[$t_pfx + 'subformat'] = '3'
    $t_map2[$t_pfx + 'clockfreq'] = '384000'
    $t_map2[$t_pfx + 'packets'] = '5998'
    $t_map2[$t_pfx + 'silentpackets'] = '1'
    $t_map2[$t_pfx + 'discont'] = '0'
    $t_map2[$t_pfx + 'tserror'] = '0'
    $t_cs = t_MakeSeries -Ppm (2.5 + (0.2 * $t_i)) -N 800 -StepSec 0.01
    $t_map2[$t_pfx + 'pkt.x'] = ($t_cs.X -join ',')
    $t_map2[$t_pfx + 'pkt.y'] = ($t_cs.Y -join ',')
    $t_map2[$t_pfx + 'clk.x'] = ''
    $t_map2[$t_pfx + 'clk.y'] = ''
}
$t_clean = Get-AudioDriftReport -Map $t_map2 -FpsList @(60.0) -RequestedSeconds 60
t_Eq -Name 'a clean machine raises no warnings' -Expected 0 -Actual (@($t_clean.Warnings).Count)
t_Eq -Name 'both endpoints measure cleanly' -Expected 2 -Actual $t_clean.MeasuredCount
t_Eq -Name 'and are correctly grouped as ONE clock domain' -Expected 1 -Actual $t_clean.ClockDomainCount
t_Ok -Name 'and the pair is reported as locked together' -Cond (@($t_clean.Pairs)[0].SameClock)

# And a genuinely broken machine must NOT report clean, or the test above
# would prove nothing.
$t_map3 = @{}
foreach ($t_k2 in $t_map2.Keys) { $t_map3[$t_k2] = $t_map2[$t_k2] }
$t_map3['ep.1.blockalign'] = '6'
$t_map3['ep.1.discont'] = '4'
$t_dirty = Get-AudioDriftReport -Map $t_map3 -FpsList @(60.0) -RequestedSeconds 60
t_Ok -Name 'a broken machine does raise warnings' -Cond ((@($t_dirty.Warnings).Count) -ge 2) -Info ([string](@($t_dirty.Warnings).Count) + ' warnings')
t_Eq -Name 'and the broken endpoint is not measured' -Expected 1 -Actual $t_dirty.MeasuredCount
t_Eq -Name 'and no pair is claimed' -Expected 0 -Actual (@($t_dirty.Pairs).Count)

# ---------------------------------------------------------------------------
t_Section 'empty and hostile input'
$t_empty = Get-AudioDriftReport -Map @{} -FpsList @(60.0) -RequestedSeconds 60
t_Eq -Name 'an empty map yields no endpoints' -Expected 0 -Actual $t_empty.EndpointCount
t_Eq -Name 'and no pairs' -Expected 0 -Actual (@($t_empty.Pairs).Count)
t_Eq -Name 'and no warnings' -Expected 0 -Actual (@($t_empty.Warnings).Count)
$t_threw = $false
try { [void]($t_empty | ConvertTo-Json -Depth 8) } catch { $t_threw = $true }
t_Ok -Name 'and still serialises' -Cond (-not $t_threw)

# An endpoint that failed to open must carry its error, not a fake zero rate.
$t_map4 = @{}
$t_map4['qpcfreq'] = '10000000'
$t_map4['endpoints'] = '1'
$t_map4['ep.0.id'] = '{0.0.1.00000000}.{dddddddd-0000-0000-0000-000000000000}'
$t_map4['ep.0.name'] = 'Denied Microphone'
$t_map4['ep.0.flow'] = 'capture'
$t_map4['ep.0.state'] = '1'
$t_map4['ep.0.default'] = '0'
$t_map4['ep.0.opened'] = '0'
$t_map4['ep.0.error'] = 'init capture 0x8889000A'
foreach ($t_z in 'rate','channels','bits','blockalign','avgbytes','formattag','clockfreq','packets','silentpackets','discont','tserror') {
    $t_map4['ep.0.' + $t_z] = '0'
}
$t_map4['ep.0.subformat'] = '-1'
foreach ($t_z in 'pkt.x','pkt.y','clk.x','clk.y') { $t_map4['ep.0.' + $t_z] = '' }
$t_denied = Get-AudioDriftReport -Map $t_map4 -FpsList @(60.0) -RequestedSeconds 60
t_Eq -Name 'a denied endpoint is listed' -Expected 1 -Actual $t_denied.EndpointCount
t_Eq -Name 'but not measured' -Expected 0 -Actual $t_denied.MeasuredCount
t_Eq -Name 'and reports the driver error verbatim' -Expected 'init capture 0x8889000A' -Actual $t_denied.Endpoints[0].MeasureNote
t_Eq -Name 'and never invents a rate' -Expected 0 -Actual $t_denied.Endpoints[0].TrueRate

# ---------------------------------------------------------------------------
t_Section '-SkipMeasure is a user choice, not a fault'
# The native layer and the PowerShell layer both hold this literal. If they
# ever drift apart the skip note silently reverts to the warning glyph, so the
# link between the two is asserted directly against the source.
$t_src = [IO.File]::ReadAllText((Join-Path $t_here 'audiodrift.ps1'))
t_Ok -Name 'the native emitter uses the pinned skip note' `
       -Cond ($t_src.Contains('e.Error = "' + $script:SkipMeasureNote + '"'))
t_Eq -Name 'the constant is exactly the note the native layer emits' `
     -Expected 'not measured (-SkipMeasure)' -Actual $script:SkipMeasureNote
t_Ok -Name 'the human path branches on that constant, not on a copy' `
       -Cond ($t_src.Contains('[String]::Equals($note, $script:SkipMeasureNote, [StringComparison]::Ordinal)'))
t_Ok -Name 'exactly one emitter builds the ep.* schema' `
       -Cond ((([regex]::Matches($t_src, 'static void EmitEndpoints\(')).Count -eq 1) -and
              (([regex]::Matches($t_src, 'EmitEndpoints\(sb, eps\);')).Count -eq 2))
t_Ok -Name 'no near-miss emitter name sneaks past the anchor' `
       -Cond (([regex]::Matches($t_src, 'void EmitEndpoints\w')).Count -eq 0)
# The embedded C# is the half of the tool PowerShell cannot type-check. If it
# does not compile, every COM path is dead - so compiling it IS an assertion.
t_Ok -Name 'the embedded C# audio layer compiles' -Cond (Initialize-AudioDriftNative)
t_Ok -Name 'and both entry points exist on the compiled type' `
       -Cond ((($null -ne [AudioDriftNative.Engine].GetMethod('Enumerate')) -and
               ($null -ne [AudioDriftNative.Engine].GetMethod('EnumerateAll'))) -and
              ($null -ne [AudioDriftNative.Engine].GetMethod('Measure')))
t_Ok -Name 'no orphan all.N.* schema survives' -Cond (-not $t_src.Contains('"all." + i'))
t_Ok -Name 'the enumerate path never calls Initialize' `
       -Cond (-not ([regex]::Match($t_src, 'public static string Enumerate\(\)[\s\S]*?\n    \}\n')).Value.Contains('.Initialize('))

# A skipped endpoint must still carry its format, and must never be counted
# as measured or given a rate.
$t_skipMap = @{
    'qpcfreq'          = '10000000'
    'endpoints'        = '1'
    'ep.0.id'          = '{0.0.0.00000000}.{aaa}'
    'ep.0.name'        = 'Speakers (Test)'
    'ep.0.flow'        = 'render'
    'ep.0.state'       = '1'
    'ep.0.default'     = '1'
    'ep.0.opened'      = '0'
    'ep.0.error'       = $script:SkipMeasureNote
    'ep.0.rate'        = '44100'
    'ep.0.channels'    = '4'
    'ep.0.bits'        = '24'
    'ep.0.blockalign'  = '12'
    'ep.0.avgbytes'    = '529200'
    'ep.0.formattag'   = '65534'
    'ep.0.subformat'   = '1'
    'ep.0.clockfreq'   = '0'
    'ep.0.packets'     = '0'
    'ep.0.silentpackets' = '0'
    'ep.0.discont'     = '0'
    'ep.0.tserror'     = '0'
    'ep.0.pkt.x'       = ''
    'ep.0.pkt.y'       = ''
    'ep.0.clk.x'       = ''
    'ep.0.clk.y'       = ''
}
$t_skipRep = Get-AudioDriftReport -Map $t_skipMap -FpsList @(60.0) -RequestedSeconds 60
t_Eq -Name 'a skipped endpoint is still listed' -Expected 1 -Actual $t_skipRep.EndpointCount
t_Eq -Name 'it is not counted as measured' -Expected 0 -Actual $t_skipRep.MeasuredCount
t_Eq -Name 'it carries the skip note' -Expected $script:SkipMeasureNote -Actual $t_skipRep.Endpoints[0].MeasureNote
# A distinctive value per field, so a tool that transposes two cannot pass.
t_Eq -Name 'the nominal rate survives the skip' -Expected 44100 -Actual $t_skipRep.Endpoints[0].NominalRate
t_Eq -Name 'the channel count survives the skip' -Expected 4 -Actual $t_skipRep.Endpoints[0].Channels
t_Eq -Name 'the bit depth survives the skip' -Expected 24 -Actual $t_skipRep.Endpoints[0].Bits
t_Eq -Name 'and no rate is invented' -Expected 0 -Actual $t_skipRep.Endpoints[0].TrueRate
t_Eq -Name 'and no clock domain is claimed' -Expected 0 -Actual $t_skipRep.ClockDomainCount
t_Eq -Name 'and no drift pair is offered' -Expected 0 -Actual (@($t_skipRep.Pairs)).Count

# ---------------------------------------------------------------------------
t_Section 'locked to the same clock is not the same claim as one crystal'
# A Bluetooth headset measures as perfectly locked to the host clock, because
# the driver resamples it onto the host clock. That is genuinely useful - they
# will not drift apart - but it is NOT a shared crystal, and saying so would be
# an over-claim the measurement cannot support. The device instance path is
# what decides it, and it comes from the hardware, not from the numbers.
function t_DomainMap { param([string]$HwA, [string]$HwB)
    $t_dm = @{}
    $t_dm['qpcfreq'] = '10000000'
    $t_dm['endpoints'] = '2'
    foreach ($t_j in 0,1) {
        $t_dp = 'ep.' + [string]$t_j + '.'
        $t_dm[$t_dp + 'id'] = '{0.0.' + [string]$t_j + '.00000000}.{dddddddd-0000-0000-0000-00000000000' + [string]$t_j + '}'
        $t_dm[$t_dp + 'name'] = 'Domain ' + [string]$t_j
        $t_dm[$t_dp + 'hw'] = $(if ($t_j -eq 0) { $HwA } else { $HwB })
        $t_dm[$t_dp + 'flow'] = 'render'
        $t_dm[$t_dp + 'state'] = '1'
        $t_dm[$t_dp + 'default'] = '0'
        $t_dm[$t_dp + 'opened'] = '1'
        $t_dm[$t_dp + 'error'] = ''
        $t_dm[$t_dp + 'rate'] = '48000'
        $t_dm[$t_dp + 'channels'] = '2'
        $t_dm[$t_dp + 'bits'] = '32'
        $t_dm[$t_dp + 'blockalign'] = '8'
        $t_dm[$t_dp + 'avgbytes'] = '384000'
        $t_dm[$t_dp + 'formattag'] = '65534'
        $t_dm[$t_dp + 'subformat'] = '3'
        $t_dm[$t_dp + 'clockfreq'] = '384000'
        $t_dm[$t_dp + 'packets'] = '5998'
        $t_dm[$t_dp + 'silentpackets'] = '0'
        $t_dm[$t_dp + 'discont'] = '0'
        $t_dm[$t_dp + 'tserror'] = '0'
        $t_ds = t_MakeSeries -Ppm (2.5 + (0.1 * $t_j)) -N 800 -StepSec 0.01
        $t_dm[$t_dp + 'pkt.x'] = ($t_ds.X -join ',')
        $t_dm[$t_dp + 'pkt.y'] = ($t_ds.Y -join ',')
        $t_dm[$t_dp + 'clk.x'] = ''
        $t_dm[$t_dp + 'clk.y'] = ''
    }
    return $t_dm
}
function t_RenderReport { param($Report)
    $script:Silent = $false
    return ((Show-AudioDriftReport -Report $Report 6>&1 | Out-String))
}

# The device instance path survives the round trip from the native emitter.
$t_oneHw = '{1}.INTELAUDIO\FUNC_01&VEN_10EC&DEV_0274'
$t_repSame = Get-AudioDriftReport -Map (t_DomainMap -HwA $t_oneHw -HwB $t_oneHw) -FpsList @(60.0) -RequestedSeconds 60
t_Eq -Name 'the device instance path reaches the endpoint record' -Expected $t_oneHw -Actual (@($t_repSame.Endpoints)[0].Hw)
t_Eq -Name 'two interfaces of one device are one domain' -Expected 1 -Actual $t_repSame.ClockDomainCount
$t_txtSame = t_RenderReport -Report $t_repSame
t_Ok -Name 'one physical device is reported as one crystal' -Cond ($t_txtSame -cmatch 'one physical device, so this is one crystal')
t_Ok -Name 'and the header no longer asserts a crystal it has not established' -Cond ($t_txtSame -cmatch 'locked to the same clock')
t_Ok -Name 'NEGATIVE CONTROL: the one-device wording is absent when it should be' `
     -Cond (-not ($t_txtSame -cmatch 'separate physical devices'))

# Same numbers, different hardware. The verdict text must change.
$t_repSplit = Get-AudioDriftReport -Map (t_DomainMap -HwA $t_oneHw -HwB '{1}.BTHHFENUM\BTHHFPAUDIO\8&380CA4EB') -FpsList @(60.0) -RequestedSeconds 60
t_Eq -Name 'two devices that read alike are still one measured domain' -Expected 1 -Actual $t_repSplit.ClockDomainCount
t_Ok -Name 'and the pair is still reported as locked, because it is' -Cond (@($t_repSplit.Pairs)[0].SameClock)
$t_txtSplit = t_RenderReport -Report $t_repSplit
t_Ok -Name 'but two physical devices are NOT called one crystal' -Cond (-not ($t_txtSplit -cmatch 'one physical device, so this is one crystal'))
t_Ok -Name 'and the resampling explanation is given instead' -Cond ($t_txtSplit -cmatch 'not by a shared crystal')
t_Ok -Name 'and it says how many devices it actually saw' -Cond ($t_txtSplit -cmatch '2 separate physical devices')
# NEGATIVE CONTROL: identical measurements, so only the hardware fact differs.
t_Ok -Name 'NEGATIVE CONTROL: the two renders differ only because the hardware does' `
     -Cond (-not [String]::Equals($t_txtSame, $t_txtSplit, [StringComparison]::Ordinal))
t_Eq -Name 'NEGATIVE CONTROL: both runs measured the same number of endpoints' -Expected $t_repSame.MeasuredCount -Actual $t_repSplit.MeasuredCount

# A missing device instance path must not be counted as a device of its own,
# or an endpoint Windows declines to describe would fake a second crystal.
$t_repBlank = Get-AudioDriftReport -Map (t_DomainMap -HwA $t_oneHw -HwB '') -FpsList @(60.0) -RequestedSeconds 60
$t_txtBlank = t_RenderReport -Report $t_repBlank
t_Ok -Name 'an unknown device path claims neither one crystal nor two devices' `
     -Cond ((-not ($t_txtBlank -cmatch 'separate physical devices')) -and (-not ($t_txtBlank -cmatch 'one physical device, so this is one crystal')))
t_Ok -Name 'and it says so out loud rather than going quiet' -Cond ($t_txtBlank -cmatch 'does not name the hardware behind all of these')
# The device instance path is only meaningful if it is the device instance
# path. A wrong property key would still return a plausible-looking string and
# would still group endpoints - just wrongly - so the key itself is pinned.
$t_srcHw = [IO.File]::ReadAllText((Join-Path $t_here 'audiodrift.ps1'))
t_Ok -Name 'the hardware lookup asks for the device instance path property' `
     -Cond ($t_srcHw.IndexOf('GetStringProp(d, "b3f8fa53-0004-438e-9003-51a46e139bfc", 2)', [StringComparison]::Ordinal) -ge 0)
t_Ok -Name 'and the friendly name still asks for its own, different property' `
     -Cond ($t_srcHw.IndexOf('GetStringProp(d, "a45c254e-df1c-4efd-8020-67d146a850e0", 14)', [StringComparison]::Ordinal) -ge 0)
t_Ok -Name 'NEGATIVE CONTROL: those two lookups are not the same property' `
     -Cond (-not [String]::Equals('b3f8fa53-0004-438e-9003-51a46e139bfc', 'a45c254e-df1c-4efd-8020-67d146a850e0', [StringComparison]::Ordinal))
t_Ok -Name 'both endpoints of the emitter carry the hardware path' `
     -Cond (([regex]::Matches($t_srcHw, [regex]::Escape('e.Hw = GetHw(d);'))).Count -eq 2)
# Collecting it and emitting it are two different things. A field that never
# crosses the native boundary is a field the PowerShell side silently defaults,
# and every endpoint would then look like unnamed hardware.
t_Ok -Name 'and the shared emitter actually emits it' `
     -Cond ($t_srcHw.IndexOf('sb.AppendLine(p + "hw=" + e.Hw);', [StringComparison]::Ordinal) -ge 0)
t_Ok -Name 'NEGATIVE CONTROL: the emitter anchor is an exact line, not a prefix' `
     -Cond ($t_srcHw.IndexOf('sb.AppendLine(p + "hw=" + e.HwRenamed);', [StringComparison]::Ordinal) -lt 0)

t_Section 'a hard failure must not look like success'
# Found by running a deliberately broken copy: with the audio layer failing to
# compile, -Json wrote nothing to stdout and exited 0. A caller doing
# "audiodrift -Json > drift.json" got an empty file and a success code, with no
# way to tell that from a machine that genuinely has no endpoints. Both halves
# of the fix live in Write-Bad so a future failure path cannot forget either.
$t_exitSave   = $script:ExitCode
$t_silentSave = $script:Silent

$script:ExitCode = 0
$script:Silent   = $false
$t_badLoud = (Write-Bad 'audiodrift: t_probe loud' 6>&1 | Out-String)
t_Ok -Name 'a failure in visible mode is printed' -Cond ($t_badLoud -cmatch 't_probe loud')
t_Eq -Name 'and it sets the exit code' -Expected 1 -Actual $script:ExitCode

# -Json and -Quiet set Silent, and stdout has to stay machine-readable, so the
# text must move to stderr rather than disappear.
$script:ExitCode = 0
$script:Silent   = $true
$t_errSave = [Console]::Error
$t_sw = New-Object IO.StringWriter
[Console]::SetError($t_sw)
$t_badQuiet = (Write-Bad 'audiodrift: t_probe quiet' 6>&1 | Out-String)
[Console]::SetError($t_errSave)
t_Ok -Name 'a failure in silent mode is not swallowed, it goes to stderr' -Cond ($t_sw.ToString() -cmatch 't_probe quiet')
t_Ok -Name 'and it stays off stdout so -Json output is still parseable' -Cond (-not ($t_badQuiet -cmatch 't_probe quiet'))
t_Eq -Name 'and it sets the exit code in silent mode too' -Expected 1 -Actual $script:ExitCode

# NEGATIVE CONTROL: a warning is not a failure. If every writer raised the exit
# code, one unusable endpoint would make a working machine report total failure.
$script:ExitCode = 0
$script:Silent   = $false
$t_noise  = (Write-Warn 'audiodrift: t_probe warn' 6>&1 | Out-String)
$t_noise += (Write-Line 'audiodrift: t_probe line' 6>&1 | Out-String)
$t_noise += (Write-Good 'audiodrift: t_probe good' 6>&1 | Out-String)
$t_noise += (Write-Head 'audiodrift: t_probe head' 6>&1 | Out-String)
t_Eq -Name 'NEGATIVE CONTROL: warnings and normal output leave the exit code at 0' -Expected 0 -Actual $script:ExitCode
t_Ok -Name 'NEGATIVE CONTROL: those writers did run, so the control is not vacuous' -Cond ($t_noise -cmatch 't_probe warn')

$script:ExitCode = $t_exitSave
$script:Silent   = $t_silentSave

# Structural. "Did anything fail" is only answerable if exactly one place
# raises the code and exactly one place acts on it.
t_Eq -Name 'the exit code is assigned in exactly two places: its initialiser and Write-Bad' `
     -Expected 2 -Actual ([regex]::Matches($t_srcHw, '\$script:ExitCode\s+=\s+[01]\b')).Count
t_Eq -Name 'and the script exits with that code in exactly one place' `
     -Expected 1 -Actual ([regex]::Matches($t_srcHw, [regex]::Escape('exit $script:ExitCode'))).Count
t_Eq -Name 'NEGATIVE CONTROL: no literal exit code is hardcoded anywhere else' `
     -Expected 0 -Actual ([regex]::Matches($t_srcHw, '(?<![\w-])exit\s+\d')).Count
t_Ok -Name 'which is guarded, so a clean run still exits 0' `
     -Cond ($t_srcHw.IndexOf('if ($script:ExitCode -ne 0) { exit $script:ExitCode }', [StringComparison]::Ordinal) -ge 0)
# The raiser has to live inside Write-Bad; sitting anywhere else would leave
# some Write-Bad call sites silent about failing.
$t_iBad  = $t_srcHw.IndexOf('function Write-Bad', [StringComparison]::Ordinal)
$t_iRaise = $t_srcHw.IndexOf('$script:ExitCode = 1', [StringComparison]::Ordinal)
$t_iErrFn = $t_srcHw.IndexOf('function Write-Err', [StringComparison]::Ordinal)
t_Ok -Name 'and the raiser sits inside Write-Bad, not at some call site' `
     -Cond (($t_iBad -ge 0) -and ($t_iRaise -gt $t_iBad) -and ($t_iRaise -lt $t_iErrFn))

# Found by running the real tool, not by reading it: the -FromJson error paths
# each forced Silent off before calling Write-Bad, which pushed the message onto
# stdout - into the file a "-Json > drift.json" caller is redirecting. Write-Bad
# already guarantees visibility, so no error path may un-silence.
$t_badSites = @([regex]::Matches($t_srcHw, '(?<!function )Write-Bad \('))
t_Eq -Name 'every hard-failure message still goes through Write-Bad' -Expected 5 -Actual $t_badSites.Count
$t_unsilenced = New-Object Collections.Generic.List[string]
foreach ($t_bs in $t_badSites) {
    $t_from = [Math]::Max(0, $t_bs.Index - 160)
    $t_lead = $t_srcHw.Substring($t_from, $t_bs.Index - $t_from)
    if ($t_lead -cmatch '\$script:Silent\s*=\s*\$false') { [void]$t_unsilenced.Add($t_srcHw.Substring($t_bs.Index, 40)) }
}
t_Eq -Name 'and no error path un-silences itself first, which would corrupt -Json stdout' `
     -Expected 0 -Actual $t_unsilenced.Count
foreach ($t_us in $t_unsilenced) { t_Ok -Name ('  offending site: ' + $t_us) -Cond $false }
# NEGATIVE CONTROL: the scan does find the pattern when it is genuinely there,
# so a count of zero means absent rather than unsearchable.
t_Ok -Name 'NEGATIVE CONTROL: the un-silence pattern is findable in the source at all' `
     -Cond (([regex]::Matches($t_srcHw, '\$script:Silent\s*=\s*\$false')).Count -ge 2)

# ---------------------------------------------------------------------------
Write-Host ''
if ($t_fail -eq 0) {
    Write-Host ('ALL PASS  ' + [string]$t_pass + ' assertions, 0 failures') -ForegroundColor Green
    exit 0
} else {
    Write-Host ([string]$t_fail + ' FAILURES out of ' + [string]($t_pass + $t_fail) + ' assertions') -ForegroundColor Red
    foreach ($t_m2 in $t_msgs) { Write-Host ('  - ' + $t_m2) -ForegroundColor Red }
    exit 1
}
