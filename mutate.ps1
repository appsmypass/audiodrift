<#
    mutate.ps1 - negative controls for the test suite itself.

    realcheck.ps1 proves the tool agrees with Windows. This proves the TESTS
    are capable of disagreeing. Each mutation introduces one specific bug
    into a copy of audiodrift.ps1 and requires selftest.ps1 to FAIL. A
    mutation that survives names a line no assertion covers.

    Three rules make the score honest:

      * ANCHORS ARE VALIDATED. A mutation whose anchor text is not in the
        source silently tests nothing and would be reported as a kill. Every
        anchor must appear EXACTLY once; anything else is an INVALID CONTROL
        and is counted separately from survivors. One mutation below is
        deliberately anchored on text that does not exist, to prove the
        detector works.
      * PAIRED EDITS ARE SUPPORTED. Redundantly defensive code produces
        equivalent mutants: removing either half alone changes nothing
        observable. Those are declared, verified to really be equivalent,
        and excluded from the score rather than counted as passes.
      * NO-OPS ARE EXCLUDED. If applying the edits leaves the file unchanged
        the mutation is not scored.

    Nothing outside the harness's own scratch directory is touched.

    Run:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File mutate.ps1
#>
[CmdletBinding()]
param([int]$TimeoutSec = 90, [switch]$Detail)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$m_here = Split-Path -Parent $MyInvocation.MyCommand.Path
$m_tool = Join-Path $m_here 'audiodrift.ps1'
$m_suite = Join-Path $m_here 'selftest.ps1'
foreach ($m_f in @($m_tool, $m_suite)) {
    if (-not (Test-Path -LiteralPath $m_f)) { Write-Host ('cannot find ' + $m_f); exit 1 }
}
$m_src = [IO.File]::ReadAllText($m_tool)

$m_work = Join-Path $env:TEMP ('audiodrift-mutate-' + [string]$PID)
if (Test-Path -LiteralPath $m_work) { Remove-Item -LiteralPath $m_work -Recurse -Force }
[void](New-Item -ItemType Directory -Path $m_work -Force)
$m_workTool = Join-Path $m_work 'audiodrift.ps1'
$m_workSuite = Join-Path $m_work 'selftest.ps1'
Copy-Item -LiteralPath $m_suite -Destination $m_workSuite -Force

function m_Run {
    param([string]$ScriptPath, [int]$Seconds)
    # Start-Process -RedirectStandardOutput holds the file with an EXCLUSIVE
    # lock, and the handle lingers after the child exits. Drive the process
    # directly and drain both pipes ASYNCHRONOUSLY instead - a synchronous
    # ReadToEnd on one pipe deadlocks as soon as the other fills.
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = (Split-Path -Parent $ScriptPath)
    $p = [Diagnostics.Process]::Start($psi)
    $tOut = $p.StandardOutput.ReadToEndAsync()
    $tErr = $p.StandardError.ReadToEndAsync()
    $done = $p.WaitForExit($Seconds * 1000)
    if (-not $done) {
        try { $p.Kill() } catch { }
        try { [void]$p.WaitForExit(5000) } catch { }
        return @{ TimedOut = $true; ExitCode = -1; Out = ''; Err = '' }
    }
    [void]$tOut.Wait(5000)
    [void]$tErr.Wait(5000)
    $o = ''; $e = ''
    if ($tOut.IsCompleted) { $o = $tOut.Result }
    if ($tErr.IsCompleted) { $e = $tErr.Result }
    $code = $p.ExitCode
    $p.Dispose()
    return @{ TimedOut = $false; ExitCode = $code; Out = $o; Err = $e }
}

# ---------------------------------------------------------------------------
# The mutations. Expect is 'kill' for a real bug, or 'equivalent' for code
# that is redundantly defensive - declared up front, then PROVEN below.
# ---------------------------------------------------------------------------
$m_muts = @(
    @{ Id = 'fit-slope-inverted'; Desc = 'least squares slope divides the wrong way'
       Edits = @(@{ Find = '    $slope = $sxy / $sxx'; Replace = '    $slope = $sxx / $sxy' }) },
    @{ Id = 'fit-intercept-sign'; Desc = 'regression intercept sign flipped'
       Edits = @(@{ Find = '    $icept = $my - $slope * $mx'; Replace = '    $icept = $my + $slope * $mx' }) },
    @{ Id = 'fit-stderr-multiplies'; Desc = 'standard error multiplies by Sxx instead of dividing'
       Edits = @(@{ Find = '    if ($n -gt 2) { $se = [math]::Sqrt(($ss / ($n - 2)) / $sxx) }'
                    Replace = '    if ($n -gt 2) { $se = [math]::Sqrt(($ss / ($n - 2)) * $sxx) }' }) },
    @{ Id = 'ppm-scale-10x'; Desc = 'ppm scaled by 100000 instead of 1000000'
       Edits = @(@{ Find = '    return ($Slope - 1.0) * 1000000.0'; Replace = '    return ($Slope - 1.0) * 100000.0' }) },
    @{ Id = 'ppm-forgets-unity'; Desc = 'ppm forgets to subtract the unity ratio'
       Edits = @(@{ Find = '    return ($Slope - 1.0) * 1000000.0'; Replace = '    return $Slope * 1000000.0' }) },
    @{ Id = 'ppm-inverse-sign'; Desc = 'ppm to ratio conversion subtracts instead of adds'
       Edits = @(@{ Find = '    return 1.0 + ($Ppm / 1000000.0)'; Replace = '    return 1.0 - ($Ppm / 1000000.0)' }) },
    @{ Id = 'msperhour-constant'; Desc = 'ms per hour uses 3.0 instead of 3.6'
       Edits = @(@{ Find = '    return $Ppm * 3.6'; Replace = '    return $Ppm * 3.0' }) },
    @{ Id = 'frameslip-multiplies'; Desc = 'frame slip multiplies by the drift instead of dividing'
       Edits = @(@{ Find = '    return (1.0 / $Fps) / ($a / 1000000.0)'; Replace = '    return (1.0 / $Fps) * ($a / 1000000.0)' }) },
    @{ Id = 'sameclock-comparison-flipped'; Desc = 'same-clock test accepts only endpoints that DISagree'
       Edits = @(@{ Find = '        Same      = ($d -le $tol)'; Replace = '        Same      = ($d -ge $tol)' }) },
    @{ Id = 'sameclock-floor-ignored'; Desc = 'tolerance floor applied in the wrong direction'
       Edits = @(@{ Find = '    if ($FloorPpm -gt $tol) { $tol = $FloorPpm }'; Replace = '    if ($FloorPpm -lt $tol) { $tol = $FloorPpm }' }) },
    @{ Id = 'sameclock-k-dropped'; Desc = 'coverage factor K dropped from the statistical tolerance'
       Edits = @(@{ Find = '    $stat = $K * [math]::Sqrt(($SeA * $SeA) + ($SeB * $SeB))'
                    Replace = '    $stat = [math]::Sqrt(($SeA * $SeA) + ($SeB * $SeB))' }) },
    @{ Id = 'floor-counts-whole-gap'; Desc = 'systematic floor counts the whole gap instead of the part noise cannot explain'
       Edits = @(@{ Find = '        $excess = $d - $noise'; Replace = '        $excess = $d' }) },
    @{ Id = 'floor-default-inverted'; Desc = 'floor default comparison inverted'
       Edits = @(@{ Find = '    if ($worst -lt $Default) { return $Default }'; Replace = '    if ($worst -gt $Default) { return $Default }' }) },
    @{ Id = 'plausible-no-abs'; Desc = 'plausibility bound forgets the absolute value, so large NEGATIVE drift passes'
       Edits = @(@{ Find = '    return ([math]::Abs($Ppm) -le $script:MaxCrystalPpm)'; Replace = '    return ($Ppm -le $script:MaxCrystalPpm)' }) },
    @{ Id = 'plausible-always-true'; Desc = 'plausibility gate always passes'
       Edits = @(@{ Find = '    return ([math]::Abs($Ppm) -le $script:MaxCrystalPpm)'; Replace = '    return $true' }) },
    @{ Id = 'blockalign-divisor'; Desc = 'block align divides bits by 4 instead of 8'
       Edits = @(@{ Find = '    $expBlk = [int](($Channels * $Bits) / 8)'; Replace = '    $expBlk = [int](($Channels * $Bits) / 4)' }) },
    @{ Id = 'byterate-adds'; Desc = 'byte rate adds rate and block align instead of multiplying'
       Edits = @(@{ Find = '    $expAvg = [long]$Rate * [long]$expBlk'; Replace = '    $expAvg = [long]$Rate + [long]$expBlk' }) },
    @{ Id = 'bits-bound-removed'; Desc = 'bit depth bound removed, so a channels/bits transposition sails through'
       Edits = @(@{ Find = '    $bitsOk = (@(8, 16, 24, 32, 64) -contains $Bits)'; Replace = '    $bitsOk = $true' }) },
    @{ Id = 'channel-bound-removed'; Desc = 'channel count bound removed'
       Edits = @(@{ Find = '    $chOk   = (($Channels -ge 1) -and ($Channels -le 64))'; Replace = '    $chOk   = $true' }) },
    @{ Id = 'rate-bound-removed'; Desc = 'sample rate bound removed'
       Edits = @(@{ Find = '    $rateOk = (($Rate -ge 4000) -and ($Rate -le 768000))'; Replace = '    $rateOk = $true' }) },
    @{ Id = 'format-gate-always-true'; Desc = 'the whole format redundancy gate always passes'
       Edits = @(@{ Find = '        Ok            = (($expBlk -eq $BlockAlign) -and ($expAvg -eq $AvgBytes) -and $bitsOk -and $chOk -and $rateOk)'
                    Replace = '        Ok            = $true' }) },
    @{ Id = 'blockalign-check-dropped'; Desc = 'block align comparison dropped from the format gate'
       Edits = @(@{ Find = '        Ok            = (($expBlk -eq $BlockAlign) -and ($expAvg -eq $AvgBytes) -and $bitsOk -and $chOk -and $rateOk)'
                    Replace = '        Ok            = (($expAvg -eq $AvgBytes) -and $bitsOk -and $chOk -and $rateOk)' }) },
    @{ Id = 'clockfreq-gate-always-true'; Desc = 'audio clock frequency gate always passes'
       Edits = @(@{ Find = '        Ok              = (($ClockFreq -eq $AvgBytes) -or ($ClockFreq -eq $Rate))'
                    Replace = '        Ok              = $true' }) },
    @{ Id = 'error-reports-smaller'; Desc = 'reports the SMALLER of the regression and batch-means errors'
       Edits = @(@{ Find = '    if ($emp.Usable -and ($emp.SeEmpirical -gt $se)) { $se = $emp.SeEmpirical }'
                    Replace = '    if ($emp.Usable -and ($emp.SeEmpirical -lt $se)) { $se = $emp.SeEmpirical }' }) },
    @{ Id = 'method-picks-worse'; Desc = 'method selection picks the LESS precise of the two techniques'
       Edits = @(@{ Find = '        if ($cm.Se -lt $pm.Se) { $use = $cm }'; Replace = '        if ($cm.Se -gt $pm.Se) { $use = $cm }' }) },
    @{ Id = 'truerate-divides'; Desc = 'true rate divides the nominal rate by the slope instead of multiplying'
       Edits = @(@{ Find = '    $r.TrueRate        = $r.NominalRate * $use.Slope'; Replace = '    $r.TrueRate        = $r.NominalRate / $use.Slope' }) },
    @{ Id = 'usable-gate-inverted'; Desc = 'usability threshold inverted, so only imprecise runs are reported'
       Edits = @(@{ Find = '    $r.Usable          = ($r.SePpm -le $script:MaxUsableSePpm)'; Replace = '    $r.Usable          = ($r.SePpm -ge $script:MaxUsableSePpm)' }) },
    @{ Id = 'sd-population-divisor'; Desc = 'batch-means standard deviation uses N instead of N-1'
       Edits = @(@{ Find = '    if ($n -gt 1) { $sd = [math]::Sqrt($ss / ($n - 1)) }'; Replace = '    if ($n -gt 1) { $sd = [math]::Sqrt($ss / $n) }' }) },
    @{ Id = 'batchmeans-no-sqrt-n'; Desc = 'batch-means error forgets to divide by sqrt(N)'
       Edits = @(@{ Find = '    $seEmp = $sd / [math]::Sqrt($n)'; Replace = '    $seEmp = $sd' }) },
    @{ Id = 'window-size-ceiling'; Desc = 'sub-window size rounds up, overrunning the series'
       Edits = @(@{ Find = '    $per = [int][math]::Floor($n / $Windows)'; Replace = '    $per = [int][math]::Ceiling($n / $Windows)' }) },
    @{ Id = 'window-tail-dropped'; Desc = 'final sub-window no longer extends to the end of the series'
       Edits = @(@{ Find = '        if ($w -eq ($Windows - 1)) { $b = $n - 1 }'; Replace = '        if ($false) { $b = $n - 1 }' }) },
    @{ Id = 'window-min-samples'; Desc = 'minimum samples per window reduced to one'
       Edits = @(@{ Find = '    if ($n -lt ($Windows * 3)) { return ,$out.ToArray() }'; Replace = '    if ($n -lt ($Windows * 1)) { return ,$out.ToArray() }' }) },
    @{ Id = 'fps-allows-thousands'; Desc = 'fps parser allows digit-group separators, so "30,60" becomes 3060'
       Edits = @(@{ Find = '                    [Globalization.NumberStyles]::Float,'; Replace = '                    [Globalization.NumberStyles]::Any,' }) },
    @{ Id = 'fps-duplicates-kept'; Desc = 'fps list no longer removes duplicates'
       Edits = @(@{ Find = '                if (-not $out.Contains($v)) { [void]$out.Add($v) }'; Replace = '                [void]$out.Add($v)' }) },
    @{ Id = 'relative-drift-adds'; Desc = 'relative drift adds the two rates instead of subtracting'
       Edits = @(@{ Find = '            $rel = $a.Ppm - $b.Ppm'; Replace = '            $rel = $a.Ppm + $b.Ppm' }) },
    @{ Id = 'domains-merge-everything'; Desc = 'every measured endpoint is forced into one clock domain'
       Edits = @(@{ Find = '            if ($t.Same) { $f.ClockDomain = $domain }'; Replace = '            $f.ClockDomain = $domain' }) },

    # The -SkipMeasure path. These guard the structural fix for a bug that hid
    # behind a clean exit code: a second emitter with its own schema that
    # nothing downstream parsed.
    @{ Id = 'skipnote-constant-changed'; Desc = 'the skip note constant no longer matches what the native layer emits'
       Edits = @(@{ Find = "`$script:SkipMeasureNote   = 'not measured (-SkipMeasure)'"
                    Replace = "`$script:SkipMeasureNote   = 'not measured'" }) },
    @{ Id = 'skipnote-native-changed'; Desc = 'the native layer emits a different skip note than the constant'
       Edits = @(@{ Find = '            e.Error = "not measured (-SkipMeasure)";'
                    Replace = '            e.Error = "skipped";' }) },
    @{ Id = 'skipnote-cries-wolf'; Desc = 'a user-requested skip is printed with the warning glyph again'
       Edits = @(@{ Find = '            if ([String]::Equals($note, $script:SkipMeasureNote, [StringComparison]::Ordinal)) {'
                    Replace = '            if ($false) {' }) },
    @{ Id = 'second-emitter-restored'; Desc = 'the measure path stops using the shared emitter'
       Edits = @(@{ Find = "        EmitEndpoints(sb, eps);`r`n`r`n        foreach (Endpoint e in eps) {`r`n            try {`r`n                if (e.Rc  != null) Marshal.ReleaseComObject(e.Rc);"
                    Replace = "        foreach (Endpoint e in eps) {`r`n            try {`r`n                if (e.Rc  != null) Marshal.ReleaseComObject(e.Rc);" }) },
    @{ Id = 'enumerate-opens-a-stream'; Desc = 'the enumerate path is given a second emitter of its own'
       Edits = @(@{ Find = '    static void EmitEndpoints(StringBuilder sb, List<Endpoint> eps) {'
                    Replace = '    static void EmitEndpointsRenamed(StringBuilder sb, List<Endpoint> eps) {' }) },
    @{ Id = 'floor-ignores-packet-plausibility'; Desc = 'a resampled endpoint may set the systematic floor via its packet reading'
       Edits = @(@{ Find = '        if (-not (Test-PpmPlausible -Ppm $e.PacketPpm)) { continue }'
                    Replace = '        if ($false) { continue }' }) },
    @{ Id = 'floor-ignores-clock-plausibility'; Desc = 'a resampled endpoint may set the systematic floor via its clock reading'
       Edits = @(@{ Find = '        if (-not (Test-PpmPlausible -Ppm $e.ClockPpm))  { continue }'
                    Replace = '        if ($false) { continue }' }) },
    @{ Id = 'floor-cap-removed'; Desc = 'the systematic floor is no longer capped at the crystal ceiling'
       Edits = @(@{ Find = '    if ($worst -gt $script:MaxCrystalPpm) { $worst = $script:MaxCrystalPpm }'
                    Replace = '    if ($worst -gt ($script:MaxCrystalPpm * 1e9)) { $worst = $script:MaxCrystalPpm }' }) },
    @{ Id = 'floor-gate-inverted'; Desc = 'the plausibility gate keeps only the implausible endpoints'
       Edits = @(@{ Find = '        if (-not (Test-PpmPlausible -Ppm $e.PacketPpm)) { continue }'
                    Replace = '        if ((Test-PpmPlausible -Ppm $e.PacketPpm)) { continue }' }) },
    @{ Id = 'hw-never-read'; Desc = 'the device instance path is never read from the hardware'
       Edits = @(@{ Find = '        return GetStringProp(d, "b3f8fa53-0004-438e-9003-51a46e139bfc", 2);'
                    Replace = '        return "";' }) },
    @{ Id = 'hw-wrong-property'; Desc = 'the hardware lookup asks for the wrong property key'
       Edits = @(@{ Find = '        return GetStringProp(d, "b3f8fa53-0004-438e-9003-51a46e139bfc", 2);'
                    Replace = '        return GetStringProp(d, "b3f8fa53-0004-438e-9003-51a46e139bfc", 6);' }) },
    @{ Id = 'hw-not-emitted'; Desc = 'the hardware path is collected but never emitted'
       Edits = @(@{ Find = "            sb.AppendLine(p + `"hw=`" + e.Hw);`r`n"
                    Replace = '' }) },
    @{ Id = 'crystal-claimed-unconditionally'; Desc = 'every clock domain is called one crystal'
       Edits = @(@{ Find = '            } elseif (@($paths).Count -eq 1) {'
                    Replace = '            } elseif ($true) {' }) },
    @{ Id = 'unknown-hardware-ignored'; Desc = 'an endpoint Windows will not name is treated as agreement'
       Edits = @(@{ Find = '            if ($unknown -gt 0) {'
                    Replace = '            if ($false) {' }) },
    @{ Id = 'resampling-reported-as-crystal'; Desc = 'separate devices are described as sharing a crystal'
       Edits = @(@{ Find = "separate physical devices: locked, but by resampling, not by a shared crystal')"
                    Replace = "separate physical devices, so this is one crystal')" }) },

    # PAIRED EDIT, declared equivalent up front and proven below. Abs(NaN)
    # and Abs(Infinity) both fail the -le comparison on their own, so these
    # two guards are redundantly defensive: neither removing one nor removing
    # BOTH changes any observable result.
    @{ Id = 'plausible-nonfinite-guards'; Desc = 'both non-finite guards removed together (paired edit)'
       Expect = 'equivalent'
       Edits = @(@{ Find = '    if ([double]::IsNaN($Ppm)) { return $false }'; Replace = '' },
                 @{ Find = '    if ([double]::IsInfinity($Ppm)) { return $false }'; Replace = '' }) },

    # DELIBERATELY BROKEN ANCHOR. This text is not in the source. It must be
    # reported as an INVALID CONTROL, never as a kill.
    @{ Id = 'harness-selfcheck-bad-anchor'; Desc = 'anchor text that does not exist (proves dead anchors are detected)'
       Edits = @(@{ Find = '    $i = $Name.IndexOf(''#'')'; Replace = '    $i = -1' }) }
)

Write-Host ''
Write-Host 'audiodrift mutation testing - can the suite actually fail?' -ForegroundColor Cyan
Write-Host ('  ' + [string]@($m_muts).Count + ' mutations, ' + [string]$TimeoutSec + ' s timeout each') -ForegroundColor Gray
Write-Host ''

# Baseline: the unmutated tool must PASS, or every "kill" below is just the
# suite being broken.
Copy-Item -LiteralPath $m_tool -Destination $m_workTool -Force
$m_base = m_Run -ScriptPath $m_workSuite -Seconds $TimeoutSec
if ($m_base.TimedOut -or $m_base.ExitCode -ne 0) {
    Write-Host '  BASELINE FAILED - the unmutated suite does not pass. Fix that first.' -ForegroundColor Red
    Write-Host $m_base.Out
    Write-Host $m_base.Err
    Remove-Item -LiteralPath $m_work -Recurse -Force
    exit 1
}
Write-Host '  baseline: unmutated tool passes the suite' -ForegroundColor Green
Write-Host ''

$m_killed = 0
$m_surv = New-Object Collections.Generic.List[string]
$m_invalid = New-Object Collections.Generic.List[string]
$m_noop = New-Object Collections.Generic.List[string]
$m_equiv = New-Object Collections.Generic.List[string]
$m_equivBroke = New-Object Collections.Generic.List[string]
$m_timeout = New-Object Collections.Generic.List[string]
$m_scored = 0

foreach ($m_m in $m_muts) {
    $m_expect = 'kill'
    if ($m_m.ContainsKey('Expect')) { $m_expect = [string]$m_m.Expect }

    # VALIDATE EVERY ANCHOR FIRST. An anchor that is absent, or ambiguous,
    # makes the mutation meaningless - and it would otherwise be silently
    # reported as a kill.
    $m_anchorOk = $true
    $m_why = ''
    foreach ($m_e in $m_m.Edits) {
        $m_n = 0
        $m_idx = 0
        while ($true) {
            $m_idx = $m_src.IndexOf($m_e.Find, $m_idx, [StringComparison]::Ordinal)
            if ($m_idx -lt 0) { break }
            $m_n++
            $m_idx += $m_e.Find.Length
        }
        if ($m_n -ne 1) {
            $m_anchorOk = $false
            $m_why = 'anchor found ' + [string]$m_n + ' times (need exactly 1)'
            break
        }
    }
    if (-not $m_anchorOk) {
        [void]$m_invalid.Add($m_m.Id + ': ' + $m_why)
        Write-Host ('  [INVALID] ' + $m_m.Id + ' - ' + $m_why) -ForegroundColor Yellow
        continue
    }

    $m_mut = $m_src
    foreach ($m_e in $m_m.Edits) {
        $m_mut = $m_mut.Replace($m_e.Find, $m_e.Replace)
    }
    if ($m_mut -eq $m_src) {
        [void]$m_noop.Add($m_m.Id)
        Write-Host ('  [no-op]   ' + $m_m.Id + ' - edits left the file unchanged, not scored') -ForegroundColor Yellow
        continue
    }

    [IO.File]::WriteAllText($m_workTool, $m_mut, (New-Object Text.UTF8Encoding($false)))
    $m_res = m_Run -ScriptPath $m_workSuite -Seconds $TimeoutSec

    if ($m_res.TimedOut) {
        [void]$m_timeout.Add($m_m.Id)
        Write-Host ('  [TIMEOUT] ' + $m_m.Id + ' - ' + $m_m.Desc) -ForegroundColor Yellow
        continue
    }
    $m_caught = ($m_res.ExitCode -ne 0)

    if ($m_expect -eq 'equivalent') {
        if ($m_caught) {
            [void]$m_equivBroke.Add($m_m.Id)
            Write-Host ('  [MISLABEL] ' + $m_m.Id + ' - declared equivalent but the suite caught it') -ForegroundColor Red
        } else {
            [void]$m_equiv.Add($m_m.Id)
            Write-Host ('  [equiv]   ' + $m_m.Id + ' - ' + $m_m.Desc) -ForegroundColor DarkGray
        }
        continue
    }

    $m_scored++
    if ($m_caught) {
        $m_killed++
        if ($Detail) { Write-Host ('  [killed]  ' + $m_m.Id + ' - ' + $m_m.Desc) -ForegroundColor DarkGray }
    } else {
        [void]$m_surv.Add($m_m.Id + ' - ' + $m_m.Desc)
        Write-Host ('  [SURVIVED] ' + $m_m.Id + ' - ' + $m_m.Desc) -ForegroundColor Red
    }
}

# PROVE the equivalence claim rather than asserting it. Abs() of a non-finite
# value fails the -le comparison, so the guards cannot change the result.
Write-Host ''
Write-Host '== equivalence proof for the paired mutation' -ForegroundColor Cyan
$m_nanFails = -not ([math]::Abs([double]::NaN) -le 1000.0)
$m_posInf   = -not ([math]::Abs([double]::PositiveInfinity) -le 1000.0)
$m_negInf   = -not ([math]::Abs([double]::NegativeInfinity) -le 1000.0)
$m_proven = ($m_nanFails -and $m_posInf -and $m_negInf)
if ($m_proven) {
    Write-Host '  Abs(NaN), Abs(+Inf) and Abs(-Inf) all fail the -le bound on their own,' -ForegroundColor Gray
    Write-Host '  so the two explicit guards are redundant and the mutation is genuinely' -ForegroundColor Gray
    Write-Host '  equivalent. The guards stay: they state the intent at the call site.' -ForegroundColor Gray
} else {
    Write-Host '  equivalence claim NOT proven - the guards are load bearing after all' -ForegroundColor Red
}

Write-Host ''
Write-Host '== result' -ForegroundColor Cyan
Write-Host ('  mutation score      ' + [string]$m_killed + ' / ' + [string]$m_scored) -ForegroundColor Gray
Write-Host ('  survivors           ' + [string]$m_surv.Count) -ForegroundColor Gray
Write-Host ('  invalid controls    ' + [string]$m_invalid.Count + ' (dead anchors, counted separately)') -ForegroundColor Gray
Write-Host ('  equivalent mutants  ' + [string]$m_equiv.Count + ' (excluded from the score, proven above)') -ForegroundColor Gray
Write-Host ('  no-ops excluded     ' + [string]$m_noop.Count) -ForegroundColor Gray
Write-Host ('  timeouts            ' + [string]$m_timeout.Count) -ForegroundColor Gray

Remove-Item -LiteralPath $m_work -Recurse -Force
Write-Host ('  scratch removed     ' + $m_work) -ForegroundColor DarkGray

# The harness self-check: exactly one mutation is deliberately anchored on
# absent text, so the invalid count must be exactly 1. Zero would mean the
# detector is broken.
$m_selfOk = ($m_invalid.Count -eq 1)
Write-Host ''
if ($m_selfOk) {
    Write-Host '  harness self-check: the deliberately dead anchor WAS detected' -ForegroundColor Green
} else {
    Write-Host ('  harness self-check FAILED: expected exactly 1 invalid control, got ' + [string]$m_invalid.Count) -ForegroundColor Red
}

$m_ok = (($m_surv.Count -eq 0) -and ($m_timeout.Count -eq 0) -and ($m_equivBroke.Count -eq 0) -and $m_selfOk -and $m_proven)
Write-Host ''
if ($m_ok) {
    Write-Host ('ALL MUTATIONS KILLED  ' + [string]$m_killed + ' of ' + [string]$m_scored +
                ', plus ' + [string]$m_equiv.Count + ' proven equivalent and ' +
                [string]$m_invalid.Count + ' invalid control detected') -ForegroundColor Green
    exit 0
} else {
    foreach ($m_s in $m_surv) { Write-Host ('  SURVIVED: ' + $m_s) -ForegroundColor Red }
    foreach ($m_s in $m_timeout) { Write-Host ('  TIMEOUT: ' + $m_s) -ForegroundColor Red }
    foreach ($m_s in $m_equivBroke) { Write-Host ('  MISLABELLED EQUIVALENT: ' + $m_s) -ForegroundColor Red }
    exit 1
}
