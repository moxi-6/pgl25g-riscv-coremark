param(
    [Parameter(Mandatory=$true)][guid]$InterfaceGuid,
    [ValidatePattern('^[0-9A-Fa-f]{12}$')][string]$MacAddress = '584120290F2C',
    [Parameter(Mandatory=$true)][string]$LogPath
)
$ErrorActionPreference = 'Stop'
try {
    $PhysicalBefore = @(Get-NetAdapter -Physical | Select-Object InterfaceGuid,MacAddress)
    $Tap = @(Get-NetAdapter -IncludeHidden | Where-Object { [guid]$_.InterfaceGuid -eq $InterfaceGuid })
    if ($Tap.Count -ne 1 -or $Tap[0].InterfaceDescription -ne 'TAP-Windows Adapter V9') {
        throw 'Requested GUID must identify exactly one TAP-Windows Adapter V9.'
    }
    $Tap = $Tap[0]
    $PreviousMac = $Tap.MacAddress
    Set-NetAdapterAdvancedProperty -Name $Tap.Name -RegistryKeyword 'MAC' -RegistryValue $MacAddress.ToUpperInvariant() -NoRestart
    Restart-NetAdapter -Name $Tap.Name -Confirm:$false
    $Matched = $false
    for ($Attempt = 0; $Attempt -lt 15; $Attempt++) {
        $Current = Get-NetAdapter -IncludeHidden | Where-Object { [guid]$_.InterfaceGuid -eq $InterfaceGuid }
        if ($Current -and ($Current.MacAddress -replace '[:-]', '') -eq $MacAddress) { $Matched = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $Matched) { throw 'TAP MAC has not taken effect after adapter restart.' }
    foreach ($Before in $PhysicalBefore) {
        $After = Get-NetAdapter -Physical | Where-Object InterfaceGuid -EQ $Before.InterfaceGuid
        if (-not $After -or $After.MacAddress -ne $Before.MacAddress) { throw 'A physical adapter changed unexpectedly.' }
    }
    [ordered]@{success=$true;interface_guid=$InterfaceGuid.ToString();adapter=$Current.InterfaceDescription;
        previous_mac=$PreviousMac;configured_mac=$Current.MacAddress;physical_adapters_unchanged=$true} |
        ConvertTo-Json | Set-Content -LiteralPath $LogPath -Encoding utf8
    exit 0
} catch {
    [ordered]@{success=$false;error=$_.Exception.Message;interface_guid=$InterfaceGuid.ToString()} |
        ConvertTo-Json | Set-Content -LiteralPath $LogPath -Encoding utf8
    exit 1
}
