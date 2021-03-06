function Get-TargetResource
{
	[CmdletBinding()]
	[OutputType([System.Collections.Hashtable])]
	param
	(
        [parameter(Mandatory = $true)]
        [System.String]
        $PortalHostName,

        [parameter(Mandatory = $true)]
		[System.String]
		$PortalAdministrator,
        
        [parameter(Mandatory = $false)]
		[System.String]
        $LicenseFilePath = $null,
        
        [parameter(Mandatory = $false)]
		[System.Boolean]
        $SetOnlyHostNamePropertiesFile
	)
    
    Import-Module $PSScriptRoot\..\..\ArcGISUtility.psm1 -Verbose:$false

    $null
}

function Set-TargetResource
{
	[CmdletBinding()]
	param
	(
        [parameter(Mandatory = $true)]
        [System.String]
        $PortalHostName,

        [parameter(Mandatory = $true)]
		[System.Management.Automation.PSCredential]
        $PortalAdministrator,
        
        [parameter(Mandatory = $false)]
		[System.String]
        $LicenseFilePath = $null,
        
        [parameter(Mandatory = $false)]
		[System.Boolean]
        $SetOnlyHostNamePropertiesFile
	)
    
    Import-Module $PSScriptRoot\..\..\ArcGISUtility.psm1 -Verbose:$false
    [System.Reflection.Assembly]::LoadWithPartialName("System.Web") | Out-Null
    $FQDN = Get-FQDN $PortalHostName
    $Referer = "https://localhost"
	
	$ServiceName = 'Portal for ArcGIS'
    $RegKey = Get-EsriRegistryKeyForService -ServiceName $ServiceName
    $InstallDir = (Get-ItemProperty -Path $RegKey -ErrorAction Ignore).InstallDir  

    $RestartRequired = $false
    $hostname = Get-ConfiguredHostName -InstallDir $InstallDir
    if($hostname -ieq $FQDN) {
        Write-Verbose "Configured hostname '$hostname' matches expected value '$FQDN'"        
    }else {
        Write-Verbose "Configured hostname '$hostname' does not match expected value '$FQDN'. Setting it"
        if(Set-ConfiguredHostName -InstallDir $InstallDir -HostName $FQDN) { 
            # Need to restart the service to pick up the hostname 
			Write-Verbose "hostname.properties file was modified. Need to restart the '$ServiceName' service to pick up changes"
            $RestartRequired = $true 
        }
    }

    $InstallDir = Join-Path $InstallDir 'framework\runtime\ds' 

    $expectedHostIdentifierType = if($FQDN -as [ipaddress]){ 'ip' }else{ 'hostname' }
	$hostidentifier = Get-ConfiguredHostIdentifier -InstallDir $InstallDir
	$hostidentifierType = Get-ConfiguredHostIdentifierType -InstallDir $InstallDir
	if(($hostidentifier -ieq $FQDN) -and ($hostidentifierType -ieq $expectedHostIdentifierType)) {        
        Write-Verbose "In Portal DataStore Configured host identifier '$hostidentifier' matches expected value '$FQDN' and host identifier type '$hostidentifierType' matches expected value '$expectedHostIdentifierType'"        
	}else {
		Write-Verbose "In Portal DataStore Configured host identifier '$hostidentifier' does not match expected value '$FQDN' or host identifier type '$hostidentifierType' does not match expected value '$expectedHostIdentifierType'. Setting it"
		if(Set-ConfiguredHostIdentifier -InstallDir $InstallDir -HostIdentifier $FQDN -HostIdentifierType $expectedHostIdentifierType) { 
            # Need to restart the service to pick up the hostidentifier 
            Write-Verbose "In Portal DataStore Hostidentifier.properties file was modified. Need to restart the '$ServiceName' service to pick up changes"
            $RestartRequired = $true 
        }
    }
    
    if($RestartRequired) {             
		Restart-PortalService -ServiceName $ServiceName
        Wait-ForUrl "https://$($FQDN):7443/arcgis/portaladmin/" -HttpMethod 'GET' -Verbose
    }

    if(-not($SetOnlyHostNamePropertiesFile)){

        [string]$UpgradeUrl = "https://$($FQDN):7443/arcgis/portaladmin/upgrade"

        $WebParams = @{ 
            isBackupRequired = $true
            isRollbackRequired = $true
            f = 'json'
        }

        $UpgradeResponse = $null
        if($LicenseFilePath){ 
            $UpgradeResponse = Invoke-UploadFile -url $UpgradeUrl -filePath $LicenseFilePath -fileContentType 'application/json' -fileParameterName 'file' `
                                -Referer $Referer -formParams $WebParams -Verbose 
            $UpgradeResponse = ConvertFrom-JSON $UpgradeResponse
        } else {
            $UpgradeResponse = Invoke-ArcGISWebRequest -Url $UpgradeUrl -HttpFormParameters $WebParams -Referer $Referer -TimeOutSec 86400 -Verbose 
        }
        
        if($UpgradeResponse.status -ieq 'success') {
            Write-Verbose "Upgrade Successful"
            if($null -ne $UpgradeResponse.recheckAfterSeconds) 
            {
                Write-Verbose "Sleeping for $($UpgradeResponse.recheckAfterSeconds*2) seconds"
                Start-Sleep -Seconds ($UpgradeResponse.recheckAfterSeconds*2)
            }

            Wait-ForUrl "https://$($FQDN):7443/arcgis/portaladmin/" -HttpMethod 'GET' -Verbose
            $Attempts = 0
            while(-not($PrimaryReady) -and ($Attempts -lt 10)) {
                $HealthCheckUrl = "https://$($FQDN):7443/arcgis/portaladmin/healthCheck/?f=json"
                Write-Verbose "Making request to health check URL '$HealthCheckUrl'" 
                try {
                    Invoke-ArcGISWebRequest -Url $HealthCheckUrl -TimeoutSec 90 -Verbose -HttpFormParameters @{ f='json' } -Referer 'http://localhost' -HttpMethod 'POST'
                    Write-Verbose "Health check succeeded"
                    $PrimaryReady = $true
                }catch {
                    Write-Verbose "Health check did not suceed. Error:- $_"
                    Start-Sleep -Seconds 30
                    $Attempts = $Attempts + 1
                }        
            }

            Write-Verbose "Waiting for portal to start."
            try {
                $token = Get-PortalToken -PortalHostName $FQDN -SiteName "arcgis" -Credential $PortalAdministrator -Referer $Referer -MaxAttempts 40 -Verbose
            } catch {
                Write-Verbose $_
            }

            $token = Get-PortalToken -PortalHostName $FQDN -SiteName 'arcgis' -Credential $PortalAdministrator -Referer $Referer -Verbose
            if(-not($token.token)) {
                throw "Unable to retrieve Portal Token for '$($PortalAdministrator.UserName)'"
            }
            Write-Verbose "Connected to Portal successfully and retrieved token for '$($PortalAdministrator.UserName)'"

            if($LicenseFilePath){
                Write-Verbose 'Populating Licenses'
                [string]$populateLicenseUrl = "https://$($FQDN):7443/arcgis/portaladmin/license/populateLicense"
                $token = Get-PortalToken -PortalHostName $FQDN -SiteName 'arcgis' -Credential $PortalAdministrator -Referer $Referer
                $populateLicenseResponse = Invoke-ArcGISWebRequest -Url $populateLicenseUrl -HttpMethod "POST" -HttpFormParameters @{f = 'json'; token = $token.token} -Referer $Referer -TimeOutSec 3000 -Verbose 
                if ($populateLicenseResponse.error -and $populateLicenseResponse.error.message) {
                    Write-Verbose "Error from Populate Licenses:- $($populateLicenseResponse.error.message)"
                    throw $populateLicenseResponse.error.message
                }
            }

            Write-Verbose "Post Upgrade Step"
            [string]$postUpgradeUrl = "https://$($FQDN):7443/arcgis/portaladmin/postUpgrade"
            $postUpgradeResponse = Invoke-ArcGISWebRequest -Url $postUpgradeUrl -HttpFormParameters @{f = 'json'; token = $token.token} -Referer $Referer -TimeOutSec 3000 -Verbose 
            $ResponseJSON = (ConvertTo-Json $postUpgradeResponse -Compress -Depth 5)
            Write-Verbose "Response received from post upgrade step $ResponseJSON"  
            if($postUpgradeResponse.status -ieq "success"){
                Write-Verbose "Sleeping for $($postUpgradeResponse.recheckAfterSeconds*2) seconds"
                Start-Sleep -Seconds ($postUpgradeResponse.recheckAfterSeconds*2)
                Write-Verbose "Post Upgrade Step Successful"
            }else{
                throw  "[ERROR]:- $(ConvertTo-Json $ResponseJSON -Compress -Depth 5)"
            }

            Write-Verbose "Reindexing Portal"
            Invoke-UpgradeReindex -PortalHttpsUrl "https://$($FQDN):7443" -PortalSiteName 'arcgis' -Referer $Referer -Token $token.token
            
            Write-Verbose "Upgrading Living Atlas Content"
            if(Get-LivingAtlasStatus -PortalHttpsUrl "https://$($FQDN):7443" -PortalSiteName 'arcgis' -Referer $Referer -Token $token.token){
                Invoke-UpgradeLivingAtlas -PortalHttpsUrl "https://$($FQDN):7443" -PortalSiteName 'arcgis' -Referer $Referer -Token $token.token
            }
        }else{
            throw  "[ERROR]:- $(ConvertTo-Json $UpgradeResponse -Compress -Depth 5)"
        }
    }
}

function Test-TargetResource
{
	[CmdletBinding()]
	[OutputType([System.Boolean])]
	param
	(
        [parameter(Mandatory = $true)]
        [System.String]
        $PortalHostName,
        
        [parameter(Mandatory = $true)]
		[System.Management.Automation.PSCredential]
		$PortalAdministrator,
        
        [parameter(Mandatory = $false)]
		[System.String]
		$LicenseFilePath = $null,
        
        [parameter(Mandatory = $false)]
		[System.Boolean]
        $SetOnlyHostNamePropertiesFile
	)
    [System.Reflection.Assembly]::LoadWithPartialName("System.Web") | Out-Null
    Import-Module $PSScriptRoot\..\..\ArcGISUtility.psm1 -Verbose:$false
    
    $FQDN = Get-FQDN $PortalHostName
    $Referer = "https://localhost"
    $result = $false

    $ServiceName = 'Portal for ArcGIS'
    $RegKey = Get-EsriRegistryKeyForService -ServiceName $ServiceName
    $InstallDir = (Get-ItemProperty -Path $RegKey -ErrorAction Ignore).InstallDir  

    $hostname = Get-ConfiguredHostName -InstallDir $InstallDir
    if ($hostname -ieq $FQDN) {
        Write-Verbose "Configured hostname '$hostname' matches expected value '$FQDN'"
        $result = $true
    }
    else {
        Write-Verbose "Configured hostname '$hostname' does not match expected value '$FQDN'"
        $result = $false
    }

    if ($result) {
        $InstallDir = Join-Path $InstallDir 'framework\runtime\ds' 

        $expectedHostIdentifierType = if($FQDN -as [ipaddress]){ 'ip' }else{ 'hostname' }
		$hostidentifier = Get-ConfiguredHostIdentifier -InstallDir $InstallDir
		$hostidentifierType = Get-ConfiguredHostIdentifierType -InstallDir $InstallDir
		if (($hostidentifier -ieq $FQDN) -and ($hostidentifierType -ieq $expectedHostIdentifierType)) {        
            Write-Verbose "In Portal DataStore Configured host identifier '$hostidentifier' matches expected value '$FQDN' and host identifier type '$hostidentifierType' matches expected value '$expectedHostIdentifierType'"        
        }
        else {
			Write-Verbose "In Portal DataStore Configured host identifier '$hostidentifier' does not match expected value '$FQDN' or host identifier type '$hostidentifierType' does not match expected value '$expectedHostIdentifierType'. Setting it"
			$result = $false
        }
    }

    if ($result -and -not($SetOnlyHostNamePropertiesFile)) {
        Wait-ForUrl -Url "https://$($FQDN):7443/arcgis/portaladmin" -MaxWaitTimeInSeconds 600 -SleepTimeInSeconds 15 -HttpMethod 'GET'
        try{
            $TestPortalResponse = Invoke-ArcGISWebRequest -Url "https://$($FQDN):7443/arcgis/portaladmin" -HttpFormParameters @{ f = 'json' } -Referer $Referer -Verbose -HttpMethod 'GET'
            if($TestPortalResponse.status -ieq "error" -and $TestPortalResponse.isUpgrade -ieq $true -and $TestPortalResponse.messages[0] -ieq "The portal site has not been upgraded. Please upgrade the site and try again."){
                $result =$false
            }else{
                if(($null -ne $TestPortalResponse.error) -and $TestPortalResponse.error.message -ieq 'Token Required.'){
                    Write-Verbose "Looks Like upgrade already Occured!"
                    $PortalHealthCheck = Invoke-ArcGISWebRequest -Url "https://$($FQDN):7443/arcgis/portaladmin/healthCheck" -HttpFormParameters @{ f = 'json' } -Referer $Referer -Verbose -HttpMethod 'GET'
                    if($PortalHealthCheck.status -ieq "success"){
                        $result = $true
                    }
                }elseif($TestPortalResponse.status -ieq 'error' -and $TestPortalResponse.isUpgrade -ieq $true -and $TestPortalResponse.messages[0] -ieq "The portal site has not been upgraded. Please upgrade the site and try again."){
                    $result = $false
                }else{
                    $jsresponse = ConvertTo-Json $TestPortalResponse -Compress -Depth 5
                    Write-Verbose "[WARNING]:- $jsresponse "
                }
            }
        }catch{
            $result = $false
            Write-Verbose "[WARNING]:- $_"
        }
    }

    $result 
}

function Invoke-UpgradeReindex
{
    [CmdletBinding()]
    param(
        [System.String]
        $PortalHttpsUrl, 
        
        [System.String]
		$PortalSiteName = 'arcgis', 

        [System.String]
		$Token, 

        [System.String]
		$Referer = 'http://localhost'
        
    )

    [string]$ReindexSiteUrl = $PortalHttpsUrl.TrimEnd('/') + "/$PortalSiteName/portaladmin/system/indexer/reindex"

    $WebParams = @{ 
                    mode = 'FULL_MODE'
                    f = 'json'
                    token = $Token
                  }

    Write-Verbose "Making request to $ReindexSiteUrl to create the site"
    $Response = Invoke-ArcGISWebRequest -Url $ReindexSiteUrl -HttpFormParameters $WebParams -Referer $Referer -TimeOutSec 3000 -Verbose 
    $ResponseJSON = (ConvertTo-JSON $Response -Depth 5 -Compress )
    Write-Verbose "Response received from Reindex site $ResponseJSON"  
    if($Response.error -and $Response.error.message) {
        throw $Response.error.message
    }
    if($Response.status -ieq 'success') {
        Write-Verbose "Reindexing Successful"
    }
}

function Get-LivingAtlasStatus
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param(
        [System.String]
        $PortalHttpsUrl, 
        
        [System.String]
        $PortalSiteName = 'arcgis', 
        
        [System.String]
        $Token,

        [System.String]
        $Referer = 'http://localhost'
    )
    
    $LAStatusURL = $PortalHttpsUrl.TrimEnd('/') + "/$PortalSiteName/sharing/rest/search"
    $resp = Invoke-ArcGISWebRequest -Url $LAStatusURL -HttpFormParameters @{ f = 'json'; token = $Token; q = "owner:esri_livingatlas" } -Referer $Referer -Verbose
    if($resp.total -gt 0){
        $true
    }else{
        $false
    }
}

function Invoke-UpgradeLivingAtlas
{
    [CmdletBinding()]
    param(
        [System.String]
        $PortalHttpsUrl, 
        
        [System.String]
        $PortalSiteName = 'arcgis', 

        [System.String]
        $Token,

        [System.String]
        $Referer = 'http://localhost'
    )

    $result = @{}
    [string[]]$LivingAtlasGroupIds =  "81f4ed89c3c74086a99d168925ce609e", "6646cd89ff1849afa1b95ed670a298b8"

    ForEach ($groupId in $LivingAtlasGroupIds)
    {
        $done = $true
        $attempts = 0
        while($done){
            $LAUpgradeURL = $PortalHttpsUrl.TrimEnd('/') + "/$PortalSiteName/portaladmin/system/content/livingatlas/upgrade"
            try{
				$resp = Invoke-ArcGISWebRequest -Url $LAUpgradeURL -HttpFormParameters @{ f = 'json'; token = $Token; groupId = $groupId } -Referer $Referer -Verbose
				if($resp.status -eq "success"){
					Write-Verbose "Upgraded Living Atlas Content For GroupId - $groupId"
					$done = $false
				}
			}catch{
				if($attempts -eq 3){
					Write-Verbose "Unable to Living Atlas Content For GroupId - $groupId - Please Follow Mannual Steps specified in the Documentation"
					$done = $false
				}
			}
			$attempts++
        }
    }
}


function Restart-PortalService
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [System.String]
        $ServiceName = 'Portal for ArcGIS'
    )

    try 
    {
		Write-Verbose "Restarting Service $ServiceName"
		Stop-Service -Name $ServiceName -Force -ErrorAction Ignore
		Write-Verbose 'Stopping the service' 
		Wait-ForServiceToReachDesiredState -ServiceName $ServiceName -DesiredState 'Stopped'
		Write-Verbose 'Stopped the service'
	}catch {
        Write-Verbose "[WARNING] Stopping Service $_"
    }

	try {
		Write-Verbose 'Starting the service'
		Start-Service -Name $ServiceName -ErrorAction Ignore        
		Wait-ForServiceToReachDesiredState -ServiceName $ServiceName -DesiredState 'Running'
		Write-Verbose "Restarted Service '$ServiceName'"
	}catch {
        Write-Verbose "[WARNING] Starting Service $_"
    }
}

Export-ModuleMember -Function *-TargetResource