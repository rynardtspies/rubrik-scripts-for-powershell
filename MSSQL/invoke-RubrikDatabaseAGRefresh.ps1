﻿#requires -modules Rubrik, SQLServer
<#
.SYNOPSIS
Refresh Availability databases from a target server, for example DevRefresh

.DESCRIPTION
Based on parameters supplied, RubrikDatabaseAGRefresh will restore a databases from a Source (eg. Production) to a target server (eg. Developer)

.PARAMETER databases
It is a mandatory parameter, the script will export supplied DBs to the given target server. 

.PARAMETER SourceServerInstance
It is a mandatory parameter, source SQL Server Instance that has the DBs, e.g. SQLserv01\Prod
For AG server environment, use the Availability group insted of the replica nodes!

.PARAMETER RubrikServer
It will be used to get the replica names if the target instance is an Availability Group
Ex. $RubrikServer = "172.21.8.51"

.PARAMETER TargetServerInstance
It is a mandatory parameter, target SQL Server Instance that has the DBs, e.g. SQLserv01\DEV
For AG server environment, use the Availability group insted of the replica nodes!

.PARAMETER LatestRecoveryPoint
Optional parameter, if informed the script will consider the LatestRecoveryPoint to restore

.PARAMETER RecoveryDateTime
Optional parameter, should be used if you want to restore an specif point in time,
this parameter has precedence in relation to the parameter LatestRecoveryPoint, so do not use this parameter toggeter with parameter LatestRecoveryPoint

.PARAMETER FinishRecovery
Optional parameter, will change the DB status to recevery (if the target is not part of AG)

.PARAMETER TargetDataFilePath
Optional parameter, path where the data file should be restored, if not informed, Rubrik will use the same location as Source instance
ex. D:\Data

.PARAMETER TargetLogFilePath
Optional parameter, path where the log file database should be restored, if not informed, Rubrik will use the same location as Source instance
ex. D:\Log

.EXAMPLE
Refreshing a gorup of databases from Prod AG to DEV ag.
    $RubrikServer = "172.21.8.51"
    $RubrikCredential = (Get-Credential -Message 'Please enter your Rubrik credentials')
    Connect-Rubrik -Server $RubrikServer -Credential $RubrikCredential

    .\invoke-RubrikDatabaseAGRefresh.ps1 -databases "dbAG01","dbAG02","dbAG03" -SourceServerInstance "PROD_AG_name" -RubrikServer = "172.21.8.51" -TargetServerInstance "DEV_AG_name" -LatestRecoveryPoint
        

.NOTES
Name:               AG database Refresh
Created:            08/06/2019
Author:             Marcelo Fernandes
Execution Process:
    Before running this script, you need to connect to the Rubrik cluster, and also ensure SQL Permission for account that will run this script.
        Ex.
        $RubrikServer = "172.21.8.51"
        #$RubrikCredential = (Get-Credential -Message 'Please enter your Rubrik credentials')
        Connect-Rubrik -Server $RubrikServer -Credential $RubrikCredential
#>

param(
    [Parameter(Mandatory=$true)]
    [String[]] $databases,

    [Parameter(Mandatory=$true)]
    [String] $SourceServerInstance,

    [Parameter(Mandatory=$true)]
    [String] $RubrikServer,

    [Parameter(Mandatory=$true)]
    [String] $TargetServerInstance,

    [Switch] $LatestRecoveryPoint,
    [Switch] $FinishRecovery,
    [string] $TargetDataFilePath,
    [string] $TargetLogFilePath,
    [ValidateScript({get-date $_ })] 
    [datetime]$RecoveryDateTime
)

Import-Module Rubrik
Import-Module SQLServer

function get-RubrikdatabaseDetail
{
    param(
        [Parameter(Mandatory=$true)]
        [String]$Hostname,
        [Parameter(Mandatory=$true)]
        [String]$InstanceName,
        [Parameter(Mandatory=$true)]
        [String]$DatabaseName
    )
    
    $DBdetail = Get-RubrikDatabase -Hostname $Hostname -Instance $InstanceName -Database $DatabaseName
    #for AG databases
    if (!$DBdetail)
    {
        $DBdetail = Get-RubrikDatabase -Name $DatabaseName -Hostname $Hostname
        if (!$DBdetail){return $null}
    }
    $DBdetail = $DBdetail | Get-RubrikDatabase | Where-Object {$_.isrelic -ne 'TRUE' -and $_.isLiveMount -ne 'TRUE'}
    return $DBdetail
}

function Get-RubrikRequestInfo
{
    param(
        # Rubrik Request Object Info
        [Parameter(Mandatory=$true)]
        [PSObject]$RubrikRequest
    )
    
    $ExitList = @("SUCCEEDED", "FAILED")
    do 
    {
        $RubrikRequestInfo = Get-RubrikRequest -id $RubrikRequest.id -Type "mssql"
        IF ($RubrikRequestInfo.progress -gt 0)
        {
            Write-Host "$($RubrikRequestInfo.id) is $($RubrikRequestInfo.status) $($RubrikRequestInfo.progress) complete"
            Write-Progress -Activity "$($RubrikRequestInfo.id) is $($RubrikRequestInfo.status)" -status "Progress $($RubrikRequestInfo.progress)" -percentComplete ($RubrikRequestInfo.progress)
        }
        else
        {
            Write-Progress -Activity "$($RubrikRequestInfo.id)" -status "Job Queued" -percentComplete (0)
        }
        Start-Sleep -Seconds 1
    } while ($RubrikRequestInfo.status -notin $ExitList) 	
}


if($SourceServerInstance -contains '\'){
    $srcHostName = ($SourceServerInstance -split '\')[0]
    $srcInstanceName = ($SourceServerInstance -split '\')[1]
} else {
    $srcHostName = $SourceServerInstance
    $srcInstanceName = 'MSSQLSERVER'
}

if($TargetServerInstance -contains '\'){
    $tgtHostName = ($TargetServerInstance -split '\')[0]
    $tgtInstanceName = ($TargetServerInstance -split '\')[1]
} else {
    $tgtHostName = $TargetServerInstance
    $tgtInstanceName = 'MSSQLSERVER'
}

$isAG = $False
$target = Get-RubrikSQLInstance -Name $tgtInstanceName -ServerInstance $tgtHostName|Select-Object @{n='rootName';e={$($_.rootProperties).rootName}},@{n='rootId';e={$($_.rootProperties).rootId}},@{n='instanceId';e={$_.id}},@{n='instanceName';e={$_.name}},RubrikRequest 
if (!$target){
    $isAG = $true
    $Header = $global:RubrikConnection.header
    $uri = "https://"+$RubrikServer+"/api/internal/mssql/hierarchy/root/children?limit=201&name="+$TargetServerInstance+"&offset=0&primary_cluster_id=local&sort_by=name&sort_order=asc"
    $x = (Invoke-RestMethod -Uri $uri -Headers $Header -Method Get -ContentType 'application/json').data  
    $y = $x | ForEach-Object{(Invoke-RubrikRESTCall  -Endpoint "mssql/db?availability_group_id=$($_.id)" -Method GET).data}| ForEach-Object{Get-RubrikDatabase -id $($_.id)}

    $target = ($y | select * -first 1).replicas |Select-Object @{n='rootName';e={$($_.rootProperties).rootName}},@{n='rootId';e={$($_.rootProperties).rootId}},@{n='role';e={$($_.availabilityInfo).role}},instanceId,instanceName,RubrikRequest 
}
#Validations

#If missing parameter RecoveryDateTime, the parameter -LatestRecoveryPoint is required to restore the lastes recovery point
if(!$RecoveryDateTime -and !$LatestRecoveryPoint){
    write-warning -message "You have to inform the parameters: -RecoveryDateTime or -LatestRecoveryPoint"
    break
}

foreach($db in $databases) {
    if($PSCmdlet.ShouldProcess($db)){
            
        $sourcedb = get-RubrikdatabaseDetail -Hostname $srcHostName -InstanceName $srcInstanceName -DatabaseName $db

        if(!$sourcedb){Write-Host "The database [$db] cannot be found." -ForegroundColor Yellow}
        else{
            #getting the recovery point
            if($RecoveryDateTime){$srcRecoveryDateTime = $RecoveryDateTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }else{$srcRecoveryDateTime = (Get-Date $sourcedb.latestRecoveryPoint)}

            #checking existing destination DB
            $targetdb =  get-RubrikdatabaseDetail -Hostname $TargetServerInstance -InstanceName $tgtInstanceName -DatabaseName $db

            if (!$TargetDataFilePath -or !$TargetLogFilePath){
                Write-Verbose "If exists, Get the file path from target DB"
                try{if($targetdb){$sourcefiles = Get-RubrikDatabaseFiles -Id $targetdb.id -RecoveryDateTime (Get-Date $targetdb.latestRecoveryPoint) |Select-Object LogicalName,@{n='exportPath';e={$_.OriginalPath}},@{n='newFileName';e={$_.OriginalName}}}
                    if(!$sourcefiles -xor !$targetdb){
                        Write-Verbose "Database [$db] does not exists on target DB, using the File Paths from source"                            
                        $sourcefiles = Get-RubrikDatabaseFiles -Id $sourcedb.id -RecoveryDateTime $srcRecoveryDateTime |Select-Object LogicalName,@{n='exportPath';e={$_.OriginalPath}},@{n='newFileName';e={$_.OriginalName}}
                    }
                }catch{Write-Warning -Message "$($targetdb.latestRecoveryPoint) is not recoverable";continue}
            }else{
                Write-Verbose "Using file path [$TargetDataFilePath] and [$TargetLogFilePath] for [$db]"                
                try{$sourcefiles = Get-RubrikDatabaseFiles -Id $sourcedb.id -RecoveryDateTime $srcRecoveryDateTime |Select-Object LogicalName,@{n='exportPath';e={if($_.fileType -eq "Data"){$TargetDataFilePath}else{$TargetLogFilePath}}},@{n='newFileName';e={$_.OriginalName}}
                }catch{Write-Warning -Message "$srcRecoveryDateTime is not recoverable"; continue}
            }

            #if not AG, Export the database
            if ($isAG -eq $False ){
                try{
                $Result = Export-RubrikDatabase -Id $sourcedb.id `
                        -TargetInstanceId $target.instanceId `
                        -TargetDatabaseName $sourcedb.name `
                        -recoveryDateTime $srcRecoveryDateTime `
                        -FinishRecovery:$FinishRecovery `
                        -Overwrite `
                        -TargetFilePaths $sourcefiles `
                        -Confirm:$false
                }catch{$_}
            }
            #if AG, remove DB of AG, setup Logshipping, add the DB back to AG and remove Logshipping
            else{
                #check if the database is part of AG on Target server, if so, remove the db from AG
                if ($targetdb.isInAvailabilityGroup -eq $True){
                    $Replica = @()
                    $primary = @()
                    $primary=$target | Where-Object {$_.role -eq "PRIMARY"}

                    #Removing DB of Primary replica
                    if($primary){
                        Write-Verbose "Removing  [$db] of AG [$TargetServerInstance] NODE [$($primary.rootName)]"
                        Try{                                    
                            Remove-SqlAvailabilityDatabase -Path "SQLSERVER:\Sql\$($primary.rootName)\$($primary.instanceName.replace("MSSQLSERVER","DEFAULT"))\AvailabilityGroups\$($TargetServerInstance)\AvailabilityDatabases\$db"
                        }CATCH{Write-Warning -Message "Could not remove the database [$db] of AG [$TargetServerInstance] - node $($primary.rootName) - Message: $_"; break}                        
                    }

                    FOREACH($Replica in $target | Sort-Object Role -Descending)
                    {                                   
                        try{
                            Write-Verbose "Exporting database [$db] to node [$($Replica.rootName)] - AG [$TargetServerInstance]"
                            $RubrikRequest = @()
                            $RubrikRequest = Export-RubrikDatabase -Id $sourcedb.id `
                                            -TargetInstanceId $replica.instanceId `
                                            -TargetDatabaseName $sourcedb.name `
                                            -recoveryDateTime $srcRecoveryDateTime `
                                            -Overwrite `
                                            -TargetFilePaths $sourcefiles `
                                            -Confirm:$false
                                    
                            $Replica.RubrikRequest = $RubrikRequest

                        }catch{$_}
                    }
                    #wait for Export completion for all nodes
                    foreach($Replica in $target | Sort-Object Role )
                    {
                        Get-RubrikRequestInfo -RubrikRequest $Replica.RubrikRequest
                    }

                    #Adding database back to AG
                    $Replica = @()
                    foreach($Replica in $target | Where-Object role -eq "Primary")
                    {
                        if($Replica.role -eq "PRIMARY"){
                            Write-Verbose "Setting $($DB) to RECOVERY on $($Replica.rootName)\$($Replica.instanceName)"
                            $Query = "RESTORE DATABASE [$db] WITH RECOVERY;"                                
                            Invoke-Sqlcmd -ServerInstance $("$($Replica.rootName)\$($Replica.instanceName)").Replace("\MSSQLSERVER","") -Database "master" -Query $Query
                        }
                        Write-Verbose "Adding $($DB) to $($TargetServerInstance) on $($Replica.rootName)\$($Replica.instanceName)"
                        try{
                            Add-SqlAvailabilityDatabase -Path "SQLSERVER:\Sql\$($Replica.rootName)\$($Replica.instanceName.replace("MSSQLSERVER","DEFAULT"))\AvailabilityGroups\$($TargetServerInstance)" -Database $db
                        }catch{$_}
                    }
                }else{Write-Warning -Message "The database [$db] is not part of AG [$TargetServerInstance]!!!"; continue}
            }    
        }
    }
}