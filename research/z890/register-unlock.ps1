# GPL-2.0-only. Z890 port: register HANDOFF.EFI on E: as the last F8 entry; Windows stays first. Nothing is unlocked by
# registering: the entry asks for Esc and then U at boot. -Remove deletes only the entry created here.
# -MakeDefault puts it first and turns Fast Startup off, so power-on always unlocks from a full shutdown; -WindowsFirst
# puts Windows Boot Manager first again and restores Fast Startup.
param([switch]$Remove,[switch]$MakeDefault,[switch]$WindowsFirst)
$ErrorActionPreference='Stop'
$name='GPU UNLOCK Z890 - EXPERIMENTAL';$path='\EFI\WindowsGPUUnlock\HANDOFF.EFI'
$stateFile=Join-Path $PSScriptRoot 'unlock-registration.local.json'
function Bcd([string[]]$Arguments){$lines=@(& bcdedit @Arguments);if($LASTEXITCODE -ne 0){throw ('BCDEdit failed: '+($Arguments -join ' '))};return ($lines -join "`r`n")}
if(!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run from an administrator PowerShell'}

$power='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$fastFile=Join-Path $PSScriptRoot 'fast-startup.local.json'
if($MakeDefault){
 if(!(Test-Path -LiteralPath $stateFile)){throw 'Not registered yet: run this script without switches first'}
 $state=Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
 if(!(Test-Path -LiteralPath $fastFile)){[ordered]@{HiberbootEnabled=(Get-ItemProperty -LiteralPath $power).HiberbootEnabled} | ConvertTo-Json | Set-Content -LiteralPath $fastFile -Encoding utf8}
 Set-ItemProperty -LiteralPath $power -Name HiberbootEnabled -Value 0 -Type DWord
 [void](Bcd @('/set','{fwbootmgr}','displayorder',$state.EntryId,'/addfirst'))
 Write-Output "'$name' is now first. Fast Startup off. F8 -> Windows Boot Manager still boots Windows directly."
 return
}
if($WindowsFirst){
 [void](Bcd @('/set','{fwbootmgr}','displayorder','{bootmgr}','/addfirst'))
 if(Test-Path -LiteralPath $fastFile){
  $saved=Get-Content -LiteralPath $fastFile -Raw | ConvertFrom-Json
  Set-ItemProperty -LiteralPath $power -Name HiberbootEnabled -Value ([int]$saved.HiberbootEnabled) -Type DWord
  Remove-Item -LiteralPath $fastFile
 }
 Write-Output 'Windows Boot Manager is first again; Fast Startup as it was.'
 return
}

if($Remove){
 if(!(Test-Path -LiteralPath $stateFile)){throw 'No registration state; nothing created by this script to remove'}
 $state=Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
 [void](Bcd @('/delete',$state.EntryId))
 Remove-Item -LiteralPath $stateFile
 Write-Output "Removed $($state.EntryId). Backup kept at $($state.BackupRoot)"
 return
}
if(Test-Path -LiteralPath $stateFile){throw 'Already registered; use -Remove first'}

$parts=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'partitions.local.json') -Raw | ConvertFrom-Json
$esp=@(Get-Partition | Where-Object IsSystem)
if($esp.Count -ne 1 -or $esp[0].Guid -ne $parts.WindowsEspGuid){throw 'Windows ESP identity changed; rebuild platform-config.h'}
$e=Get-Partition -DriveLetter E
if($e.Guid -ne $parts.DiagnosticPartitionGuid -or ($e | Get-Volume).FileSystem -ne 'FAT32'){throw 'E: identity changed; rebuild platform-config.h'}
foreach($file in 'E:\EFI\WindowsGPUUnlock\HANDOFF.EFI','E:\EFI\WindowsGPUUnlock\UNLOCK.EFI'){if(!(Test-Path -LiteralPath $file)){throw "Missing $file"}}
if(!(Test-Path -LiteralPath 'E:\RTX3090-UNLOCK\ASSETS' -PathType Container)){throw 'Missing assets on E:'}

$backup=Join-Path $env:ProgramData ('WindowsGPUUnlock\Z890Backups\'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
[void][IO.Directory]::CreateDirectory($backup)
[void](Bcd @('/export',(Join-Path $backup 'BCD-export')))
[IO.File]::WriteAllText((Join-Path $backup 'firmware-before.txt'),(Bcd @('/enum','firmware')))

$out=Bcd @('/copy','{bootmgr}','/d',$name)
$m=[regex]::Match($out,'\{[0-9a-f-]{36}\}');if(!$m.Success){throw "Could not parse new entry id: $out"}
$id=$m.Value
[ordered]@{EntryId=$id;Name=$name;Path=$path;BackupRoot=$backup;RegisteredUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding utf8
[void](Bcd @('/set',$id,'device','partition=E:'))
[void](Bcd @('/set',$id,'path',$path))
[void](Bcd @('/set','{fwbootmgr}','displayorder',$id,'/addlast'))
[IO.File]::WriteAllText((Join-Path $backup 'firmware-after.txt'),(Bcd @('/enum','firmware')))

Write-Output "Registered '$name' as the LAST firmware entry. Windows remains first. Backup: $backup"
