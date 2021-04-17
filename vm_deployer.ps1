param(
    [parameter(Mandatory=$true)]
    [string[]]$hostnames  
)

#create objects via function because a few are the same format
function build-object {
    param($var,$count)

    for($i = 0; $i -lt $count; $i++){
        [pscustomobject]@{
            Number = $i
            Name   = $var[$i]
        }
    }
}

$vcenterfolder = "Folder-group-v17"
$vcenterip     = "192.168.1.1"

import-module vmware.vimautomation.core -WarningAction SilentlyContinue -erroraction SilentlyContinue  | out-null
set-PowerCliConfiguration -InvalidCertificateAction Ignore -Confirm:$false | out-null

Connect-VIServer $vcenterip -Credential (Get-Credential -message "Enter Password" -UserName administrator@vsphere.local -erroraction SilentlyContinue) -erroraction SilentlyContinue | out-null

#set up a few menu choices
$cluster = (get-cluster).name
$folder  = (get-folder | where{$_.parentid -eq $vcenterfolder}).name
$temp    = (get-template).name

#hastable to iterate through
$list = @{
    cluster = $cluster
    folder  = $folder
    temp    = $temp
}

#build our menu options and select choices.
foreach($l in $list.keys){

    #dynamic variable creation (2spooky4me)
    Remove-Variable -name $str -ErrorAction SilentlyContinue | out-null
    
    $str = $l + "_built"
    New-Variable -Name $str -Value @(build-object -var @($list[$l]) -count $list[$l].count)

    $a = get-variable -name $str -ValueOnly

    #menu and select
    cls
    write-host "Choose A " (Get-Culture).TextInfo.ToTitleCase($l)
    write-output $a | ft -AutoSize
    
    $choice = Read-Host -prompt "Enter The Number You Want To Choose"
    cls

    $str2 = $str + "_choice"
    Remove-Variable -name $str2 -ErrorAction SilentlyContinue | out-null
    new-variable -name $str2 -value (((Get-Variable -Name $str).Value | where{$_.number -eq $choice}).name)
}

#get hosts based on cluster and get the current usage.
$host_built = $(foreach($c in (Get-Cluster $cluster_built_choice | Get-VMHost)){
    [pscustomobject]@{
        Name = $c.name
        CPU  = ([math]::round(($c.CpuTotalMhz - $c.CpuUsageMhz),0))
        RAM  = ([math]::round(($c.MemoryTotalGB - $c.MemoryUsageGB),0))
    }
}) | sort ram -Descending | ForEach-Object{$i = 0}{
    [pscustomobject]@{
        Number      = $i
        Name        = $_.name
        Free_CPU    = $_.cpu
        Free_RAM    = $_.ram
        }
    ++$i
}

Write-host "Choose a Host"
Write-Output $host_built | ft -AutoSize
$host_built_choice = ($host_built[$(read-host -Prompt "Enter The Number You Want To Choose")].name)
cls

#system resources
$memory = $null
while(!($memory)){
    try{
        cls
        [int]$memory = read-host -Prompt "Enter Amount Of RAM As Gigabyte, Number Only."
    }catch{}
}

$cpu = $null
while(!($cpu)){
    try{
        cls
        [int]$cpu = read-host -Prompt "Enter Amount Of CPU, Number Only."
    }catch{}
}

$coreoptions = $(for($i = 1; $i -le $cpu; $i++){
    if($cpu % $i -eq 0){
        if($($cpu / $i) -le 4){
            [pscustomobject]@{
                Core   = $cpu / $i
                Socket = $i
            }
        }
    }
}) | ForEach-Object{$i = 0}{
    [pscustomobject]@{
        Number = $i
        Core   = $_.core
        Socket = $_.socket
    }
    ++$i
}

cls
write-host "Core And Socket Count"
Write-output $coreoptions | ft -AutoSize
$core_choice = Read-Host -Prompt "Choose The Core And Socket Count"
cls

write-host "Finding DataStores..."
$datastore = Get-Datastore | where{$_.ExtensionData.host.key -eq (get-vmhost $host_built_choice).Id} | sort freespacegb -Descending | select -first 10
cls

$datastore_built = for($i = 0; $i -lt $datastore.count; $i++){
    [pscustomobject]@{
        Number = $i
        Name   = $datastore[$i].name
        Size   = [math]::round($datastore[$i].freespacegb,0)
    }
}

write-host "Choose A Datastore"
write-output $datastore_built | ft -AutoSize

$choice = Read-Host -prompt "Enter The Number You Want To Choose"
cls
$datastore_built_choice = ($datastore_built | where{$_.number -eq $choice}).name

foreach($h in $hostnames){

    $gobuild = ""
    while("y" -notcontains $gobuild){
    
        cls
        read-host -Prompt "Press Enter To Configure $h"

        #disk count
        $diskcount = $null
        while(!($diskcount)){
            try{
                cls
                [int]$diskcount = read-host -Prompt "How Many Disks Do You Need In Addition To The C Drive?"
                
                if($diskcount -lt 1){
                    break
                }
            }catch{}
        }

        Get-Variable -Name "disk_$($h)_*" -ErrorAction SilentlyContinue | %{remove-variable $_.name}

        #create variables, use [char] to increment a letter so you see C, D drive.
        for($i = 1; $i -le $diskcount; ++$i){
            cls
            New-Variable -Name "disk_$($h)_$i" -Value (read-host -Prompt "Enter The Size of Your $([char](67 + $i)) Drive")
            cls
        }
    
        #build an object so we can check out settings before we deploy.
        $buildspecs = [pscustomobject]@{
            Name      = $h
            Cluster   = $cluster_built_choice
            DataStore = $datastore_built_choice
            Folder    = $folder_built_choice
            Template  = $temp_built_choice
            Host      = $host_built_choice
            RAM       = $memory
            CPU       = $cpu
            Core      = $coreoptions[$core_choice].Core
        }
    
        #add disks dynamically because there can be any number.
        $diskvarcount = (get-variable "disk_$($h)_*").count
        for($i = 1; $i -le $diskvarcount; $i++){
            $buildspecs | add-member -MemberType NoteProperty -Name "Disk_$($h)_$i" -Value $((get-variable "disk_$($h)_$i").value)
        }
    
        write-output $buildspecs | ft -autosize -Property *
        $gobuild = ""
        $gobuild = read-host -Prompt "Are The Build Spec's Correct? Y or N"
        cls

        #switch on check, restart the while if we see anything but y.
        switch($gobuild){
            Y      {break}
            N      {continue}
            Default{continue}
        }
    }

    #deploy VM based on the settings, run async for multiple deployments.
    $newvm = new-vm -Template $temp_built_choice `
        -VMHost $(get-vmhost $host_built_choice) `
        -Name $h `
        -Location $(get-folder $folder_built_choice | where{$_.parentid -eq $vcenterfolder}) `
        -Datastore $(Get-Datastore $datastore_built_choice) `
        -DiskStorageFormat Thin `
        -Confirm:$false `
        -RunAsync `
}

#wait for the deployment to finish all vms
while(Get-Task | where {$_.name -eq "CloneVM_Task" -and $_.state -eq "Running"}){
    start-sleep -Seconds 5
}

for($h = 0; $h -lt ($hostnames).Count; $h++){
    
    write-host "Configuring " $hostnames[$h]
    
    #get vm for config tasks
    $vm = get-vm $hostnames[$h]

    #create the disk start at index 1 as to not recreate the c drive sized disk
    for($i = 1; $i -le (Get-Variable "disk_$($hostnames[$h])_*").count; $i++){
        
        [void](New-HardDisk -VM $vm -DiskType Flat -CapacityGB (Get-Variable "disk_$($hostnames[$h])_$i").Value -StorageFormat Thin -Datastore $buildspecs.datastore -Confirm:$false -WarningAction SilentlyContinue | out-null)
            
        if($i -eq (Get-Variable "disk_$($hostnames[$h])_*").count){
            continue
        }else{
            while(Get-Task | where {$_.name -eq "ReconfigVM_Task" -and $_.state -eq "Running" -and $_.ObjectId -eq $vm.Id}){
                start-sleep -Seconds 5
            }
        }
    }
    
    #set vm resources
    set-vm -VM $vm -MemoryGB $buildspecs.ram -NumCpu $buildspecs.cpu -Confirm:$false -RunAsync | out-null

    $spec = new-object -typename vmware.vim.virtualmachineconfigspec -Property @{"NumCoresPerSocket" = $buildspecs.core}
    ($vm).extensiondata.reconfigvm_task($spec) | out-null
}

while(Get-Task | where {$_.name -eq "ReconfigVM_Task" -and $_.state -eq "Running"}){
    start-sleep -Seconds 5
}

#start the vm 
try{
    $start = $hostnames | %{ start-vm -VM $_ -Confirm:$false -RunAsync | out-null}
}catch{}