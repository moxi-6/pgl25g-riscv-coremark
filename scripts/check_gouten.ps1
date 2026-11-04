<#
.SYNOPSIS
Read-only report of the live PGL25G configuration state, with the gouten bit called out.

.DESCRIPTION
Downloads nothing and writes nothing. Connects to the local Pango JTAG server,
scans the chain, and reads STATUSR through two independent channels: the
high-level device property (mode 3) and the raw register interface at address 9.
It then decodes the user-mode bits and says plainly whether the board's IO is
driven or parked in high-Z.

Why this exists: a successful CLI download leaves gouten (STATUSR bit 17) at 0,
which parks every IO pin in high-Z and makes the board emit nothing on UART. That
is invisible to every other check in this repository -- DONE is 1, readback verify
passes, and the vendor tool prints "successfully". This script makes the silent
failure visible.

.PARAMETER PdsRoot
Pango PDS installation root.

.PARAMETER JtagFrequency
JTAG clock to use. Keep at 1Mhz; 15Mhz reports false success with DONE=0.

.PARAMETER WorkRoot
ASCII-only working directory for the vendor tool. The tool rejects non-ASCII paths
in both -work_dir and the process working directory.

.PARAMETER Json
Emit machine-readable JSON instead of human-readable text.

.EXAMPLE
& .\scripts\check_gouten.ps1
#>
param(
    [string]$PdsRoot = 'C:\pango\PDS_2022.2-SP4.2-ads',
    [ValidateSet('1Mhz', '5Mhz', '10Mhz', '15Mhz')][string]$JtagFrequency = '1Mhz',
    [string]$WorkRoot = 'C:\fpga\riscv_l50\gouten_check',
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
if ($WorkRoot -match '[^\x00-\x7f]') { throw 'Work directory must use ASCII characters.' }
New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null

# STATUSR bit map for PGL25G (Logos family), as named by the vendor tool itself.
# Ordered array of bit/name pairs: an [ordered] hashtable with integer keys is not
# reliably enumerable here, so keep the order explicit.
$Bits = @(
    @{ Bit = 12; Name = 'DONE' }
    @{ Bit = 14; Name = 'glogen' }
    @{ Bit = 16; Name = 'vddt_n' }
    @{ Bit = 17; Name = 'gouten' }
    @{ Bit = 18; Name = 'grsn' }
    @{ Bit = 19; Name = 'gwen' }
    @{ Bit = 20; Name = 'pll_lock' }
)

$Tcl = @'
cfg_set_tcl_break -flag true
cfg_connect -ip 127.0.0.1 -port 65420
cfg_set_cable_property -index 0 -freq __FREQ__
cfg_scan_chain
cfg_read_device_property -mode 0 -device_index 0
puts "PROPERTY_STATUS"
cfg_read_device_property -mode 3 -device_index 0
puts "RAW_STATUS"
cfg_read_register -address 9
cfg_disconnect
cfg_close
'@
$Tcl = $Tcl.Replace('__FREQ__', $JtagFrequency)
$TclPath = Join-Path $WorkRoot 'check_gouten.tcl'
[IO.File]::WriteAllText($TclPath, $Tcl, (New-Object Text.UTF8Encoding($false)))

$Saved = [IO.Directory]::GetCurrentDirectory()
try {
    # SetCurrentDirectory (not Push-Location) is required: the vendor tool validates
    # the real process working directory, and Push-Location changes only the
    # PowerShell provider location, leaving the inherited cwd untouched.
    [IO.Directory]::SetCurrentDirectory($WorkRoot)
    $Out = @(& (Join-Path $PdsRoot 'bin/cdt_cfg_shell.exe') -work_dir $WorkRoot -file $TclPath 2>&1)
} finally {
    [IO.Directory]::SetCurrentDirectory($Saved)
}
$Text = $Out -join "`n"

function Get-StatusFrom([string]$Marker, [string]$Pattern) {
    $seg = $Text -split [regex]::Escape($Marker)
    if ($seg.Count -lt 2) { return $null }
    $m = [regex]::Match($seg[1], $Pattern)
    if (-not $m.Success) { return $null }
    return [Convert]::ToUInt32($m.Groups[1].Value, 16)
}

$PropertyStatus = Get-StatusFrom 'PROPERTY_STATUS' 'Status Register:\s*0x([0-9a-fA-F]+)'
$RawStatus = Get-StatusFrom 'RAW_STATUS' 'The register value is:\s*0x([0-9a-fA-F]+)'
$IdMatch = [regex]::Match($Text, 'The ID value is:\s*(0x[0-9a-fA-F]+)')

$Status = if ($null -ne $PropertyStatus) { $PropertyStatus } else { $RawStatus }
$Agree = if ($null -ne $PropertyStatus -and $null -ne $RawStatus) { $PropertyStatus -eq $RawStatus } else { $null }

$Decoded = [ordered]@{}
if ($null -ne $Status) {
    foreach ($entry in $Bits) {
        $Decoded[$entry.Name] = [bool]((($Status -shr $entry.Bit) -band 1) -ne 0)
    }
}
$Gouten = if ($Decoded.Contains('gouten')) { $Decoded['gouten'] } else { $null }
$Done = if ($Decoded.Contains('DONE')) { $Decoded['DONE'] } else { $null }

$Verdict = if ($null -eq $Status) { 'UNKNOWN' }
elseif (-not $Done) { 'NOT_CONFIGURED' }
elseif ($Gouten) { 'IO_ACTIVE' }
else { 'IO_HIGH_Z' }

$Summary = switch ($Verdict) {
    'IO_ACTIVE' { 'gouten=1: user-mode output is enabled, IO is driven. UART should work.' }
    'IO_HIGH_Z' { 'gouten=0: bitstream is configured but output is NOT enabled; every IO pin is high-Z and UART will be silent. This is the normal state after a CLI download - use the PDS GUI Program button to assert gouten.' }
    'NOT_CONFIGURED' { 'DONE=0: no bitstream is running. Program the device first.' }
    default { 'Could not read STATUSR; check that the Pango JTAG server is reachable.' }
}

if ($Json) {
    [ordered]@{
        device_id = $(if ($IdMatch.Success) { $IdMatch.Groups[1].Value } else { $null })
        status_register = $Status
        property_status = $PropertyStatus
        raw_status = $RawStatus
        status_sources_agree = $Agree
        bits = $Decoded
        verdict = $Verdict
        summary = $Summary
    } | ConvertTo-Json -Depth 4
} else {
    Write-Host 'PGL25G status'
    Write-Host ('  device id      : ' + $(if ($IdMatch.Success) { $IdMatch.Groups[1].Value } else { '(unknown)' }))
    Write-Host ('  STATUSR        : ' + $(if ($null -ne $Status) { '0x{0:x8}' -f $Status } else { '(unreadable)' }))
    $PropText = if ($null -ne $PropertyStatus) { '0x{0:x8}' -f $PropertyStatus } else { 'n/a' }
    $RawText = if ($null -ne $RawStatus) { '0x{0:x8}' -f $RawStatus } else { 'n/a' }
    $AgreeText = if ($null -eq $Agree) { 'n/a' } else { $Agree }
    Write-Host "  status sources : property=$PropText  raw(addr 9)=$RawText  agree=$AgreeText"
    foreach ($entry in $Bits) {
        $name = $entry.Name
        $mark = if ($name -eq 'gouten') { '   <== user-mode output enable' } else { '' }
        Write-Host ('  bit {0,2} {1,-9} = {2}{3}' -f $entry.Bit, $name, ([int]$Decoded[$name]), $mark)
    }
    Write-Host ''
    Write-Host ('  verdict: ' + $Verdict)
    Write-Host ('  ' + $Summary)
}