param([string]$GameRoot=$PSScriptRoot,[switch]$CheckOnly,[switch]$Yes,[switch]$Repair)
$ErrorActionPreference='Stop'
$FFRepository='Craditz/Abiotic-Feral-Fox'
$FFVersion='1.0.0'

function Get-FFHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Assert-FFGameClosed {
    if (Get-Process -Name 'AbioticFactor','AbioticFactor-Win64-Shipping' -ErrorAction SilentlyContinue) {
        throw 'Fully close Abiotic Factor before updating.'
    }
}
function Get-FFSafePath([string]$Root,[string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative.Contains('\') -or $Relative.Contains(':') -or $Relative.StartsWith('/') -or $Relative -match '(^|/)\.\.?(/|$)') { throw "Unsafe path: $Relative" }
    $base=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $target=[IO.Path]::GetFullPath((Join-Path $base $Relative))
    if (-not $target.StartsWith($base+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Path escaped game folder.' }
    $cursor=$target
    while ($cursor.Length -ge $base.Length) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked paths are not supported: $cursor" }
        }
        if ($cursor -eq $base) { break }; $cursor=Split-Path -Parent $cursor
    }
    return $target
}
function Test-FFPayloadPath([string]$Name) {
    if ($Name -in @('FeralFox-Updater.ps1','Update-FeralFox.cmd')) {return $true}
    if ($Name -match '^FeralFox-Docs/[A-Za-z0-9_.-]+\.(md|txt|json)$') {return $true}
    if ($Name -match '^AbioticFactor/Content/Paks/~mods/FeralFoxCore_2_P\.(pak|utoc|ucas)$') {return $true}
    if ($Name -match '^AbioticFactor/Binaries/Win64/(dwmapi\.dll|ue4ss/(UE4SS\.dll|LICENSE|UE4SS-settings\.ini|MemberVariableLayout\.ini|VTableLayout\.ini|UE4SS_SDK_Backends/UE4SS\.json|Mods/mods\.txt))$') {return $true}
    if ($Name -match '^AbioticFactor/Binaries/Win64/ue4ss/Mods/FeralFoxPrototype/Scripts/(main|network|remote_visuals|character_profiles|character_identity|emotes|animation_state|actions|config|equipment|preferences|customization|customization_preview|appearance|appearance_catalog|voice|voice_catalog)\.lua$') {return $true}
    return $false
}
function Test-FFPreserve([string]$Name) {
    return $Name -match '/(config\.lua|UE4SS-settings\.ini|MemberVariableLayout\.ini|VTableLayout\.ini)$'
}
function Invoke-FFDownload([string]$Url,[string]$Destination) {
    if (-not $Url.StartsWith('https://github.com/'+$FFRepository+'/releases/download/',[StringComparison]::Ordinal)) {throw 'Unexpected download source.'}
    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 180 -UserAgent "FeralFox-Updater/$FFVersion" | Out-Null
}
function Get-FFRelease {
    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $all=Invoke-RestMethod -Uri "https://api.github.com/repos/$FFRepository/releases?per_page=30" -TimeoutSec 60 -Headers @{Accept='application/vnd.github+json';'User-Agent'="FeralFox-Updater/$FFVersion"}
    $eligible=@($all | Where-Object {-not $_.draft -and $_.tag_name -match '^v\d+\.\d+\.\d+$' -and @($_.assets | Where-Object {$_.name -eq 'feralfox-release.json'}).Count -eq 1})
    if (-not $eligible.Count) {throw 'No compatible published release is available.'}
    return ($eligible | Sort-Object -Property @{Expression={[version]$_.tag_name.Substring(1)};Descending=$true} | Select-Object -First 1)
}
function Get-FFAsset($Release,[string]$Name) {
    $found=@($Release.assets | Where-Object {$_.name -ceq $Name})
    if ($found.Count -ne 1) {throw "Release asset missing or duplicated: $Name"}
    $expected="https://github.com/$FFRepository/releases/download/$($Release.tag_name)/$Name"
    if ($found[0].browser_download_url -cne $expected) {throw 'Release asset URL does not match repository/tag.'}
    return $found[0]
}
function Expand-FFVerifiedPackage([string]$ZipPath,[string]$Stage,$Package) {
    if ($Package.sha256 -cnotmatch '^[a-f0-9]{64}$' -or (Get-FFHash $ZipPath) -cne $Package.sha256) {throw 'Package SHA-256 mismatch.'}
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $expected=@{}; $seen=@{}; [long]$total=0
    foreach ($property in $Package.files.PSObject.Properties) {
        if (-not (Test-FFPayloadPath $property.Name) -or $property.Value -cnotmatch '^[a-f0-9]{64}$' -or $expected.ContainsKey($property.Name)) {throw 'Invalid package file manifest.'}
        $expected[$property.Name]=$property.Value
    }
    if ($expected.Count -lt 5 -or $expected.Count -gt 128) {throw 'Unexpected package file count.'}
    $zip=[IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $zip.Entries) {
            $name=$entry.FullName
            if (-not $expected.ContainsKey($name) -or $seen.ContainsKey($name) -or -not (Test-FFPayloadPath $name)) {throw "Unexpected or duplicate ZIP member: $name"}
            if (($entry.ExternalAttributes -shr 16 -band 61440) -eq 40960) {throw 'ZIP links are not allowed.'}
            $total+=$entry.Length
            if ($total -gt 2147483648 -or $entry.Length -gt 1073741824) {throw 'Package exceeds extraction limit.'}
            $dest=Get-FFSafePath $Stage $name
            [IO.Directory]::CreateDirectory((Split-Path -Parent $dest)) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$dest,$false)
            if ((Get-FFHash $dest) -cne $expected[$name]) {throw "Extracted file SHA-256 mismatch: $name"}
            $seen[$name]=$true
        }
        if ($seen.Count -ne $expected.Count) {throw 'Package has missing files.'}
    } finally { $zip.Dispose() }
}
function Write-FFFile([string]$Source,[string]$Destination) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Destination)) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}
function Install-FFPackage([string]$Root,[string]$Stage,[string]$Backup,$Package,[string]$Version) {
    Assert-FFGameClosed
    $plan=New-Object 'System.Collections.Generic.List[object]'
    foreach ($property in $Package.files.PSObject.Properties) {
        $name=$property.Name
        if ($name -eq 'AbioticFactor/Binaries/Win64/ue4ss/Mods/mods.txt') {continue}
        $dest=Get-FFSafePath $Root $name
        if ((Test-FFPreserve $name) -and (Test-Path -LiteralPath $dest)) {continue}
        $plan.Add(@{name=$name;destination=$dest;source=(Get-FFSafePath $Stage $name);existed=(Test-Path -LiteralPath $dest)})
    }
    $modsName='AbioticFactor/Binaries/Win64/ue4ss/Mods/mods.txt'
    $modsPath=Get-FFSafePath $Root $modsName
    $modsText=if(Test-Path -LiteralPath $modsPath){[IO.File]::ReadAllText($modsPath)}else{''}
    if ($modsText -match '(?m)^\s*FeralFoxPrototype\s*:') {
        $modsText=[regex]::Replace($modsText,'(?m)^(\s*FeralFoxPrototype\s*:)\s*[01]\s*(?=\r?$)','$1 1')
        if ($modsText -notmatch '(?m)^\s*FeralFoxPrototype\s*:\s*1\s*$') {throw 'Unrecognized FeralFoxPrototype entry in mods.txt; please correct it manually.'}
    } else {$modsText=$modsText.TrimEnd()+"`r`nFeralFoxPrototype : 1`r`n"}
    $modsStage=Join-Path $Stage 'generated-mods.txt'; [IO.File]::WriteAllText($modsStage,$modsText)
    $plan.Add(@{name=$modsName;destination=$modsPath;source=$modsStage;existed=(Test-Path -LiteralPath $modsPath)})
    $receiptPath=Get-FFSafePath $Root 'FeralFox-install.json'
    $receiptStage=Join-Path $Stage 'generated-receipt.json'
    @{version=$Version;flavor='core';protocol=2;installed_utc=[DateTime]::UtcNow.ToString('o');backup=$Backup} | ConvertTo-Json | Set-Content -LiteralPath $receiptStage -Encoding UTF8
    $plan.Add(@{name='FeralFox-install.json';destination=$receiptPath;source=$receiptStage;existed=(Test-Path -LiteralPath $receiptPath)})
    [IO.Directory]::CreateDirectory($Backup) | Out-Null
    foreach ($item in $plan) {
        $item.backup=Get-FFSafePath $Backup $item.name
        if ($item.existed) {
            if ((Get-Item -LiteralPath $item.destination).PSIsContainer) {throw 'An installation file is a directory.'}
            Write-FFFile $item.destination $item.backup
        }
    }
    $plan | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Backup 'rollback.json') -Encoding UTF8
    Assert-FFGameClosed
    $touched=New-Object 'System.Collections.Generic.List[object]'
    try {
        foreach ($item in $plan) {
            $touched.Add($item)
            Write-FFFile $item.source $item.destination
            if ((Get-FFHash $item.destination) -cne (Get-FFHash $item.source)) {throw 'Installed bytes failed verification.'}
        }
    } catch {
        $original=$_; $rollbackErrors=@()
        for ($i=$touched.Count-1;$i -ge 0;$i--) {
            $item=$touched[$i]
            try {
                if ($item.existed) {
                    [IO.File]::Copy($item.backup,$item.destination,$true)
                    if ((Get-FFHash $item.destination) -cne (Get-FFHash $item.backup)) {throw 'Rollback verification failed.'}
                } elseif (Test-Path -LiteralPath $item.destination) {Remove-Item -LiteralPath $item.destination -Force}
            } catch {$rollbackErrors+=$item.name}
        }
        if ($rollbackErrors.Count) {throw "Update failed; restore these files from ${Backup}: $($rollbackErrors -join ', ')"}
        throw "Update failed; previous files restored. Backup: $Backup. Cause: $($original.Exception.Message)"
    }
    Write-Host "Installed Feral Fox $Version core. Backup: $Backup"
}
function Invoke-FFUpdater([string]$Root,[bool]$Check,[bool]$Accept,[bool]$ForceRepair) {
    $Root=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'AbioticFactor.exe') -PathType Leaf)) {throw 'Place the updater beside AbioticFactor.exe, or provide -GameRoot with the game folder.'}
    Assert-FFGameClosed
    $state=Get-FFSafePath $Root '.FeralFoxUpdater'
    [IO.Directory]::CreateDirectory($state) | Out-Null
    $lock=$null;$stage=$null
    try {
        $lock=[IO.File]::Open((Join-Path $state 'updater.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $release=Get-FFRelease; $version=$release.tag_name.Substring(1)
        $localVersion='0.0.0';$main=Join-Path $Root 'AbioticFactor/Binaries/Win64/ue4ss/Mods/FeralFoxPrototype/Scripts/main.lua'
        if (Test-Path -LiteralPath $main) {
            $first=Get-Content -LiteralPath $main -TotalCount 1
            if ($first -match 'FeralFoxPrototype (\d+\.\d+\.\d+)') {$localVersion=$Matches[1]}
        }
        Write-Host "Installed: $localVersion | Available: $version (experimental core)"
        if ($Check) {return}
        if ([version]$localVersion -gt [version]$version) {Write-Host 'A newer local build is installed; no downgrade performed.';return}
        if ([version]$localVersion -eq [version]$version -and -not $ForceRepair) {Write-Host 'Already up to date. Use -Repair to reinstall.';return}
        Write-Host 'This download contains no sounds. Existing local sound assets are retained. Fresh installs keep the native scientist voice. Settings, character choices, saves and other mods are preserved.'
        if (-not $Accept -and (Read-Host 'Install this release? [y/N]') -notmatch '^(y|yes)$') {Write-Host 'Cancelled.';return}
        $id=[guid]::NewGuid().ToString('N');$stage=Get-FFSafePath $state ('staging/'+$id)
        [IO.Directory]::CreateDirectory($stage) | Out-Null
        $asset=Get-FFAsset $release 'feralfox-release.json';$manifestPath=Join-Path $stage 'release.json'
        Invoke-FFDownload $asset.browser_download_url $manifestPath
        if ((Get-Item -LiteralPath $manifestPath).Length -gt 1048576) {throw 'Release manifest too large.'}
        if ($asset.digest -match '^sha256:([a-f0-9]{64})$' -and (Get-FFHash $manifestPath) -cne $Matches[1]) {throw 'Release manifest digest mismatch.'}
        $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($manifest.schema -ne 1 -or $manifest.version -cne $version -or $manifest.repository -cne $FFRepository -or $manifest.flavor -cne 'core') {throw 'Incompatible release manifest.'}
        $kind=if(Test-Path -LiteralPath (Join-Path $Root 'AbioticFactor/Binaries/Win64/ue4ss/UE4SS.dll')){'update'}else{'install'}
        $package=$manifest.packages.$kind
        $expectedName=if($kind -eq 'install'){"FeralFox-$version-with-UE4SS-Windows.zip"}else{"FeralFox-$version-update.zip"}
        if ($package.name -cne $expectedName -or $package.bytes -le 0 -or $package.bytes -gt 536870912) {throw 'Invalid package metadata.'}
        $asset=Get-FFAsset $release $package.name;$zipPath=Join-Path $stage 'package.zip'
        Invoke-FFDownload $asset.browser_download_url $zipPath
        if ((Get-Item -LiteralPath $zipPath).Length -ne $package.bytes) {throw 'Incomplete package download.'}
        $payload=Join-Path $stage 'payload';[IO.Directory]::CreateDirectory($payload) | Out-Null
        Expand-FFVerifiedPackage $zipPath $payload $package
        $backup=Get-FFSafePath $state ('backups/'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+$id)
        Install-FFPackage $Root $payload $backup $package $version
    } finally {
        if ($lock) {$lock.Dispose()}
        if ($stage -and $stage.StartsWith($state+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $stage)) {[IO.Directory]::Delete($stage,$true)}
    }
}
if ($MyInvocation.InvocationName -ne '.') {
    try {Invoke-FFUpdater $GameRoot $CheckOnly.IsPresent $Yes.IsPresent $Repair.IsPresent}
    catch {Write-Error $_.Exception.Message; exit 1}
}
