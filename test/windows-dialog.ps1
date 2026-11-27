param([string] $PublicRef)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$ui = [Windows.Automation.AutomationElement]
$app = Get-AppxPackage -Name OpenAI.Codex | Where-Object PackageFamilyName -eq 'OpenAI.Codex_2p2nqsd0c76g0'
$codex = Join-Path $app.InstallLocation 'app/resources/codex.exe'
$root = Join-Path $env:USERPROFILE ("sworncard-test-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -Type Directory $root
$acl = Get-Acl $root
$acl.SetAccessRuleProtection($true, $false)
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
foreach ($principal in @($sid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($principal, 'FullControl', 'ContainerInherit,ObjectInherit', 'None','Allow'))
}
Set-Acl $root $acl
$env:CODEX_HOME = Join-Path $root '.codex'
$env:CODEX_ELECTRON_USER_DATA_PATH = Join-Path $root 'desktop-data'
$env:SWORNCARD_CONNECT_PAT = $null
$exeName = 'SwornCardSetup.exe'
$workspace = $PWD.Path
$exitTag = '0.2.0-alpha.5'

function Wait-For([scriptblock] $condition, [string] $description) {
    $deadline = [DateTime]::UtcNow.AddSeconds(50)
    do {
        $value = & $condition
        if ($value) { return $value }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $description"
}
function Element($window, [string] $name) {
    $byId = $window.FindFirst([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.PropertyCondition]::new($ui::AutomationIdProperty,$name))
    if ($byId) { return $byId }
    # Older WinForms UIA providers expose Win32 IDs; match only children of this test-owned window.
    $found = $window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
    foreach ($child in $found) {
        $info = $child.Current
        if ($name -eq 'PersonalAccessToken' -and $info.ControlType -eq [Windows.Automation.ControlType]::Edit) {return $child}
        if ($name -eq 'Save' -and $info.Name -in @('Сохранить','Готово')) {return $child}
        if ($name -eq 'Cancel' -and $info.Name -eq 'Отмена') {return $child}
        if ($name -eq 'Status' -and $info.ControlType -eq [Windows.Automation.ControlType]::Text -and $info.Name -notlike 'Вставьте PAT*') {return $child}
    }
}
function Set-Field($element, [string]$value) {
    $element.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($value)
}
function Click($element) {
    $element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
}
function New-Part {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}
function Open-Setup {
    $script:dialog = Start-Process $installed -PassThru
    $hwnd = Wait-For { $dialog.Refresh(); if ($dialog.HasExited) {throw "Dialog exited: $($dialog.ExitCode)"}; if ($dialog.MainWindowHandle -ne 0) {$dialog.MainWindowHandle} } 'WinForms window'
    $window = $ui::FromHandle($hwnd)
    $field = Wait-For {Element $window 'PersonalAccessToken'} 'password edit control'
    if (!$field.Current.IsPassword) {throw 'Masked PAT field missing'}
    return $window
}

try {
    # Launch the installed Desktop on the empty runner, apart from the test's app-server RPC calls.
    $desktop = Start-Process (Join-Path $app.InstallLocation 'app/ChatGPT.exe') -PassThru
    $null = Wait-For { (Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object {$_.MainWindowHandle -ne 0} | Select-Object -First 1) } 'official Desktop window'
    Write-Host "Opened clean official Codex Desktop $($app.Version)"
    if ($PublicRef) {
        & $codex plugin marketplace add https://github.com/idemnia/sworncard-connect-codex.git --ref $PublicRef
    } else { & $codex plugin marketplace add $workspace }
    if ($LASTEXITCODE) {throw 'Marketplace installation failed'}
    & $codex plugin add sworncard-connect@sworncard-connect
    if ($LASTEXITCODE) {throw 'Plugin installation failed'}
    $installed = Join-Path $env:CODEX_HOME "plugins/cache/sworncard-connect/sworncard-connect/$exitTag/skills/sworncard-setup/scripts/$exeName"
    if (!(Test-Path -LiteralPath $installed)) {throw 'Missing installed Windows dialog'}
    $config = Join-Path $env:CODEX_HOME 'config.toml'
    $original = (Get-FileHash $config).Hash
    $window = Open-Setup
    Click (Element $window 'Cancel')
    if (!$dialog.WaitForExit(5000) -or (Get-FileHash $config).Hash -ne $original) {throw 'Cancellation changed the configuration'}
    $id = 'pc_' + (New-Part)
    $old = ''
    foreach ($stage in @('create','rotate')) {
        $window = Open-Setup
        $field = Element $window 'PersonalAccessToken'
        $button = Element $window 'Save'
        if ($stage -eq 'create') {
            Set-Field $field 'invalid'
            Click $button
            $null = Wait-For {(Element $window 'Status').Current.Name -like '*Скопируйте весь PAT*'} 'invalid input message'
            if ((Get-FileHash $config).Hash -ne $original) {throw 'Invalid token changed configuration'}
        }
        $token = 'scpat1.' + $id + '.' + (New-Part)
        Set-Field $field $token
        Click $button
        $null = Wait-For {
            $name = (Element $window 'Status').Current.Name
            if ($name -like '*сохранена*') { return $true }
            if ((Element $window 'Save').Current.IsEnabled -and $name -notlike '*будет сохранён*' -and $name -notlike '*Скопируйте*') {throw "Setup status: $name"}
        } 'confirmed save'
        Click (Element $window 'Save')
        if (!$dialog.WaitForExit(5000) -or $dialog.ExitCode -ne 0) {throw 'Setup did not close successfully'}
        $text = [IO.File]::ReadAllText($config)
        if (!$text.Contains("sworncard_$id") -or !$text.Contains("Bearer $token") -or !$text.Contains('https://connect.sworncard.ru/mcp') -or ($old -and $text.Contains($old))) {throw 'Personal configuration mismatch'}
        $old = $token
        Write-Host "Passed Windows GUI step: $stage"
    }
    # A restarted process must actually authenticate. Use a loopback fixture; the installer pins the real RU URL.
    python (Join-Path $PSScriptRoot 'windows-catalogue.py') $codex
    if ($LASTEXITCODE) {throw 'Catalogue check failed'}
} finally {
    if ($dialog -and !$dialog.HasExited) { $dialog.Kill() }
    if ($desktop -and !$desktop.HasExited) { $null = $desktop.CloseMainWindow() }
}
