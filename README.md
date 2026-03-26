# Azure PowerShell Scripts

A community-driven collection of production-ready and field-tested PowerShell scripts for Azure management and operations. These scripts automate common Azure tasks, remediate configuration issues, and streamline administrative workflows.

## 📋 Scripts

### [Azure Diagnostic Settings](./Azure%20Diagnostic%20Settings/)

**Remove Diagnostic Settings in Bulk**

Safely identify and remove duplicate diagnostic settings from Azure resources in bulk. This script is designed to clean up diagnostic settings created by Azure Policy `DeployIfNotExists` effects when policy targets change (e.g., switching Log Analytics Workspaces).

**Key Features:**
- Dry-run mode for safe preview  
- Confirmation prompts and automatic backups  
- Filter by Log Analytics Workspace, resource group, or resource type  
- Detailed logging and audit trails  

**Script:** [`remove-diagnosticSettings.ps1`](./Azure%20Diagnostic%20Settings/remove-diagnosticSettings.ps1)  
**Documentation:** [Full README](./Azure%20Diagnostic%20Settings/README.md)

---

## 🚀 Getting Started

1. **Prerequisites:**
   - PowerShell 5.1+ or PowerShell Core 7+
   - Azure PowerShell modules (`Az.Accounts`, `Az.Monitor`, etc.)
   - Appropriate Azure permissions

2. **Install Azure PowerShell:**
   ```powershell
   Install-Module -Name Az -AllowClobber -Force
   ```

3. **Choose a script** from the list above and review its README for usage instructions.

4. **Always test first:**
   - Run with `-DryRun` flag if available
   - Test in non-production environments first
   - Review the preview output carefully

## ⚠️ Disclaimer

These scripts are provided as-is for community use. Users are responsible for:
- Testing thoroughly in non-production environments first
- Understanding what each script does before execution
- Having appropriate backups and recovery procedures
- Verifying they have correct Azure permissions
- Reviewing and modifying scripts to fit their organizational needs

The author assumes no liability for any damage, data loss, or unintended consequences.

## 🤝 Contributing

Community contributions are welcome! If you have:
- A useful Azure PowerShell script to share
- Improvements or bug fixes
- Documentation updates

Please feel free to submit pull requests or open issues.

## 💡 Support

For questions or issues:
1. Review the specific script's README
2. Check the troubleshooting section
3. Open an issue on GitHub with details about the problem

---

**Last Updated:** March 2026