# Smoke-test for WinGrowl's per-PID suppression gate.
#
# Run this script from TWO separate PowerShell windows. Each invocation
# uses its host powershell.exe's own PID as the GNTP sender, so the two
# windows produce two NOTIFY packets with distinct owning PIDs — the same
# scenario as two Firestorm instances. WinGrowl's TcpPidResolver should
# see two different PIDs and gate suppression per-instance.
#
# Usage (in each PowerShell window):
#     pwsh -NoExit -File .\WinGrowl\scripts\smoke-multi-instance.ps1
# then call Send-GntpNotify "title" "text".
#
# Inspect %LOCALAPPDATA%\WinGrowl\wingrowl.log to see each NOTIFY's
# gate=pid=NNNN line. The two windows must show different PIDs.

function Send-GntpRegister {
    param([string]$AppName = 'PsSmoke')
    $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 23053)
    $stream = $client.GetStream()
    $writer = New-Object System.IO.StreamWriter($stream)
    $writer.NewLine = "`r`n"
    $writer.WriteLine('GNTP/1.0 REGISTER NONE')
    $writer.WriteLine("Application-Name: $AppName")
    $writer.WriteLine('Notifications-Count: 1')
    $writer.WriteLine('')
    $writer.WriteLine('Notification-Name: alert')
    $writer.WriteLine('Notification-Display-Name: alert')
    $writer.WriteLine('Notification-Enabled: True')
    $writer.WriteLine('')
    $writer.WriteLine('')
    $writer.Flush()
    Start-Sleep -Milliseconds 150
    $client.Close()
}

function Send-GntpNotify {
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Text = '',
        [string]$AppName = 'PsSmoke'
    )
    $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 23053)
    $stream = $client.GetStream()
    $writer = New-Object System.IO.StreamWriter($stream)
    $writer.NewLine = "`r`n"
    $writer.WriteLine('GNTP/1.0 NOTIFY NONE')
    $writer.WriteLine("Application-Name: $AppName")
    $writer.WriteLine('Notification-Name: alert')
    $writer.WriteLine("Notification-Title: $Title")
    $writer.WriteLine("Notification-Text: $Text")
    $writer.WriteLine('')
    $writer.WriteLine('')
    $writer.Flush()
    Start-Sleep -Milliseconds 200
    $client.Close()
    Write-Host "sent NOTIFY title='$Title' from pid $PID"
}

Send-GntpRegister
Write-Host "ready. this powershell pid = $PID"
Write-Host "call: Send-GntpNotify 'title' 'text'"
