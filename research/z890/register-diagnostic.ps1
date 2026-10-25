# GPL-2.0-only. Z890 port: register the read-only DIAGNOSTIC.EFI on E: as the
# last F8 entry; Windows stays first. -Remove deletes only the entry created here.
param([switch]$Remove)
$ErrorActionPreference='Stop'
$name='GPU Diagnostic Z890 - NO UNLOCK';$path='\EFI\WindowsGPUUnlock\DIAGNOSTIC.EFI'
$stateFile=Join-Path $PSScriptRoot 'registration.local.json'
function Bcd([string[]]$Arguments){$lines=@(& bcdedit @Arguments);if($LASTEXITCODE -ne 0){throw ('BCDEdit failed: '+($Arguments -join ' '))};return ($lines -join "`r`n")}
if(!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run from an administrator PowerShell'}

if($Remove){
 if(!(Test-Path -LiteralPath $stateFile)){throw 'No registration state; nothing created by this script to remove'}
 $state=Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
 [void](Bcd @('/delete',$state.EntryId))
 Remove-Item -LiteralPath $stateFile
 Write-Output "Removed $($state.EntryId). Backup kept at $($state.BackupRoot)"
 return
}
if(Test-Path -LiteralPath $stateFile){throw 'Already registered; use -Remove first'}

# Windows Boot Manager must live on the ESP the diagnostic will chain-load. The partition
# GUIDs built into platform-config.h are local, never published: partitions.local.json.
$parts=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'partitions.local.json') -Raw | ConvertFrom-Json
$esp=@(Get-Partition | Where-Object IsSystem)
if($esp.Count -ne 1 -or $esp[0].Guid -ne $parts.WindowsEspGuid){throw 'Windows ESP identity changed; rebuild platform-config.h'}
$e=Get-Partition -DriveLetter E
if($e.Guid -ne $parts.DiagnosticPartitionGuid -or ($e | Get-Volume).FileSystem -ne 'FAT32'){throw 'E: identity changed; rebuild platform-config.h'}
$efi=Join-Path 'E:\' $path.TrimStart('\')
if(!(Test-Path -LiteralPath $efi) -or !(Test-Path -LiteralPath 'E:\RTX3090-UNLOCK' -PathType Container)){throw 'Stage DIAGNOSTIC.EFI and E:\RTX3090-UNLOCK first'}
$manager=Bcd @('/enum','{bootmgr}')
if($manager -notmatch '(?mi)^path\s+\\EFI\\Microsoft\\Boot\\bootmgfw\.efi\s*$'){throw 'Unexpected Windows Boot Manager path'}
try{$secure=Confirm-SecureBootUEFI}catch{$secure=$null}

$backup=Join-Path $env:ProgramData ('WindowsGPUUnlock\Z890Backups\'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
[void][IO.Directory]::CreateDirectory($backup)
[void](Bcd @('/export',(Join-Path $backup 'BCD-export')))
[IO.File]::WriteAllText((Join-Path $backup 'firmware-before.txt'),(Bcd @('/enum','firmware')))

$out=Bcd @('/copy','{bootmgr}','/d',$name)
$m=[regex]::Match($out,'\{[0-9a-f-]{36}\}');if(!$m.Success){throw "Could not parse new entry id: $out"}
$id=$m.Value
[ordered]@{EntryId=$id;Name=$name;Path=$path;BackupRoot=$backup;EfiSha256=(Get-FileHash -LiteralPath $efi).Hash;RegisteredUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding utf8
[void](Bcd @('/set',$id,'device','partition=E:'))
[void](Bcd @('/set',$id,'path',$path))
[void](Bcd @('/set','{fwbootmgr}','displayorder',$id,'/addlast'))
[IO.File]::WriteAllText((Join-Path $backup 'firmware-after.txt'),(Bcd @('/enum','firmware')))

Bcd @('/enum',$id)
Write-Output ''
Write-Output "Registered '$name' as the LAST firmware entry. Windows remains first. Backup: $backup"
if($secure -ne $false){Write-Output 'WARNING: Secure Boot is not confirmed OFF. Disable it in BIOS before choosing this entry in F8.'}
