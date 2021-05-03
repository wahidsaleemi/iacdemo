#Requires -Version 3.0
#Requires -Module Az.Resources

Param(
    [string] $SubscriptionName = 'airs-wasaleem',
    [string] $ResourceGroupLocation = 'South Central US',
    [string] $ResourceGroupName = 'rg-iacdemo-dev',
    [hashtable] $rgTags = @{Location=$ResourceGroupLocation;Description="IaC Demo App";CostCenter="04181"},
    [switch] $UploadArtifacts = $true,
    [string] $ArtefactStorageAccountName = '9deployartifacts',
    [string] $ArtefactStorageContainerName = 'templates',
    [string] $TemplateFolder = 'C:\Users\wasaleem\Code\iacdemo\app-iacdemo\', #MUST contain trailing \
    [string] $TemplateFileName = 'medium.json',
    [string] $TemplateParametersFileName = 'medium.parameters.json'
)
[string] $TemplateFile = $TemplateFolder + $TemplateFileName
[string] $TemplateParametersFile = $TemplateFolder + $TemplateParametersFileName

$startDeployment = Get-Date

Write-Host "This deployment typically takes 20-30 minutes to complete." -ForegroundColor Cyan

Import-Module Az -ErrorAction SilentlyContinue

Function Test-AzureLogin {
 $ErrorActionPreference = "Stop"
 try
 {
     Write-Host "Checking for login..." -ForegroundColor Cyan
     # Try to get the Context.
     $context = Get-AzContext -ErrorAction SilentlyContinue | Out-Null
 }
 catch
 {
     if($Error[0].Exception.Message.Contains("Run Login-AzureRmAccount to login."))
     {
         Write-Host "Not logged in." -ForegroundColor Yellow
         Login-AzureRmAccount
         Write-Host "Logged in now." -ForegroundColor Cyan -NoNewline
         $context = Get-AzureRmContext -ErrorAction SilentlyContinue
     }
 }
}

#Test-AzureLogin

If ((Get-AzContext).Subscription.Name -ne $SubscriptionName)
    {
        Select-AzSubscription -SubscriptionName $SubscriptionName | Out-Null
        Write-Host "Switching to $SubscriptionName" -ForegroundColor Cyan
    }

#Set-StrictMode -Version 3


# Convert relative paths to absolute paths if needed
$TemplateFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $TemplateFile))
$TemplateParametersFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $TemplateParametersFile))
$TemplateFolder = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $TemplateFolder))

$OptionalParameters = New-Object -TypeName Hashtable

if ($UploadArtifacts) {

    Set-Variable ArtifactsLocationName 'baseUrl' -Option ReadOnly -Force
    Set-Variable ArtifactsLocationSasTokenName 'baseUrlSASToken' -Option ReadOnly -Force

    $OptionalParameters.Add($ArtifactsLocationName, $null)
    $OptionalParameters.Add($ArtifactsLocationSasTokenName, $null)

    # Parse the parameter file and update the values of artifacts location and artifacts location SAS token if they are present
    $JsonContent = Get-Content $TemplateParametersFile -Raw | ConvertFrom-Json
    $JsonParameters = $JsonContent | Get-Member -Type NoteProperty | Where-Object {$_.Name -eq "parameters"}

    if ($null -eq $JsonParameters) {
        $JsonParameters = $JsonContent
    }
    else {
        $JsonParameters = $JsonContent.parameters
    }

    $JsonParameters | Get-Member -Type NoteProperty | ForEach-Object {
        $ParameterValue = $JsonParameters | Select-Object -ExpandProperty $_.Name

        if ($_.Name -eq $ArtifactsLocationName -or $_.Name -eq $ArtifactsLocationSasTokenName) {
            $OptionalParameters[$_.Name] = $ParameterValue.value
        }
    }

    #Set storage account context
    $StorageAccountContext = (Get-AzStorageAccount | Where-Object{$_.StorageAccountName -eq $ArtefactStorageAccountName}).Context

    # Generate the value for artifacts location if it is not provided in the parameter file
    $ArtifactsLocation = $OptionalParameters[$ArtifactsLocationName]
    if ($null -eq $ArtifactsLocation) {
        $ArtifactsLocation = $StorageAccountContext.BlobEndPoint + $ArtefactStorageContainerName
        $OptionalParameters[$ArtifactsLocationName] = $ArtifactsLocation
    }

    # Copy files from the local storage staging location to the storage account container
    New-AzStorageContainer -Name $ArtefactStorageContainerName -Context $StorageAccountContext -Permission Container -ErrorAction SilentlyContinue *>&1

#region Copy the ARM JSON files to the container
Function Invoke-UploadFiles {
    $JsonFilePaths = Get-ChildItem $TemplateFolder -Recurse -File | ForEach-Object -Process {$_.FullName}
    foreach ($SourcePath in $JsonFilePaths) {
        $BlobName = $SourcePath.Substring($TemplateFolder.length)
        Set-AzStorageBlobContent -File $SourcePath -Blob $BlobName -Container $ArtefactStorageContainerName -Context $StorageAccountContext -Force
    }
}
#endregion

#region Generate the value for artifacts location SAS token if it is not provided in the parameter file
    $ArtifactsLocationSasToken = $OptionalParameters[$ArtifactsLocationSasTokenName]
    if ($null -eq $ArtifactsLocationSasToken) {
        # Create a SAS token for the storage container - this gives temporary read-only access to the container
        $ArtifactsLocationSasToken = New-AzStorageContainerSASToken -Container $ArtefactStorageContainerName -Context $StorageAccountContext -Permission r -ExpiryTime (Get-Date).AddHours(4)
        #Write-Host $ArtifactsLocationSasToken
        $ArtifactsLocationSasToken = ConvertTo-SecureString $ArtifactsLocationSasToken -AsPlainText -Force
        $OptionalParameters[$ArtifactsLocationSasTokenName] = $ArtifactsLocationSasToken
    }
#endregion

    #Write-Host $OptionalParameters[$ArtifactsLocationSasTokenName]
    #Write-Host $OptionalParameters[$ArtifactsLocationName]
}

#region Resouce Group creation
Write-Host "Checking for existing rg $ResourceGroupName..." -ForegroundColor Cyan
If ($null -eq (Get-AzResourceGroup -Name $ResourceGroupName -Location $ResourceGroupLocation -ErrorAction SilentlyContinue))
    {New-AzResourceGroup -Name $ResourceGroupName -Location $ResourceGroupLocation -Tag $rgTags}
#endregion
Write-Host "Starting upload of templates and artifacts" -ForegroundColor Cyan
Invoke-UploadFiles
Write-Host "Parameters have been populated:" -ForegroundColor Cyan
$OptionalParameters.Values

Test-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName `
                                    -TemplateFile $TemplateFile `
                                    -TemplateParameterFile $TemplateParametersFile `
                                    @OptionalParameters -Verbose
#$Error[0]

$deploymentName = ((Get-ChildItem $TemplateFile).BaseName + '-' + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm'))
Write-Host "Starting deployment: $deploymentName" -ForegroundColor Cyan
New-AzResourceGroupDeployment -Name $deploymentName `
                                   -ResourceGroupName $ResourceGroupName `
                                   -TemplateFile $TemplateFile `
                                   -TemplateParameterFile $TemplateParametersFile `
                                   @OptionalParameters `
                                   -Force -Verbose

$endDeployment = Get-Date
$endDeployment - $startDeployment | Format-Table