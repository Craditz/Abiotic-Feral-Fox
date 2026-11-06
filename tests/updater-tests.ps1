param([Parameter(Mandatory=$true)][string]$TestRoot)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'FeralFox-Updater.ps1')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$testBase=[IO.Path]::GetFullPath((Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))))
[IO.Directory]::CreateDirectory($testBase) | Out-Null
$utf8=New-Object Text.UTF8Encoding($false)
$prefix='AbioticFactor/Binaries/Win64/ue4ss/'
$scripts=$prefix+'Mods/FeralFoxPrototype/Scripts/'
$script:fixtures=Join-Path $testBase 'downloads';[IO.Directory]::CreateDirectory($script:fixtures) | Out-Null
function Assert($Condition,[string]$Message) {if(-not $Condition){throw $Message}}
function Put([string]$Path,[string]$Value) {[IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null;[IO.File]::WriteAllText($Path,$Value,$utf8)}
function Tree([string]$Root) {
    $data=[ordered]@{}
    Get-ChildItem -LiteralPath $Root -File -Recurse | Where-Object {$_.FullName -notlike '*\.FeralFoxUpdater\*'} | Sort-Object FullName | ForEach-Object {$data[$_.FullName.Substring($Root.Length)]=Get-FFHash $_.FullName}
    return ($data | ConvertTo-Json -Compress)
}
function Make-Zip([string]$Name,$Files) {
    $file=Join-Path $script:fixtures $Name
    if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file}
    $z=[IO.Compression.ZipFile]::Open($file,[IO.Compression.ZipArchiveMode]::Create)
    $hashes=@{}
    try {foreach($n in $Files.Keys){
        $data=$utf8.GetBytes($Files[$n]);$entry=$z.CreateEntry($n);$stream=$entry.Open()
        try {$stream.Write($data,0,$data.Length)}finally{$stream.Dispose()}
        $algorithm=[Security.Cryptography.SHA256]::Create()
        try {$hashes[$n]=([BitConverter]::ToString($algorithm.ComputeHash($data))).Replace('-','').ToLowerInvariant()}finally{$algorithm.Dispose()}
    }}finally{$z.Dispose()}
    return [pscustomobject]@{name=$Name;bytes=(Get-Item $file).Length;sha256=(Get-FFHash $file);files=[pscustomobject]$hashes}
}
$files=@{}
$files[$scripts+'main.lua']='-- FeralFoxPrototype 0.16.3: test'
$files[$scripts+'config.lua']='DEFAULT_CONFIG'
$files[$scripts+'voice.lua']='OPTIONAL_LOCAL_VOICE'
foreach($ext in @('pak','utoc','ucas')){$files['AbioticFactor/Content/Paks/~mods/FeralFoxCore_2_P.'+$ext]='CORE_'+$ext}
$update=Make-Zip 'FeralFox-0.16.3-update.zip' $files
$fullFiles=$files.Clone();$fullFiles[$prefix+'UE4SS.dll']='TEST_LOADER';$fullFiles[$prefix+'UE4SS-settings.ini']='DEFAULT_LOADER_CONFIG'
$install=Make-Zip 'FeralFox-0.16.3-with-UE4SS-Windows.zip' $fullFiles
$script:manifest=[pscustomobject]@{schema=1;repository=$FFRepository;version='0.16.3';flavor='core';packages=[pscustomobject]@{update=$update;install=$install}}
function Set-Fixture {
    Put (Join-Path $script:fixtures 'feralfox-release.json') ($script:manifest | ConvertTo-Json -Depth 10)
    $script:release=[pscustomobject]@{tag_name='v0.16.3';draft=$false;prerelease=$true;assets=@()}
    foreach($n in @('feralfox-release.json',$update.name,$install.name)){
        $script:release.assets += [pscustomobject]@{name=$n;browser_download_url="https://github.com/$FFRepository/releases/download/v0.16.3/$n";digest=('sha256:'+(Get-FFHash (Join-Path $script:fixtures $n)))}
    }
}
function Get-FFRelease {return $script:release}
$script:downloads=0
function Invoke-FFDownload([string]$Url,[string]$Destination) {$script:downloads++;Copy-Item -LiteralPath (Join-Path $script:fixtures ($Url.Split('/')[-1])) -Destination $Destination}
function New-Game([string]$Name,[bool]$Existing) {
    $g=Join-Path $testBase $Name;Put (Join-Path $g 'AbioticFactor.exe') 'fixture'
    if($Existing){
        Put (Join-Path $g ($prefix+'UE4SS.dll')) 'ORIGINAL_LOADER'
        Put (Join-Path $g ($prefix+'UE4SS-settings.ini')) 'MY_LOADER_CONFIG'
        Put (Join-Path $g ($scripts+'main.lua')) '-- FeralFoxPrototype 0.16.2: old'
        Put (Join-Path $g ($scripts+'config.lua')) 'MY_CONFIG'
        Put (Join-Path $g ($scripts+'voice.lua')) 'ORIGINAL_VOICE'
        Put (Join-Path $g ($scripts+'character-options-a.txt')) 'MY_FOX'
        Put (Join-Path $g ($scripts+'network-server-id.txt')) 'MY_SERVER'
        Put (Join-Path $g ($prefix+'Mods/mods.txt')) "OtherMod : 1`r`nFeralFoxPrototype : 0`r`n"
        Put (Join-Path $g 'unrelated/save.sav') 'MY_SAVE'
        foreach($ext in @('pak','utoc','ucas')){Put (Join-Path $g ('AbioticFactor/Content/Paks/~mods/FeralFoxAssets_P.'+$ext)) ('EXISTING_SOUND_BASE_'+$ext)}
    }
    return $g
}
Set-Fixture
$clean=New-Game 'clean' $false;Invoke-FFUpdater $clean $false $true $false
Assert ((Get-Content (Join-Path $clean ($prefix+'UE4SS.dll')) -Raw) -ceq 'TEST_LOADER') 'Clean loader install failed'
Assert ((Get-Content (Join-Path $clean ($scripts+'config.lua')) -Raw) -ceq 'DEFAULT_CONFIG') 'Default config missing'
Write-Output 'PASS clean install'
$existing=New-Game 'existing' $true
$preserved=@{};Get-ChildItem $existing -Recurse -File | Where-Object {$_.Name -notin @('main.lua','voice.lua','mods.txt')} | ForEach-Object {$preserved[$_.FullName]=Get-FFHash $_.FullName}
Invoke-FFUpdater $existing $false $true $false
foreach($n in $preserved.Keys){Assert ((Get-FFHash $n) -ceq $preserved[$n]) "Preservation failed: $n"}
$text=Get-Content (Join-Path $existing ($prefix+'Mods/mods.txt')) -Raw
Assert ($text.Contains('OtherMod : 1') -and $text.Contains('FeralFoxPrototype : 1')) 'Mod entries lost'
Write-Output 'PASS config/profile/host identity/loader/other mod/save/base sound pack preservation'
$before=Tree $existing;$count=$script:downloads
Invoke-FFUpdater $existing $true $true $false;Invoke-FFUpdater $existing $false $true $false
Assert ((Tree $existing) -ceq $before -and $script:downloads -eq $count) 'Check or same-version run changed files'
Invoke-FFUpdater $existing $false $true $true
Assert ((Tree $existing) -ne '') 'Repair failed'
Put (Join-Path $existing ($scripts+'main.lua')) '-- FeralFoxPrototype 0.99.0: future'
$before=Tree $existing;$count=$script:downloads;Invoke-FFUpdater $existing $false $true $true
Assert ((Tree $existing) -ceq $before -and $script:downloads -eq $count) 'Downgrade was allowed'
Write-Output 'PASS check-only, up-to-date, repair and downgrade guard'
$bad=New-Game 'tampered' $true;$before=Tree $bad;$originalSha=$update.sha256;$update.sha256='0'*64;Set-Fixture
$rejected=$false;try{Invoke-FFUpdater $bad $false $true $false}catch{$rejected=$true}
Assert ($rejected -and (Tree $bad) -ceq $before) 'Tampered ZIP was not rejected before installation'
$update.sha256=$originalSha;Set-Fixture
foreach($name in @('../escape.lua','/absolute.lua','AbioticFactor/Binaries/Win64/ue4ss/Mods/FeralFoxPrototype/Scripts/player-option.txt')){
    $badFiles=$files.Clone();$badFiles[$name]='bad';$p=Make-Zip 'unsafe.zip' $badFiles
    $dest=Join-Path $testBase ([guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($dest) | Out-Null
    $rejected=$false;try{Expand-FFVerifiedPackage (Join-Path $script:fixtures 'unsafe.zip') $dest $p}catch{$rejected=$true}
    Assert $rejected "Unsafe member accepted: $name"
}
$wrong=Make-Zip 'wrong-file.zip' $files;$wrong.files.($scripts+'voice.lua')='0'*64
$rejected=$false;try{Expand-FFVerifiedPackage (Join-Path $script:fixtures 'wrong-file.zip') (Join-Path $testBase 'wrong') $wrong}catch{$rejected=$true}
Assert $rejected 'Wrong per-file digest was accepted'
Write-Output 'PASS package/per-file integrity, traversal, absolute and personal-file rejection'
$rollback=New-Game 'rollback' $true;$before=Tree $rollback
$script:originalWrite=(Get-Item Function:\Write-FFFile).ScriptBlock;$script:faultRoot=$rollback
function Write-FFFile([string]$Source,[string]$Destination){
    if($Destination.StartsWith($script:faultRoot) -and $Destination -notlike '*\.FeralFoxUpdater\*' -and $Destination.EndsWith('voice.lua')){throw 'Simulated write failure'}
    & $script:originalWrite $Source $Destination
}
$rejected=$false;try{Invoke-FFUpdater $rollback $false $true $false}catch{$rejected=$_.Exception.Message.Contains('previous files restored')}
Set-Item Function:\Write-FFFile $script:originalWrite
Assert ($rejected -and (Tree $rollback) -ceq $before) 'Rollback did not restore exact prior files'
Write-Output 'PASS injected installation failure restores exact prior files'
function Get-Process {param($Name,$ErrorAction);return [pscustomobject]@{ProcessName='AbioticFactor'}}
$rejected=$false;try{Assert-FFGameClosed}catch{$rejected=$true};Remove-Item Function:\Get-Process
Assert $rejected 'Running game guard failed'
Write-Output 'PASS running game guard'
Write-Output "All updater fixtures passed: $testBase"
