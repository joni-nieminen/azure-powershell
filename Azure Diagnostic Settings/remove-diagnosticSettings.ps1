#Requires -Modules Az.Accounts, Az.Monitor

<#
.SYNOPSIS
    Removes diagnostic settings from Azure resources in a specified subscription.
    Designed to handle cleanup of diagnostic settings created by DeployIfNotExists policies.

.DESCRIPTION
    This script safely removes diagnostic settings from Azure resources. It provides:
    - Subscription selection (by ID or name)
    - Multiple filtering options (by resource type, LAW ID, resource name)
    - Dry-run mode to preview changes
    - Confirmation prompts for safety
    - Detailed logging of all operations
    - Export of settings before deletion for recovery

.PARAMETER SubscriptionId
    The subscription ID or name to target for diagnostic setting removal.

.PARAMETER LogAnalyticsWorkspaceId
    Optional: Filter by source Log Analytics Workspace ID to remove settings pointing to a specific LAW.
    Format: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{name}

.PARAMETER ResourceGroupName
    Optional: Limit scope to a specific resource group.

.PARAMETER ResourceType
    Optional: Filter by resource type (e.g., 'Microsoft.Compute/virtualMachines').

.PARAMETER ResourceName
    Optional: Filter by resource name pattern (supports wildcards).

.PARAMETER DryRun
    If specified, shows what would be deleted without actually deleting.

.PARAMETER ExportBeforeDelete
    If specified, exports all matched diagnostic settings to JSON before deletion.

.EXAMPLE
    # List all diagnostic settings in subscription (dry-run)
    .\Remove-DiagnosticSettings-Bulk.ps1 -SubscriptionId "contoso-prod" -DryRun

.EXAMPLE
    # Remove settings pointing to old LAW, with export
    .\Remove-DiagnosticSettings-Bulk.ps1 -SubscriptionId "contoso-prod" `
        -LogAnalyticsWorkspaceId "/subscriptions/xxx/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/old-law" `
        -ExportBeforeDelete

.EXAMPLE
    # Remove settings from VM resources only in a specific RG
    .\Remove-DiagnosticSettings-Bulk.ps1 -SubscriptionId "contoso-prod" `
        -ResourceGroupName "MyResourceGroup" `
        -ResourceType "Microsoft.Compute/virtualMachines"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$LogAnalyticsWorkspaceId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$ResourceType,

    [Parameter(Mandatory = $false)]
    [string]$ResourceName,

    [switch]$DryRun,

    [switch]$ExportBeforeDelete
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Setup logging - temporary path, will be updated with subscription name later
$LogPath = "$(Get-Location)\DiagnosticSettings_Removal_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$ExportPath = "$(Get-Location)\DiagnosticSettings_Export_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"

function Write-LogMessage {
    param([string]$Message, [string]$Level = "INFO")
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    Write-Host $logEntry
    Add-Content -Path $LogPath -Value $logEntry -Force
}

function Get-TargetSubscription {
    param([string]$SubId)
    
    Write-LogMessage "Resolving subscription: $SubId"
    
    # Try as subscription ID first
    $sub = Get-AzSubscription -SubscriptionId $SubId -ErrorAction SilentlyContinue
    
    # If not found, try as subscription name
    if (-not $sub) {
        $sub = Get-AzSubscription -SubscriptionName $SubId -ErrorAction SilentlyContinue
    }
    
    if (-not $sub) {
        throw "Subscription '$SubId' not found. Verify subscription ID or name."
    }
    
    Write-LogMessage "Selected subscription: $($sub.Name) (ID: $($sub.Id))"
    return $sub
}

function Get-ResourcesWithDiagnosticSettings {
    param(
        [string]$SubId,
        [string]$RgName,
        [string]$ResType,
        [string]$ResName
    )
    
    Write-LogMessage "Querying resources with diagnostic settings..."
    
    Set-AzContext -SubscriptionId $SubId | Out-Null
    
    $resources = @()
    
    # Build query parameters
    $getParams = @{
        ResourceType = $ResType
    }
    
    if ($RgName) {
        $getParams['ResourceGroupName'] = $RgName
    }
    
    if ($ResName) {
        $getParams['ResourceNameContains'] = $ResName
    }
    
    try {
        $resources = Get-AzResource @getParams -ErrorAction SilentlyContinue
    }
    catch {
        Write-LogMessage "Warning: Could not retrieve resources via Get-AzResource. Will query all resources." "WARN"
    }
    
    # If no specific resource type, get all resources
    if (-not $ResType) {
        if ($RgName) {
            $resources = Get-AzResource -ResourceGroupName $RgName -ErrorAction SilentlyContinue
        }
        else {
            $resources = Get-AzResource -ErrorAction SilentlyContinue
        }
    }
    
    Write-LogMessage "Found $($resources.Count) resources to check for diagnostic settings"
    return $resources
}

function Get-DiagnosticSettingsForResource {
    param(
        [object]$Resource
    )
    
    $diagSettings = @()
    
    # Try to get diagnostic settings for this resource
    try {
        $settings = Get-AzDiagnosticSetting -ResourceId $Resource.ResourceId -ErrorAction SilentlyContinue
        
        # Enrich each diagnostic setting with the source resource ID
        foreach ($setting in $settings) {
            # Create a new object with the ResourceId explicitly set
            $enriched = $setting | Select-Object -Property *
            $enriched | Add-Member -MemberType NoteProperty -Name "SourceResourceId" -Value $Resource.ResourceId -Force
            $diagSettings += $enriched
        }
    }
    catch {
        # Resource may not support diagnostic settings - continue silently
    }
    
    return $diagSettings
}

function Test-DiagnosticSettingMatch {
    param(
        [object]$DiagSetting,
        [string]$TargetLawId
    )
    
    if (-not $TargetLawId) {
        # If no LAW filter specified, match all diagnostic settings
        return $true
    }
    
    # Check if this diagnostic setting points to the target LAW
    if ($DiagSetting.WorkspaceId -eq $TargetLawId) {
        return $true
    }
    
    # Also check in LogAnalyticsDestinations array if it exists
    if ($DiagSetting.LogAnalyticsDestinations) {
        foreach ($dest in $DiagSetting.LogAnalyticsDestinations) {
            if ($dest -eq $TargetLawId) {
                return $true
            }
        }
    }
    
    return $false
}

function Remove-DiagnosticSettingsWithConfirmation {
    param(
        [object[]]$DiagSettings,
        [object[]]$Resources,
        [bool]$IsDryRun,
        [bool]$ShouldExport
    )
    
    if ($DiagSettings.Count -eq 0) {
        Write-LogMessage "No diagnostic settings matched the filter criteria."
        return @{
            ExportedCount = 0
            RemovedCount = 0
            SkippedCount = 0
        }
    }
    
    Write-LogMessage ("=" * 80)
    Write-LogMessage "SUMMARY OF DIAGNOSTIC SETTINGS TO REMOVE" "INFO"
    Write-LogMessage ("=" * 80)
    
    foreach ($diagSetting in $DiagSettings) {
        Write-Host "  - Name: $($diagSetting.Name)"
        Write-Host "    Resource: $($diagSetting.SourceResourceId)"
        Write-Host "    Workspace: $($diagSetting.WorkspaceId)"
        Write-Host ""
    }
    
    Write-LogMessage "Total diagnostic settings to remove: $($DiagSettings.Count)"
    Write-LogMessage ("=" * 80)
    
    if ($IsDryRun) {
        Write-Host -ForegroundColor Yellow "DRY-RUN MODE: No changes will be made."
        Write-LogMessage "DRY-RUN MODE: No changes were made." "INFO"
        return @{
            ExportedCount = $DiagSettings.Count
            RemovedCount = 0
            SkippedCount = 0
        }
    }
    
    # Confirmation prompt
    Write-Host -ForegroundColor Cyan "`nWARNING: This will DELETE the diagnostic settings listed above."
    Write-Host -ForegroundColor Cyan "This action cannot be easily undone."
    
    if ($ExportBeforeDelete) {
        Write-Host -ForegroundColor Green "Settings will be exported to: $ExportPath"
    }
    
    $confirmation = Read-Host -Prompt "Continue with deletion? Type 'yes' to confirm"
    
    if ($confirmation -ne "yes") {
        Write-LogMessage "Operation cancelled by user." "WARN"
        return @{
            ExportedCount = 0
            RemovedCount = 0
            SkippedCount = $DiagSettings.Count
        }
    }
    
    $removedCount = 0
    $failedCount = 0
    $exportData = @()
    
    # Process each diagnostic setting
    foreach ($diagSetting in $DiagSettings) {
        Write-LogMessage "Processing: $($diagSetting.Name) on $($diagSetting.SourceResourceId)"
        
        # Export before deletion if requested
        if ($ShouldExport) {
            $exportData += @{
                SettingName = $diagSetting.Name
                ResourceId = $diagSetting.SourceResourceId
                WorkspaceId = $diagSetting.WorkspaceId
                Categories = $diagSetting.Categories
                Timings = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                FullObject = $diagSetting | ConvertTo-Json -Depth 5
            }
        }
        
        try {
            # Remove the diagnostic setting using the source resource ID
            Remove-AzDiagnosticSetting -ResourceId $diagSetting.SourceResourceId -Name $diagSetting.Name -confirm:$false
            
            Write-LogMessage "Successfully removed: $($diagSetting.Name)" "SUCCESS"
            $removedCount++
        }
        catch {
            Write-LogMessage "Failed to remove $($diagSetting.Name): $($_.Exception.Message)" "ERROR"
            $failedCount++
        }
    }
    
    # Export to file if requested
    if ($ShouldExport -and $exportData.Count -gt 0) {
        try {
            $exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $ExportPath -Force
            Write-LogMessage "Exported $($exportData.Count) diagnostic settings to: $ExportPath" "INFO"
        }
        catch {
            Write-LogMessage "Failed to export diagnostic settings: $($_.Exception.Message)" "ERROR"
        }
    }
    
    # Log summary
    Write-LogMessage ("=" * 80)
    Write-LogMessage "REMOVAL SUMMARY" "INFO"
    Write-LogMessage "Successfully removed: $removedCount" "SUCCESS"
    Write-LogMessage "Failed to remove: $failedCount" "ERROR"
    Write-LogMessage ("=" * 80)
    
    return @{
        ExportedCount = $exportData.Count
        RemovedCount = $removedCount
        SkippedCount = $failedCount
    }
}

<# ===== MAIN SCRIPT EXECUTION ===== #>

try {
    # Ensure user is connected to Azure FIRST, before any other operations
    $azContext = Get-AzContext
    if (-not $azContext) {
        Write-Host "Not authenticated to Azure. Configuring default subscription and running Connect-AzAccount..."
        # Set the default subscription BEFORE connecting to avoid interactive selection
        Update-AzConfig -DefaultSubscriptionForLogin $SubscriptionId | Out-Null
        # Connect without context population to avoid interactive prompts
        Connect-AzAccount -SkipContextPopulation | Out-Null
    }
    
    # Immediately set context to the target subscription (handles both ID and name)
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    
    # Now resolve subscription to get the name
    $targetSubscription = Get-TargetSubscription -SubId $SubscriptionId
    
    # Update logging paths with subscription name
    $sanitizedSubName = $targetSubscription.Name -replace '[\\/:*?"<>|]', '-'
    $LogPath = "$(Get-Location)\DiagnosticSettings_Removal_$($sanitizedSubName)_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $ExportPath = "$(Get-Location)\DiagnosticSettings_Export_$($sanitizedSubName)_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    
    Write-LogMessage "Script started by user: $env:USERNAME" "INFO"
    Write-LogMessage "Subscription Filter: $SubscriptionId"
    Write-LogMessage "Log Analytics Workspace Filter: $(if ($LogAnalyticsWorkspaceId) { $LogAnalyticsWorkspaceId } else { 'None (all settings)' })"
    Write-LogMessage "Resource Group Filter: $(if ($ResourceGroupName) { $ResourceGroupName } else { 'None' })"
    Write-LogMessage "Resource Type Filter: $(if ($ResourceType) { $ResourceType } else { 'None' })"
    Write-LogMessage "Dry-Run Mode: $(if ($DryRun) { 'Yes' } else { 'No' })"
    Write-LogMessage "Export Before Delete: $(if ($ExportBeforeDelete) { 'Yes' } else { 'No' })"
    
    # Set context to the target subscription
    Set-AzContext -SubscriptionId $targetSubscription.Id | Out-Null
    
    # Get all resources with diagnostic settings
    $resources = Get-ResourcesWithDiagnosticSettings `
        -SubId $targetSubscription.Id `
        -RgName $ResourceGroupName `
        -ResType $ResourceType `
        -ResName $ResourceName
    
    # Collect diagnostic settings matching criteria
    $matchedDiagSettings = @()
    
    foreach ($resource in $resources) {
        $diagSettings = Get-DiagnosticSettingsForResource -Resource $resource
        
        foreach ($diagSetting in $diagSettings) {
            if (Test-DiagnosticSettingMatch -DiagSetting $diagSetting -TargetLawId $LogAnalyticsWorkspaceId) {
                $matchedDiagSettings += $diagSetting
            }
        }
    }
    
    Write-LogMessage "Matched $($matchedDiagSettings.Count) diagnostic settings based on filter criteria"
    
    # Process removals
    Remove-DiagnosticSettingsWithConfirmation `
        -DiagSettings $matchedDiagSettings `
        -Resources $resources `
        -IsDryRun $DryRun `
        -ShouldExport $ExportBeforeDelete
    
    Write-LogMessage "Script completed successfully." "SUCCESS"
    Write-LogMessage "Log file: $LogPath"
    
    Write-Host -ForegroundColor Green "`nOperation completed successfully!"
    Write-Host "Log file saved to: $LogPath"
    
}
catch {
    Write-LogMessage "Script error: $($_.Exception.Message)" "ERROR"
    Write-LogMessage "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    Write-Host -ForegroundColor Red "Error: $($_.Exception.Message)"
    exit 1
}
