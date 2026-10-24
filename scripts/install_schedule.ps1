# Richtet die automatischen Laeufe um 08:00 und 15:00 Uhr in der Windows-Aufgabenplanung ein.
# Ausfuehren:     powershell -ExecutionPolicy Bypass -File scripts\install_schedule.ps1
# Mit Autostart:  powershell -ExecutionPolicy Bypass -File scripts\install_schedule.ps1 -Autostart   (Server bei Anmeldung)
# Entfernen:      powershell -ExecutionPolicy Bypass -File scripts\install_schedule.ps1 -Remove

param([switch]$Remove, [switch]$Autostart)

$Root  = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Py    = Join-Path $Root ".venv\Scripts\pythonw.exe"   # pythonw = kein Konsolenfenster
if (-not (Test-Path $Py)) { $Py = Join-Path $Root ".venv\Scripts\python.exe" }

$SyncName   = "StudIP-LernApp Sync"
$ServerName = "StudIP-LernApp Server"

if ($Remove) {
  foreach ($n in @($SyncName, $ServerName)) {
    if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $n -Confirm:$false; Write-Host "Entfernt: $n" }
  }
  exit 0
}

$action   = New-ScheduledTaskAction -Execute $Py -Argument "`"$Root\sync.py`"" -WorkingDirectory $Root
$triggers = @(
  (New-ScheduledTaskTrigger -Daily -At "08:00"),
  (New-ScheduledTaskTrigger -Daily -At "15:00")
)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $SyncName -Action $action -Trigger $triggers -Settings $settings -Force | Out-Null
Write-Host "Eingerichtet: '$SyncName' taeglich 08:00 und 15:00 Uhr (verpasste Laeufe werden nachgeholt)"

if ($Autostart) {
  $a2 = New-ScheduledTaskAction -Execute $Py -Argument "`"$Root\serve.py`"" -WorkingDirectory $Root
  $t2 = New-ScheduledTaskTrigger -AtLogOn
  Register-ScheduledTask -TaskName $ServerName -Action $a2 -Trigger $t2 -Force | Out-Null
  Write-Host "Eingerichtet: '$ServerName' beim Anmelden"
}

Write-Host ""
Write-Host "Pruefen:       Get-ScheduledTaskInfo -TaskName '$SyncName'"
Write-Host "Sofort testen: Start-ScheduledTask -TaskName '$SyncName'"
