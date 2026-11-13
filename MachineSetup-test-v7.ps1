#requires -Version 5.1
# MACHINE SETUP - DEVELOPMENT TEST v7 (based on approved baseline V0.09). Not an approved release.
# Run in a normal PowerShell window as the intended signed-in user.
# Office and all-user taskbar policy request UAC separately.

$ErrorActionPreference = 'Stop'
$KeepLanguages = @('en-gb')
$Work = Join-Path $env:LOCALAPPDATA 'MachineSetup'
$ODTDir = Join-Path $Work 'ODT'
$ODTExe = Join-Path $Work 'ODT.exe'
$InstallXML = Join-Path $Work 'InstallOffice.xml'
$RemoveXML = Join-Path $Work 'RemoveLanguages.xml'
$Helper = Join-Path $Work 'Configure-AllUsersTaskbar.ps1'
$Log = Join-Path $Work 'Setup.log'
$dellRemovalLog = Join-Path $Work 'DellRemovalLog.csv'
$ODTUrl = 'https://download.microsoft.com/download/6c1eeb25-cf8b-41d9-8d0d-cc1dbc032140/officedeploymenttool_20430-20146.exe'

$Result = [ordered]@{
    'ODT download' = 'Not started'
    'Office installation' = 'Not started'
    'Dell cleanup' = 'Not started'
    'Office languages' = 'Not started'
    'Adobe Acrobat Reader' = 'Not started'
    'OneDrive Files On-Demand' = 'Not attempted'
    'Outlook Cached Mode' = 'Not attempted'
    'Copilot button' = 'Not attempted'
    'All-user taskbar' = 'Not attempted'
    'Microsoft Edge defaults' = 'Not attempted'
}
$TranscriptStarted = $false
$SetupCompleted = $false
$CustomRun = $false
$machineReady = $false
$SetupVersion = 'test v7'

$StateRoot = Join-Path $env:ProgramData 'MachineSetup\Recovery'
$UserStateRoot = Join-Path $env:LOCALAPPDATA 'MachineSetup\Recovery'

function Show-Menu {
    Clear-Host
    Write-Host ''
    Write-Host '====================================================' -ForegroundColor Cyan
    Write-Host '          WINDOWS 11 PC SETUP & RECOVERY' -ForegroundColor Cyan
    Write-Host '====================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  1. Confirm & Install (everything)' -ForegroundColor Green
    Write-Host '     Clean Dell utilities, install Microsoft 365 and Adobe Reader, and apply settings including Edge defaults and taskbar pins.'
    Write-Host ''
    Write-Host '  2. Revert Setup Changes' -ForegroundColor Yellow
    Write-Host '     Restore saved settings and remove setup-created taskbar files.'
    Write-Host ''
    Write-Host '  3. Choose what to install' -ForegroundColor Cyan
    Write-Host '     Pick individual items from a list, e.g. only Adobe Reader or only Edge and taskbar settings.'
    Write-Host ''
    Write-Host '  0. Exit'
    Write-Host ''
    return (Read-Host 'Choose an option')
}

function Save-UserRegistryBackup {
    New-Item -Path $UserStateRoot -ItemType Directory -Force | Out-Null
    # Keep the first (pre-setup) backup. Re-running setup must not overwrite it with already-changed settings.
    if (Test-Path (Join-Path $UserStateRoot 'BackupCreated.txt')) { return }
    $backupFile = Join-Path $UserStateRoot 'UserSettings.reg'
    $key = 'HKCU\Software\Policies\Microsoft\Office\16.0\Outlook'
    $exists = Test-Path 'HKCU:\Software\Policies\Microsoft\Office\16.0\Outlook'
    Set-Content -Path (Join-Path $UserStateRoot 'OutlookKeyExisted.txt') -Value ([string]$exists)
    if ($exists) { & reg.exe export $key $backupFile /y | Out-Null }
    else { Remove-Item $backupFile -Force -ErrorAction SilentlyContinue }  # no stale backup from an earlier run

    $advancedKey = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $advancedFile = Join-Path $UserStateRoot 'ExplorerAdvanced.reg'
    & reg.exe export $advancedKey $advancedFile /y | Out-Null
    $copilotExisted = $null -ne (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowCopilotButton' -ErrorAction SilentlyContinue)
    Set-Content -Path (Join-Path $UserStateRoot 'CopilotValueExisted.txt') -Value ([string]$copilotExisted)

    $edgeKey = 'HKCU\Software\Policies\Microsoft\Edge'
    $edgeFile = Join-Path $UserStateRoot 'EdgePolicy.reg'
    $edgeExisted = Test-Path 'HKCU:\Software\Policies\Microsoft\Edge'
    Set-Content -Path (Join-Path $UserStateRoot 'EdgePolicyKeyExisted.txt') -Value ([string]$edgeExisted)
    if ($edgeExisted) { & reg.exe export $edgeKey $edgeFile /y | Out-Null }
    else { Remove-Item $edgeFile -Force -ErrorAction SilentlyContinue }  # no stale backup from an earlier run

    Set-Content -Path (Join-Path $UserStateRoot 'BackupCreated.txt') -Value (Get-Date -Format o)
}

function Invoke-Revert {
    Write-Host ''
    Write-Host 'REVERT SETUP CHANGES' -ForegroundColor Yellow
    Write-Host 'This restores saved settings for the current Windows user and machine-wide settings.'
    Write-Host 'It does not delete personal files or OneDrive content.'
    $confirm = Read-Host 'Type REVERT to continue'
    if ($confirm -cne 'REVERT') { Write-Host 'Revert cancelled.'; return }

    if (-not (Test-Path (Join-Path $UserStateRoot 'BackupCreated.txt')) -and
        -not (Test-Path (Join-Path $StateRoot 'MachineBackupCreated.txt'))) {
        Write-Host 'No recovery backup was found. Nothing has been changed.' -ForegroundColor Yellow
        return
    }

    if (Test-Path $UserStateRoot) {
        # reg import only adds/overwrites values, so clear each policy key first to remove values setup added.
        $outlookFile = Join-Path $UserStateRoot 'UserSettings.reg'
        if (Test-Path $outlookFile) {
            Remove-Item 'HKCU:\Software\Policies\Microsoft\Office\16.0\Outlook' -Recurse -Force -ErrorAction SilentlyContinue
            & reg.exe import $outlookFile | Out-Null
        }
        $outlookExistedFile = Join-Path $UserStateRoot 'OutlookKeyExisted.txt'
        if ((Test-Path $outlookExistedFile) -and
            (Get-Content $outlookExistedFile -Raw).Trim() -eq 'False') {
            Remove-Item 'HKCU:\Software\Policies\Microsoft\Office\16.0\Outlook' -Recurse -Force -ErrorAction SilentlyContinue
        }

        $advancedFile = Join-Path $UserStateRoot 'ExplorerAdvanced.reg'
        if (Test-Path $advancedFile) { & reg.exe import $advancedFile | Out-Null }
        # The Explorer\Advanced key holds many personal settings, so only the value setup added is removed.
        $copilotExistedFile = Join-Path $UserStateRoot 'CopilotValueExisted.txt'
        if ((Test-Path $copilotExistedFile) -and (Get-Content $copilotExistedFile -Raw).Trim() -eq 'False') {
            Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowCopilotButton' -ErrorAction SilentlyContinue
        }

        $edgeFile = Join-Path $UserStateRoot 'EdgePolicy.reg'
        if (Test-Path $edgeFile) {
            Remove-Item 'HKCU:\Software\Policies\Microsoft\Edge' -Recurse -Force -ErrorAction SilentlyContinue
            & reg.exe import $edgeFile | Out-Null
        }
        $edgeExistedFile = Join-Path $UserStateRoot 'EdgePolicyKeyExisted.txt'
        if ((Test-Path $edgeExistedFile) -and (Get-Content $edgeExistedFile -Raw).Trim() -eq 'False') {
            Remove-Item 'HKCU:\Software\Policies\Microsoft\Edge' -Recurse -Force -ErrorAction SilentlyContinue
        }
        # Allow the next setup run to take a fresh backup.
        Remove-Item (Join-Path $UserStateRoot 'BackupCreated.txt') -Force -ErrorAction SilentlyContinue
    }

    $revertHelper = Join-Path $Work 'Revert-MachineSetup.ps1'
    $helper = @'
$ErrorActionPreference = "Stop"
$state = Join-Path $env:ProgramData "MachineSetup\Recovery"
$policy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"
$oneDrive = "HKLM:\SOFTWARE\Policies\Microsoft\OneDrive"
$edge = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
$cloud = "HKLM:\SYSTEM\CurrentControlSet\Services\CldFlt"

foreach ($item in @(
    @{ Key = "HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer"; File = "ExplorerPolicy.reg"; Path = $policy; ClearFirst = $true },
    @{ Key = "HKLM\SOFTWARE\Policies\Microsoft\OneDrive"; File = "OneDrivePolicy.reg"; Path = $oneDrive; ClearFirst = $true },
    @{ Key = "HKLM\SOFTWARE\Policies\Microsoft\Edge"; File = "EdgePolicy.reg"; Path = $edge; ClearFirst = $true },
    @{ Key = "HKLM\SYSTEM\CurrentControlSet\Services\CldFlt"; File = "CloudFilter.reg"; Path = $cloud; ClearFirst = $false }
)) {
    $file = Join-Path $state $item.File
    $marker = Join-Path $state ($item.File + ".existed")
    if (Test-Path $file) {
        # reg import only adds/overwrites values; clear policy keys first so values added by setup are removed.
        # The CldFlt service key is never deleted - only its saved values are re-imported.
        if ($item.ClearFirst) { Remove-Item $item.Path -Recurse -Force -ErrorAction SilentlyContinue }
        & reg.exe import $file | Out-Null
    }
    elseif ((Test-Path $marker) -and (Get-Content $marker -Raw).Trim() -eq "False") {
        Remove-Item $item.Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$common = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\MachineSetup"
Remove-Item $common -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:ProgramData "MachineSetup\TaskbarLayout.xml") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $state "MachineBackupCreated.txt") -Force -ErrorAction SilentlyContinue
Write-Output "Machine-wide policies and setup-created taskbar files have been reverted where backups were available."
'@
    $helper | Set-Content -Path $revertHelper -Encoding UTF8
    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $revertArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $revertHelper
    if (IsAdmin) { $proc = Start-Process $psExe -ArgumentList $revertArgs -Wait -PassThru }
    else { $proc = Start-Process $psExe -ArgumentList $revertArgs -Verb RunAs -Wait -PassThru }
    if ($proc.ExitCode -ne 0) { throw "Machine revert helper failed with exit code $($proc.ExitCode)." }

    Write-Host ''
    Write-Host 'Settings and setup-created taskbar files have been reverted where backups existed.' -ForegroundColor Green
    Write-Host 'Installed applications (Office and Adobe Reader) have NOT been uninstalled.'
    Write-Host 'Edge policy settings are restored for the current Windows user when a backup was available.' -ForegroundColor Yellow
    Write-Host 'Dell utilities removed during setup are logged in DellRemovalLog.csv; reinstalling them requires their vendor installers.' -ForegroundColor Yellow
    Write-Host 'Other Windows user profiles have not had their per-user settings restored.'
}

function Status([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray) {
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'),$Text) -ForegroundColor $Color
}
function IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function RunODT([string]$Setup,[string]$ArgumentText) {
    if ([string]::IsNullOrWhiteSpace($ArgumentText)) { throw 'Office Deployment Tool arguments were empty.' }
    try {
        if (IsAdmin) {
            $p = Start-Process -FilePath $Setup -ArgumentList $ArgumentText -Wait -PassThru -ErrorAction Stop
        } else {
            Status 'Office setup needs administrator approval.' Yellow
            $p = Start-Process -FilePath $Setup -ArgumentList $ArgumentText -Verb RunAs -Wait -PassThru -ErrorAction Stop
        }
        if ($null -eq $p) { throw 'Could not start Office Deployment Tool.' }
        return $p.ExitCode
    } catch {
        $cancelled = ($_.Exception.NativeErrorCode -eq 1223) -or
                     ($_.Exception.Message -match '(?i)operation was canceled by the user|operation was cancelled by the user')
        if ($cancelled) {
            Status 'Administrator approval was cancelled at the UAC prompt.' Yellow
            return 1223
        }
        throw
    }
}
function FindOffice {
    $paths = @()
    $key = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    if (Test-Path $key) {
        $c = Get-ItemProperty $key
        if ($c.InstallationPath) {
            $paths += (Join-Path $c.InstallationPath 'root\Office16')
            $paths += (Join-Path $c.InstallationPath 'Office16')
        }
    }
    $paths += (Join-Path $env:ProgramFiles 'Microsoft Office\root\Office16')
    if (${env:ProgramFiles(x86)}) {
        $paths += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Office\root\Office16')
    }
    foreach ($p in ($paths | Select-Object -Unique)) {
        if (Test-Path (Join-Path $p 'WINWORD.EXE')) { return $p }
    }
    return $null
}

function ConvertTo-OfficeCulture([string]$Text) {
    # Returns a lower-case culture tag (e.g. de-de) or $null. x-none (language-neutral) is not a language.
    # Proofing tools carry a ".proof" suffix (e.g. es-es.proof); the suffix is removed here.
    if ($Text -match '^([a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})+)(\.proof)?$') { return $Matches[1].ToLowerInvariant() }
    return $null
}

function Add-LanguageToMap([hashtable]$Map,[string]$Product,[string]$Culture) {
    if (-not $Product -or -not $Culture) { return }
    if (-not $Map.ContainsKey($Product)) { $Map[$Product] = New-Object System.Collections.ArrayList }
    if (-not $Map[$Product].Contains($Culture)) { [void]$Map[$Product].Add($Culture) }
}

function Get-OfficeC2RLanguageMap {
    # SOURCE A - the ACTIVE Click-to-Run configuration, recorded per product
    # (e.g. O365BusinessRetail, LanguagePack, ProofingTools) so removal can name the product that owns each language.
    # Older, inactive configurations under ProductReleaseIDs are ignored.
    $result = [pscustomobject]@{ Found = $false; Map = @{} }
    $root = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\ProductReleaseIDs'
    if (-not (Test-Path $root)) { return $result }
    $active = $null
    $rootProps = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue
    if ($rootProps.ActiveConfiguration -and (Test-Path (Join-Path $root $rootProps.ActiveConfiguration))) {
        $active = Join-Path $root $rootProps.ActiveConfiguration
    } elseif (Test-Path (Join-Path $root 'Active')) {
        $active = Join-Path $root 'Active'
    }
    if (-not $active) { return $result }
    foreach ($k in (Get-ChildItem -Path $active -Recurse -ErrorAction SilentlyContinue)) {
        $culture = ConvertTo-OfficeCulture $k.PSChildName
        if (-not $culture) { continue }
        $parent = Split-Path -Path $k.PSParentPath -Leaf
        $product = ($parent -split '\.')[0]
        if ($k.PSChildName -match '(?i)\.proof$') { $product = 'ProofingTools' }
        if ($product -match '^[A-Za-z][A-Za-z0-9]+$') { Add-LanguageToMap $result.Map $product $culture }
    }
    # Only trust this source when it actually lists languages (avoids false failures if its layout differs).
    $result.Found = ($result.Map.Count -gt 0)
    return $result
}

function Get-CultureFromName([string]$Name) {
    # "Microsoft 365 Apps for business - es-es.proof" -> Culture es-es, Proofing true
    if ($Name -match '\s-\s([A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})+)(\.proof)?\s*$') {
        return [pscustomobject]@{ Culture = $Matches[1].ToLowerInvariant(); Proofing = [bool]$Matches[2] }
    }
    return $null
}

function Get-OfficeArpLanguageEntries {
    # SOURCE B - Windows Uninstall entries written by Click-to-Run (the "<product> - <culture>" entries in
    # Programs and Features), read from both 64-bit and 32-bit registry views.
    # Proofing entries (".proof") are attributed to the ProofingTools product.
    # Entries whose uninstall command can't be parsed are still listed (from their name) with no product;
    # those are removed through their own uninstall command, never through ODT.
    $entries = @()
    foreach ($u in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($k in (Get-ChildItem -Path $u -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
            $us = [string]$p.UninstallString
            if ($us -notmatch '(?i)OfficeClickToRun\.exe') { continue }
            $matched = $false
            foreach ($m in [regex]::Matches($us, '(?i)productstoremove=(\S+)')) {
                foreach ($token in ($m.Groups[1].Value -split '\|')) {
                    if ($token -match '^([A-Za-z][A-Za-z0-9]+)\.\d+_([A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})+)(\.proof)?(?:_|$)') {
                        $isProof = [bool]$Matches[3]
                        $entries += [pscustomobject]@{
                            Product         = $(if ($isProof) { 'ProofingTools' } else { $Matches[1] })
                            Culture         = $Matches[2].ToLowerInvariant()
                            Proofing        = $isProof
                            DisplayName     = [string]$p.DisplayName
                            UninstallString = $us
                        }
                        $matched = $true
                    }
                }
            }
            if (-not $matched) {
                $n = Get-CultureFromName ([string]$p.DisplayName)
                if ($n) {
                    $entries += [pscustomobject]@{
                        Product         = $(if ($n.Proofing) { 'ProofingTools' } else { $null })
                        Culture         = $n.Culture
                        Proofing        = $n.Proofing
                        DisplayName     = [string]$p.DisplayName
                        UninstallString = $us
                    }
                }
            }
        }
    }
    return $entries
}

function Get-OfficeArpNameLanguages {
    # SOURCE D (verification only) - the language shown at the END OF EACH OFFICE ENTRY'S NAME in
    # Programs and Features (e.g. "... - es-es.proof"), read independently of the uninstall command.
    $langs = @()
    foreach ($u in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($k in (Get-ChildItem -Path $u -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
            if ([string]$p.UninstallString -notmatch '(?i)OfficeClickToRun\.exe') { continue }
            $n = Get-CultureFromName ([string]$p.DisplayName)
            if ($n) { $langs += $n.Culture }
        }
    }
    return @($langs | Sort-Object -Unique)
}

function Get-OfficeFolderLanguages {
    # SOURCE C - language resource folders on disk under Office16 (folder names are LCIDs, e.g. 2057 = en-gb).
    $langs = @()
    $office = FindOffice
    if (-not $office) { return $langs }
    foreach ($d in (Get-ChildItem -Path $office -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -notmatch '^\d{4,5}$') { continue }
        try { $langs += ([Globalization.CultureInfo]::GetCultureInfo([int]$d.Name)).Name.ToLowerInvariant() } catch {}
    }
    return @($langs | Sort-Object -Unique)
}

function Get-OfficeC2RInfo {
    $info = [pscustomobject]@{
        Installed   = $false                 # Click-to-Run Microsoft 365 Apps present
        OtherOffice = $false                 # Word present but not Click-to-Run (ODT cannot manage it)
        ProductId   = 'O365BusinessRetail'   # used for a fresh install, or the detected main product
        Edition     = '64'
        Languages   = @()                    # every detected language, any product
        Products    = @{}                    # product -> languages (sources A and B combined)
        Reliable    = $false                 # at least one registry source could be read
        IsBusiness  = $true                  # main product is Microsoft 365 Apps for business/enterprise
        ArpOnly     = @()                    # languages seen only in Programs and Features, product unknown
    }
    $cfgKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $cfg = $null
    if (Test-Path $cfgKey) { $cfg = Get-ItemProperty -Path $cfgKey -ErrorAction SilentlyContinue }

    if ($cfg -and $cfg.ProductReleaseIds -and (FindOffice)) {
        $info.Installed = $true
        $ids = @(([string]$cfg.ProductReleaseIds -split ',') |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and $_ -notmatch '(?i)^(LanguagePack|ProofingTools)' -and $_ -notmatch '\.' })
        # Prefer a business/enterprise product when more than one is installed.
        $main = $ids | Where-Object { $_ -match '^O365(Business|ProPlus)' } | Select-Object -First 1
        if (-not $main) { $main = $ids | Where-Object { $_ -match '^(O365|Microsoft365|ProPlus|Standard|HomeBusiness|HomeStudent|Personal|Professional)' } | Select-Object -First 1 }
        if (-not $main) { $main = $ids | Select-Object -First 1 }
        if ($main) { $info.ProductId = $main }
        $info.IsBusiness = ($info.ProductId -match '^O365(Business|ProPlus)')
        if ($cfg.Platform -eq 'x86') { $info.Edition = '32' }

        # Detection deliberately combines two registry sources: a language counts as installed if either reports it.
        $c2r = Get-OfficeC2RLanguageMap
        $arp = @(Get-OfficeArpLanguageEntries)
        $products = @{}
        foreach ($prod in $c2r.Map.Keys) { foreach ($l in $c2r.Map[$prod]) { Add-LanguageToMap $products $prod $l } }
        foreach ($e in $arp) { Add-LanguageToMap $products $e.Product $e.Culture }
        $info.Products = $products
        $info.ArpOnly = @($arp | Where-Object { -not $_.Product } | ForEach-Object { $_.Culture } | Sort-Object -Unique)
        $info.Languages = @(@($products.Values | ForEach-Object { $_ }) + @($info.ArpOnly) | Sort-Object -Unique)
        $info.Reliable = ($c2r.Found -or $arp.Count -gt 0)
    }
    elseif (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\winword.exe') {
        $info.OtherOffice = $true
    }
    return $info
}

function New-OdtAddConfig([string]$Path,[string]$ProductId,[string]$Edition,[string[]]$Languages,[switch]$Existing) {
    if ($Existing) {
        # Adding a language to an existing install: keep the installed build, channel and architecture.
        $addLine = (' <Add Version="MatchInstalled" OfficeClientEdition="{0}" AllowCdnFallback="TRUE">' -f $Edition)
    } else {
        $addLine = (' <Add OfficeClientEdition="{0}" Channel="Current" AllowCdnFallback="TRUE">' -f $Edition)
    }
    $lines = @(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<Configuration>'
        $addLine
        ('  <Product ID="{0}">' -f $ProductId)
    )
    foreach ($l in $Languages) { $lines += ('   <Language ID="{0}" />' -f $l) }
    $lines += @(
        '  </Product>'
        ' </Add>'
    )
    if (-not $Existing) { $lines += ' <Updates Enabled="TRUE" />' }
    $lines += @(
        ' <Display Level="None" AcceptEULA="TRUE" />'
        (' <Logging Level="Standard" Path="{0}" />' -f $Work)
        '</Configuration>'
    )
    $lines | Set-Content -Path $Path -Encoding UTF8
}

function New-OdtRemoveLanguagesConfig([string]$Path,[hashtable]$ByProduct) {
    # One Product element per owning product (e.g. O365BusinessRetail, LanguagePack, ProofingTools).
    # Language elements under Remove/Product remove only those languages, not the product.
    $lines = @(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<Configuration>'
        ' <Remove All="FALSE">'
    )
    foreach ($prod in ($ByProduct.Keys | Sort-Object)) {
        $lines += ('  <Product ID="{0}">' -f $prod)
        foreach ($l in $ByProduct[$prod]) { $lines += ('   <Language ID="{0}" />' -f $l) }
        $lines += '  </Product>'
    }
    $lines += @(
        ' </Remove>'
        ' <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />'
        ' <Display Level="None" AcceptEULA="TRUE" />'
        (' <Logging Level="Standard" Path="{0}" />' -f $Work)
        '</Configuration>'
    )
    $lines | Set-Content -Path $Path -Encoding UTF8
}

function New-OdtRemoveProductConfig([string]$Path,[string]$ProductId,[string[]]$Languages) {
    # Removes one whole product (all its listed languages). Used only to replace a consumer Office edition.
    $lines = @(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<Configuration>'
        ' <Remove All="FALSE">'
        ('  <Product ID="{0}">' -f $ProductId)
    )
    foreach ($l in @($Languages | Where-Object { $_ })) { $lines += ('   <Language ID="{0}" />' -f $l) }
    $lines += @(
        '  </Product>'
        ' </Remove>'
        ' <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />'
        ' <Display Level="None" AcceptEULA="TRUE" />'
        (' <Logging Level="Standard" Path="{0}" />' -f $Work)
        '</Configuration>'
    )
    $lines | Set-Content -Path $Path -Encoding UTF8
}

function Invoke-ArpLanguageRemoval([string[]]$Languages) {
    # Fallback: run the same uninstall command Programs and Features uses, silently, for each leftover
    # language entry. Never touches a language in $KeepLanguages.
    $done = @()
    foreach ($e in @(Get-OfficeArpLanguageEntries)) {
        if ($KeepLanguages -contains $e.Culture) { continue }
        if ($Languages -notcontains $e.Culture) { continue }
        if ($done -contains $e.UninstallString) { continue }
        $done += $e.UninstallString
        $mentionsKept = $false
        foreach ($k in $KeepLanguages) { if ($e.UninstallString -match ('(?i)(_|culture=)' + [regex]::Escape($k) + '(\.proof)?(_|\s|$)')) { $mentionsKept = $true } }
        if ($mentionsKept) {
            Status ('Skipped {0}: its uninstall command also covers {1}.' -f $e.DisplayName,($KeepLanguages -join ', ')) Yellow
            continue
        }
        if ($e.UninstallString -notmatch '^\s*"([^"]+OfficeClickToRun\.exe)"\s*(.*)$') {
            Status ('Skipped {0}: unexpected uninstall command format.' -f $e.DisplayName) Yellow
            continue
        }
        $exe = $Matches[1]; $c2rArgs = $Matches[2].Trim()
        if ($c2rArgs -notmatch '(?i)DisplayLevel=') { $c2rArgs += ' DisplayLevel=False' }
        Status ('Removing via its uninstall entry: {0}' -f $e.DisplayName) Cyan
        $code = RunODT $exe $c2rArgs
        Status ('Uninstall entry for {0} returned exit code {1}' -f $e.Culture,$code) Gray
    }
}

function Get-LanguageVerdict {
    # Independent verification. Each source is checked separately; a leftover in ANY registry source is a failure.
    # Source A (active C2R config) and B (Uninstall entries) are registry-based; C (folders on disk) is separate.
    $c2r = Get-OfficeC2RLanguageMap
    $arp = @(Get-OfficeArpLanguageEntries)
    $sources = [ordered]@{}
    if ($c2r.Found) { $sources['Click-to-Run config'] = @($c2r.Map.Values | ForEach-Object { $_ } | Sort-Object -Unique) }
    if ($arp.Count -gt 0) { $sources['Programs and Features'] = @($arp | ForEach-Object { $_.Culture } | Sort-Object -Unique) }
    $nameLangs = @(Get-OfficeArpNameLanguages)
    if ($nameLangs.Count -gt 0) { $sources['Programs and Features names'] = $nameLangs }
    $folders = @(Get-OfficeFolderLanguages)

    $failed = @(); $unverified = @(); $remaining = @()
    if ($sources.Count -eq 0) { $unverified += 'no Office language registry source could be read' }
    foreach ($name in $sources.Keys) {
        $left = @($sources[$name] | Where-Object { $KeepLanguages -notcontains $_ })
        $missing = @($KeepLanguages | Where-Object { $sources[$name] -notcontains $_ })
        if ($left.Count -gt 0) { $failed += ('{0} still lists {1}' -f $name,($left -join ', ')); $remaining += $left }
        if ($missing.Count -gt 0) { $failed += ('{0} does not list {1}' -f $name,($missing -join ', ')) }
    }
    $folderLeft = @($folders | Where-Object { $KeepLanguages -notcontains $_ })
    $folderMissing = @($KeepLanguages | Where-Object { $folders -notcontains $_ })
    if ($folderLeft.Count -gt 0) { $unverified += ('language folders still on disk: {0}' -f ($folderLeft -join ', ')) }
    if ($folderMissing.Count -gt 0) { $unverified += ('no language folder found for {0}' -f ($folderMissing -join ', ')) }

    $office = FindOffice
    foreach ($exe in @('WINWORD.EXE','EXCEL.EXE','OUTLOOK.EXE')) {
        if (-not $office -or -not (Test-Path (Join-Path $office $exe))) { $failed += ('{0} not found' -f $exe) }
    }

    if ($failed.Count -gt 0) {
        $outcome = 'FAILED'; $text = ($failed + $unverified) -join '; '
    } elseif ($unverified.Count -gt 0) {
        $outcome = 'COULD NOT VERIFY'; $text = $unverified -join '; '
    } else {
        $outcome = 'VERIFIED'
        $text = ('only {0} installed (checked: {1}, language folders); Word, Excel and Outlook present' -f ($KeepLanguages -join ', '),(@($sources.Keys) -join ', '))
    }
    return [pscustomobject]@{
        Outcome   = $outcome
        Text      = ('{0}: {1}' -f $outcome,$text)
        Remaining = @($remaining | Sort-Object -Unique)
    }
}

function Install-WinGetIfMissing {
    # Returns the WinGet command. If WinGet is missing, tries two Microsoft-documented methods
    # for the signed-in user: (1) register the App Installer package that ships with Windows 11,
    # (2) install it with Repair-WinGetPackageManager from the Microsoft.WinGet.Client module.
    # Returns $null if WinGet still cannot be found.
    $find = {
        $c = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $c) {
            $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
            if (Test-Path $alias) { $c = Get-Command $alias -ErrorAction SilentlyContinue }
        }
        $c
    }
    $cmd = & $find
    if ($cmd) { return $cmd }

    Status 'WinGet not found. Registering App Installer for this user...' Yellow
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop
        Start-Sleep -Seconds 5
    } catch {
        Status ('App Installer registration did not succeed: {0}' -f $_.Exception.Message) Yellow
    }
    $cmd = & $find
    if ($cmd) { Status 'WinGet is now available.' Green; return $cmd }

    Status 'Installing WinGet with the Microsoft.WinGet.Client PowerShell module...' Yellow
    $oldProgress = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $nuget = Get-PackageProvider -ListAvailable -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'NuGet' -and $_.Version -ge [version]'2.8.5.201' }
        if (-not $nuget) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
        }
        Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Import-Module Microsoft.WinGet.Client -Force -ErrorAction Stop
        Repair-WinGetPackageManager -Latest -Force -ErrorAction Stop
        Start-Sleep -Seconds 5
    } catch {
        Status ('WinGet installation did not succeed: {0}' -f $_.Exception.Message) Yellow
    } finally {
        $ProgressPreference = $oldProgress
    }
    $cmd = & $find
    if ($cmd) { Status 'WinGet is now available.' Green }
    return $cmd
}

function Select-SetupItems {
    # Returns an ordered table of the items chosen, or $null if cancelled / invalid.
    $items = @(
        @{ Key = 'Dell';    Text = 'Remove Dell utilities (Dell PCs only)' }
        @{ Key = 'Office';  Text = 'Install Microsoft 365 and keep en-GB as the only Office language' }
        @{ Key = 'Adobe';   Text = 'Install Adobe Acrobat Reader' }
        @{ Key = 'Outlook'; Text = 'Outlook Classic Cached Exchange Mode (this user)' }
        @{ Key = 'Copilot'; Text = 'Hide the Copilot taskbar button (this user)' }
        @{ Key = 'Machine'; Text = 'All users: OneDrive Files On-Demand, Edge Google defaults and taskbar pins (needs Microsoft 365)' }
    )
    Write-Host ''
    Write-Host 'CHOOSE WHAT TO INSTALL' -ForegroundColor Cyan
    for ($i = 0; $i -lt $items.Count; $i++) { Write-Host ('  {0}. {1}' -f ($i + 1),$items[$i].Text) }
    Write-Host ''
    $answer = Read-Host 'Enter the numbers you want, separated by commas (e.g. 1,3,6), or press ENTER to cancel'
    if ([string]::IsNullOrWhiteSpace($answer)) { return $null }
    $run = [ordered]@{}
    foreach ($it in $items) { $run[$it.Key] = $false }
    foreach ($part in @($answer -split '[,\s]+' | Where-Object { $_ })) {
        $n = 0
        if (-not [int]::TryParse($part, [ref]$n) -or $n -lt 1 -or $n -gt $items.Count) {
            Write-Host ("'{0}' is not a valid option." -f $part) -ForegroundColor Yellow
            return $null
        }
        $run[$items[$n - 1].Key] = $true
    }
    Write-Host ''
    Write-Host 'Selected:' -ForegroundColor Green
    foreach ($it in $items) { if ($run[$it.Key]) { Write-Host ('  - {0}' -f $it.Text) } }
    if ($run['Machine'] -and -not $run['Office'] -and -not (FindOffice)) {
        Write-Host 'Warning: Microsoft 365 is not installed, so the all-users step will be skipped. Add option 2 as well.' -ForegroundColor Yellow
    }
    return $run
}

$choice = Show-Menu
if ($choice -eq '0') { return }
if ($choice -eq '2') {
    try { Invoke-Revert } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
    Read-Host 'Press ENTER to close this PowerShell window' | Out-Null
    return
}
# Option 1 runs everything. Option 3 runs only the chosen items.
$Run = [ordered]@{ Dell = $true; Office = $true; Adobe = $true; Outlook = $true; Copilot = $true; Machine = $true }
if ($choice -eq '3') {
    $Run = Select-SetupItems
    if (-not $Run) {
        Write-Host 'Nothing selected. No changes were made.' -ForegroundColor Yellow
        Read-Host 'Press ENTER to close this PowerShell window' | Out-Null
        return
    }
    $CustomRun = $true
}
elseif ($choice -ne '1') {
    Write-Host 'Invalid selection. No changes were made.' -ForegroundColor Yellow
    Read-Host 'Press ENTER to close this PowerShell window' | Out-Null
    return
}
$approval = Read-Host 'This will install apps and change Windows settings. Type INSTALL to continue'
if ($approval -cne 'INSTALL') {
    Write-Host 'Setup cancelled. No changes were made.'
    Read-Host 'Press ENTER to close this PowerShell window' | Out-Null
    return
}

# Items that were not chosen show as "Not selected" in the summary.
$ResultKeys = @{
    Dell    = @('Dell cleanup')
    Office  = @('ODT download','Office installation','Office languages')
    Adobe   = @('Adobe Acrobat Reader')
    Outlook = @('Outlook Cached Mode')
    Copilot = @('Copilot button')
    Machine = @('OneDrive Files On-Demand','Microsoft Edge defaults','All-user taskbar')
}
foreach ($k in $ResultKeys.Keys) {
    if (-not $Run[$k]) { foreach ($r in $ResultKeys[$k]) { $Result[$r] = 'Not selected' } }
}

try {
    New-Item -Path $Work -ItemType Directory -Force | Out-Null
    Start-Transcript -Path $Log -Append | Out-Null
    $TranscriptStarted = $true
    Save-UserRegistryBackup

    if ($Run['Dell']) {  # menu selection - stage code below is unchanged
    # STAGE 0 - Remove selected Dell utilities only on Dell hardware.
    Write-Host ''
    Status 'STAGE 0: Checking for Dell hardware and removing selected Dell utilities...' Cyan
    $dellRemovalLog = Join-Path $Work 'DellRemovalLog.csv'
    $dellResults = @()
    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($computer.Manufacturer -match '(?i)\bDell\b') {
            Status ("Dell hardware detected: {0} {1}" -f $computer.Manufacturer,$computer.Model) Green
            $wingetCmd = Install-WinGetIfMissing
            if (-not $wingetCmd) {
                $Result['Dell cleanup'] = 'Dell detected; WinGet unavailable, no Dell apps removed'
                Status 'WinGet is unavailable. Dell application removal was skipped.' Yellow
            } else {
                $dellApps = @(
                    @{ Name = 'Dell SupportAssist (desktop)'; Id = 'Dell.SupportAssist' },
                    @{ Name = 'Dell SupportAssist (Store)'; Id = 'DellInc.DellSupportAssistforPCs'; AppxName = 'DellInc.DellSupportAssistforPCs' },
                    @{ Name = 'Dell SupportAssist Remediation'; Id = 'Dell.SupportAssistRemediation' },
                    @{ Name = 'Dell Digital Delivery'; Id = 'Dell.DigitalDelivery' },
                    @{ Name = 'MyDell'; Id = 'DellInc.MyDell'; AppxName = 'DellInc.MyDell' },
                    @{ Name = 'Dell Optimizer'; Id = 'Dell.Optimizer' },
                    @{ Name = 'Dell Display and Peripheral Manager (current combined app)'; Id = 'Dell.DisplayAndPeripheralManager' },
                    @{ Name = 'Dell Peripheral Manager (legacy package)'; Id = 'Dell.PeripheralManager' },
                    @{ Name = 'Dell Display Manager (legacy package)'; Id = 'Dell.DisplayManager' }
                )
                foreach ($app in $dellApps) {
                    $uninstall = Start-Process -FilePath $wingetCmd.Source -ArgumentList @(
                        'uninstall','--id',$app.Id,'--exact','--silent',
                        '--disable-interactivity','--accept-source-agreements'
                    ) -Wait -PassThru -NoNewWindow
                    $removed = $false
                    if ($uninstall.ExitCode -eq 0) {
                        $statusText = 'Uninstall command completed'
                        $removed = $true
                        Status ("Uninstall command completed: {0}" -f $app.Name) Green
                    } elseif ($uninstall.ExitCode -eq -1978335212) {
                        # 0x8A150014 APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND
                        $statusText = 'Not installed (WinGet found no matching package)'
                        Status ("{0}: {1}" -f $app.Name,$statusText) Gray
                    } else {
                        $statusText = "Uninstall failed (exit $($uninstall.ExitCode))"
                        Status ("{0}: {1}" -f $app.Name,$statusText) Yellow
                    }
                    # Store (MSIX) apps may not match a WinGet ID; remove the app package for this user directly.
                    if (-not $removed -and $app.AppxName) {
                        $appx = @(Get-AppxPackage -Name $app.AppxName -ErrorAction SilentlyContinue)
                        if ($appx.Count -gt 0) {
                            try {
                                $appx | Remove-AppxPackage -ErrorAction Stop
                                $statusText = 'Removed Store app package for this user'
                                $removed = $true
                                Status ("{0}: {1}" -f $app.Name,$statusText) Green
                            } catch {
                                $statusText = "Store app package removal failed: $($_.Exception.Message)"
                                Status ("{0}: {1}" -f $app.Name,$statusText) Yellow
                            }
                        }
                    }
                    $dellResults += [pscustomobject]@{
                        Application = $app.Name
                        PackageId = $app.Id
                        Result = $statusText
                        ExitCode = $uninstall.ExitCode
                        Removed = $removed
                    }
                }
                $dellResults | Export-Csv -Path $dellRemovalLog -NoTypeInformation -Encoding UTF8
                $removedCount = @($dellResults | Where-Object { $_.Removed }).Count
                $Result['Dell cleanup'] = "$removedCount of $($dellApps.Count) apps removed; see DellRemovalLog.csv"
                Status $Result['Dell cleanup'] Green
            }
        } else {
            $Result['Dell cleanup'] = "Skipped: manufacturer is $($computer.Manufacturer)"
            Status 'This is not a Dell computer. Dell clean-up skipped.' Green
        }
    } catch {
        $Result['Dell cleanup'] = "Could not complete: $($_.Exception.Message)"
        Status $Result['Dell cleanup'] Yellow
    }

    } # end Dell

    Write-Host ''
    Write-Host '====================================================' -ForegroundColor Cyan
    Write-Host '             WINDOWS 11 ONE-FILE SETUP' -ForegroundColor Cyan
    Write-Host '====================================================' -ForegroundColor Cyan
    Status ("Signed-in account: {0}" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name)
    if (IsAdmin) {
        Status 'PowerShell is elevated. Copilot changes apply to this signed-in account.' Yellow
    } else {
        Status 'Running non-elevated. This is recommended; UAC is requested only for machine changes.' Green
    }

    if ($Run['Office']) {  # menu selection - stage code below is unchanged
    # Download the Office Deployment Tool only when Office actually needs installing or changing.
    $KeepLanguages = @($KeepLanguages | ForEach-Object { $_.ToLowerInvariant() })
    $preInfo = Get-OfficeC2RInfo
    $needODT = $true
    if ($preInfo.OtherOffice) { $needODT = $false }
    elseif ($preInfo.Installed -and $preInfo.Reliable -and $preInfo.IsBusiness) {
        $preExtra = @($preInfo.Languages | Where-Object { $KeepLanguages -notcontains $_ })
        $preMain = @($preInfo.Products[$preInfo.ProductId])
        $preMissing = @($KeepLanguages | Where-Object { $preMain -notcontains $_ })
        if ($preExtra.Count -eq 0 -and $preMissing.Count -eq 0) { $needODT = $false }
    }
    if (-not $needODT) {
        $Result['ODT download'] = 'Not needed: no Office changes required'
        Write-Host ''
        Status 'STAGE 1: Office Deployment Tool not needed - no Office changes required.' Green
    } else {
    # STAGE 1 - Download ODT directly from Microsoft
    Write-Host ''
    Status 'STAGE 1: Downloading Microsoft Office Deployment Tool...' Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # Look up the current ODT download on Microsoft's download page; fall back to the built-in link.
    $odtSource = $ODTUrl
    try {
        $odtPage = Invoke-WebRequest -Uri 'https://www.microsoft.com/en-us/download/details.aspx?id=49117' -UseBasicParsing -ErrorAction Stop
        $odtMatch = [regex]::Match($odtPage.Content, 'https://download\.microsoft\.com/download/[^"''\s<>]+/officedeploymenttool_[\d-]+\.exe')
        if ($odtMatch.Success) { $odtSource = $odtMatch.Value; Status ("Latest ODT link found: {0}" -f $odtSource) Green }
        else { Status 'Could not read the latest ODT link from Microsoft; using the built-in link.' Yellow }
    } catch {
        Status 'Could not reach the Microsoft ODT download page; using the built-in link.' Yellow
    }
    try {
        Invoke-WebRequest -Uri $odtSource -OutFile $ODTExe -UseBasicParsing -ErrorAction Stop
    } catch {
        if ($odtSource -ne $ODTUrl) {
            Status 'Latest ODT link failed; trying the built-in link.' Yellow
            try { Invoke-WebRequest -Uri $ODTUrl -OutFile $ODTExe -UseBasicParsing -ErrorAction Stop }
            catch { throw "Could not download the Office Deployment Tool. The built-in link may be out of date - update `$ODTUrl at the top of the script from https://www.microsoft.com/en-us/download/details.aspx?id=49117" }
        } else {
            throw "Could not download the Office Deployment Tool. The built-in link may be out of date - update `$ODTUrl at the top of the script from https://www.microsoft.com/en-us/download/details.aspx?id=49117"
        }
    }
    if (-not (Test-Path $ODTExe)) { throw 'ODT download file was not created.' }
    $sig = Get-AuthenticodeSignature -FilePath $ODTExe
    if ($sig.Status -ne 'Valid') { throw "ODT signature check failed: $($sig.Status)" }
    if ($sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw "ODT is not signed by Microsoft: $($sig.SignerCertificate.Subject)" }
    New-Item -Path $ODTDir -ItemType Directory -Force | Out-Null
    Start-Process -FilePath $ODTExe -ArgumentList "/quiet /extract:`"$ODTDir`"" -Wait
    $Setup = Join-Path $ODTDir 'setup.exe'
    if (-not (Test-Path $Setup)) { throw 'ODT extraction did not produce setup.exe.' }
    $Result['ODT download'] = 'Downloaded, Microsoft signature verified and extracted'
    Status 'ODT downloaded and verified.' Green
    }

    # STAGE 2 - Microsoft 365 Apps: fresh install with en-GB only, or reduce an existing install to en-GB only.
    Write-Host ''
    Status 'STAGE 2: Checking Microsoft 365 Apps and installed languages...' Cyan
    $KeepLanguages = @($KeepLanguages | ForEach-Object { $_.ToLowerInvariant() })
    $languageWorkDone = $false
    $officeInfo = Get-OfficeC2RInfo

    if ($officeInfo.OtherOffice) {
        $Result['Office installation'] = 'Skipped: Office is installed but is not Click-to-Run, so ODT cannot manage it'
        $Result['Office languages'] = 'Not changed (non Click-to-Run Office)'
        Status $Result['Office installation'] Yellow
    }
    elseif (-not $officeInfo.Installed) {
        Status ('Microsoft 365 Apps not found. Installing with languages: {0}' -f ($KeepLanguages -join ', ')) Yellow
        Status 'Office installation may take several minutes.'
        New-OdtAddConfig $InstallXML $officeInfo.ProductId $officeInfo.Edition $KeepLanguages
        $code = RunODT $Setup ('/configure "{0}"' -f $InstallXML)
        if ($code -ne 0) { throw "Office installation returned exit code $code. Check $Work." }
        $Result['Office installation'] = ('Installed ({0} only)' -f ($KeepLanguages -join ', '))
        Status 'Office installation command completed.' Green
        $languageWorkDone = $true
    }
    else {
        # A consumer edition (e.g. Microsoft 365 Family/Personal, often preinstalled) is replaced with
        # Microsoft 365 Apps for business. The business edition is added FIRST, so Office is never fully absent.
        $replacedFrom = $null
        if (-not $officeInfo.IsBusiness) {
            $consumer = $officeInfo.ProductId
            Write-Host ''
            Write-Host ('Office edition found: {0}. This is not Microsoft 365 Apps for business.' -f $consumer) -ForegroundColor Yellow
            Write-Host 'Replacing it installs Microsoft 365 Apps for business (en-GB), then removes this edition.' -ForegroundColor Yellow
            Write-Host 'Word, Excel, PowerPoint, Outlook, OneNote and Access will be closed WITHOUT saving.' -ForegroundColor Yellow
            $rep = Read-Host 'Save your work, then type REPLACE to continue (or press ENTER to keep the current edition)'
            if ($rep -ceq 'REPLACE') {
                foreach ($name in @('OUTLOOK','WINWORD','EXCEL','POWERPNT','ONENOTE','MSACCESS','VISIO')) {
                    Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                }
                Status 'Installing Microsoft 365 Apps for business alongside the current edition...' Cyan
                New-OdtAddConfig $InstallXML 'O365BusinessRetail' $officeInfo.Edition $KeepLanguages -Existing
                $bizCode = RunODT $Setup ('/configure "{0}"' -f $InstallXML)
                if ($bizCode -ne 0) { throw "Microsoft 365 Apps for business could not be installed (ODT exit code $bizCode). $consumer was left in place." }
                Status ('Removing {0}...' -f $consumer) Cyan
                New-OdtRemoveProductConfig $RemoveXML $consumer @($officeInfo.Products[$consumer])
                $remCode = RunODT $Setup ('/configure "{0}"' -f $RemoveXML)
                $officeInfo = Get-OfficeC2RInfo
                $cfgNow = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
                if ([string]$cfgNow.ProductReleaseIds -match ('(?i)(^|,)\s*' + [regex]::Escape($consumer) + '\s*(,|$)')) {
                    Status ('{0} is still installed after removal (ODT exit code {1}); continuing with Microsoft 365 Apps for business.' -f $consumer,$remCode) Yellow
                } else {
                    Status ('{0} removed.' -f $consumer) Green
                }
                $replacedFrom = $consumer
            } else {
                Status ('Keeping {0}. Its languages will still be reduced to en-GB.' -f $consumer) Yellow
            }
        }
        if ($replacedFrom) {
            $Result['Office installation'] = ('Replaced {0} with {1} (en-GB)' -f $replacedFrom,$officeInfo.ProductId)
        } else {
            $Result['Office installation'] = ('Skipped: {0} already installed' -f $officeInfo.ProductId)
        }
        if (-not $officeInfo.Reliable) {
            $Result['Office languages'] = 'COULD NOT VERIFY: installed Office languages could not be identified; nothing was removed'
            Status $Result['Office languages'] Red
        } else {
        $found = @($officeInfo.Languages)
        $foundText = if ($found.Count -gt 0) { $found -join ', ' } else { 'none detected' }
        Status ('Existing Office product: {0}. Languages detected: {1}' -f $officeInfo.ProductId,$foundText) Green
        foreach ($prod in ($officeInfo.Products.Keys | Sort-Object)) {
            Status ('  {0}: {1}' -f $prod,(@($officeInfo.Products[$prod]) -join ', ')) Gray
        }

        # Make sure the main product has the language to keep BEFORE anything is removed,
        # otherwise ODT could be asked to remove the main product's last language.
        $mainLangs = @($officeInfo.Products[$officeInfo.ProductId])
        $missing = @($KeepLanguages | Where-Object { $mainLangs -notcontains $_ })
        if ($missing.Count -gt 0) {
            Status ('Adding missing Office language(s) to {0}: {1}...' -f $officeInfo.ProductId,($missing -join ', ')) Yellow
            New-OdtAddConfig $InstallXML $officeInfo.ProductId $officeInfo.Edition $KeepLanguages -Existing
            $addCode = RunODT $Setup ('/configure "{0}"' -f $InstallXML)
            if ($addCode -ne 0) {
                $Result['Office languages'] = "Could not add $($missing -join ', '); ODT exit code $addCode. Nothing was removed."
                throw $Result['Office languages']
            }
            $officeInfo = Get-OfficeC2RInfo
            $mainLangs = @($officeInfo.Products[$officeInfo.ProductId])
            $stillMissing = @($KeepLanguages | Where-Object { $mainLangs -notcontains $_ })
            if ($stillMissing.Count -gt 0) {
                $Result['Office languages'] = "ODT reported success but $($stillMissing -join ', ') is still not detected. Nothing was removed."
                throw $Result['Office languages']
            }
        }

        # Build the removal list per owning product.
        $toRemove = @{}
        foreach ($prod in $officeInfo.Products.Keys) {
            foreach ($l in $officeInfo.Products[$prod]) {
                if ($KeepLanguages -notcontains $l) { Add-LanguageToMap $toRemove $prod $l }
            }
        }
        $extra = @(@($toRemove.Values | ForEach-Object { $_ }) + @($officeInfo.ArpOnly | Where-Object { $KeepLanguages -notcontains $_ }) | Sort-Object -Unique)
        if ($extra.Count -eq 0) {
            Status 'No extra Office languages found.' Green
            $languageWorkDone = $true
        } else {
            Write-Host ''
            Write-Host ('These Office languages will be removed: {0}' -f ($extra -join ', ')) -ForegroundColor Yellow
            Write-Host 'Word, Excel, PowerPoint, Outlook, OneNote and Access will be closed WITHOUT saving.' -ForegroundColor Yellow
            $go = Read-Host 'Save your work, then type REMOVE to continue (or press ENTER to skip language removal)'
            if ($go -cne 'REMOVE') {
                $Result['Office languages'] = ('Skipped by user; still installed: {0}' -f ($extra -join ', '))
                Status $Result['Office languages'] Yellow
            } else {
                foreach ($name in @('OUTLOOK','WINWORD','EXCEL','POWERPNT','ONENOTE','MSACCESS','VISIO')) {
                    Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                }
                Status ('Removing Office languages: {0}...' -f ($extra -join ', ')) Cyan
                if ($toRemove.Count -gt 0) {
                    New-OdtRemoveLanguagesConfig $RemoveXML $toRemove
                    $removeCode = RunODT $Setup ('/configure "{0}"' -f $RemoveXML)
                } else {
                    $removeCode = 0   # nothing ODT can target by product; their uninstall entries are used below
                }
                if ($removeCode -eq 1223) {
                    $Result['Office languages'] = 'Language removal cancelled at the UAC prompt; nothing was removed'
                    Status $Result['Office languages'] Yellow
                } else {
                    if ($removeCode -ne 0) { Status ("ODT language removal returned exit code $removeCode; checking what remains...") Yellow }
                    else { Status 'ODT language removal command completed; checking what remains...' Green }
                    $languageWorkDone = $true
                    # An exit code of 0 is not taken as proof. If anything remains, use the uninstall entries.
                    $check = Get-LanguageVerdict
                    if ($check.Remaining.Count -gt 0) {
                        Status ('Still detected after ODT: {0}. Trying their Programs and Features uninstall entries...' -f ($check.Remaining -join ', ')) Yellow
                        Invoke-ArpLanguageRemoval $check.Remaining
                    }
                }
            }
        }
        }
    }

    # STAGE 3 - Verify the resulting language list (best effort, read from the registry).
    if ($languageWorkDone) {
        Write-Host ''
        Status 'STAGE 3: Verifying Office languages...' Cyan
        $verdict = Get-LanguageVerdict
        $Result['Office languages'] = $verdict.Text
        $verdictColour = switch ($verdict.Outcome) { 'VERIFIED' { 'Green' } 'FAILED' { 'Red' } default { 'Yellow' } }
        Status $Result['Office languages'] $verdictColour
    }

    } # end Office

    if ($Run['Adobe']) {  # menu selection - stage code below is unchanged
    # STAGE 4 - Install free Adobe Acrobat Reader (64-bit) using WinGet
    Write-Host ''
    Status 'STAGE 4: Installing free Adobe Acrobat Reader (64-bit)...' Cyan
    $winget = Install-WinGetIfMissing
    if (-not $winget) {
        $Result['Adobe Acrobat Reader'] = 'Skipped: WinGet was not available and could not be installed'
        Status 'WinGet could not be installed. Adobe Acrobat Reader was skipped; install App Installer from the Microsoft Store and rerun.' Yellow
    } else {
        $wingetArgs = @(
            'install'
            '--id'
            'Adobe.Acrobat.Reader.64-bit'
            '--exact'
            '--silent'
            '--accept-package-agreements'
            '--accept-source-agreements'
            '--disable-interactivity'
            '--source'
            'winget'
        )
        $readerProcess = Start-Process -FilePath $winget.Source -ArgumentList $wingetArgs -Wait -PassThru
        # WinGet "already installed / no update" codes: 0x8A15002B, 0x8A150061, 0x8A15010D
        $alreadyCodes = @(-1978335189, -1978335135, -1978334963)
        if ($readerProcess.ExitCode -eq 0) {
            $Result['Adobe Acrobat Reader'] = 'Installed or already present'
            Status 'Adobe Acrobat Reader installation completed.' Green
        } elseif ($alreadyCodes -contains $readerProcess.ExitCode) {
            $Result['Adobe Acrobat Reader'] = 'Already installed (no update needed)'
            Status $Result['Adobe Acrobat Reader'] Green
        } else {
            $Result['Adobe Acrobat Reader'] = "WinGet returned exit code $($readerProcess.ExitCode)"
            Status $Result['Adobe Acrobat Reader'] Yellow
        }
    }

    } # end Adobe

    if ($Run['Machine']) {  # menu selection - stage code below is unchanged
    # STAGE 5 - Locate required applications
    Write-Host ''
    Status 'STAGE 5: Locating Office apps and Edge...' Cyan
    # If anything is missing, the all-users step is skipped and reported; the rest of setup carries on.
    try {
    $office = FindOffice
    if (-not $office) { throw 'Could not locate Office installation folder / WINWORD.EXE.' }
    $Outlook = Join-Path $office 'OUTLOOK.EXE'
    $Word = Join-Path $office 'WINWORD.EXE'
    $Excel = Join-Path $office 'EXCEL.EXE'
    foreach ($path in @($Outlook,$Word,$Excel)) {
        if (-not (Test-Path $path)) { throw "Required Office application not found: $path" }
    }
    $edgePaths = @((Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'))
    if (${env:ProgramFiles(x86)}) { $edgePaths += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe') }
    $Edge = $edgePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $Edge) { throw 'Microsoft Edge was not found.' }
    Status 'Outlook Classic, Word, Excel and Edge found.' Green
    $machineReady = $true
    } catch {
        foreach ($r in @('OneDrive Files On-Demand','Microsoft Edge defaults','All-user taskbar')) { $Result[$r] = "Skipped: $($_.Exception.Message)" }
        Status ('All-users settings skipped: {0}' -f $_.Exception.Message) Red
    }

    } # end Machine

    if ($Run['Outlook']) {  # menu selection - stage code below is unchanged
    # STAGE 6 - Configure Outlook Classic policies for the signed-in user.
    # These policies are written before an Outlook profile/account is created.
    Write-Host ''
    Status 'STAGE 6: Configuring Outlook Classic Cached Exchange Mode...' Cyan
    try {
        $outlookPolicy = 'HKCU:\Software\Policies\Microsoft\Office\16.0\Outlook\Cached Mode'
        New-Item -Path $outlookPolicy -Force | Out-Null
        New-ItemProperty -Path $outlookPolicy -Name 'Enable' -PropertyType DWord -Value 1 -Force | Out-Null
        New-ItemProperty -Path $outlookPolicy -Name 'DownloadSharedFolders' -PropertyType DWord -Value 0 -Force | Out-Null
        $Result['Outlook Cached Mode'] = 'Cached Exchange Mode enabled; shared-folder caching disabled for signed-in user'
        Status 'Outlook policies configured. They will apply when an Exchange/Microsoft 365 account is added to Outlook Classic.' Green
    } catch {
        $Result['Outlook Cached Mode'] = "Not configured: $($_.Exception.Message)"
        Status $Result['Outlook Cached Mode'] Yellow
    }

    } # end Outlook

    if ($Run['Copilot']) {  # menu selection - stage code below is unchanged
    # STAGE 7 - Copilot is a current-user preference. Do not elevate this write.
    Write-Host ''
    Status 'STAGE 7: Hiding the Copilot taskbar button for the signed-in user...' Cyan
    try {
        $advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        if (-not (Test-Path $advanced)) { throw 'Explorer Advanced registry key not found.' }
        New-ItemProperty -Path $advanced -Name 'ShowCopilotButton' -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
        $Result['Copilot button'] = 'Setting written for signed-in user'
        Status 'Copilot setting updated.' Green
    } catch {
        $Result['Copilot button'] = "Not changed: $($_.Exception.Message)"
        Status $Result['Copilot button'] Yellow
    }

    } # end Copilot

    if ($Run['Machine'] -and $machineReady) {  # menu selection - stage code below is unchanged
    # STAGE 8 - Edge policies are applied machine-wide in the elevated helper below.
    # This avoids writing user-scope policy values that may conflict with machine policy.
    Write-Host ''
    Status 'STAGE 8: Edge Google defaults will be configured in the elevated local-policy stage...' Cyan

    # STAGE 9 - Create a helper to configure a machine-wide taskbar policy.
    # It creates shared shortcuts and XML in ProgramData, then writes HKLM policy.
    Write-Host ''
    Status 'STAGE 9: Configuring OneDrive and taskbar settings for all users...' Cyan

    $helperText = @'
param(
 [string]$ExplorerExe,
 [string]$EdgeExe,
 [string]$OutlookExe,
 [string]$WordExe,
 [string]$ExcelExe
)
$ErrorActionPreference = 'Stop'
$recovery = Join-Path $env:ProgramData 'MachineSetup\Recovery'
New-Item -Path $recovery -ItemType Directory -Force | Out-Null

function Save-RegKey([string]$RegPath,[string]$FileName,[string]$RegistryPath) {
    $file = Join-Path $recovery $FileName
    $marker = Join-Path $recovery ($FileName + '.existed')
    $exists = Test-Path $RegistryPath
    Set-Content -Path $marker -Value ([string]$exists)
    if ($exists) { & reg.exe export $RegPath $file /y | Out-Null }
    else { Remove-Item $file -Force -ErrorAction SilentlyContinue }  # no stale backup from an earlier run
}
# Keep the first (pre-setup) backup; re-running setup must not overwrite it.
if (-not (Test-Path (Join-Path $recovery 'MachineBackupCreated.txt'))) {
Save-RegKey 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'ExplorerPolicy.reg' 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
Save-RegKey 'HKLM\SOFTWARE\Policies\Microsoft\OneDrive' 'OneDrivePolicy.reg' 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
Save-RegKey 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'EdgePolicy.reg' 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
Save-RegKey 'HKLM\SYSTEM\CurrentControlSet\Services\CldFlt' 'CloudFilter.reg' 'HKLM:\SYSTEM\CurrentControlSet\Services\CldFlt'
Set-Content -Path (Join-Path $recovery 'MachineBackupCreated.txt') -Value (Get-Date -Format o)
}

# Machine-wide OneDrive Files On-Demand policy.
$oneDrivePolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
New-Item -Path $oneDrivePolicy -Force | Out-Null
New-ItemProperty -Path $oneDrivePolicy -Name 'FilesOnDemandEnabled' -PropertyType DWord -Value 1 -Force | Out-Null

# Microsoft Edge local machine policies (no MDM/Intune enrollment required).
# Recommended settings provide defaults users can change; NewTabPageLocation is enforced.
$edgePolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$edgeRecommended = Join-Path $edgePolicy 'Recommended'
New-Item -Path $edgeRecommended -Force | Out-Null
New-ItemProperty -Path $edgeRecommended -Name 'HomepageLocation' -PropertyType String -Value 'https://www.google.com' -Force | Out-Null
New-ItemProperty -Path $edgeRecommended -Name 'HomepageIsNewTabPage' -PropertyType DWord -Value 0 -Force | Out-Null
New-ItemProperty -Path $edgeRecommended -Name 'RestoreOnStartup' -PropertyType DWord -Value 4 -Force | Out-Null
New-ItemProperty -Path $edgeRecommended -Name 'RestoreOnStartupURLs' -PropertyType MultiString -Value @('https://www.google.com') -Force | Out-Null
New-ItemProperty -Path $edgeRecommended -Name 'DefaultSearchProviderEnabled' -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path $edgeRecommended -Name 'DefaultSearchProviderName' -PropertyType String -Value 'Google' -Force | Out-Null
New-ItemProperty -Path $edgeRecommended -Name 'DefaultSearchProviderSearchURL' -PropertyType String -Value 'https://www.google.com/search?q={searchTerms}' -Force | Out-Null
New-ItemProperty -Path $edgeRecommended -Name 'DefaultSearchProviderSuggestURL' -PropertyType String -Value 'https://www.google.com/complete/search?output=chrome&q={searchTerms}' -Force | Out-Null
New-ItemProperty -Path $edgePolicy -Name 'NewTabPageLocation' -PropertyType String -Value 'https://www.google.com' -Force | Out-Null

# Ensure the Windows Cloud Files Filter Driver is set to automatic start.
$cloudFilter = 'HKLM:\SYSTEM\CurrentControlSet\Services\CldFlt'
if (Test-Path $cloudFilter) {
 Set-ItemProperty -Path $cloudFilter -Name 'Start' -Type DWord -Value 2
}

function MakeShortcut([string]$Name,[string]$Target) {
 if (-not (Test-Path -LiteralPath $Target)) { throw "Executable not found: $Target" }
 $folder = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\MachineSetup'
 New-Item -Path $folder -ItemType Directory -Force | Out-Null
 $file = Join-Path $folder ($Name + '.lnk')
 $shell = New-Object -ComObject WScript.Shell
 $link = $shell.CreateShortcut($file)
 $link.TargetPath = $Target
 $link.WorkingDirectory = Split-Path $Target -Parent
 $link.Save()
 return $file
}

$common = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\MachineSetup'
$layoutDir = Join-Path $env:ProgramData 'MachineSetup'
$layoutFile = Join-Path $layoutDir 'TaskbarLayout.xml'
New-Item -Path $layoutDir -ItemType Directory -Force | Out-Null

$stalePowerPointShortcut = Join-Path $common 'PowerPoint.lnk'
Remove-Item -LiteralPath $stalePowerPointShortcut -Force -ErrorAction SilentlyContinue

$paths = @(
 (MakeShortcut 'File Explorer' $ExplorerExe)
 (MakeShortcut 'Microsoft Edge' $EdgeExe)
 (MakeShortcut 'Outlook Classic' $OutlookExe)
 (MakeShortcut 'Word' $WordExe)
 (MakeShortcut 'Excel' $ExcelExe)
)

$xml = @(
 '<?xml version="1.0" encoding="utf-8"?>'
 '<LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1">'
 ' <CustomTaskbarLayoutCollection PinListPlacement="Replace">'
 '  <defaultlayout:TaskbarLayout>'
 '   <taskbar:TaskbarPinList>'
)
foreach ($path in $paths) {
 $escaped = [System.Security.SecurityElement]::Escape($path)
 $xml += ('    <taskbar:DesktopApp DesktopApplicationLinkPath="{0}" PinGeneration="1" />' -f $escaped)
}
$xml += @(
 '   </taskbar:TaskbarPinList>'
 '  </defaultlayout:TaskbarLayout>'
 ' </CustomTaskbarLayoutCollection>'
 '</LayoutModificationTemplate>'
)
$xml | Set-Content -Path $layoutFile -Encoding UTF8

# Computer Configuration > Administrative Templates > Start Menu and Taskbar > Start Layout
$policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
New-Item -Path $policy -Force | Out-Null
New-ItemProperty -Path $policy -Name 'StartLayoutFile' -PropertyType ExpandString -Value $layoutFile -Force | Out-Null
New-ItemProperty -Path $policy -Name 'LockedStartLayout' -PropertyType DWord -Value 1 -Force | Out-Null

Write-Output "Taskbar layout XML: $layoutFile"
Write-Output "Common shortcuts: $common"
Write-Output 'Machine-level Start Layout policy was written.'
Write-Output 'Machine-wide OneDrive Files On-Demand policy was written.'
'@
    $helperText | Set-Content -Path $Helper -Encoding UTF8

    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $explorerExe = Join-Path $env:WINDIR 'explorer.exe'
    $helperArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ExplorerExe "{1}" -EdgeExe "{2}" -OutlookExe "{3}" -WordExe "{4}" -ExcelExe "{5}"' -f $Helper,$explorerExe,$Edge,$Outlook,$Word,$Excel

    try {
        if (IsAdmin) {
            $machine = Start-Process -FilePath $psExe -ArgumentList $helperArgs -Wait -PassThru
        } else {
            Status 'Administrator approval is required for the all-user taskbar policy.' Yellow
            $machine = Start-Process -FilePath $psExe -ArgumentList $helperArgs -Verb RunAs -Wait -PassThru
        }
        if ($null -eq $machine) { throw 'Windows did not return the elevated helper process.' }
        if ($machine.ExitCode -ne 0) { throw "Elevated taskbar helper exited with code $($machine.ExitCode)." }
        $Result['OneDrive Files On-Demand'] = 'Machine-wide policy enabled; Cloud Files Filter Driver set to automatic'
        $Result['Microsoft Edge defaults'] = 'Google homepage, startup, new tab and search local policies written'
        $Result['All-user taskbar'] = 'Shared shortcuts and machine-level layout policy configured'
        Status 'OneDrive Files On-Demand, Edge local policies and taskbar layout policy configured.' Green
    } catch {
        $Result['All-user taskbar'] = "Not configured: $($_.Exception.Message)"
        Status $Result['All-user taskbar'] Yellow
    }

    } # end Machine

    # Summary
    Write-Host ''
    Write-Host '====================================================' -ForegroundColor Green
    Write-Host '                   SETUP SUMMARY' -ForegroundColor Green
    Write-Host '====================================================' -ForegroundColor Green
    foreach ($item in $Result.GetEnumerator()) {
        Write-Host ('{0,-25} {1}' -f ($item.Key + ':'),$item.Value)
    }
    Write-Host ''
    Write-Host 'Sign out and sign back in to test the taskbar layout.'
    Write-Host 'Windows applies the taskbar layout at sign-in; behavior can vary for existing profiles and Windows builds.'
    Write-Host 'Edge homepage, startup and search are recommended defaults; the Google new-tab URL is enforced.'
    Write-Host 'Existing manually pinned apps on an already-used profile may remain.'
    Write-Host ("Logs and working files: {0}" -f $Work)
    Write-Host ("Recovery backups: {0}" -f $UserStateRoot)
    Write-Host ''
    $SetupCompleted = $true
}
catch {
    Write-Host ''
    Write-Host 'SETUP STOPPED' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ("Logs and working files: {0}" -f $Work) -ForegroundColor Yellow
    if (Test-Path $dellRemovalLog) { Write-Host ("Dell removal log: {0}" -f $dellRemovalLog) }
}
finally {
    if ($TranscriptStarted) { try { Stop-Transcript | Out-Null } catch {} }
    Write-Host ''
    if ($SetupCompleted -and $CustomRun) {
        Write-Host 'The selected items have finished.' -ForegroundColor Green
        Write-Host 'Taskbar, Copilot and policy changes need a restart (or sign out and back in) to take effect.'
        $restartNow = Read-Host 'Restart now? Type Y to restart in 30 seconds, or press ENTER to skip'
        if ($restartNow -match '^(?i)y') {
            Write-Host 'To cancel the restart, run: shutdown.exe /a' -ForegroundColor Yellow
            & shutdown.exe /r /t 30 /c ("Machine Setup ({0}) has finished. Windows will restart in 30 seconds." -f $SetupVersion)
            if ($LASTEXITCODE -ne 0) {
                Write-Host 'Windows could not schedule the restart. Please restart the PC manually.' -ForegroundColor Red
                Read-Host 'Press ENTER to close this PowerShell window' | Out-Null
            }
        } else {
            Read-Host 'No restart scheduled. Press ENTER to close this PowerShell window' | Out-Null
        }
    } elseif ($SetupCompleted) {
        Write-Host 'Setup has finished. This PC will restart in 30 seconds.' -ForegroundColor Yellow
        Write-Host 'To cancel the restart, run: shutdown.exe /a' -ForegroundColor Yellow
        & shutdown.exe /r /t 30 /c ("Machine Setup ({0}) has finished. Windows will restart in 30 seconds." -f $SetupVersion)
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'Windows could not schedule the restart. Please restart the PC manually.' -ForegroundColor Red
            Read-Host 'Press ENTER to close this PowerShell window' | Out-Null
        }
    } else {
        Read-Host 'Press ENTER to close this PowerShell window'
    }
}
