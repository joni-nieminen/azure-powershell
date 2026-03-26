# remove-diagnosticSettings.ps1

## ⚠️ Disclaimer

**This script is provided as-is. Use of this script is at your own risk and responsibility.** The author assumes no liability for any damage, data loss, or unintended consequences that may result from using this script. 

Before running this script in any production environment:
- Thoroughly test it in a non-production environment first
- Understand exactly what diagnostic settings will be removed
- Ensure you have proper backups and recovery procedures
- Review the dry-run output carefully before confirming deletion
- Verify you have the correct permissions and access

The script includes safety mechanisms (dry-run, confirmations, backups), but it is the user's responsibility to use it safely and appropriately.

## Table of Contents

- [Background](#background)
  - [The Problem](#the-problem)
  - [The Solution](#the-solution)
- [What This Script Does](#what-this-script-does)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
  - [Basic Usage - Dry Run](#basic-usage---dry-run-recommended-first-step)
  - [Remove Settings Pointing to a Specific LAW](#remove-settings-pointing-to-a-specific-law)
  - [Remove Settings from Specific Resource Type](#remove-settings-from-specific-resource-type)
  - [Remove All Diagnostic Settings](#remove-all-diagnostic-settings-dangerous---use-with-caution)
- [Parameters](#parameters)
- [Safety Features](#safety-features)
- [Output Files](#output-files)
- [Real-World Example](#real-world-example)
- [Troubleshooting](#troubleshooting)
- [Recovery](#recovery)
- [Notes](#notes)
- [License](#license)
- [Support](#support)

## Background

### The Problem

Azure Policy's `DeployIfNotExists` effect is a powerful automation tool for enforcing organizational standards at scale. Many organizations use it to automatically configure diagnostic settings on resources and route logs to a centralized Log Analytics Workspace (LAW).

However, organizations often evolve their logging and monitoring strategies:
- A policy targeting Log Analytics Workspace "A" is created and applied to a management group scope
- Resources get diagnostic settings automatically configured to send logs to LAW-A
- Later, the organization decides to consolidate logging and change the policy to target Log Analytics Workspace "B" instead
- The policy is updated and applied, creating *new* diagnostic settings on resources
- **The old diagnostic settings pointing to LAW-A remain**, creating duplicate logging

This results in:
- **Duplicate log data** being sent to LAW-A (unnecessary storage costs)
- **Operational confusion** (logs from the same resource in two different workspaces)
- **Cost waste** (paying for duplicate ingestion and storage)
- **Hard to clean up manually** at scale (hundreds or thousands of resources)

### The Solution

This script safely identifies and removes diagnostic settings in bulk. It's designed specifically for scenarios where:
- You've changed the target LAW in your `DeployIfNotExists` policies
- Resources now have duplicate diagnostic settings (one old, one new)
- You need to remove the old diagnostic settings without impacting the new ones
- Safety is critical (confirmation prompts, dry-run mode, automatic backups)

## What This Script Does

The script:
1. **Connects to Azure** and targets a specific subscription
2. **Discovers all resources** (optionally filtered by type or resource group)
3. **Retrieves diagnostic settings** from each resource
4. **Filters settings** by source Log Analytics Workspace (optional, but recommended)
5. **Previews changes** with detailed output
6. **Exports settings to JSON** before deletion (for recovery if needed)
7. **Removes unwanted diagnostic settings** with confirmation prompts
8. **Logs all operations** to a timestamped file for audit trails

## Prerequisites

- **Azure PowerShell modules**: `Az.Accounts` and `Az.Monitor`
  ```powershell
  Install-Module -Name Az.Accounts -AllowClobber -Force
  Install-Module -Name Az.Monitor -AllowClobber -Force
  ```
- **Azure permissions**: Contributor or higher on the target subscription (to remove diagnostic settings)
- **PowerShell 5.1+** or PowerShell Core 7+

## Usage

### Basic Usage - Dry Run (Recommended First Step)

Preview what will be deleted without making any changes:

```powershell
.\Remove-DiagnosticSettings-Bulk.ps1 `
    -SubscriptionId "Production" `
    -DryRun
```

### Remove Settings Pointing to a Specific LAW

Remove all diagnostic settings that currently point to an old Log Analytics Workspace:

```powershell
.\Remove-DiagnosticSettings-Bulk.ps1 `
    -SubscriptionId "Production" `
    -LogAnalyticsWorkspaceId "/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/my-rg/providers/microsoft.operationalinsights/workspaces/old-law" `
    -ExportBeforeDelete
```

### Remove Settings from Specific Resource Type

Remove settings only from Virtual Machines in a resource group:

```powershell
.\Remove-DiagnosticSettings-Bulk.ps1 `
    -SubscriptionId "Production" `
    -ResourceGroupName "my-resource-group" `
    -ResourceType "Microsoft.Compute/virtualMachines" `
    -ExportBeforeDelete
```

### Remove All Diagnostic Settings (Dangerous - Use with Caution)

Remove ALL diagnostic settings in a subscription:

```powershell
.\Remove-DiagnosticSettings-Bulk.ps1 `
    -SubscriptionId "Production" `
    -ExportBeforeDelete
```

## Parameters

| Parameter | Required | Type | Description |
|-----------|----------|------|-------------|
| **SubscriptionId** | Yes | String | The subscription ID or name to target |
| **LogAnalyticsWorkspaceId** | No | String | Filter by source LAW ID (full ARM resource ID). Only removes settings pointing to this LAW |
| **ResourceGroupName** | No | String | Limit scope to a specific resource group |
| **ResourceType** | No | String | Filter by resource type (e.g., `Microsoft.Compute/virtualMachines`, `Microsoft.KeyVault/vaults`) |
| **ResourceName** | No | String | Filter by resource name pattern (supports wildcards) |
| **DryRun** | No | Switch | Preview what would be deleted without making changes |
| **ExportBeforeDelete** | No | Switch | Export all matched diagnostic settings to JSON before deletion (for recovery) |

## Safety Features

### ✅ Dry-Run Mode
Test the script without making any changes:
```powershell
-DryRun
```

### ✅ Confirmation Prompts
The script explicitly asks for confirmation before deleting:
```
WARNING: This will DELETE the diagnostic settings listed above.
This action cannot be easily undone.
Continue with deletion? Type 'yes' to confirm
```

### ✅ Automatic Backup Export
Export all diagnostic settings to JSON before deletion:
```powershell
-ExportBeforeDelete
```
Settings are saved to: `DiagnosticSettings_Export_[SubscriptionName]_[Timestamp].json`

### ✅ Detailed Logging
All operations are logged to a file:
```
DiagnosticSettings_Removal_[SubscriptionName]_[Timestamp].log
```
Includes timestamps, operation status (SUCCESS/ERROR/WARN), and detailed error messages.

### ✅ Error Handling
- Resources that don't support diagnostic settings are silently skipped
- Failed removals are logged and don't stop the script
- Clear error messages indicate what went wrong

## Output Files

The script creates two files in the working directory:

### Log File
```
DiagnosticSettings_Removal_[SubscriptionName]_[Timestamp].log
```
Contains all operations with timestamps and status levels.

### Export File (if -ExportBeforeDelete)
```
DiagnosticSettings_Export_[SubscriptionName]_[Timestamp].json
```
Contains complete JSON representation of all diagnostic settings that were deleted, for recovery if needed.

## Real-World Example

Scenario: You changed a `DeployIfNotExists` policy to target a new LAW. Now you need to clean up the old diagnostic settings.

**Step 1:** Get the old LAW ID
```powershell
# List all LAWs in your subscription
Get-AzOperationalInsightsWorkspace | Select-Object ResourceGroupName, Name, ResourceId
```

**Step 2:** Preview what will be removed
```powershell
.\Remove-DiagnosticSettings-Bulk.ps1 `
    -SubscriptionId "Production" `
    -LogAnalyticsWorkspaceId "/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/my-rg/providers/microsoft.operationalinsights/workspaces/old-law" `
    -DryRun
```

**Step 3:** Review the preview, then execute with backup
```powershell
.\Remove-DiagnosticSettings-Bulk.ps1 `
    -SubscriptionId "Production" `
    -LogAnalyticsWorkspaceId "/subscriptions/12345678-1234-1234-1234-123456789012/resourcegroups/my-rg/providers/microsoft.operationalinsights/workspaces/old-law" `
    -ExportBeforeDelete
```

**Step 4:** Type `yes` when prompted to confirm deletion

**Step 5:** Review the log file for confirmation

## Troubleshooting

### Authentication Loop
If you see "Run Connect-AzAccount to login" repeatedly:
- Ensure your Azure CLI is freshly authenticated
- Try: `Disconnect-AzAccount` and re-run the script

### No Resources Found
If the script finds no resources:
- Verify the subscription name/ID is correct
- Check your permissions in the subscription
- Try without resource group filter first

### "Cannot bind argument to parameter 'ResourceId'"
This means a resource doesn't support diagnostic settings. The script skips these automatically.

### Large Subscriptions Taking Long Time
For very large subscriptions (1000+ resources), the script queries each one. Consider:
- Using `-ResourceGroupName` to limit scope
- Using `-ResourceType` to target specific resource types

## Recovery

If something goes wrong:

1. **Check the log file** for what happened:
   ```powershell
   Get-Content "DiagnosticSettings_Removal_*.log" | Select-String "ERROR"
   ```

2. **Restore from backup** if you used `-ExportBeforeDelete`:
   ```powershell
   # The JSON file contains the full diagnostic setting objects
   # You can use them to recreate settings if needed
   Get-Content "DiagnosticSettings_Export_*.json" | ConvertFrom-Json
   ```

## Notes

- **Min-privilege**: This script requires Contributor role (not Owner) on the subscription
- **Performance**: Large subscriptions may take several minutes to scan
- **Cost**: Running this saves costs by preventing duplicate log ingestion
- **Idempotent**: Safe to run multiple times; already-deleted settings won't cause errors

## Support

For issues:
1. Review the generated log file for specific error messages
2. Ensure prerequisite PowerShell modules are installed
3. Verify you have the correct subscription and permissions
4. Check that the LAW ID format is correct (full ARM resource ID)