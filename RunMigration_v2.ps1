Clear-Host

$dockerhost     = Read-Host -Prompt "Enter docker host IP address"
$source         = Read-Host -Prompt "Enter source container name"
$dest           = Read-Host -Prompt "Enter destination container name"
$database       = Read-Host -Prompt "Enter database to migrate"

Write-Host "Beginning database migration..." -ForegroundColor Magenta

$docker = (Get-Item $PsScriptRoot\docker.exe).FullName

# create function to get container details
function Get-Containers {
    $fields = "ContainerId","Image","Command","Created","Status","Port","Name"
   
    . $docker -H "tcp://$dockerHost`:2375" ps |
        Select-Object -Skip 1 |
        ConvertFrom-String -Delimiter "[\s]{2,}" -PropertyNames $fields
}


# capture details of source container
Write-Host "Capturing source container details..." -ForegroundColor Yellow
try{
    $sourcecontainer = Get-Containers | ? {$_.Name -eq $source}
    $sourceport = $sourcecontainer.Port

    $startpos = $sourceport.IndexOf(":") + 1
    $endpos = $sourceport.IndexOf("-") - $startpos
    $sourceport = $sourceport.substring($startpos, $endpos)

    Write-Host "Successfully captured source container details" -ForegroundColor Green 
}
catch{
    Write-Host "Capturing source container details failed" -ForegroundColor Red
    exit 
}


# capture details of dest container
Write-Host "Capturing destination container details..." -ForegroundColor Yellow
try{
    $destcontainer = Get-Containers | ? {$_.Name -eq $dest}
    $destport = $destcontainer.Port

    $startpos = $destport.IndexOf(":") + 1
    $endpos = $destport.IndexOf("-") - $startpos
    $destport = $destport.substring($startpos, $endpos)

    Write-Host "Successfully captured destination container details" -ForegroundColor Green 
}
catch{
    Write-Host "Capturing destination container details failed" -ForegroundColor Red
    exit 
}


# set credentials to connect to containers
Write-Host "Enter credentials to connect to SQL instances within containers..." -ForegroundColor Yellow
$scred = Get-Credential


# get database backup location in source container
Write-Host "Retrieving database backup location in source container..." -ForegroundColor Yellow
$getsrcbackuplocation = "EXEC  master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer',N'BackupDirectory'"
try{
    $srcbackuplocation  = Invoke-Sqlcmd2 -ServerInstance "$dockerhost,$sourceport" -Credential $scred -Query $getsrcbackuplocation -ErrorAction Stop
    $srcbackuplocation = $srcbackuplocation.Data
   Write-Host "Sucessfully retrieved database backup location" -ForegroundColor Green
}
catch{
    Write-Host "Failed to get database backup location" -ForegroundColor Red
    Exit
}


# backup database
Write-Host "Attempting to backup database..." -ForegroundColor Yellow
try{
    $databasebk = "$database.bak"
    $backupdb = "IF EXISTS (SELECT DB_ID('$database')) BACKUP DATABASE [$database] TO DISK = '$srcbackuplocation\$databasebk' WITH INIT,COMPRESSION;"
    Invoke-Sqlcmd2 -ServerInstance "$dockerhost,$sourceport" -Credential $scred -Query $backupdb -ErrorAction Stop
    Write-Host "Successfully backed up database" -ForegroundColor Green
}
catch{
    Write-host "Failed to backup database" -ForegroundColor Red
    Exit
}


# create directory on host to hold database backup
Write-Host "Creating directory on the host..." -ForegroundColor Yellow
$hostdirectory = "\\$dockerhost\C$\DatabaseBackup\"

if((Test-Path $hostdirectory) -eq 0){      
    try{
        New-Item -ItemType Directory $hostdirectory -ErrorAction Stop | Out-Null
        Write-Host "Successfully created directory on the host" -ForegroundColor Green
    }
    catch{
        Write-Host "Failed to create directory on host" -ForegroundColor Red
        Exit
    }
}
elseif((Test-Path $hostdirectory) -eq 1){     
    Write-Host "Directory already exists!" -ForegroundColor Green
}


# copy database backup onto the host
Write-Host "Copying database backup to host..." -ForegroundColor Yellow
try{
    [string]$copytohost = "docker -H tcp://$dockerhost`:2375 cp sqlcontainer1:""$srcbackuplocation\$databasebk"" $hostdirectory"
    Invoke-Expression -Command $copytohost -ErrorAction Stop | Out-Null
    Write-Host "Successfully copied backup to host" -ForegroundColor Green
}
catch{
 Write-Host "Failed to copy backup to host" -ForegroundColor Red
 Exit
}


# get database backup location in destination container
Write-Host "Retrieving location in destination container..." -ForegroundColor Yellow
$getdestbackuplocation = "EXEC  master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer',N'BackupDirectory'"
try{
    $destbackuplocation  = Invoke-Sqlcmd2 -ServerInstance "$dockerhost,$destport" -Credential $scred -Query $getdestbackuplocation -ErrorAction Stop
    $destbackuplocation = $destbackuplocation.Data
    Write-Host "Sucessfully retrieved database backup location" -ForegroundColor Green
}
catch{
    Write-Host "Failed to get database backup location" -ForegroundColor Red
    Exit
}


# copy files into destination container
Write-Host "Attempting to copy files into destination container..." -ForegroundColor Yellow
$hostdbfiles = gci $hostdirectory | ? {$_.Name -eq $databasebk}
foreach($hostdbfile in $hostdbfiles){
    try{
        [string]$copytodest = "docker -H tcp://$dockerhost`:2375 cp $hostdirectory$hostdbfile $dest`:""$destbackuplocation"""
        Invoke-Expression -Command $copytodest -ErrorAction Stop | Out-Null
        Write-Host "Successfully copied $hostdbfile to destination container" -ForegroundColor Green
    }
    catch{
        Write-Host "Failed to copy $hostdbfile to destination container" -ForegroundColor Red
        Exit
    }
 }
 

# get default data location in destination container
Write-Host "Retrieving default data location in source container..." -ForegroundColor Yellow
$getdestdatalocation = "SELECT SERVERPROPERTY('INSTANCEDEFAULTDATAPATH') AS [DataDir]"
try{
    $destdatalocation  = Invoke-Sqlcmd2 -ServerInstance "$dockerhost,$destport" -Credential $scred -Query $getdestdatalocation -ErrorAction Stop
    $destdatalocation = $destdatalocation.DataDir
    Write-Host "Sucessfully retrieved default data location" -ForegroundColor Green
}
catch{
    Write-Host "Failed to get default data location" -ForegroundColor Red
    Exit
}


# connect to destination SQL instance & restore database
Write-Host "Attempting to restore database..." -ForegroundColor Yellow
try{
    $restorefilelist = "RESTORE FILELISTONLY FROM DISK = '$destbackuplocation\$databasebk'"
    $dbfiles = Invoke-Sqlcmd2 -ServerInstance "$dockerhost,$destport" -Credential $scred -Query $restorefilelist -ErrorAction Stop 
    $restorestatement = "RESTORE DATABASE [$database] FROM DISK = '$destbackuplocation\$databasebk' WITH"
    
    foreach($dbfile in $dbfiles){
        $physname = $dbfile.PhysicalName
        $logicalname = $dbfile.LogicalName

        $startpos = $physname.LastIndexOf("\") + 1
        $endpos = $physname | Measure-Object -Character
        $endpos =  $endpos.Characters - $startpos
        $physname = $physname.substring($startpos, $endpos)

        $movestatement = " MOVE '$logicalName' TO '$destdatalocation$physname',"
        $restorestatement = $restorestatement + $movestatement
    }

    $restorestatement = $restorestatement + " REPLACE, RECOVERY"   
    
    Invoke-Sqlcmd2 -ServerInstance "$dockerhost,$destport" -Credential $scred -Query $restorestatement -ErrorAction Stop 
    Write-Host "Successfully restored database" -ForegroundColor Green
}
catch{
    Write-Host "Failed to restore database" -ForegroundColor Red
    Exit
}

Write-Host "Database migration complete!" -ForegroundColor Magenta
