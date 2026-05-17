function Send-Gntp([string]$payload) {
    $client = New-Object System.Net.Sockets.TcpClient
    $client.Connect("127.0.0.1", 23053)
    $stream = $client.GetStream()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $stream.Write($bytes, 0, $bytes.Length)
    Start-Sleep -Milliseconds 600
    $buf = New-Object byte[] 4096
    $n = $stream.Read($buf, 0, 4096)
    $client.Close()
    return [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
}

# Case 1: spec-compliant REGISTER with a single inline type block, followed
# by a NOTIFY referencing it. Verifies the structural read picks up the
# type block (the rev that prompted ReadFullMessageAsync to be rewritten).
$register = "GNTP/1.0 REGISTER NONE`r`nApplication-Name: WinGrowl SmokeTest`r`nNotifications-Count: 1`r`n`r`nNotification-Name: ping`r`nNotification-Display-Name: Ping`r`nNotification-Enabled: True`r`n`r`n"
Write-Host "=== Case 1: REGISTER (compliant, 1 inline type block) ==="
Send-Gntp $register

$notify = "GNTP/1.0 NOTIFY NONE`r`nApplication-Name: WinGrowl SmokeTest`r`nNotification-Name: ping`r`nNotification-Title: Smoke test`r`nNotification-Text: Synthetic notification from the build pipeline test`r`n`r`n"
Write-Host "=== Case 1: NOTIFY ==="
Send-Gntp $notify

# Case 2: Firestorm-shaped REGISTER — declares Notifications-Count > 0 but
# ships zero inline type blocks, expecting the server to auto-register
# on first NOTIFY. The 250 ms quiescence timeout in ReadFullMessageAsync
# is what lets this path complete instead of hanging on the missing
# blocks. NOTIFY for an unknown type name should be auto-registered as
# enabled and dispatched.
$registerFx = "GNTP/1.0 REGISTER NONE`r`nApplication-Name: WinGrowl SmokeTest Firestorm-Shape`r`nNotifications-Count: 5`r`n`r`n"
Write-Host "=== Case 2: REGISTER (Firestorm-shaped, count=5 / no blocks) ==="
Send-Gntp $registerFx

$notifyFx = "GNTP/1.0 NOTIFY NONE`r`nApplication-Name: WinGrowl SmokeTest Firestorm-Shape`r`nNotification-Name: auto-registered`r`nNotification-Title: Auto-register check`r`nNotification-Text: Type 'auto-registered' was never declared in REGISTER`r`n`r`n"
Write-Host "=== Case 2: NOTIFY (auto-register on first arrival) ==="
Send-Gntp $notifyFx
