# Xenserver-UpdateScript
# V 0.9.7
# 03.12.2012
# written by Maikel Gaedker (maikel@gaedker.de)
# rewrited by yoke88 (yoke-msn@hotmail.com) at 2014/09/05 using xen server powershell sdk 6.2
# Updates XenServer with all patches available within a defined path
# Requirements: PowerShell v2.0; XenServerPSSnapIn

$servers = (Read-Host "Enter each XS to patch (separate with comma)").split(',') | % {$_.trim()}
$SecureString = read-host "Enter root-password" -asSecureString
$password = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString))
$Scriptfolder=split-path $myinvocation.mycommand.path
$isToolsOk=$false
$updatepath="$Scriptfolder\updates"
$global:xe=""
function checkForPSSnapins (){
	Write-Host "Verifying PowerShell snapin..."
	#Check if the snapin is installed AND registered properly.
	if(Get-PSSnapin "XenServerPSSnapIn" -Registered -ErrorAction SilentlyContinue){
		#If the snapin is not loaded, load it.
		if (!(Get-PSSnapin "XenServerPSSnapIn" -ErrorAction SilentlyContinue)){
			Write-Host "-- Loading XenServerPSSnapIn."
			Add-PSSnapin XenServerPSSnapIn
		}else{
           Write-Host "-- Loaded XenServerPSSnapIn." 
        }
        return $true
	}
	else{
		Write-Host "-- Citrix XenServerPSSnapIn is not installed/registered on this machine."
        Write-Host "-- Download The XenServer SDK for PowerShell from: http://www.community.citrix.com/cdn/xs/sdks"
		Write-Host "-- Script will now exit."
		return $false
	}
}


#Check Xe tool path

    if(test-path "$Scriptfolder\xe.exe"){
        $xe="$Scriptfolder\xe.exe"
    }

    if($env:PROCESSOR_ARCHITECTURE -eq "AMD64"){
        $xePath="$(${env:ProgramFiles(x86)})\Citrix\XenCenter\xe.exe"
        
    }else{
        $xePath="$($env:ProgramFiles)\Citrix\XenCenter\xe.exe"
    }

    if(test-path $xePath){
        $xe=$xepath
    }

    if(test-path $xe){
		$isXeExist=$true
	}else{
		$isXeExist=$false
	}


function checkConnect (){
	$maxTries = 1000
	$i = 0
	do {start-sleep 30;$i++} while ((! (test-connection -computername $server -count 1 -EA SilentlyContinue)) -and $i -lt $maxTries)
}

if(checkForPSSnapins -and $isXeExist){
    $isToolsOk=$true
}

"XE Path was :$global:xe"
$isNeedUpdate=$false
if(test-path "$scriptfolder\updates.xml"){
    $updatefileLastCreateDate=(Get-ChildItem "$scriptfolder\updates.xml").CreationTime
    if(($updatefileLastCreateDate -[datetime]::Now).Days -gt 15){
        $isNeedUpdate=$true
    }
}else{
    $isNeedUpdate=$true
}

if($isNeedUpdate){
    if(test-path "$scriptfolder\updates.xml"){
        Remove-Item "$scriptfolder\updates.xml" -Force
    }
    Invoke-WebRequest -uri http://updates.xensource.com/XenServer/updates.xml -OutFile "$scriptfolder\updates.xml"
}

$orderedUpdates=@()

$updateXML=[xml](get-content "$scriptfolder\updates.xml")
Get-ChildItem $updatepath\*.xsupdate|%{
    $namelabel=$_.name.Split(".")[0]
    $updateInXml= $objUpdate=$updateXML.SelectSingleNode("//patch[@name-label='$namelabel']")
    $objupdate=New-Object psobject
    $objupdate|Add-Member -MemberType NoteProperty -Name name -Value $namelabel
    $objupdate|Add-Member -MemberType NoteProperty -Name ReleaseDate -Value ([datetime]$updateInXml."timestamp")
    $objupdate|add-member -MemberType NoteProperty -Name filepath -Value $_.FullName
    $orderedUpdates+=$objUpdate
}

$orderedUpdates=$orderedUpdates|Sort-Object -Property releasedate

write-host "value2:$isToolsOk"
# 
#Start Script
#
if($isToolsOk){
    write-host "tools ok"
    foreach ($server in $servers) 
    {
        $updateStatus=@()
        $VMforceShutdown=@()
        $session=Connect-XenServer -server $server -username root -password $password -nowarncertificates -PassThru -SetDefaultSession
        $myhost=get-xenhost -ref $session.get_this_host()
        write-host "$server will be patched; running VMs will be suspend" -foregroundcolor "green" 
	    write-host "=======================================================" 
        #eject mounted iso from vms.

	    $allruningVm=Get-XenVM | Where-Object {!$_.is_a_template  -and !$_.is_control_domain  -and $_.power_state -eq 'Running'} 
        Get-XenVBD|?{$_.type -eq 'cd' -and $_.vdi -ne 'OpaqueRef:NULL' -and $_.currently_attached}|invoke-xenvbd -XenAction Eject

        # suspend Running vms
        $allruningVm|%{
            #suspend VM
            write-host "VM $($_.name_label) will be suspend"
            $VM=$_
            try{
                Invoke-XenVM -vm $VM -XenAction Suspend
            }catch [exception ]
            {
                write-host "suspend VM $($vm.name_label) fail" -ForegroundColor Red
                write-host "shutdown vm $($vm.name_label) "
                invoke-xenvm -vm $VM -XenAction HardShutdown
                $VMforceShutdown+=$VM
            }
        }
        write-host "Server $($myhost."name_label") will enter maintenance mode" -foregroundcolor "green" 

        # enter maintence mode
        Invoke-XenHost -XenHost $myhost -XenAction Disable

        foreach ($update in $orderedUpdates)
        { 
        #check whether update has been applied 
        $mystatus=New-Object psobject
        $mystatus|Add-Member -MemberType NoteProperty -Name Name -Value $update.name
        $mystatus|Add-Member -MemberType NoteProperty -Name StatusBefore -Value ""
        $mystatus|Add-Member -MemberType NoteProperty -Name StatusAfter -Value ""
        $poolpatch=$null
        try{    
            $poolpatch=Get-XenPoolPatch -Name $update.name -ErrorAction SilentlyContinue
        }
        catch [exception ]
        {
            #do nothing
        }
        
        if($poolpatch){
            $hostPatch=Get-XenHostPatch -Ref $poolpatch.host_patches[0]

            if($hostPatch.applied){
                $mystatus.StatusBefore="Applied"
                $mystatus.StatusAfter="Applied"
                Write-Host "$($update.name) has been applied ,skip."
            }else{
                #apply host patch
                Invoke-XenHostPatch -ref $hostPatch -XenAction Apply 
                $mystatus.StatusBefore="Uploaded"
                $mystatus.StatusAfter="Applied"
            }
        }else{
            
            #upload patch
            write-host "$($update.filepath) will be uploaded" -foregroundcolor "green"
            ### This is the only step not implemented in XenServer SDK so far
	        $uuid_patch=& "$xe" -s $server -u root -pw $password patch-upload file-name=$($update.filepath)
            write-host "$($update.filepath) upload successfull,the update uuid: $uuid_patch" -ForegroundColor "green"
            # apply patch
			if($uuid_patch){
            $poolpatch=Get-XenPoolPatch -Uuid $uuid_patch
            Invoke-XenPoolPatch -ref $poolpatch -XenAction Apply -XenHost $myhost
            $mystatus.StatusBefore="NotUploaded"
            $mystatus.StatusAfter="Applied"
            write-host "$($update.name) applied" -ForegroundColor "green"
			}
        }
        $updateStatus+=$mystatus
	    write-host "======================================================="
        
	    }

        
        if($updateStatus|?{$_.StatusBefore -ne "Applied"}){
            write-host "reboot server $($myhost.name_label) now  and wait for up....."
            Invoke-XenHost -XenHost $myhost -XenAction Reboot 
	        checkConnect
            $session=Connect-XenServer -server $server -username root -password $password -nowarncertificates -PassThru -SetDefaultSession
            $myhost=get-xenhost -ref $session.get_this_host()
        }

        Invoke-XenHost -XenHost $myhost -XenAction Enable
        Get-XenVM |Where-Object {!$_.is_a_template  -and !$_.is_control_domain  -and $_.power_state -eq 'Suspended'} |%{
            write-host "resume VM $($_.name_label)"
            invoke-xenvm -XenAction Resume -Ref $_ -Async
            }
        $VMforceShutdown|%{
            invoke-xenvm -ref $_  -XenAction Start -Async
        }
        Disconnect-XenServer -Session $session
        
        write-host "Update Summary of the server $($myhost.name_label)" -foregroundcolor "green" 
        write-host "======================================================="
        $updatestatus|ft * -AutoSize
    }
}