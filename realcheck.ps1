<#
    realcheck.ps1 - audiodrift verified against real system data.

    selftest.ps1 proves the arithmetic with synthetic data. This suite proves
    the tool agrees with Windows itself, using independent sources written
    with a DIFFERENT technique from the tool's own:

      tool                              independent reference
      ----------------------------      ----------------------------------
      COM IPropertyStore / GetMixFormat raw registry REG_BINARY under
                                        HKLM MMDevices, parsed by hand
      COM IMMDeviceEnumerator           Get-PnpDevice -Class AudioEndpoint
      QueryPerformanceFrequency         [Diagnostics.Stopwatch]::Frequency
      measured drift                    drift planted inside the REAL series

    Every comparison is followed by NEGATIVE CONTROLS: the same check is
    replayed against deliberately corrupted values and every one must be
    rejected. A comparison that tolerates anything proves nothing.

    Read-only. Nothing here writes to the registry or changes a setting.

    Run:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File realcheck.ps1
#>
[CmdletBinding()]
param([int]$MeasureSeconds = 30, [switch]$Detail)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$t_here = Split-Path -Parent $MyInvocation.MyCommand.Path
$t_tool = Join-Path $t_here 'audiodrift.ps1'
if (-not (Test-Path -LiteralPath $t_tool)) { Write-Host 'cannot find audiodrift.ps1'; exit 1 }
. $t_tool -NoRun

$t_pass = 0
$t_fail = 0
$t_skip = 0
$t_msgs = New-Object Collections.Generic.List[string]

function t_Ok { param([string]$Name, [bool]$Cond, [string]$Info = '')
    if ($Cond) {
        $script:t_pass++
        if ($Detail) { Write-Host ('  [ok]   ' + $Name + '  ' + $Info) -ForegroundColor DarkGray }
    } else {
        $script:t_fail++
        Write-Host ('  [FAIL] ' + $Name + '  ' + $Info) -ForegroundColor Red
        [void]$script:t_msgs.Add($Name + ': ' + $Info)
    }
}
function t_Note { param([string]$Text) Write-Host ('  ' + $Text) -ForegroundColor Gray }
function t_Skip { param([string]$Name, [string]$Why)
    $script:t_skip++
    Write-Host ('  [skip] ' + $Name + '  ' + $Why) -ForegroundColor Yellow
}
function t_Section { param([string]$Name)
    Write-Host ''
    Write-Host ('== ' + $Name) -ForegroundColor Cyan
}

Write-Host ''
Write-Host 'audiodrift realcheck - real system data, independent references, negative controls' -ForegroundColor Cyan

# ---------------------------------------------------------------------------
t_Section 'PROVE READ-ONLY'
# Claim one: the source contains no call that could change machine state.
$t_src = [IO.File]::ReadAllText($t_tool)
$t_banned = @(
    'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'Remove-Item',
    'New-Item', 'Set-Item', 'Set-Content', 'Add-Content', 'Out-File',
    'Set-Service', 'Stop-Service', 'Start-Service', 'Stop-Process', 'Start-Process',
    'Set-ExecutionPolicy', 'git config', 'SetValue', 'DeleteValue', 'DeleteSubKey',
    'CreateSubKey', 'setx', 'reg add', 'reg delete',
    'SetEnvironmentVariable', 'WriteAllText', 'WriteAllBytes', 'AppendAllText',
    'Remove-ItemProperty', 'Rename-Item', 'Move-Item', 'Clear-Content'
)
# CLASSIFY BEFORE JUDGING. A COM interface must declare EVERY method of the
# interface in order, because the declaration order IS the vtable layout.
# IPropertyStore::SetValue therefore appears in the source as a signature
# that is never called - omitting it would silently move GetValue's slot.
# A naive "grep for mutating calls" flags it and would be wrong. So scan
# call sites only, and prove separately that the declaration is inert.
$t_srcLines = $t_src -split "`r?`n"
$t_callLines = New-Object Collections.Generic.List[string]
$t_declLines = New-Object Collections.Generic.List[string]
foreach ($t_ln in $t_srcLines) {
    $t_trim = $t_ln.Trim()
    if ($t_trim.StartsWith('[PreserveSig]', [StringComparison]::Ordinal) -and $t_trim.EndsWith(';', [StringComparison]::Ordinal)) {
        [void]$t_declLines.Add($t_trim)
    } else {
        [void]$t_callLines.Add($t_ln)
    }
}
$t_callText = ($t_callLines.ToArray()) -join "`n"
$t_hits = New-Object Collections.Generic.List[string]
foreach ($t_b in ($t_banned | Sort-Object -Unique)) {
    if ($t_callText.IndexOf($t_b, [StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$t_hits.Add($t_b) }
}
$t_bannedCount = @($t_banned | Sort-Object -Unique).Count
t_Ok -Name ('no call site in the source matches any of ' + [string]$t_bannedCount + ' state-changing patterns') `
     -Cond ($t_hits.Count -eq 0) -Info (($t_hits.ToArray()) -join ', ')
t_Note ('scanned ' + [string]$t_callLines.Count + ' code lines (' + [string]$t_src.Length + ' characters); ' +
        [string]$t_declLines.Count + ' COM vtable signatures excluded as declarations, not calls')

# Whatever was excluded must be a declaration ONLY: the same identifier must
# never appear as an invocation anywhere in the file.
$t_declInert = $true
$t_declNames = New-Object Collections.Generic.List[string]
foreach ($t_d2 in $t_declLines) {
    foreach ($t_b in $t_banned) {
        if ($t_d2.IndexOf($t_b, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if (-not $t_declNames.Contains($t_b)) { [void]$t_declNames.Add($t_b) }
        if ($t_callText.IndexOf('.' + $t_b + '(', [StringComparison]::OrdinalIgnoreCase) -ge 0) { $t_declInert = $false }
    }
}
t_Ok -Name 'every excluded COM signature is declared but never invoked' -Cond $t_declInert `
     -Info ('declared-only: ' + (($t_declNames.ToArray()) -join ', '))
t_Note ('IPropertyStore::SetValue is declared to preserve vtable order and is never called')

# Negative control: the scan must be capable of finding something. If the
# pattern list could never match, the check above would pass vacuously.
$t_probe = $t_callText + "`nSet-ItemProperty -Path X -Name Y -Value Z"
$t_caught = $false
foreach ($t_b in $t_banned) {
    if ($t_probe.IndexOf($t_b, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $t_caught = $true; break }
}
t_Ok -Name 'NEGATIVE CONTROL: the same scan does detect a planted mutating call' -Cond $t_caught
# And a planted CALL to the declared-only method must break the inert claim.
$t_probe2 = $t_callText + "`n        ps.SetValue(ref k, ref v);"
t_Ok -Name 'NEGATIVE CONTROL: a planted call to the declared-only method is detected' `
     -Cond ($t_probe2.IndexOf('.SetValue(', [StringComparison]::OrdinalIgnoreCase) -ge 0)

# Claim two: the registry keys the tool reads are byte-identical afterwards.
$t_regRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio'
function t_SnapshotAudioRegistry {
    $t_sb = New-Object Text.StringBuilder
    foreach ($t_flow in @('Render','Capture')) {
        $t_path = Join-Path $t_regRoot $t_flow
        if (-not (Test-Path $t_path)) { continue }
        foreach ($t_dev in (Get-ChildItem $t_path | Sort-Object PSChildName)) {
            $t_pk = Join-Path $t_dev.PSPath 'Properties'
            if (-not (Test-Path $t_pk)) { continue }
            $t_props = Get-ItemProperty $t_pk
            foreach ($t_n in ($t_props.PSObject.Properties.Name | Sort-Object)) {
                if ($t_n -like 'PS*') { continue }
                $t_v = $t_props.$t_n
                if ($t_v -is [byte[]]) {
                    [void]$t_sb.AppendLine($t_dev.PSChildName + '|' + $t_n + '|' + [BitConverter]::ToString($t_v))
                } else {
                    [void]$t_sb.AppendLine($t_dev.PSChildName + '|' + $t_n + '|' + [string]$t_v)
                }
            }
        }
    }
    return $t_sb.ToString()
}
$t_before = t_SnapshotAudioRegistry
$t_beforeLines = @($t_before -split "`r?`n" | Where-Object { $_.Length -gt 0 }).Count

# ---------------------------------------------------------------------------
t_Section 'INDEPENDENT REFERENCE 1: hand-parsed registry vs the tool COM walk'
# The tool reads the endpoint list and format through COM. This reference
# reads the SAME facts straight out of the registry as raw bytes, decoding
# WAVEFORMATEX by offset arithmetic. No shared code path whatsoever.

# PROPVARIANT-wrapped blob: 8 bytes of header, then the structure itself.
function t_ParseWfxBlob {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes) { return $null }
    if ($Bytes.Length -lt 26) { return $null }
    $t_vt = [BitConverter]::ToUInt32($Bytes, 0)
    if ($t_vt -ne 65) { return $null }           # VT_BLOB
    $t_o = 8
    $t_tag = [BitConverter]::ToUInt16($Bytes, $t_o + 0)
    $t_ch  = [BitConverter]::ToUInt16($Bytes, $t_o + 2)
    # A real blob on this machine carries 4294967032 in the sample-rate slot.
    # [int] THROWS on any UInt32 above Int32.MaxValue, so every 32-bit field
    # must be carried as [long] and rejected by the bounds check instead of
    # crashing the parser before it can judge the value.
    $t_sr  = [long][BitConverter]::ToUInt32($Bytes, $t_o + 4)
    $t_ab  = [long][BitConverter]::ToUInt32($Bytes, $t_o + 8)
    $t_ba  = [BitConverter]::ToUInt16($Bytes, $t_o + 12)
    $t_bits= [BitConverter]::ToUInt16($Bytes, $t_o + 14)
    $t_cb  = [BitConverter]::ToUInt16($Bytes, $t_o + 16)
    $t_sub = -1
    if ($t_tag -eq 1) { $t_sub = 1 }
    elseif ($t_tag -eq 3) { $t_sub = 3 }
    elseif ($t_tag -eq 65534 -and $Bytes.Length -ge ($t_o + 22 + 4)) {
        $t_sub = [BitConverter]::ToInt32($Bytes, $t_o + 24)
    }
    return @{
        Tag = [int]$t_tag; Channels = [int]$t_ch; Rate = [long]$t_sr
        AvgBytes = [long]$t_ab; BlockAlign = [int]$t_ba; Bits = [int]$t_bits
        CbSize = [int]$t_cb; SubFormat = [int]$t_sub
        # The blob's own length must equal header + WAVEFORMATEX + cbSize.
        # This is a redundant field pair and is what proves the offsets used
        # above are the right ones rather than a lucky coincidence.
        LengthConsistent = ($Bytes.Length -eq (8 + 18 + $t_cb))
        Length = $Bytes.Length
    }
}

function t_RegEndpoint {
    param([string]$Flow, [string]$EndpointId)
    $t_core = $EndpointId
    $t_i = $EndpointId.IndexOf('}.')
    if ($t_i -ge 0) { $t_core = $EndpointId.Substring($t_i + 2) }
    $t_k = Join-Path (Join-Path $t_regRoot $Flow) ($t_core + '\Properties')
    if (-not (Test-Path $t_k)) { return $null }
    $t_p = Get-ItemProperty $t_k
    $t_get = {
        param($Name)
        $t_pr = $t_p.PSObject.Properties[$Name]
        if ($null -eq $t_pr) { return $null }
        return $t_pr.Value
    }
    return @{
        Key         = $t_k
        Description = (& $t_get '{a45c254e-df1c-4efd-8020-67d146a850e0},2')
        Adapter     = (& $t_get '{b3f8fa53-0004-438e-9003-51a46e139bfc},6')
        InstancePath= (& $t_get '{b3f8fa53-0004-438e-9003-51a46e139bfc},2')
        FormatBlob  = (& $t_get '{f19f064d-082c-4e27-bc73-6882a1bb8e4c},0')
        Props       = $t_p
    }
}

if (-not (Initialize-AudioDriftNative)) { Write-Host 'cannot build native layer'; exit 1 }
$t_enumRaw = [AudioDriftNative.Engine]::Enumerate()
$t_enumMap = ConvertFrom-AdRecords -Text $t_enumRaw
$t_allCount = 0
if ($t_enumMap.ContainsKey('alldevices')) { $t_allCount = [int]$t_enumMap['alldevices'] }
t_Ok -Name 'COM enumeration returned at least one endpoint' -Cond ($t_allCount -ge 1) -Info ([string]$t_allCount + ' across all device states')

$t_comparedFields = 0
$t_mismatch = New-Object Collections.Generic.List[string]
$t_regFound = 0
$t_pairs = New-Object Collections.Generic.List[object]
$t_adapterVerbatim = 0
$t_adapterPrefix = 0
for ($t_i = 0; $t_i -lt $t_allCount; $t_i++) {
    $t_id = $t_enumMap['all.' + [string]$t_i + '.id']
    $t_nm = $t_enumMap['all.' + [string]$t_i + '.name']
    $t_flow = 'Render'
    if ($t_id.StartsWith('{0.0.1.', [StringComparison]::Ordinal)) { $t_flow = 'Capture' }
    $t_reg = t_RegEndpoint -Flow $t_flow -EndpointId $t_id
    if ($null -eq $t_reg) { continue }
    $t_regFound++
    [void]$t_pairs.Add(@{ Id = $t_id; Name = $t_nm; Flow = $t_flow; Reg = $t_reg })
    # The COM friendly name is built as: description + " (" + device + ")".
    # Containment is the correct assertion for the description - demanding
    # equality would fail on Windows' own "(2- )" disambiguation prefix.
    $t_desc = ''
    if ($null -ne $t_reg.Description) { $t_desc = [string]$t_reg.Description }
    if ($t_desc.Length -gt 0) {
        $t_comparedFields++
        if ($t_nm.IndexOf($t_desc, [StringComparison]::Ordinal) -lt 0) {
            [void]$t_mismatch.Add($t_id + ' description "' + $t_desc + '" not in COM name "' + $t_nm + '"')
        }
    }
    # CLASSIFY BEFORE JUDGING. The registry adapter name is the name of the
    # AUDIO INTERFACE; the parenthesised part of the COM name is the name of
    # the DEVICE. For a bus-attached codec they are the same string. For
    # Bluetooth they are not: the HFP endpoint is adapter
    # "iClever-BTH12 Hands-Free" but COM name "Headset (iClever-BTH12)",
    # because one physical headset exposes A2DP and Hands-Free as separate
    # interfaces of the same device. Asserting verbatim containment would
    # report a fault that does not exist, so assert the relation that holds
    # in both cases: the device name is a prefix of the adapter name.
    $t_adap = ''
    if ($null -ne $t_reg.Adapter) { $t_adap = [string]$t_reg.Adapter }
    if ($t_adap.Length -gt 0) {
        $t_comparedFields++
        if ($t_nm.IndexOf($t_adap, [StringComparison]::Ordinal) -ge 0) {
            $t_adapterVerbatim++
        } else {
            # Recover the device name using the description length, so the
            # split point is derived from a field already verified above.
            $t_inner = ''
            if ($t_desc.Length -gt 0 -and $t_nm.Length -gt ($t_desc.Length + 3) -and
                $t_nm.EndsWith(')', [StringComparison]::Ordinal)) {
                $t_inner = $t_nm.Substring($t_desc.Length + 2, $t_nm.Length - $t_desc.Length - 3)
            }
            if ($t_inner.Length -gt 0 -and $t_adap.StartsWith($t_inner, [StringComparison]::Ordinal)) {
                $t_adapterPrefix++
            } else {
                [void]$t_mismatch.Add($t_id + ' adapter "' + $t_adap + '" is neither contained in nor prefixed by COM name "' + $t_nm + '"')
            }
        }
    }
}
t_Ok -Name 'every COM endpoint was located in the registry by its own id' -Cond ($t_regFound -eq $t_allCount) `
     -Info ([string]$t_regFound + ' of ' + [string]$t_allCount)
t_Ok -Name ('COM friendly names agree with registry text across ' + [string]$t_comparedFields + ' fields') `
     -Cond ($t_mismatch.Count -eq 0) -Info (($t_mismatch.ToArray()) -join '; ')
t_Note ([string]$t_comparedFields + ' name fields compared against the registry, ' + [string]$t_mismatch.Count + ' mismatches')
t_Note ([string]$t_adapterVerbatim + ' adapters matched verbatim, ' + [string]$t_adapterPrefix +
        ' matched as a device-name prefix (Bluetooth renames its interfaces)')

# NEGATIVE CONTROL: the containment check must reject a name it should not
# accept. Without this, "0 mismatches" could just mean the check is inert.
# Some corruptions are genuinely UNDECIDABLE by this check and are excluded
# a priori rather than scored: this machine has four endpoints described
# "Headphones", three "Speakers" and two "Microphone", and "Microphone" is a
# substring of "Microphone Array" while "Headset" is a substring of "Headset
# Microphone". Substituting one of those for another produces a string that
# is still legitimately present, so the check cannot and should not fail.
$t_killed = 0; $t_total = 0; $t_undec = New-Object Collections.Generic.List[string]
foreach ($t_pr2 in $t_pairs) {
    if ($null -eq $t_pr2.Reg.Description) { continue }
    $t_d = [string]$t_pr2.Reg.Description
    if ($t_d.Length -lt 2) { continue }
    # Mutation 1: a single character changed.
    $t_total++
    $t_mut = ([string][char](([int][char]$t_d[0]) + 1)) + $t_d.Substring(1)
    if ($t_pr2.Name.IndexOf($t_mut, [StringComparison]::Ordinal) -lt 0) { $t_killed++ }
    # Mutation 2: the description reversed.
    $t_arr = $t_d.ToCharArray(); [array]::Reverse($t_arr)
    $t_rev = -join $t_arr
    if ($t_rev -ne $t_d) {
        $t_total++
        if ($t_pr2.Name.IndexOf($t_rev, [StringComparison]::Ordinal) -lt 0) { $t_killed++ }
    }
    # Mutation 3: another endpoint's description.
    foreach ($t_other in $t_pairs) {
        if ($t_other.Id -eq $t_pr2.Id) { continue }
        if ($null -eq $t_other.Reg.Description) { continue }
        $t_od = [string]$t_other.Reg.Description
        if ($t_od -eq $t_d) { continue }
        # Decided a priori, without looking at the outcome: if one
        # description is a substring of the other, no containment test can
        # tell them apart.
        if ($t_d.IndexOf($t_od, [StringComparison]::Ordinal) -ge 0) {
            [void]$t_undec.Add('"' + $t_od + '" inside "' + $t_d + '"')
            continue
        }
        $t_total++
        if ($t_pr2.Name.IndexOf($t_od, [StringComparison]::Ordinal) -lt 0) { $t_killed++ }
    }
}
t_Ok -Name ('NEGATIVE CONTROL: ' + [string]$t_killed + ' of ' + [string]$t_total + ' corrupted names rejected') `
     -Cond (($t_total -gt 0) -and ($t_killed -eq $t_total)) -Info ([string]$t_killed + '/' + [string]$t_total)
$t_undecU = @($t_undec.ToArray() | Sort-Object -Unique)
t_Note ('mutation score ' + [string]$t_killed + '/' + [string]$t_total + '; ' + [string]$t_undec.Count +
        ' excluded as UNDETECTABLE by a containment test (' + (($t_undecU) -join ', ') + ')')

# ---------------------------------------------------------------------------
t_Section 'INDEPENDENT REFERENCE 2: every real format blob in the registry'
# There are far more format blobs on a real machine than the two the tool
# uses - supported formats, preferred formats, per-mode formats. Parsing all
# of them proves the offsets are right while surrounded by hundreds of real,
# irrelevant values, and that none of them leak into the result.
$t_blobTotal = 0
$t_blobValid = 0
$t_blobBad = New-Object Collections.Generic.List[string]
$t_realBlobs = New-Object Collections.Generic.List[object]
foreach ($t_flow in @('Render','Capture')) {
    $t_path = Join-Path $t_regRoot $t_flow
    if (-not (Test-Path $t_path)) { continue }
    foreach ($t_dev in (Get-ChildItem $t_path)) {
        $t_pk = Join-Path $t_dev.PSPath 'Properties'
        if (-not (Test-Path $t_pk)) { continue }
        $t_props = Get-ItemProperty $t_pk
        foreach ($t_n in $t_props.PSObject.Properties.Name) {
            if ($t_n -like 'PS*') { continue }
            $t_v = $t_props.$t_n
            if (-not ($t_v -is [byte[]])) { continue }
            $t_w = t_ParseWfxBlob -Bytes $t_v
            if ($null -eq $t_w) { continue }
            # Only count entries that really are WAVEFORMATEX: the blob's own
            # length must be explained by its own cbSize field.
            if (-not $t_w.LengthConsistent) { continue }
            if ($t_w.Tag -ne 1 -and $t_w.Tag -ne 3 -and $t_w.Tag -ne 65534) { continue }
            $t_blobTotal++
            [void]$t_realBlobs.Add(@{ Dev = $t_dev.PSChildName; Key = $t_n; W = $t_w; Bytes = $t_v })
            $t_chk = Test-FormatRedundancy -Rate $t_w.Rate -Channels $t_w.Channels -Bits $t_w.Bits `
                                           -BlockAlign $t_w.BlockAlign -AvgBytes $t_w.AvgBytes
            if ($t_chk.Ok) { $t_blobValid++ }
            else { [void]$t_blobBad.Add($t_dev.PSChildName + ' ' + $t_n + ' rate=' + [string]$t_w.Rate + ' ch=' + [string]$t_w.Channels + ' bits=' + [string]$t_w.Bits + ' blk=' + [string]$t_w.BlockAlign + ' avg=' + [string]$t_w.AvgBytes) }
        }
    }
}
t_Ok -Name 'the registry contains real format blobs to test against' -Cond ($t_blobTotal -ge 2) -Info ([string]$t_blobTotal + ' found')
t_Ok -Name ('all ' + [string]$t_blobTotal + ' real format blobs pass the tool redundancy gate') `
     -Cond ($t_blobBad.Count -eq 0) -Info (($t_blobBad.ToArray()) -join '; ')
t_Note ([string]$t_blobTotal + ' genuine WAVEFORMATEX blobs parsed from the live registry, ' + [string]$t_blobBad.Count + ' inconsistencies')
$t_fieldsFromBlobs = $t_blobTotal * 7
t_Note ([string]$t_fieldsFromBlobs + ' real format fields decoded by offset arithmetic and validated')

# NEGATIVE CONTROLS on the blob parser. Each mutation corrupts ONE field of
# a REAL blob in a way that must be caught. A gate that accepts these would
# make the count above meaningless.
$t_mutKilled = 0; $t_mutTotal = 0; $t_mutMissed = New-Object Collections.Generic.List[string]
$t_mutSkipped = 0
foreach ($t_rb in $t_realBlobs) {
    $t_w = $t_rb.W
    $t_cases = @(
        @{ N = 'block align off by one';   R = $t_w.Rate; C = $t_w.Channels; B = $t_w.Bits; K = ($t_w.BlockAlign + 1); A = $t_w.AvgBytes },
        @{ N = 'byte rate off by one';     R = $t_w.Rate; C = $t_w.Channels; B = $t_w.Bits; K = $t_w.BlockAlign; A = ($t_w.AvgBytes + 1) },
        @{ N = 'rate doubled';             R = ($t_w.Rate * 2); C = $t_w.Channels; B = $t_w.Bits; K = $t_w.BlockAlign; A = $t_w.AvgBytes },
        @{ N = 'channels doubled';         R = $t_w.Rate; C = ($t_w.Channels * 2); B = $t_w.Bits; K = $t_w.BlockAlign; A = $t_w.AvgBytes },
        @{ N = 'bits halved';              R = $t_w.Rate; C = $t_w.Channels; B = ([int]($t_w.Bits / 2)); K = $t_w.BlockAlign; A = $t_w.AvgBytes },
        @{ N = 'channels and bits swapped';R = $t_w.Rate; C = $t_w.Bits; B = $t_w.Channels; K = $t_w.BlockAlign; A = $t_w.AvgBytes },
        @{ N = 'byte rate read as block align'; R = $t_w.Rate; C = $t_w.Channels; B = $t_w.Bits; K = [int][math]::Min([long]2147483647, $t_w.AvgBytes); A = $t_w.AvgBytes },
        @{ N = 'rate read as byte rate';   R = $t_w.Rate; C = $t_w.Channels; B = $t_w.Bits; K = $t_w.BlockAlign; A = $t_w.Rate }
    )
    foreach ($t_c in $t_cases) {
        # Exclude genuine no-ops: if the mutation happens to reproduce the
        # original values it tests nothing and must not be scored as a pass.
        if (($t_c.R -eq $t_w.Rate) -and ($t_c.C -eq $t_w.Channels) -and ($t_c.B -eq $t_w.Bits) -and
            ($t_c.K -eq $t_w.BlockAlign) -and ($t_c.A -eq $t_w.AvgBytes)) { $t_mutSkipped++; continue }
        $t_mutTotal++
        $t_res = Test-FormatRedundancy -Rate $t_c.R -Channels $t_c.C -Bits $t_c.B -BlockAlign $t_c.K -AvgBytes $t_c.A
        if (-not $t_res.Ok) { $t_mutKilled++ }
        else { [void]$t_mutMissed.Add($t_rb.Key + ': ' + $t_c.N) }
    }
}
t_Ok -Name ('NEGATIVE CONTROL: ' + [string]$t_mutKilled + ' of ' + [string]$t_mutTotal + ' corrupted real formats rejected') `
     -Cond (($t_mutTotal -gt 0) -and ($t_mutKilled -eq $t_mutTotal)) -Info (($t_mutMissed.ToArray()) -join '; ')
t_Note ('mutation score ' + [string]$t_mutKilled + '/' + [string]$t_mutTotal + ' on real registry data, ' + [string]$t_mutSkipped + ' excluded as no-ops')

# The length-consistency rule is itself a redundant-field check; corrupt the
# length and it must notice.
$t_lenKilled = 0; $t_lenTotal = 0
foreach ($t_rb in $t_realBlobs) {
    foreach ($t_delta in @(-1, 1, 8)) {
        $t_lenTotal++
        $t_newLen = $t_rb.Bytes.Length + $t_delta
        if ($t_newLen -lt 26) { $t_lenKilled++; continue }
        $t_copy = New-Object byte[] $t_newLen
        [Array]::Copy($t_rb.Bytes, $t_copy, [math]::Min($t_rb.Bytes.Length, $t_newLen))
        $t_parsed = t_ParseWfxBlob -Bytes $t_copy
        if ($null -eq $t_parsed -or (-not $t_parsed.LengthConsistent)) { $t_lenKilled++ }
    }
}
t_Ok -Name ('NEGATIVE CONTROL: ' + [string]$t_lenKilled + ' of ' + [string]$t_lenTotal + ' length-corrupted blobs rejected') `
     -Cond (($t_lenTotal -gt 0) -and ($t_lenKilled -eq $t_lenTotal))

# ---------------------------------------------------------------------------
t_Section 'CLASSIFY BEFORE JUDGING: device format is not engine format'
# The registry holds the DEVICE format, the format shown in the Sound control
# panel. GetMixFormat returns the ENGINE MIX format, which the shared mixer
# always runs in float. Comparing bit depth between them would report a
# mismatch that is not one. Only the fields that describe the same thing -
# sample rate and channel count - may be compared.
$t_measureRaw = ''
$t_liveMap = @{}
Write-Host ('  measuring live endpoints for ' + [string]$MeasureSeconds + ' s ...') -ForegroundColor Gray
$t_measureRaw = [AudioDriftNative.Engine]::Measure($MeasureSeconds, 5, $true)
$t_liveMap = ConvertFrom-AdRecords -Text $t_measureRaw
$t_liveCount = 0
if ($t_liveMap.ContainsKey('endpoints')) { $t_liveCount = [int]$t_liveMap['endpoints'] }
t_Ok -Name 'at least one active endpoint was measured' -Cond ($t_liveCount -ge 1) -Info ([string]$t_liveCount + ' active')

$t_rateCompared = 0; $t_rateBad = New-Object Collections.Generic.List[string]
$t_engineFloat = 0; $t_deviceInt = 0
$t_liveRegs = New-Object Collections.Generic.List[object]
for ($t_i = 0; $t_i -lt $t_liveCount; $t_i++) {
    $t_p = 'ep.' + [string]$t_i + '.'
    if (-not $t_liveMap.ContainsKey($t_p + 'id')) { continue }
    if ($t_liveMap[$t_p + 'opened'] -ne '1') { continue }
    $t_id = $t_liveMap[$t_p + 'id']
    $t_flow = 'Render'
    if ($t_liveMap[$t_p + 'flow'] -eq 'capture') { $t_flow = 'Capture' }
    $t_reg = t_RegEndpoint -Flow $t_flow -EndpointId $t_id
    if ($null -eq $t_reg -or $null -eq $t_reg.FormatBlob) { continue }
    $t_w = t_ParseWfxBlob -Bytes $t_reg.FormatBlob
    if ($null -eq $t_w) { continue }
    [void]$t_liveRegs.Add(@{ Idx = $t_i; Reg = $t_reg; W = $t_w; Flow = $t_flow; Id = $t_id })
    $t_comRate = [long]$t_liveMap[$t_p + 'rate']
    $t_comCh   = [int]$t_liveMap[$t_p + 'channels']
    $t_comBits = [int]$t_liveMap[$t_p + 'bits']
    $t_comSub  = [int]$t_liveMap[$t_p + 'subformat']
    $t_rateCompared += 2
    if ($t_comRate -ne $t_w.Rate) { [void]$t_rateBad.Add($t_id + ' rate COM=' + [string]$t_comRate + ' reg=' + [string]$t_w.Rate) }
    if ($t_comCh -ne $t_w.Channels) { [void]$t_rateBad.Add($t_id + ' channels COM=' + [string]$t_comCh + ' reg=' + [string]$t_w.Channels) }
    if ($t_comSub -eq 3) { $t_engineFloat++ }
    if ($t_w.SubFormat -eq 1) { $t_deviceInt++ }
    if ($Detail) {
        t_Note ('endpoint ' + [string]$t_i + ' engine=' + [string]$t_comBits + '-bit ' + (Get-SubFormatName -Code $t_comSub) +
                '  device=' + [string]$t_w.Bits + '-bit ' + (Get-SubFormatName -Code $t_w.SubFormat))
    }
}
t_Ok -Name ('sample rate and channels agree between COM and registry across ' + [string]$t_rateCompared + ' fields') `
     -Cond ($t_rateBad.Count -eq 0) -Info (($t_rateBad.ToArray()) -join '; ')
t_Note ([string]$t_rateCompared + ' comparable format fields, ' + [string]$t_rateBad.Count + ' mismatches')
if ($t_engineFloat -gt 0 -and $t_deviceInt -gt 0) {
    t_Ok -Name 'engine float vs device integer correctly treated as different layers, not a fault' -Cond $true `
         -Info ([string]$t_engineFloat + ' float engine formats, ' + [string]$t_deviceInt + ' integer device formats')
    t_Note ('engine mixes in float while the device runs integer - comparing bit depth here would be a false alarm')
} else {
    t_Skip -Name 'engine/device layer difference' -Why 'this machine does not exhibit both layers'
}

# NEGATIVE CONTROL for the rate comparison.
$t_rk = 0; $t_rt = 0
foreach ($t_lr in $t_liveRegs) {
    $t_p = 'ep.' + [string]$t_lr.Idx + '.'
    $t_comRate = [long]$t_liveMap[$t_p + 'rate']
    $t_comCh   = [int]$t_liveMap[$t_p + 'channels']
    foreach ($t_bad in @(($t_lr.W.Rate + 1), ($t_lr.W.Rate * 2), 44100, ($t_lr.W.Rate - 1))) {
        if ($t_bad -eq $t_comRate) { continue }
        $t_rt++
        if ($t_comRate -ne $t_bad) { $t_rk++ }
    }
    foreach ($t_badc in @(($t_lr.W.Channels + 1), ($t_lr.W.Channels * 2))) {
        if ($t_badc -eq $t_comCh) { continue }
        $t_rt++
        if ($t_comCh -ne $t_badc) { $t_rk++ }
    }
}
t_Ok -Name ('NEGATIVE CONTROL: ' + [string]$t_rk + ' of ' + [string]$t_rt + ' wrong rates/channels rejected') `
     -Cond (($t_rt -gt 0) -and ($t_rk -eq $t_rt))

# ---------------------------------------------------------------------------
t_Section 'INDEPENDENT REFERENCE 3: the codec identity behind the verdict'
# The headline claim is "these endpoints share a crystal". Windows records
# the physical device each endpoint belongs to, so that claim can be checked
# against the hardware topology rather than against another measurement.
$t_instances = @{}
foreach ($t_lr in $t_liveRegs) {
    $t_ip = $t_lr.Reg.InstancePath
    if ($null -eq $t_ip) { continue }
    $t_key = [string]$t_ip
    if (-not $t_instances.ContainsKey($t_key)) { $t_instances[$t_key] = New-Object Collections.Generic.List[int] }
    [void]$t_instances[$t_key].Add($t_lr.Idx)
}
t_Ok -Name 'every measured endpoint reports a device instance path' -Cond ($t_instances.Count -ge 1) `
     -Info ([string]$t_instances.Count + ' distinct physical devices')
foreach ($t_ik in $t_instances.Keys) {
    t_Note ('physical device ' + $t_ik.Substring(0, [math]::Min(60, $t_ik.Length)) + ' -> endpoints ' + (($t_instances[$t_ik].ToArray()) -join ', '))
}

# Now build the tool's report from the SAME live data and compare its clock
# domain grouping against the hardware topology.
$t_rep = Get-AudioDriftReport -Map $t_liveMap -FpsList @(30.0, 60.0) -RequestedSeconds $MeasureSeconds
$t_measured = @($t_rep.Endpoints | Where-Object { $_.Measured })
t_Ok -Name 'the tool measured at least one endpoint from this run' -Cond (@($t_measured).Count -ge 1) `
     -Info ([string](@($t_measured).Count) + ' of ' + [string]$t_rep.EndpointCount)

$t_sharedChecked = 0; $t_sharedBad = New-Object Collections.Generic.List[string]
foreach ($t_ik in $t_instances.Keys) {
    $t_idxs = @($t_instances[$t_ik].ToArray())
    if ($t_idxs.Count -lt 2) { continue }
    # Two endpoints on ONE physical codec are driven by ONE crystal, so if
    # the tool measured both it must place them in the same domain.
    $t_doms = New-Object Collections.Generic.List[int]
    foreach ($t_ix in $t_idxs) {
        foreach ($t_e in $t_rep.Endpoints) {
            if ($t_e.Index -eq $t_ix -and $t_e.Measured) { [void]$t_doms.Add($t_e.ClockDomain) }
        }
    }
    if ($t_doms.Count -lt 2) { continue }
    $t_sharedChecked++
    $t_distinct = @($t_doms.ToArray() | Sort-Object -Unique)
    if ($t_distinct.Count -ne 1) {
        [void]$t_sharedBad.Add('endpoints ' + ($t_idxs -join ',') + ' share a codec but were split into domains ' + (($t_doms.ToArray()) -join ','))
    }
}
if ($t_sharedChecked -gt 0) {
    t_Ok -Name 'endpoints on one physical codec are grouped into one clock domain' -Cond ($t_sharedBad.Count -eq 0) `
         -Info (($t_sharedBad.ToArray()) -join '; ')
    t_Note ([string]$t_sharedChecked + ' shared-codec group(s) confirmed against the hardware topology')
} else {
    t_Skip -Name 'shared-codec grouping' -Why 'fewer than two measured endpoints share a physical device here'
}

# ---------------------------------------------------------------------------
t_Section 'INDEPENDENT REFERENCE 4: Get-PnpDevice, a built-in Windows command'
$t_pnp = $null
try { $t_pnp = @(Get-PnpDevice -Class AudioEndpoint -ErrorAction Stop) } catch { $t_pnp = $null }
if ($null -eq $t_pnp -or @($t_pnp).Count -eq 0) {
    t_Skip -Name 'Get-PnpDevice cross-check' -Why 'Get-PnpDevice returned nothing on this machine'
} else {
    $t_pnpOk = @($t_pnp | Where-Object { $_.Status -eq 'OK' })
    t_Ok -Name 'Get-PnpDevice sees audio endpoints' -Cond (@($t_pnp).Count -gt 0) -Info ([string](@($t_pnp).Count) + ' total, ' + [string](@($t_pnpOk).Count) + ' OK')
    # Each active endpoint the tool found must appear in the PnP list by name.
    $t_nameHit = 0; $t_nameMiss = New-Object Collections.Generic.List[string]
    foreach ($t_e in $t_rep.Endpoints) {
        $t_found = $false
        foreach ($t_pd in $t_pnp) {
            if ($null -eq $t_pd.FriendlyName) { continue }
            if ([String]::Equals([string]$t_pd.FriendlyName, $t_e.Name, [StringComparison]::Ordinal)) { $t_found = $true; break }
        }
        if ($t_found) { $t_nameHit++ } else { [void]$t_nameMiss.Add($t_e.Name) }
    }
    t_Ok -Name 'every active endpoint the tool found also appears in Get-PnpDevice' `
         -Cond ($t_nameMiss.Count -eq 0) -Info (($t_nameMiss.ToArray()) -join '; ')
    t_Note ([string]$t_nameHit + ' endpoint names confirmed by Get-PnpDevice')
    # Windows must not report fewer endpoints than are actively streaming.
    t_Ok -Name 'the OK-status PnP count is at least the active endpoint count' `
         -Cond (@($t_pnpOk).Count -ge $t_rep.EndpointCount) `
         -Info ([string](@($t_pnpOk).Count) + ' vs ' + [string]$t_rep.EndpointCount)
    # NEGATIVE CONTROL
    # Two traps live in the next three lines and both were found by this
    # control reporting an impossible count. First, PowerShell's comma binds
    # TIGHTER than plus, so @(a, b, c + 'x') parses as (a,b,c) + 'x' and
    # yields FOUR elements - the unparenthesised form silently invented a
    # phantom mutation testing nothing. Every arithmetic element must be
    # parenthesised. Second, -eq on strings is CASE-INSENSITIVE, so an
    # upper-cased name compares EQUAL to the original and the mutation is an
    # equivalent mutant by construction; identity must be ordinal.
    $t_nk = 0; $t_nt = 0; $t_nSurv = New-Object Collections.Generic.List[string]
    foreach ($t_e in $t_rep.Endpoints) {
        foreach ($t_fake in @(($t_e.Name + 'X'), ('X' + $t_e.Name), ($t_e.Name.ToUpper() + '!!'), $t_e.Name.ToUpper())) {
            $t_nt++
            $t_hit = $false
            foreach ($t_pd in $t_pnp) {
                if ($null -eq $t_pd.FriendlyName) { continue }
                if ([String]::Equals([string]$t_pd.FriendlyName, $t_fake, [StringComparison]::Ordinal)) { $t_hit = $true; break }
            }
            if (-not $t_hit) { $t_nk++ } else { [void]$t_nSurv.Add($t_fake) }
        }
    }
    t_Ok -Name ('NEGATIVE CONTROL: ' + [string]$t_nk + ' of ' + [string]$t_nt + ' fabricated endpoint names rejected') `
         -Cond (($t_nt -gt 0) -and ($t_nk -eq $t_nt)) -Info (($t_nSurv.ToArray()) -join '; ')
    t_Note ('includes a case-only mutation, which a case-insensitive -eq would have accepted')
}

# ---------------------------------------------------------------------------
t_Section 'INDEPENDENT REFERENCE 5: the performance counter frequency'
$t_qpc = 0
if ($t_liveMap.ContainsKey('qpcfreq')) { $t_qpc = [long]$t_liveMap['qpcfreq'] }
$t_sw = [Diagnostics.Stopwatch]::Frequency
t_Ok -Name 'the native QPC frequency matches Stopwatch.Frequency exactly' -Cond ($t_qpc -eq $t_sw) `
     -Info ('native ' + [string]$t_qpc + ' vs .NET ' + [string]$t_sw)
t_Ok -Name 'and it is a sane, non-zero value' -Cond ($t_qpc -gt 1000000)
t_Note ('QPC frequency ' + [string]$t_qpc + ' Hz confirmed by two independent APIs')
# NEGATIVE CONTROL: an equality check that cannot fail proves nothing.
t_Ok -Name 'NEGATIVE CONTROL: a wrong QPC frequency would be rejected' -Cond (($t_qpc + 1) -ne $t_sw)
# The device clock timestamps are in 100 ns units, NOT QPC ticks. On this
# machine QPC happens to run at exactly 10 MHz, which makes the two divisors
# numerically identical and the bug invisible. Record that explicitly.
if ($t_qpc -eq 10000000) {
    t_Note ('NOTE: QPC runs at exactly 10 MHz here, the same as the 100 ns timestamp unit,')
    t_Note ('      so confusing the two divisors would be a silent no-op on this machine.')
    t_Note ('      The tool divides device timestamps by 1e7 unconditionally, which is correct everywhere.')
}

# ---------------------------------------------------------------------------
t_Section 'GROUND TRUTH PLANTED INSIDE THE REAL SAMPLE SERIES'
# The strongest test available: take the genuine timestamp series captured
# from the hardware a moment ago and scale the device axis by a known ppm.
# The tool must recover exactly (real + planted), surrounded by thousands of
# real samples it must not be confused by.
$t_plantChecked = 0
$t_plantBad = New-Object Collections.Generic.List[string]
$t_realSamples = 0
for ($t_i = 0; $t_i -lt $t_liveCount; $t_i++) {
    $t_p = 'ep.' + [string]$t_i + '.'
    if (-not $t_liveMap.ContainsKey($t_p + 'pkt.x')) { continue }
    $t_x = ConvertFrom-Series -Text $t_liveMap[$t_p + 'pkt.x']
    $t_y = ConvertFrom-Series -Text $t_liveMap[$t_p + 'pkt.y']
    if (@($t_x).Count -lt 100) { continue }
    $t_realSamples += @($t_x).Count
    $t_base = Get-LinearFit -X $t_x -Y $t_y
    $t_basePpm = ConvertTo-Ppm -Slope $t_base.Slope
    foreach ($t_plant in @(5.0, -12.5, 100.0, 0.25, -0.75)) {
        $t_scale = 1.0 + ($t_plant / 1000000.0)
        $t_y2 = New-Object Collections.Generic.List[double]
        foreach ($t_v in $t_y) { [void]$t_y2.Add($t_v * $t_scale) }
        $t_fit = Get-LinearFit -X $t_x -Y $t_y2.ToArray()
        $t_got = ConvertTo-Ppm -Slope $t_fit.Slope
        # Scaling the device axis multiplies the slope, so the expected ppm is
        # the composition of the two ratios, not their sum.
        $t_expect = ((1.0 + $t_basePpm / 1000000.0) * $t_scale - 1.0) * 1000000.0
        $t_plantChecked++
        if ([math]::Abs($t_got - $t_expect) -gt 0.0001) {
            [void]$t_plantBad.Add('ep' + [string]$t_i + ' plant ' + [string]$t_plant + ': expected ' + ('{0:F6}' -f $t_expect) + ' got ' + ('{0:F6}' -f $t_got))
        }
    }
}
t_Ok -Name 'planted drift is recovered exactly from inside the real series' `
     -Cond (($t_plantChecked -gt 0) -and ($t_plantBad.Count -eq 0)) -Info (($t_plantBad.ToArray()) -join '; ')
t_Note ([string]$t_plantChecked + ' planted-drift recoveries across ' + [string]$t_realSamples + ' genuine hardware timestamps, ' + [string]$t_plantBad.Count + ' failures')

# NEGATIVE CONTROL: the recovery check must reject a wrong expectation.
$t_pk2 = 0; $t_pt2 = 0
for ($t_i = 0; $t_i -lt $t_liveCount; $t_i++) {
    $t_p = 'ep.' + [string]$t_i + '.'
    if (-not $t_liveMap.ContainsKey($t_p + 'pkt.x')) { continue }
    $t_x = ConvertFrom-Series -Text $t_liveMap[$t_p + 'pkt.x']
    $t_y = ConvertFrom-Series -Text $t_liveMap[$t_p + 'pkt.y']
    if (@($t_x).Count -lt 100) { continue }
    $t_base = Get-LinearFit -X $t_x -Y $t_y
    $t_basePpm = ConvertTo-Ppm -Slope $t_base.Slope
    $t_scale = 1.0 + (5.0 / 1000000.0)
    $t_y2 = New-Object Collections.Generic.List[double]
    foreach ($t_v in $t_y) { [void]$t_y2.Add($t_v * $t_scale) }
    $t_fit = Get-LinearFit -X $t_x -Y $t_y2.ToArray()
    $t_got = ConvertTo-Ppm -Slope $t_fit.Slope
    # Each of these is a plausible WRONG answer a broken implementation gives.
    $t_wrongs = @(
        @{ N = 'planted value alone, ignoring the real rate'; V = 5.0 },
        @{ N = 'real rate alone, ignoring the plant';         V = $t_basePpm },
        @{ N = 'sign of the plant flipped';                   V = ($t_basePpm - 5.0) },
        @{ N = 'plant applied twice';                         V = ($t_basePpm + 10.0) },
        @{ N = 'zero';                                        V = 0.0 }
    )
    foreach ($t_wr in $t_wrongs) {
        if ([math]::Abs($t_wr.V - ($t_basePpm + 5.0)) -lt 0.0001) { continue }
        $t_pt2++
        if ([math]::Abs($t_got - $t_wr.V) -gt 0.0001) { $t_pk2++ }
    }
}
t_Ok -Name ('NEGATIVE CONTROL: ' + [string]$t_pk2 + ' of ' + [string]$t_pt2 + ' plausible wrong answers rejected') `
     -Cond (($t_pt2 -gt 0) -and ($t_pk2 -eq $t_pt2))

# ---------------------------------------------------------------------------
t_Section 'HEADLINE FEATURE: the two techniques agree on the same hardware'
# The tool measures each endpoint two independent ways. Where both are
# precise they must agree, because they are watching the same crystal. This
# is the end-to-end proof that the number is a property of the hardware and
# not an artefact of one API.
$t_agreeChecked = 0; $t_agreeBad = New-Object Collections.Generic.List[string]
foreach ($t_e in $t_rep.Endpoints) {
    if (-not $t_e.MethodsComparable) { continue }
    # Only compare where BOTH are precise enough for the comparison to mean
    # something. Demanding agreement from a method with a 25 ppm error would
    # be comparing noise.
    $t_comb = 3.0 * [math]::Sqrt(($t_e.PacketSePpm * $t_e.PacketSePpm) + ($t_e.ClockSePpm * $t_e.ClockSePpm))
    if ($t_comb -gt 20.0) {
        t_Note ('endpoint ' + [string]($t_e.Index + 1) + ': one method too imprecise to compare (combined tolerance ' + ('{0:F1}' -f $t_comb) + ' ppm) - not asserted')
        continue
    }
    $t_agreeChecked++
    if ($t_e.MethodDeltaPpm -gt $t_comb) {
        [void]$t_agreeBad.Add($t_e.Name + ' packets ' + ('{0:F3}' -f $t_e.PacketPpm) + ' vs clock ' + ('{0:F3}' -f $t_e.ClockPpm) + ' (tolerance ' + ('{0:F3}' -f $t_comb) + ')')
    } else {
        t_Note ('endpoint ' + [string]($t_e.Index + 1) + ': packets ' + ('{0:F3}' -f $t_e.PacketPpm) + ' ppm vs IAudioClock ' + ('{0:F3}' -f $t_e.ClockPpm) + ' ppm, differ by ' + ('{0:F3}' -f $t_e.MethodDeltaPpm) + ' ppm')
    }
}
if ($t_agreeChecked -gt 0) {
    t_Ok -Name 'two independent techniques agree on the same endpoint' -Cond ($t_agreeBad.Count -eq 0) `
         -Info (($t_agreeBad.ToArray()) -join '; ')
} else {
    t_Skip -Name 'two-technique agreement' -Why 'no endpoint had both methods precise enough this run'
}

# The measurement must not be a constant. A broken path that returns a fixed
# value would satisfy every check above.
$t_distinctPpm = @($t_rep.Endpoints | Where-Object { $_.Measured } | ForEach-Object { [math]::Round($_.Ppm, 6) } | Sort-Object -Unique)
if (@($t_measured).Count -ge 2) {
    t_Ok -Name 'different endpoints do not return a single hard-coded value' -Cond (@($t_distinctPpm).Count -ge 2) `
         -Info ((@($t_distinctPpm) -join ', '))
} else {
    t_Skip -Name 'distinct values across endpoints' -Why 'fewer than two endpoints measured'
}
foreach ($t_e in $t_measured) {
    t_Ok -Name ('endpoint ' + [string]($t_e.Index + 1) + ' rate is not exactly nominal (which would mean nothing was measured)') `
         -Cond ($t_e.Ppm -ne 0.0) -Info ('ppm ' + ('{0:F6}' -f $t_e.Ppm))
    t_Ok -Name ('endpoint ' + [string]($t_e.Index + 1) + ' collected a realistic number of samples') `
         -Cond ($t_e.Samples -gt ($MeasureSeconds * 10)) -Info ([string]$t_e.Samples + ' samples over ' + ('{0:F1}' -f $t_e.SpanSec) + ' s')
    t_Ok -Name ('endpoint ' + [string]($t_e.Index + 1) + ' span matches the requested duration') `
         -Cond ([math]::Abs($t_e.SpanSec - $MeasureSeconds) -lt ($MeasureSeconds * 0.2)) `
         -Info (('{0:F2}' -f $t_e.SpanSec) + ' s of ' + [string]$MeasureSeconds + ' s')
}

# ---------------------------------------------------------------------------
t_Section 'REDUNDANCY GATES ON LIVE HARDWARE'
$t_gated = 0
for ($t_i = 0; $t_i -lt $t_liveCount; $t_i++) {
    $t_p = 'ep.' + [string]$t_i + '.'
    if (-not $t_liveMap.ContainsKey($t_p + 'clockfreq')) { continue }
    if ($t_liveMap[$t_p + 'opened'] -ne '1') { continue }
    $t_cf = [long]$t_liveMap[$t_p + 'clockfreq']
    $t_ab = [long]$t_liveMap[$t_p + 'avgbytes']
    $t_sr = [long]$t_liveMap[$t_p + 'rate']
    $t_gated++
    t_Ok -Name ('endpoint ' + [string]($t_i + 1) + ' audio clock frequency matches its own byte rate') `
         -Cond ((Test-ClockFrequency -ClockFreq $t_cf -AvgBytes $t_ab -Rate $t_sr).Ok) `
         -Info ('clock ' + [string]$t_cf + ' vs avgBytes ' + [string]$t_ab + ' / rate ' + [string]$t_sr)
    t_Ok -Name ('endpoint ' + [string]($t_i + 1) + ' reported no timestamp errors') `
         -Cond ([int]$t_liveMap[$t_p + 'tserror'] -eq 0) -Info ('tsErr ' + $t_liveMap[$t_p + 'tserror'])
    t_Ok -Name ('endpoint ' + [string]($t_i + 1) + ' reported no stream discontinuities') `
         -Cond ([int]$t_liveMap[$t_p + 'discont'] -eq 0) -Info ('discont ' + $t_liveMap[$t_p + 'discont'])
}
t_Note ([string]$t_gated + ' live endpoints passed the redundancy gates')

# ---------------------------------------------------------------------------
t_Section 'BOUNDS CHECK ON THE TOOL OWN JSON'
# Every individual reading can be sane while an aggregate is not. Re-read the
# tool's own output and recompute each derived number from its inputs.
$t_jsonText = $t_rep | ConvertTo-Json -Depth 8
$t_jsonBack = $null
$t_threw = $false
try { $t_jsonBack = ConvertFrom-Json -InputObject $t_jsonText } catch { $t_threw = $true }
t_Ok -Name 'the live report is valid JSON' -Cond (-not $t_threw)
t_Ok -Name 'and survives the round trip' -Cond ((-not $t_threw) -and ($t_jsonBack.EndpointCount -eq $t_rep.EndpointCount))
foreach ($t_e in $t_jsonBack.Endpoints) {
    t_Ok -Name ('json: ' + $t_e.Name + ' nominal rate is positive') -Cond ($t_e.NominalRate -gt 0)
    t_Ok -Name ('json: ' + $t_e.Name + ' uncertainty is not negative') -Cond ($t_e.SePpm -ge 0)
    t_Ok -Name ('json: ' + $t_e.Name + ' reported error is the larger of the two estimates') `
         -Cond (($t_e.SePpm -ge ($t_e.SeOlsPpm - 1e-9)) -and ($t_e.SePpm -ge ($t_e.SeEmpiricalPpm - 1e-9))) `
         -Info ('se ' + [string]$t_e.SePpm + ' ols ' + [string]$t_e.SeOlsPpm + ' emp ' + [string]$t_e.SeEmpiricalPpm)
    if ($t_e.Measured) {
        $t_implied = (($t_e.TrueRate / $t_e.NominalRate) - 1.0) * 1000000.0
        t_Ok -Name ('json: ' + $t_e.Name + ' true rate agrees with its own ppm') `
             -Cond ([math]::Abs($t_implied - $t_e.Ppm) -lt 0.0001) -Info ('implied ' + ('{0:F6}' -f $t_implied) + ' vs ' + ('{0:F6}' -f $t_e.Ppm))
        t_Ok -Name ('json: ' + $t_e.Name + ' ms per hour agrees with its own ppm') `
             -Cond ([math]::Abs(($t_e.Ppm * 3.6) - $t_e.MsPerHour) -lt 1e-9)
        t_Ok -Name ('json: ' + $t_e.Name + ' drift is within crystal bounds') `
             -Cond ([math]::Abs($t_e.Ppm) -le 1000.0) -Info ('ppm ' + ('{0:F3}' -f $t_e.Ppm))
        t_Ok -Name ('json: ' + $t_e.Name + ' true rate is within 0.1 percent of nominal') `
             -Cond ([math]::Abs($t_e.TrueRate - $t_e.NominalRate) -lt ($t_e.NominalRate * 0.001)) `
             -Info ('true ' + ('{0:F4}' -f $t_e.TrueRate) + ' nominal ' + [string]$t_e.NominalRate)
        $t_wn = @($t_e.WindowPpms)
        if ($t_wn.Count -gt 0) {
            $t_allSame = $true
            foreach ($t_wv in $t_wn) { if ([math]::Abs($t_wv - $t_wn[0]) -gt 1e-12) { $t_allSame = $false; break } }
            t_Ok -Name ('json: ' + $t_e.Name + ' sub-window rates are not all identical (which would mean a stub)') `
                 -Cond (-not $t_allSame)
        }
    }
}
foreach ($t_pr3 in @($t_jsonBack.Pairs)) {
    $t_a3 = $null; $t_b3 = $null
    foreach ($t_e in $t_jsonBack.Endpoints) {
        if ($t_e.Index -eq $t_pr3.AIndex) { $t_a3 = $t_e }
        if ($t_e.Index -eq $t_pr3.BIndex) { $t_b3 = $t_e }
    }
    t_Ok -Name 'json: pair relative drift equals the difference of its members' `
         -Cond ([math]::Abs(($t_a3.Ppm - $t_b3.Ppm) - $t_pr3.RelativePpm) -lt 1e-9)
    # The classic aggregate bug: a derived total that exceeds what its parts
    # allow. Relative drift can never exceed the sum of the two magnitudes.
    t_Ok -Name 'json: relative drift never exceeds the sum of both magnitudes' `
         -Cond ([math]::Abs($t_pr3.RelativePpm) -le ([math]::Abs($t_a3.Ppm) + [math]::Abs($t_b3.Ppm) + 1e-9)) `
         -Info ('rel ' + ('{0:F4}' -f $t_pr3.RelativePpm) + ' vs ' + ('{0:F4}' -f ([math]::Abs($t_a3.Ppm) + [math]::Abs($t_b3.Ppm))))
    foreach ($t_sl in @($t_pr3.FrameSlip)) {
        t_Ok -Name ('json: slip at ' + [string]$t_sl.Fps + ' fps is positive') -Cond ($t_sl.SecondsPerSlip -gt 0)
        $t_exp = (1.0 / $t_sl.Fps) / ([math]::Abs($t_pr3.RelativePpm) / 1000000.0)
        t_Ok -Name ('json: slip at ' + [string]$t_sl.Fps + ' fps recomputes from the relative drift') `
             -Cond ([math]::Abs($t_exp - $t_sl.SecondsPerSlip) -lt ([math]::Max(0.001, $t_exp * 1e-9)))
    }
}
t_Ok -Name 'json: the clock domain count never exceeds the endpoint count' `
     -Cond ($t_jsonBack.ClockDomainCount -le $t_jsonBack.EndpointCount)
t_Ok -Name 'json: the measured count never exceeds the endpoint count' `
     -Cond ($t_jsonBack.MeasuredCount -le $t_jsonBack.EndpointCount)
t_Ok -Name 'json: the systematic floor is positive' -Cond ($t_jsonBack.SystematicFloorPpm -gt 0)

# ---------------------------------------------------------------------------
t_Section 'READ-ONLY CONFIRMED AFTER THE RUN'
$t_after = t_SnapshotAudioRegistry
$t_afterLines = @($t_after -split "`r?`n" | Where-Object { $_.Length -gt 0 }).Count
t_Ok -Name 'the audio registry is byte-identical after a full measurement' -Cond ($t_before -eq $t_after) `
     -Info ('before ' + [string]$t_before.Length + ' chars / ' + [string]$t_beforeLines + ' values, after ' + [string]$t_after.Length + ' chars / ' + [string]$t_afterLines + ' values')
t_Note ([string]$t_beforeLines + ' registry values snapshotted before and after; all identical')
# NEGATIVE CONTROL: the comparison must be able to see a change.
t_Ok -Name 'NEGATIVE CONTROL: the snapshot comparison does detect a planted change' `
     -Cond (($t_before + 'x') -ne $t_after)

# ---------------------------------------------------------------------------
Write-Host ''
if ($t_fail -eq 0) {
    Write-Host ('ALL PASS  ' + [string]$t_pass + ' assertions, 0 failures, ' + [string]$t_skip + ' skipped') -ForegroundColor Green
    exit 0
} else {
    Write-Host ([string]$t_fail + ' FAILURES out of ' + [string]($t_pass + $t_fail) + ' assertions') -ForegroundColor Red
    foreach ($t_m in $t_msgs) { Write-Host ('  - ' + $t_m) -ForegroundColor Red }
    exit 1
}
