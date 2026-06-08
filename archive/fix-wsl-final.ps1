# fix-wsl-final.ps1
# Uses Registry Run key instead of scheduled task - most reliable at logon

Write-Host "=== Fixing WSL Auto-Start (Final Attempt) ==="

# Step 1: Clean up broken scheduled tasks
Write-Host "`n[1] Removing broken scheduled tasks..."
Unregister-ScheduledTask -TaskName "AutoStartWSL" -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "AutoStartWSLBoot" -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "  Removed AutoStartWSL and AutoStartWSLBoot"

# Step 2: Create a VBS wrapper (runs hidden, no cmd window)
Write-Host "`n[2] Creating VBS launcher..."
$vbs = @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "cmd /c C:\start-wsl.bat", 0, False
"@
$vbs | Out-File -FilePath "C:\start-wsl.vbs" -Encoding ASCII
Write-Host "  Created C:\start-wsl.vbs"

# Step 3: Update the batch file to be more robust
Write-Host "`n[3] Updating start-wsl.bat..."
$bat = @"
@echo off
REM Wait for system to fully boot
timeout /t 20 /nobreak >nul
REM Kill any stale WSL
wsl --shutdown 2>nul
timeout /t 5 /nobreak >nul
REM Start WSL and Docker
wsl -d Ubuntu-22.04 -- bash -c "sudo systemctl start docker 2>/dev/null || sudo service docker start"
REM Keep WSL alive - ping every 2 minutes
:loop
timeout /t 120 /nobreak >nul
wsl -d Ubuntu-22.04 -- echo alive >nul 2>nul
goto loop
"@
$bat | Out-File -FilePath "C:\start-wsl.bat" -Encoding ASCII
Write-Host "  Updated C:\start-wsl.bat"

# Step 4: Add to HKCU Run key (runs at user logon, in user context)
Write-Host "`n[4] Adding to Registry Run key (HKCU)..."
$runPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
Set-ItemProperty -Path $runPath -Name "StartWSL" -Value 'wscript.exe "C:\start-wsl.vbs"'
Write-Host "  Added 'StartWSL' to HKCU\...\Run"

# Step 5: Also add to HKLM Run key (runs for all users)
Write-Host "`n[5] Adding to Registry Run key (HKLM)..."
$runPathLM = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
Set-ItemProperty -Path $runPathLM -Name "StartWSL" -Value 'wscript.exe "C:\start-wsl.vbs"'
Write-Host "  Added 'StartWSL' to HKLM\...\Run"

# Step 6: Create a SYSTEM scheduled task as final backup
Write-Host "`n[6] Creating backup SYSTEM task..."
$bootAction = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d Ubuntu-22.04 -- echo keepalive"
$bootTrigger = New-ScheduledTaskTrigger -AtStartup
$bootTrigger.Delay = "PT30S"
$bootSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
$bootPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName "WSLKeepAlive" -Action $bootAction -Trigger $bootTrigger `
    -Settings $bootSettings -Principal $bootPrincipal `
    -Description "Wake WSL at boot (SYSTEM backup)" -Force
Write-Host "  Registered WSLKeepAlive (SYSTEM, 30s after boot)"

# Step 7: Verify current state
Write-Host "`n[7] Current state:"
Write-Host "  Auto-logon: $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon').AutoAdminLogon)"
Write-Host "  HKCU Run: $((Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run').StartWSL)"
Write-Host "  HKLM Run: $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run').StartWSL)"

# Step 8: Start WSL now
Write-Host "`n[8] Starting WSL + Docker now..."
Start-Process -FilePath "wscript.exe" -ArgumentList '"C:\start-wsl.vbs"' -WindowStyle Hidden
Start-Sleep -Seconds 25

Write-Host "`n=== Verification ==="
wsl --list --verbose
Write-Host "`nDocker:"
wsl -d Ubuntu-22.04 -- bash -c "docker ps --format 'table {{.Names}}\t{{.Status}}'" 2>&1

# Clean up
Remove-Item "C:\fix-and-check.ps1" -Force -ErrorAction SilentlyContinue
Remove-Item "C:\restart-docker.ps1" -Force -ErrorAction SilentlyContinue
Remove-Item "C:\update-bat.ps1" -Force -ErrorAction SilentlyContinue
