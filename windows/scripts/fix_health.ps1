$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Continue'

Write-Output '=== Delete dead WSLKeepAlive ==='
if (Get-ScheduledTask -TaskName 'WSLKeepAlive' -ErrorAction SilentlyContinue) {
  Unregister-ScheduledTask -TaskName 'WSLKeepAlive' -Confirm:$false
  Write-Output 'Deleted WSLKeepAlive'
}

Write-Output '=== (Re)create WSLDockerHealth with valid duration ==='
if (Get-ScheduledTask -TaskName 'WSLDockerHealth' -ErrorAction SilentlyContinue) {
  Unregister-ScheduledTask -TaskName 'WSLDockerHealth' -Confirm:$false
}
$haction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\wsl-health.ps1'
# Use a long but finite repetition duration (3650 days) -> valid XML.
$htrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650)
$hprincipal = New-ScheduledTaskPrincipal -UserId '<hostname>\ted' -LogonType Interactive -RunLevel Highest
$hsettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 4)
$hsettings.MultipleInstances = 'IgnoreNew'
Register-ScheduledTask -TaskName 'WSLDockerHealth' -Action $haction -Trigger $htrigger -Principal $hprincipal -Settings $hsettings -Description 'Every 5 min: ensure WSL keepalive task is running and Docker is up.' | Out-Null
Write-Output 'Registered WSLDockerHealth'

Write-Output '=== Final inventory ==='
Get-ScheduledTask | Where-Object {$_.TaskName -match 'WSL|Hotspot|Docker'} | Select-Object TaskName,State | Format-Table -AutoSize
