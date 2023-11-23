Param (
 	[string]$SQLINSTANCEPORTSET,
 	[string]$DISKFREESPACETHRESHOLDPC,
 	[string]$DBFREEPC,
 	[string]$STRANGEDISKPC,
 	[string]$STRANGEDBPC
 )

#
$DiskId = "C:"
$DiskFreePcThreshold = 10
$DbfFreePcThreshold = 20
$StrangeDiskFreePc = 10
$StrangeDbFreePc = 85
$ExitCode = 0
$enrich = $null
#
if ($DISKFREESPACETHRESHOLDPC) {
	try {
		$DiskFreePcThreshold = [int] $DISKFREESPACETHRESHOLDPC
	}
	catch {
		write-host "FAILED_ARGUMENT_ERROR DISKFREESPACETHRESHOLDPC non numeric value"
		[Environment]::Exit(1)
	}
}

if ($DBFREEPC) {
	try {
		$DbfFreePcThreshold = [int] $DBFREEPC
	}
	catch {}
}

if ($STRANGEDISKPC) {
	try {
		$StrangeDiskFreePc = [int] $STRANGEDISKPC
	}
	catch {}
}

if ($STRANGEDBPC) {
	try {
		$StrangeDbFreePc = [int] $STRANGEDBPC
	}
	catch {}
}

# Input Args control - Disk free space Threshold is mandatory and must be numeric
if ( $DiskFreePcThreshold -gt 100 ){
	write-host "FAILED_ARGUMENT_ERROR DISKFREESPACETHRESHOLDPC bad value"
	[Environment]::Exit(2)
}
# Check disk and Get Current spaces
$myLogicalDisk = Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.DeviceID -eq $DiskId}
if (-Not $myLogicalDisk) {
	Write-Host "Unable to get disk $DiskId"
	[Environment]::Exit(3)
}
$DiskFreePc = [int] (( $myLogicalDisk.FreeSpace / $myLogicalDisk.size) * 100)
if ($DiskFreePc -gt $DiskFreePcThreshold){
	Write-Host "CLOSED COMPLETE - $DiskId Disk Free Space Percentage is $DiskFreePc %. "
	[Environment]::Exit(0)
}8

$Enrich = "$DiskId Disk Free Space Percentage is $DiskFreePc %. "

# SQL Server Analysis Part
if (-Not $SQLINSTANCEPORTSET) {
	$str = "CLOSED INCOMPLETE - Need further investigation - " + $Enrich + "No SQL Server Instance to check. "
	Write-Host $str
	[Environment]::Exit(0)
}

#
$SqlInstanceList = New-Object Collections.Generic.List[String]
try {
	$SqlInstanceList = $SQLINSTANCEPORTSET -split ";"
}
catch {
	Write-Host "EXCEPTION SQL Server Instance and/or SQL Server Port set values are not correct."
	[Environment]::Exit(4)
}

# 
if (-Not $SqlInstanceList){
	$str = "CLOSED INCOMPLETE - Need further investigation - " + $Enrich + " No SQL Server Instance to check. "
	Write-Host $str
	[Environment]::Exit(10)
}

# Work foreach instance
$InfoComp = ""
$ExitCode = 0
$EmergengyChangeToCreate = $false

foreach ($SQLINSTANCEPORT in $SqlInstanceList){

	$bError = $False
	$SQLINSTANCE =  ""
	$SQLPORT = ""
	try {
		if ($SQLINSTANCEPORT -match '^(?<servername>[\w-\.]+)#(?<instance>[\w-\.]+)#(?<port>\d+)$') {
			$SQLINSTANCE = $Matches.instance
			$SQLPORT = $Matches.port
		}
	}
	catch {
		Write-Host "EXCEPTION SQL Server Instance and/or SQL Server Port values are not correct."
		$ExitCode = 5
		[Environment]::Exit($ExitCode)
	}
	if (-Not $SQLINSTANCE -OR -Not $SQLPORT) {
		continue
	}
	
	if ($InfoComp){
		$InfoComp = $InfoComp + "INSTANCE " + $SQLINSTANCE
	}
	else {
		$InfoComp = "INSTANCE " + $SQLINSTANCE
	}
	
	if ($SQLINSTANCE -eq "EMPTY"){
		$InfoComp = $InfoComp + " SKIPPED. "
		continue
	}
	
	# Get Database list from SQL Server
	try {

		$DbRows = sqlcmd -S "localhost\$SQLINSTANCE,$SQLPORT" -d "master" -E -Q "set nocount on;SELECT name , recovery_model FROM sys.databases WHERE Lower(name) not in ('master','tempdb','model','msdb','reportserver','reportservertempdb','ssisdb') ORDER BY database_id" -h -1 
		
		# Working on all databases of the current instance
		if (-Not $DbRows){
			$InfoComp = $InfoComp + "/No User Database found. "
		}
		else {
		
			foreach ($db in $DbRows){
			
				if ($bError){
					$InfoComp = $InfoComp + $db + ". "
					break
				}
				
				if ($db -match '^Msg\s\d+\,\sLevel\s\d+\,[\w\.\,\s\-\\]+$') {
					$bError = $True
					$InfoComp = $InfoComp + "Unable to get Databases information. "
					continue
				}
			
				if ($db -notmatch '^(?<name>[\w\-\.]+)[\s]+(?<recoverymodel>[\d])$'){
					$InfoComp = $InfoComp + ". "
					continue
				}
				
				$SQLDBNAME = $Matches.name
				$RECOVERYMODEL = $Matches.recoverymodel
				
				$InfoComp = $InfoComp + "/Database " + $SQLDBNAME + ": "
				
				try {
					# SQLServer Sys.sysfiles table query
					$SysFileRows = sqlcmd -S "localhost\$SQLINSTANCE,$SQLPORT" -d $SQLDBNAME -E -Q "set nocount on;SELECT size , maxsize , filename FROM sys.sysfiles where filename LIKE '$DiskId%' " -h -1 
					if ($SysFileRows){
						if ($SysFileRows -match '^(?<size>\d+)\s+(?<maxsize>\-?\d+)\s+(?<filename>[\w\\\.\-\:\d]+)\s+$'){
							
							#
							$TotDbMaxSize = 0
							$TotDbFreeSize = 0
							$TotDbFreePc = 0
							$strDatafiles = ""
							$strStrange = ""
							foreach ($row in $SysFileRows){
								$iMaxSize = $row.maxsize
								if ($iMaxSize -lt 0){
									# no sqlserver limit, max size -> dbf length + disk free space
									if (!(Test-Path $row.filename)){
										continue
									}
									$f = Get-Item $row.filename
									$iMaxSize = $f.length + $myLogicalDisk.FreeSpace
								}
								$iFreeSize = $iMaxSize - $row.size
								$iDbfFreePc =  [int] (($iFreeSize / $iMaxSize) * 100)
								$strfilename = $row.filename.Replace('\','/')
								
								if ($iDbfFreePc -le $DbfFreePcThreshold){
									$strDatafiles = $strDatafiles + [String]::Format("{0} - Size {1}KB - Max {2}KB - Free {3}%. ", $strfilename, [int]($row.size / 1KB), [int]($iMaxsize / 1KB) , $iDbfFreePc)
								}
								$TotDbMaxSize = $TotDbMaxSize + $iMaxSize
								$TotDbFreeSize = $TotDbFreeSize + $iFreeSize
							}
							
							if ($TotDbMaxSize -gt 0) {
								$TotDbFreePc = [int] (($TotDbFreeSize / $TotDbMaxSize) * 100)
								
								# if DiskFree is low and dbfile free sizes are high, then there is something strange so need further investigation
								if ( ($DiskFreePc -le $StrangeDiskFreePc) -AND ($TotDbFreePc -ge $StrangeDbFreePc) ) {
									$strStrange = [String]::Format("Something STRANGE, Free disk space is Low and Database available free space is High. Disk Free Space {0} % - DB Free space {1} %. ", $DiskFreePc , $TotDbFreePc)
									$InfoComp = $InfoComp + $strStrange
								}
							}

							if ($strDatafiles){	
								$InfoComp = $InfoComp + "Datafile Low Free space :" + $strDatafiles + " (Emergency change should be created to solve). "
								$EmergengyChangeToCreate = $true
							}
							else {
								$InfoComp = $InfoComp + "Datafile sizes are all OK. "
							}
						}
					}
				}
				catch{
					$InfoComp = $InfoComp + "Exception Raised. "
				}
				
				# 
				if ($RECOVERYMODEL -ne 1){
					$InfoComp = $InfoComp + "Database NOT in RECOVERY FULL MODE (backup/shrink log skipped). "
				}
				else {
					$InfoComp = $InfoComp + "Database in RECOVERY FULL MODE. "
					# Get Backup folder from Registry
					try {
						$Rows = sqlcmd -S "localhost\$SQLINSTANCE,$SQLPORT" -d "$SQLDBNAME" -E -Q "set nocount on; Execute master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE',N'Software\Microsoft\MSSQLServer\MSSQLServer',N'BackupDirectory'" -h -1
						if ($Rows) {
							if ($Rows -match '^BackupDirectory\s+(?<BkDir>[\w\\\.\-\:\d]+)\s+$'){
								$BackupFolder = $Matches.BkDir
							}
						}
					}
					catch {
						Write-Host "CLOSED INCOMPLETE - Need Further investigation - Exception raised  - UNABLE TO GET SQLSERVER BackupDirectory - Current Instance/Database is $SQLINSTANCE / $SQLDBNAME "
						[Environment]::Exit(18)
					}
					
					# Launch Backup Log with compression -> Backup Folder
					$myTs = Get-Date -Format "yyyyMMddHHmmss"
					$SQLBackupFile = [string]::Format("{0}\{1}_log.{2}.bak", $BackupFolder , $SQLDBNAME , $myTs)
					try {
						Backup-SqlDatabase -ServerInstance "localhost\$SQLINSTANCE,$SQLPORT" -Database "$SQLDBNAME" -BackupFile "$SQLBackupFile" -CompressionOption On -BackupAction Log | Out-Null
						Start-Sleep -s 30
						$InfoComp = $InfoComp + "SQLSERVER BACKUP LOG DONE. "
					}
					catch {
						# Write-Host "CLOSED INCOMPLETE - Need further investigation - Exception raised  - SQLSERVER BACKUP LOG FAILED for Instance/Database $SQLINSTANCE/$SQLDBNAME"
						# [Environment]::Exit(19)
						$InfoComp = $InfoComp + "SQLSERVER BACKUP LOG FAILED. "
						continue
					}
					
					# Check Backup Log Output file
					if (!(Test-Path $SQLBackupFile)){
						# Write-Host "CLOSED INCOMPLETE - Need further investigation - SQL Server Instance/Database $SQLINSTANCE/$SQLDBNAME - ERROR - SQLSERVER Backup Log file NOT FOUND after Backup Log action."
						# [Environment]::Exit(20)
						$InfoComp = $InfoComp + "SQLSERVER Backup Log file NOT FOUND after Backup Log action. "
						continue
					}

					try {
						$SQLBackupFileLastWrite = (Get-Item $SQLBackupFile).LastWriteTime
						$AgeTs = New-Timespan -minutes 5
						if ( ((Get-Date) - $SQLBackupFileLastWrite) -gt $AgeTs ) {
							# Write-Host "CLOSED INCOMPLETE - Need further investigation - SQL Server Instance/Database $SQLINSTANCE/$SQLDBNAME - SQLSERVER BACKUP LOG FILE CHECK FAILED."
							# [Environment]::Exit(21)
							$InfoComp = $InfoComp + "SQLSERVER BACKUP LOG FILE CHECK FAILED. "
							continue
						}
					}
					catch {
						# Write-Host "CLOSED INCOMPLETE - Need further investigation - SQL Server Instance/Database $SQLINSTANCE/$SQLDBNAME - Exception raised - SQLServer Backup Log file check FAILED."
						# [Environment]::Exit(22)
						$InfoComp = $InfoComp + "SQLSERVER BACKUP LOG FILE FAILED. "
						continue
					}
					
					$InfoComp = $InfoComp + "Backup Log file check OK. "

					# Get Log File Path
					try {
						$Rows = sqlcmd -S "localhost\$SQLINSTANCE,$SQLPORT" -d "$SQLDBNAME" -E -Q "set nocount on; SELECT size , max_size , name , physical_name FROM sys.database_files where type_desc = 'LOG' AND physical_name LIKE '$DiskId%' " -h -1
					}
					catch {
						# Write-Host "CLOSED INCOMPLETE - Need further investigation - SQL Server Instance/Database $SQLINSTANCE/$SQLDBNAME - Exception raised  - UNABLE TO GET SQLSERVER LOG FILE NAME."
						# [Environment]::Exit(23)
						$InfoComp = $InfoComp + "UNABLE TO GET SQLSERVER LOG FILE NAME. "
						continue
					}

					if (-Not $Rows) {
						# Write-Host "CLOSED INCOMPLETE - Need further investigation - SQL Server Instance/Database $SQLINSTANCE/$SQLDBNAME - UNABLE TO GET SQLSERVER LOG FILE. "
						# [Environment]::Exit(24)
						$InfoComp = $InfoComp + "UNABLE TO GET SQLSERVER LOG FILE NAME. "
						continue
					}

					if ($Rows -notmatch '^\s*(?<size>\d+)\s+(?<maxsize>\-?\d+)\s+(?<name>[\w\\\.\-\:\d]+)\s+(?<physicalname>[\w\\\.\-\:\d]+)\s+$'){
						$InfoComp = $InfoComp + "UNABLE TO GET SQLSERVER LOG FILE NAME. "
						continue
					}
							
					$SQLLogFileName = $Matches.name
					$SQLLogFilePath = $Matches.physicalname
					$SQLLogSize = $Matches.size
					$InfoComp = $InfoComp + "Log File is $SQLLogFileName. "

					# Get Physical Log File size before shrink
					$LogFileSize0 = (Get-Item -Path "$SQLLogFilePath").Length
					$InfoComp = $InfoComp + "Log File physical size before shrink : " + ([int]($LogFileSize0/1KB)) + "KB. "

					# Shrink DbLog
					try {
						$SQLShrink = sqlcmd -S "localhost\$SQLINSTANCE,$SQLPORT" -d "$SQLDBNAME" -E -Q "DBCC SHRINKFILE ( $SQLLogFileName ) " -h -1
						Start-Sleep -s 60
						$InfoComp = $InfoComp + "DBCC SHRINKFILE $SQLLogFileName DONE. "
					}
					catch {
						# Write-Host "CLOSED INCOMPLETE - Need further investigation - SQL Server Instance/Database $SQLINSTANCE/$SQLDBNAME - EXCEPTION Raised - SQLSERVER SHRINK FAILED."
						# [Environment]::Exit(25)
						$InfoComp = $InfoComp + "SQLSERVER DBCC SHRINKFILE $SQLLogFileName FAILED. "
						continue 
					}

					# Get size after shrink
					$LogFileSize1 = (Get-Item -Path "$SQLLogFilePath").Length
					$InfoComp = $InfoComp + "Log File physical size after shrink : " + ([int]($LogFileSize1/1KB)) + "KB. "
					
					# Shrink attempt 2 removed
					
				} # If recovery_model
				
			} # End foreach Database
		}
	}
	catch {
		$InfoComp = $InfoComp + "Exception Raised. "
	}

} # End of foreach Instance

# G: Free space
$myLogicalDisk = Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.DeviceID -eq $DiskId}
if (-Not $myLogicalDisk) {
	Write-Host "CLOSED INCOMPLETE - ERROR - FAILED_DISK_NOT_FOUND $DiskId"
	[Environment]::Exit(27)
}

$DiskFreePc = [int] (( $myLogicalDisk.FreeSpace / $myLogicalDisk.size) * 100)
if ($DiskFreePc -le $DiskFreePcThreshold){
	# G: disk free size is still less than threshold
	if ($EmergengyChangeToCreate){
		Write-Host "CLOSED COMPLETE - Need further investigation - G: Disk Free space $DiskFreePc% is still less than Threshold ($DiskFreePcThreshold%) - An emergency change should be created because of existing datafile with low free space in SQL Server - $InfoComp"
		[Environment]::Exit(28)
	}
	else {
		Write-Host "CLOSED COMPLETE - Need further investigation - G: Disk Free space $DiskFreePc% is still less than Threshold ($DiskFreePcThreshold%) - $InfoComp"
		[Environment]::Exit(29)
	}
}

if ($EmergengyChangeToCreate){
	Write-Host "CLOSED COMPLETE - Need further investigation - G: Disk Free space $DiskFreePc% is above the threshold - An emergency change should be created because of existing datafile with low free space in SQL Server - $InfoComp"
	[Environment]::Exit(30)
}
Write-Host "CLOSED COMPLETE - Percentage of free space for G: is $DiskFreePc% - $InfoComp"

[Environment]::Exit(0)
