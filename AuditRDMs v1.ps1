#=====================================================================#
#   SCRIPT:     AuditRDMs v1.ps1                                      #
#   CREATED:    11/06/2018                                            #
#   AUTHOR:     David Quinlisk - Hewlett Packard Enterprise           #
#   VERSION:    v1.0                                                  #
#   Notes:    - PowerCLI needs to be installed.                       #
#             - Further Information: https://kb.vmware.com/kb/1016106 #
#   Tested:   - PowerCLI v10 & Powershell v4 or later                 #
#             - Further Information: https://kb.vmware.com/kb/1016106 #
#=====================================================================#
#   CHANGE LOG:                                                       #
#   v1.0 - Initial Release                                            #
#=====================================================================#
$scriptversion = "v1.0"
#=====================================================================#

$UIControl = (Get-Host).UI.RawUI
$UIControl.WindowTitle = "RDM Audit Script " + $scriptversion

clear
Write-Host "AIX2WIN " -foregroundcolor red -nonewline
Write-Host "Raw Device Mapping(RDM) Audit Script " $scriptversion
Write-Host ""
Write-Host "Please connect to the Computacenter vCenter required, the following are two examples for reference:"
Write-Host "1. (UK-Hatfield) ukentvicp20.computacenter.com"
Write-Host "2. (DE-Frankfurt) deentvicp20.computacenter.com"
Write-Host ""
$strVCServer = Read-Host "Type FQDN for vCenter Server"
$strVCUser = Read-Host "Type Username for vCenter"
$secVCPass = Read-Host "Type Password for vCenter" -AsSecureString
$secVCCred = New-Object System.Management.Automation.PSCredential -ArgumentList $strVCUser,$secVCPass

Connect-VIServer $strVCServer -Credential $secVCCred | out-null

Write-Host "Currently connected to vCenter:" -NoNewline
Write-Host $strVCServer
Write-Host ""
Write-Host "The following clusters are available on this vCenter:"
Get-Cluster
Write-Host ""
$strVCCluster = Read-Host "Please type the cluster name that you would like to validate"
Write-Host ""
Write-Host "This script will now gather the RDMs active on the vSphere cluster: " -NoNewline
Write-Host $strVCCluster -ForegroundColor Red
Write-Host ""
pause
$VMCluster = Get-Cluster $strVCCluster
$VMHosts = $VMCluster | Get-VMHost

# Declarations
$ActiveCanonNames = $null
$ReservedCanonNames = $null
$ActiveCanonNames = @()
$ReservedCanonNames = @()
$allReservedCanonNames = $null
$allCanonNamesToAdd =  $null
$allCanonNamesToRemove =  $null
$allReservedCanonNames = @{}
$allCanonNamesToAdd = @{}
$allCanonNamesToRemove = @{}

#Get List A - RDM's Currently In Use on Cluster
#Input $VMCluster / Array of Objects
#Output $ActiveCanonNames / Array
Write-Host "Generating list of RDMs assigned to Virtual Machines..."
$ActiveCanonNames = $VMCluster | Get-VM | Get-HardDisk -DiskType RawPhysical | Select ScsiCanonicalName
$ActiveCanonNames = $ActiveCanonNames.ScsiCanonicalName
$ActiveCanonNames = $ActiveCanonNames | select -Unique

#Get List B - All RDM's Currently Reserved on Host
#Input > $VMhosts / Array of Objects
#Output > $allReservedCanonNames / Hash Table
Write-Host "Generating list of already reserved RDMs assigned to Hosts..."

foreach ($VMhost in $VMhosts) {
        $esxcli = Get-EsxCli -VMHost $VMhost
        $strVMhost = $VMhost.Name
        $ReservedCanonNames = $esxcli.storage.core.device.list() | Where IsPerenniallyReserved -EQ "TRUE" | Select Device
        $strReservedCanonNames = $ReservedCanonNames.Device
        $strReservedCanonNames = $strReservedCanonNames | select -Unique
        $allReservedCanonNames.$strVMhost = @()
        #Add Host Name and associated Canon names to Hash Table
        foreach ($ReservedCanonName in $strReservedCanonNames) {
            $allReservedCanonNames.$strVMhost += $ReservedCanonName
        }
    }

#Get List C - RDM's that are active on host and not currently reserved
#Input > $allReservedCanonNames / Hash Table
#Output > $allCanonNamesToAdd / Hash Table
foreach ($hostinCanonFile in $allReservedCanonNames.Keys) {
    $hostCanonNamesToAdd = compare-object $ActiveCanonNames $allReservedCanonNames.$hostinCanonFile -PassThru | where SideIndicator -EQ "<=" # Output list of active naa.ID's to reserve.
    $allCanonNamesToAdd.$hostinCanonFile = @()
    foreach ($hostCanonNameToAdd in $hostCanonNamesToAdd) {
        $allCanonNamesToAdd.$hostinCanonFile += $hostCanonNameToAdd
    }
}

#Get List D - RDM's that are not active on cluster but are currently reserved
#Input > $allReservedCanonNames / Hash Table
#Output > $allCanonNamesToRemove / Hash Table
foreach ($hostinCanonFile in $allReservedCanonNames.Keys) {
    # Output list of reserved naa.ID's to remove as they are not in use.
    $hostCanonNamesToRemove = compare-object $ActiveCanonNames $allReservedCanonNames.$hostinCanonFile -PassThru | where SideIndicator -EQ "=>"
    # Add output to Hast Table for use later.
    $allCanonNamesToRemove.$hostinCanonFile = @()
    foreach ($hostCanonNameToRemove in $hostCanonNamesToRemove) {
        $allCanonNamesToRemove.$hostinCanonFile += $hostCanonNameToRemove
    }
}

     
#Create Reservation
foreach ($VMhost in $allCanonNamesToAdd.Keys) {
    $esxcli = Get-EsxCli -VMHost $VMhost
    clear
    Write-Host ""
    Write-Host "The current ESXi host (" -NoNewline
    Write-Host $VMhost -ForegroundColor Red -NoNewline
    Write-Host ") is about to set the perennially reserved status on Physical RDM disks that currently do not have it set."
    Write-Host ""
    Write-Host ""
    Write-Host "This round contains " -NoNewline
    Write-Host $allCanonNamesToAdd.$VMHost.Count -ForegroundColor Red -NoNewline
    Write-Host " RDMs that do not have Perennial Reservations. Hit any key to begin reservations:"
    Write-Host ""
    pause
    $progressCount = 0
    foreach ($CurrentCanonName in $allCanonNamesToAdd.$VMhost) {
        $esxcli.storage.core.device.setconfig($false, $CurrentCanonName, $true) | out-null
        $progresscount++
        Write-Host "Adding reservation for the canonical name: " -NoNewline
        Write-Host $CurrentCanonName -ForegroundColor Red -NoNewline
        Write-Host " (" -NoNewline
        Write-Host $progresscount -ForegroundColor Red -NoNewline
        Write-Host " of " -NoNewline
        Write-Host $allCanonNamesToAdd.$VMhost.Count -ForegroundColor Red -NoNewline
        Write-Host ")"
        $CurrentCanonName = $null
    }
}


#Remove Reservation
foreach ($VMhost in $allCanonNamesToRemove.Keys) {
    $esxcli = Get-EsxCli -VMHost $VMhost
    clear
    Write-Host ""
    Write-Host "The current ESXi host (" -NoNewline
    Write-Host $VMhost -ForegroundColor Red -NoNewline
    Write-Host ") is about to remove the perennially reserved status on Physical RDM disks that currently are not assigned to any Virtual Machines."
    Write-Host ""
    Write-Host ""
    Write-Host "This round contains " -NoNewline
    Write-Host $allCanonNamesToRemove.$VMhost.Count -ForegroundColor Red -NoNewline
    Write-Host " RDMs that have Perennial Reservations but are not assigned to Virtual Machines. Hit any key to remove reservations:"
    Write-Host ""
    pause
    $progressCount = 0
        foreach ($CurrentCanonName in $allCanonNamesToRemove.$VMhost) {
        $esxcli.storage.core.device.setconfig($false, $CurrentCanonName, $false) | out-null
        $progresscount++
        Write-Host "Removing reservation for the canonical name: " -NoNewline
        Write-Host $CurrentCanonName -ForegroundColor Red -NoNewline
        Write-Host " (" -NoNewline
        Write-Host $progresscount -ForegroundColor Red -NoNewline
        Write-Host " of " -NoNewline
        Write-Host $allCanonNamesToRemove.$VMhost.Count -ForegroundColor Red -NoNewline
        Write-Host ")"
        $CurrentCanonName = $null
    }
}

Disconnect-VIServer -Confirm:$false
clear
Write-Host "Disconnected from vCenter, Thank you for utilising this script. Goodbye."