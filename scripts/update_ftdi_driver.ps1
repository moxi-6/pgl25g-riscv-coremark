# Run elevated. Install only the FTDI update identified by the read-only audit.
$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$LogPath = Join-Path (Split-Path -Parent $ProjectRoot) '交接记录/2026-10-19_FTDI驱动更新.log'
Start-Transcript -Path $LogPath -Force
try {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]$Identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator is required for driver installation.'
    }
    $Session = New-Object -ComObject Microsoft.Update.Session
    $Searcher = $Session.CreateUpdateSearcher()
    $Found = $Searcher.Search("IsInstalled=0 and Type='Driver'")
    $Selected = New-Object -ComObject Microsoft.Update.UpdateColl
    for ($Index = 0; $Index -lt $Found.Updates.Count; $Index++) {
        $Update = $Found.Updates.Item($Index)
        if ($Update.Identity.UpdateID -eq '02a4cee3-3f22-473b-9bbf-3aa2262842bc' -and
            $Update.Title -eq 'FTDI - USB - 2.12.36.20' -and
            $Update.DriverHardwareID -in @('usb\vid_0403&pid_6010&mi_00','usb\vid_0403&pid_6010&mi_01')) {
            Write-Output "Selected: $($Update.Title) / $($Update.DriverHardwareID)"
            if (-not $Update.EulaAccepted) { $Update.AcceptEula() }
            [void]$Selected.Add($Update)
        }
    }
    if ($Selected.Count -ne 1) { throw 'Expected exactly one audited FTDI driver update.' }
    $Downloader = $Session.CreateUpdateDownloader()
    $Downloader.Updates = $Selected
    $DownloadResult = $Downloader.Download()
    Write-Output "Download result: $($DownloadResult.ResultCode)"
    if ($DownloadResult.ResultCode -ne 2) { throw 'Driver download did not succeed.' }
    $Installer = $Session.CreateUpdateInstaller()
    $Installer.Updates = $Selected
    $Result = $Installer.Install()
    Write-Output "Install result: $($Result.ResultCode); Reboot required: $($Result.RebootRequired)"
    if ($Result.ResultCode -ne 2) { throw 'Driver installation did not succeed.' }
    Get-CimInstance Win32_PnPEntity | Where-Object PNPDeviceID -Match 'VID_0403&PID_6010' |
        Select-Object Name,ConfigManagerErrorCode,Service,PNPDeviceID | Format-List
} catch {
    Write-Output $_
    exit 1
} finally {
    Stop-Transcript
}
