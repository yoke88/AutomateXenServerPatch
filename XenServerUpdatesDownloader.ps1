$Scriptfolder=split-path $myinvocation.mycommand.path
$updatesFolder="$scriptfolder\updates"
$alertsCsvPath="$scriptfolder\alerts.csv"


function Expand-ZIPFile($file, $destination,$filter="*.xsupdate")
{
    $shell = new-object -com shell.application
    $zip = $shell.NameSpace($file)
    $items=$zip.Items()|?{$_.name -like $filter}
    foreach($item in $items)
    {
        if(test-path "$destination\$($item.name)"){
        }else{
            $shell.Namespace($destination).copyhere($item)
        }
    }
}

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

if(!(test-path $updatesFolder)){
    mkdir $updatesFolder -force
}

$updateXML=[xml](get-content "$scriptfolder\updates.xml")
$allupdates=@()
$alertsCsv=Import-Csv $alertsCsvPath

$alertsCsv|?{$_.Title.startswith("New Update Available -") }|%{
    $namelabel=$_.Title.split("-")[1].trim()
    #seachUpdate
    $objUpdate=$updateXML.SelectSingleNode("//patch[@name-label='$namelabel']")

    if($objUpdate){
     $allupdates+=$objUpdate
    }else{

        Write-Error "can not found the Patch $namelabel" 
    }

}

# download-file
#Invoke-WebRequest -Uri $PatchdownloadUrl -OutFile "$updatesFolder\$filename"
# unzip file
#Expand-ZIPFile -file "$updatesFolder\$filename" -destination $updatesFolder

$selectedUpdates=$allupdates|Out-GridView -PassThru
$selectedUpdates|%{
    $filename=$_."patch-url".split("/")[-1].trim()
    if(!(test-path "$updatesFolder\$filename")){
        Invoke-WebRequest -Uri $_."patch-url"  -OutFile "$updatesFolder\$filename"
    }
    Expand-ZIPFile -file "$updatesFolder\$filename" -destination $updatesFolder
    
}