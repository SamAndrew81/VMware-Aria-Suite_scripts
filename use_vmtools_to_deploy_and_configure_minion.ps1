# PowerShell
function handler($context, $inputs) {
  <#--- Set vCenter Connection Variables ---#>
  $vcServer = "10.206.240.100"   # Enter vCenter IP or FQDN here between the double-quotes
  $vcUsername = "administrator@vsphere.local"     # Different vCenter user can be specified, admin rights in vSphere required
  $vcPassword = $context.getSecret($inputs.vcPassword)  # Must use encrypted SECRET in vRA here
  write-host "${vcServer}: " $vcServer
  write-host "${vcUsername}: " $vcUsername
 
  <#--- Set SaltStack Connection Variables ---#>
  $salt_master = "10.225.0.237"                  # Enter SaltStack Config master IP or FQDN here
  $saltUsername = "root"
  $saltPassword = $context.getSecret($inputs.saltPassword)     # Must use encrypted SECRET in vRA here
  $salt_userpass = $saltUsername + ":" + $saltPassword
  $base64encoded = [Convert]::ToBase64String([Text.Encoding]::Utf8.GetBytes($salt_userpass))
  $salt_base64Auth = "Basic $base64encoded"
  $global:xsrfTokenRequest = $null
  write-host "${salt_master}: " $salt_master
  write-host "${saltUsername}: " $saltUsername
  
# NOTHING AFTER THIS LINE GETS CUSTOMIZED   
  
  if($inputs.resourceName -eq $null) {
      write-host "Triggered from a subscription"
      $VMName = $inputs.resourceNames[0]
  } else {
      write-host "Triggered from Day-2 action"
      $VMName = $inputs.resourceName
  }

  function Set-MinionSettings {
    $vm = get-VM -Name $VMName
    $salt_minion_id = $VMName.ToLower()
    New-AdvancedSetting -Entity $vm -Name "guestinfo./vmware.components.salt_minion.args" -Value "master=$salt_master id=$salt_minion_id" -Confirm:$false -Force
    New-AdvancedSetting -Entity $vm -Name "guestinfo./vmware.components.salt_minion.desiredstate" -Value "present" -Confirm:$false -Force
  }

  function Get-MinionInstallStatus {
    $vm = get-VM -Name $VMName
    $timeOut = 800
    $sleepIntervall = 30
    $retryCounter = 0
    
    <#Loop until laststatus confirms the minion registration
      100 - Installed
      101 - Installing
      102 - Not Installed
      103 - Install Failed
      104 - Removing
      105 - Removing Failed
      126 - Script Failed
      130 - Script Terminated
    #>
    
    DO
    {
    write-host "Checking Last Status"
    $lastStatus = Get-AdvancedSetting -Entity $vm -Name guestinfo.vmware.components.salt_minion.laststatus
    if($lastStatus.value -eq $null)
        {
            write-host "Last Status is null, sleeping for 60 seconds"
            Start-Sleep -Seconds 60
        }
        elseif($lastStatus.value -eq 100)
        {
            write-host "Minion Installed"
        }
        elseif($lastStatus.value -eq 101)
        {
            write-host "Installing Minion, sleeping for 15 seconds"
            Start-Sleep -Seconds 15
        }
        elseif($lastStatus.value -eq 102)
        {
            write-host "Minion Not Installed, sleeping for 15 seconds"
            Start-Sleep -Seconds 15
        }
        elseif($lastStatus.value -eq 103)
        {
            write-host "Minion Deployment Failed"
            Throw "Minion Deployment Failed"
        }
        elseif($lastStatus.Value -eq 130)
        {
            write-host "Restart VM"
            Restart-VM -VM $vm -Confirm:$false
            Start-Sleep -Seconds 60
        }
        else
        {
            write-host "Status: " $lastStatus.value
            Start-Sleep -Seconds 15
        }
    $retryCounter = $retryCounter + $sleepIntervall
    if($retryCounter -gt $timeOut) {break}
    } Until ($lastStatus.Value -eq 100)
}

  function Get-LastToolsMinionStatus {
  $connect = Connect-VIServer $vcServer -User $vcUsername -Password $vcPassword -Protocol https -Force
  $vm = get-vm -Name $VMName
  
  $lastStatus = Get-AdvancedSetting -Entity $vm -Name guestinfo.vmware.components.salt_minion.laststatus
  if($lastStatus.value -ne $null){write-host "Last Status: " $lastStatus.value}
  }
  
  function Disconnect-vCenter {
  $disconnect = disconnect-VIServer -Server $connect -Force -Confirm:$false
  Write-Host "Diconnected from Server $Server"
  }
  
  function Get-AriaConfigStatus {
  <#--- Setup headers and connect to receive a X-Xsrftoken ---#>
  $Headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
  $Headers.Add("Authorization", $salt_base64Auth)
  do {
        $xsrfTokenRequest = Invoke-WebRequest https://$salt_master/version -Method 'GET' -Headers $Headers -SkipCertificateCheck -SkipHttpErrorCheck -MaximumRetryCount '1000' -RetryIntervalSec '15'
        #Write-Host "xsrf request StatusCode: " $xsrfTokenRequest.StatusCode
       } while (($xsrfTokenRequest.StatusCode -ne '200'))
       Write-Host "Exiting loop, Aria Automation Config returned 200 success"
  }
  
  function Get-JobStatus ($jid,$headers) {
    Write-Host "Entering Get-JobStatus function"
    Write-Host "input1: " $jid
    Write-Host "input2: " $headers
    #Write-Host "Connecting to: " $salt_master
    $jobStatusResponse = $null
    $jobStatusBody = "{ `"resource`": `"cmd`", `"method`": `"get_cmds`", `"kwarg`": { `"jid`":`"$jid`"}}"
    #$jobStatusBody = "{ `"resource`": `"cmd`", `"method`": `"get_cmd_details`", `"kwarg`": { `"jid`":`"$jid`"}}"
    Write-Host "Checking https://$salt_master/rpc -Method 'POST' -Headers $headers -Body $jobStatusBody -SkipCertificateCheck"
    do {
        $jobStatusResponse = Invoke-RestMethod https://$salt_master/rpc -Method 'POST' -Headers $headers -Body $jobStatusBody -SkipCertificateCheck
        Write-Host "Job " $jid " "$jobStatusResponse.ret.results.state
        #$jobStatusResponse.ret.count -eq '0'
        #Write-Host "Job " $jid " for " $jobStatusResponse.ret.results.minion_id " has completed: " $jobStatusResponse.ret.results.has_return
        Start-Sleep -s 5
       } while (($jobStatusResponse.ret.results.state -eq 'new') -or ($jobStatusResponse.ret.results.state -eq 'retrieved'))
       Write-Host "Job has returned: " $jobStatusResponse.ret.results.state 
  }
  
  function Get-MasterKeyState ($masterKeyHeaders) {
    Write-Host "Entering Get-MasterKeyState function"
    Write-Host "input1: " $masterKeyHeaders
    Write-Host "Connecting to: " $salt_master
    $masterKeyResponse = $null
    $masterKeyBody = "{ `"resource`": `"master`", `"method`": `"get_master_keys`", `"kwarg`": { `"state`":`"accepted`"}}"
    Write-Host "Checking https://$salt_master/rpc -Method 'POST' -Headers $masterKeyHeaders -Body $masterKeyBody -SkipCertificateCheck"
    do {
        $masterKeyResponse = Invoke-RestMethod https://$salt_master/rpc -Method 'POST' -Headers $masterKeyHeaders -Body $masterKeyBody -SkipCertificateCheck
        Write-Host "Master Key State is: " $masterKeyResponse.ret.state
        Start-Sleep -s 5
       } while ($masterKeyResponse.ret.state -ne 'accepted')
       Write-Host "Master Key State: " $masterKeyResponse.ret.state
  }
    
  <#--- Connect to vCenter and add salt_minion attributes to the vm ---#>
  Write-Host "Setting configuration parameter for $VMName"
  $connect = Connect-VIServer $vcServer -User $vcUsername -Password $vcPassword -Protocol https -Force

  if($VMName -like '*win*') {
    write-host "Installing tools minion on " $VMName
    Set-MinionSettings
    Get-MinionInstallStatus
    Get-LastToolsMinionStatus
    Disconnect-vCenter
    Get-AriaConfigStatus
    write-host "Aria Config is responding with 200"
   } else {
    write-host "Accepting minion id: " $VMName
    Disconnect-vCenter
    Get-AriaConfigStatus
    write-host "Aria Config is responding with 200"
  }
    
  <#--- Setup headers and connect to receive a X-Xsrftoken ---#>
  #write-host "xsrfTokenHeaders: " $xsrfTokenHeaders
  $xsrfTokenHeaders = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
  $xsrfTokenHeaders.Add("Authorization", $salt_base64Auth)
  
  write-host "Request xsrfToken"
  $xsrfTokenRequest = Invoke-WebRequest https://$salt_master/version -Method 'GET' -Headers $xsrfTokenHeaders -SkipCertificateCheck -SkipHttpErrorCheck -MaximumRetryCount '1000' -RetryIntervalSec '5'
  $xsrfToken = ($xsrfTokenRequest.Headers.'Set-Cookie' -split ";" -split '_xsrf=')[1]
  #Write-Host "xsrfToken: " $xsrfToken
  
  <#--- Login with X-Xsrftoken to receive jwt bearer token ---#>
  $loginHeaders = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
  $loginHeaders.Add("X-Xsrftoken", $xsrfToken)
  $loginHeaders.Add("Authorization", $salt_base64Auth)
  $loginHeaders.Add("Content-Type", "application/json")
  $loginHeaders.Add("Cookie", "_xsrf=$xsrfToken")
  
  $loginBody = "{ `"password`": `"$saltPassword`", `"username`": `"$saltUsername`", `"config_name`": `"internal`", `"token_type`": `"jwt`" }"
  #Write-Host "Login Body" $loginBody

  $LoginResponse = Invoke-RestMethod https://$salt_master/account/login -Method 'POST' -Headers $loginHeaders -Body $loginBody -SkipCertificateCheck
  Write-Host "Login Response: " $LoginResponse.ret
    
  <#--- Check Minion status  ---#>
  $salt_minion_id = $VMName.ToLower()
  $minionStatusBody = "{ `"resource`": `"minions`", `"method`": `"get_minion_key_state`", `"kwarg`": { `"minion_id`": `"$salt_minion_id`"}}"
  do {
    $minionStatus = Invoke-RestMethod https://$salt_master/rpc -Method 'POST' -Headers $loginHeaders -Body $minionStatusBody -SkipCertificateCheck
    $minionKeyStatus = $minionStatus.ret.results.key_state
    Write-Host "Minion Status key state: " $minionStatus.ret.results.key_state
    Start-Sleep -s 5
   } until ($minionKeyStatus -eq "accepted" -or $minionKeyStatus -eq "pending")
   Write-Host "Proceeding with Minion Key State: " $minionKeyStatus
  
  <#--- Accept Minion ---#>
  if ($minionStatus.ret.results.key_state -ne 'accepted') {
        $minionAcceptBody = "{ `"resource`": `"cmd`", `"method`": `"route_cmd`", `"kwarg`": { `"cmd`": `"wheel`", `"masters`": [`"*`"], `"fun`": `"key.accept_dict`", `"arg`": { `"arg`": [{ `"minions`": [], `"minions_denied`": [], `"minions_pre`": [`"$salt_minion_id`"], `"minions_rejected`": [] }], `"kwarg`": { `"include_denied`": `"True`", `"include_rejected`": `"True`" } } } }"
        $minionAcceptResponse = Invoke-RestMethod https://$salt_master/rpc -Method 'POST' -Headers $loginHeaders -Body $minionAcceptBody -SkipCertificateCheck
        Write-Host "Minion Accepted ? : " $minionAcceptResponse.ret
  }
  
  <#--- Apply states to minion based on minion name  ---#>
  #Write-Host "Applying states to minion based on minion name"
  #Set-MinionState
  
return $inputs

}
