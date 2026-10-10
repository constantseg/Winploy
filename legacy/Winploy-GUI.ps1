#Requires -Version 5.1
<#
.SYNOPSIS
    WinPloy - Déploiement et désinstallation d'applications WinGet et de paquets personnalisés
    sur des postes Active Directory, via WinRM.

.DESCRIPTION
    - Recherche des postes AD par nom et/ou par OU.
    - Catalogue partagé (fichier JSON) contenant des paquets WinGet et des paquets personnalisés.
    - Paquet personnalisé : script d'installation et script de désinstallation (optionnel)
      stockés sur un partage. Le dossier du script est copié sur le poste par la machine
      d'administration via la session WinRM : le poste cible n'accède jamais au partage.
    - Panier mixte (WinGet + personnalisé), exécution parallèle limitée, interface non bloquante.

.NOTES
    Poste d'administration :
      - Windows PowerShell 5.1, module ActiveDirectory (RSAT), exécution en administrateur.
      - Accès en lecture/écriture au catalogue et en lecture aux scripts des paquets personnalisés.
    Postes cibles :
      - WinRM activé (GPO recommandée). WinPloy ne configure jamais WinRM ni le pare-feu des cibles.
      - WinGet (App Installer) présent pour les paquets WinGet.

    Auteur : Constant Segretain
    Licence : voir LICENSE
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    ) | Out-Null
    exit
}

# ============================================================
# Configuration
# ============================================================
$Script:Version     = '1.0.0'
$Script:AppDataDir  = Join-Path $env:ProgramData 'WinPloy'
$Script:ConfigFile  = Join-Path $Script:AppDataDir 'config.json'
$Script:HistoryFile = Join-Path $Script:AppDataDir 'historique-deploiements.json'
$Script:LogFile     = Join-Path $Script:AppDataDir 'gui.log'
$Script:HistoryMax  = 200
$Script:LogMaxBytes = 5MB

$Script:Config = [pscustomobject]@{
    CataloguePath     = '\\SERVEUR\Depot\catalogue.json'
    PackageTimeoutMin = 30
    MaxParallel       = 10
}

if (-not (Test-Path -LiteralPath $Script:AppDataDir)) {
    New-Item -Path $Script:AppDataDir -ItemType Directory -Force | Out-Null
}

function Get-ClampedInt {
    param($Value, [int]$Min, [int]$Max, [int]$Default)
    $n = 0
    if ([int]::TryParse([string]$Value, [ref]$n) -and $n -ge $Min -and $n -le $Max) { return $n }
    return $Default
}

function Import-WinPloyConfig {
    if (-not (Test-Path -LiteralPath $Script:ConfigFile)) { return }
    try {
        $cfg = Get-Content -LiteralPath $Script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return
    }
    $props = $cfg.PSObject.Properties.Name
    if ($props -contains 'CataloguePath' -and $cfg.CataloguePath) {
        $Script:Config.CataloguePath = [string]$cfg.CataloguePath
    }
    if ($props -contains 'PackageTimeoutMin') {
        $Script:Config.PackageTimeoutMin = Get-ClampedInt $cfg.PackageTimeoutMin 1 240 30
    }
    if ($props -contains 'MaxParallel') {
        $Script:Config.MaxParallel = Get-ClampedInt $cfg.MaxParallel 1 50 10
    }
}

function Save-WinPloyConfig {
    try {
        $Script:Config | ConvertTo-Json | Set-Content -LiteralPath $Script:ConfigFile -Encoding UTF8
        return $true
    } catch {
        Write-DeployLog "Impossible d'enregistrer les réglages : $($_.Exception.Message)" 'ERREUR'
        return $false
    }
}

function Get-DepotRoot { Split-Path -Path $Script:Config.CataloguePath -Parent }

Import-WinPloyConfig

# ============================================================
# Journal, historique, Active Directory
# ============================================================
$Script:LogBox = $null

function Write-DeployLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($Script:LogBox) {
        $Script:LogBox.AppendText("$line`r`n")
        $Script:LogBox.ScrollToEnd()
    }
    try {
        if ((Test-Path -LiteralPath $Script:LogFile) -and (Get-Item -LiteralPath $Script:LogFile).Length -gt $Script:LogMaxBytes) {
            Move-Item -LiteralPath $Script:LogFile -Destination "$($Script:LogFile).1" -Force
        }
        Add-Content -LiteralPath $Script:LogFile -Value $line -Encoding UTF8
    } catch {
        Write-Verbose "Journal fichier indisponible : $($_.Exception.Message)"
    }
}

function Save-DeployHistory {
    param([object[]]$Results)
    $history = @()
    if (Test-Path -LiteralPath $Script:HistoryFile) {
        try {
            $parsed = Get-Content -LiteralPath $Script:HistoryFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $history = @($parsed)
        } catch { $history = @() }
    }
    $history += [pscustomobject]@{ Date = Get-Date -Format 's'; Resultats = $Results }
    if ($history.Count -gt $Script:HistoryMax) {
        $history = $history[($history.Count - $Script:HistoryMax)..($history.Count - 1)]
    }
    try {
        ConvertTo-Json -InputObject @($history) -Depth 6 | Set-Content -LiteralPath $Script:HistoryFile -Encoding UTF8
    } catch {
        Write-DeployLog "Impossible d'écrire l'historique : $($_.Exception.Message)" 'ATTENTION'
    }
}

function Import-ADModule {
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        throw 'Module ActiveDirectory introuvable. Installer les RSAT : Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'
    }
    Import-Module ActiveDirectory -ErrorAction Stop
}

function Get-ADComputersFiltered {
    param([string]$SearchText, [string]$OuDN)
    Import-ADModule
    $filter = "Enabled -eq 'True'"
    if (-not [string]::IsNullOrWhiteSpace($SearchText)) {
        $filter += " -and Name -like '*{0}*'" -f $SearchText.Trim().Replace("'", "''")
    }
    $params = @{ Filter = $filter }
    if ($OuDN) { $params.SearchBase = $OuDN }
    Get-ADComputer @params | Sort-Object Name
}

function Get-ADOuTree {
    Import-ADModule
    Get-ADOrganizationalUnit -Filter * | Sort-Object DistinguishedName
}

# ============================================================
# Catalogue partagé
# ============================================================
# Schéma d'une entrée :
#   WinGet : { "Type": "WinGet", "Id": "Git.Git", "Name": "Git" }
#   Custom : { "Type": "Custom", "Id": "custom:Nom", "Name": "Nom",
#              "InstallScript": "\\srv\partage\Nom\install.ps1",
#              "UninstallScript": "\\srv\partage\Nom\uninstall.ps1", "RunAs": "User|System" }
# Le type est toujours déduit de l'Id (préfixe "custom:").

$Script:WingetIdPattern  = '^[A-Za-z0-9][A-Za-z0-9._+-]*$'
$Script:ScriptExtensions = @('.ps1', '.bat', '.cmd', '.exe')

function ConvertTo-CatalogueEntry {
    param($Item)
    $props = @($Item.PSObject.Properties.Name)
    $id = if ($props -contains 'Id') { ([string]$Item.Id).Trim() } else { '' }
    if (-not $id) { return $null }
    $name = if ($props -contains 'Name' -and $Item.Name) { [string]$Item.Name } else { $id }

    if ($id -like 'custom:*') {
        $runAs = if ($props -contains 'RunAs' -and [string]$Item.RunAs -eq 'System') { 'System' } else { 'User' }
        $entry = [pscustomobject][ordered]@{
            Type            = 'Custom'
            Id              = $id
            Name            = $name
            InstallScript   = if ($props -contains 'InstallScript')   { [string]$Item.InstallScript }   else { '' }
            UninstallScript = if ($props -contains 'UninstallScript') { [string]$Item.UninstallScript } else { '' }
            RunAs           = $runAs
        }
    } else {
        $entry = [pscustomobject][ordered]@{ Type = 'WinGet'; Id = $id; Name = $name }
    }
    $suffix = if ($entry.Type -eq 'Custom') { ' [Custom]' } else { '' }
    $entry | Add-Member -MemberType NoteProperty -Name Label -Value "$name$suffix"
    return $entry
}

function Read-CatalogueFile {
    $path = $Script:Config.CataloguePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Catalogue introuvable : $path" }
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $data = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
    return @(@($data) | ForEach-Object { ConvertTo-CatalogueEntry $_ } | Where-Object { $_ })
}

function Write-CatalogueFile {
    param([object[]]$Catalogue)
    $path = $Script:Config.CataloguePath
    $dir  = Split-Path -Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

    $json = ConvertTo-Json -InputObject @($Catalogue | Select-Object * -ExcludeProperty Label) -Depth 4
    $tmp  = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
    try {
        if (Test-Path -LiteralPath $path) { [IO.File]::Replace($tmp, $path, [NullString]::Value) }
        else { Move-Item -LiteralPath $tmp -Destination $path }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Import-Catalogue {
    try {
        $data = Read-CatalogueFile
        Write-DeployLog "Catalogue chargé : $($data.Count) application(s)."
        return $data
    } catch {
        Write-DeployLog "Catalogue illisible : $($_.Exception.Message)" 'ERREUR'
        return @()
    }
}

# Chaque modification relit le fichier juste avant d'écrire pour limiter
# l'écrasement des changements faits par un autre administrateur.
function Edit-Catalogue {
    param([scriptblock]$Change)
    $current = @(Read-CatalogueFile)
    $updated = @(& $Change $current | Where-Object { $_ })
    Write-CatalogueFile -Catalogue $updated
    return $updated
}

function Add-CatalogueEntry {
    param($Entry)
    Edit-Catalogue {
        param($current)
        if ($current | Where-Object { $_.Id -eq $Entry.Id }) {
            throw "Un paquet avec l'Id '$($Entry.Id)' existe déjà dans le catalogue."
        }
        $current + $Entry
    }
    Write-DeployLog "Paquet ajouté : $($Entry.Name) ($($Entry.Id))."
}

function Update-CatalogueEntry {
    param([string]$OldId, $Entry)
    Edit-Catalogue {
        param($current)
        if ($Entry.Id -ne $OldId -and ($current | Where-Object { $_.Id -eq $Entry.Id })) {
            throw "Un paquet avec l'Id '$($Entry.Id)' existe déjà dans le catalogue."
        }
        if (-not ($current | Where-Object { $_.Id -eq $OldId })) {
            throw "Le paquet '$OldId' n'existe plus dans le catalogue (supprimé par un autre administrateur ?)."
        }
        $current | ForEach-Object { if ($_.Id -eq $OldId) { $Entry } else { $_ } }
    }
    Write-DeployLog "Paquet modifié : $($Entry.Name) ($($Entry.Id))."
}

function Remove-CatalogueEntry {
    param([string[]]$Ids)
    Edit-Catalogue {
        param($current)
        $current | Where-Object { $Ids -notcontains $_.Id }
    }
    foreach ($id in $Ids) { Write-DeployLog "Paquet retiré du catalogue : $id." }
}

# ============================================================
# Exécution sur le poste cible (dans la session WinRM)
# ============================================================
$Script:RemoteActionScriptBlock = {
    param($WingetPkgs, $CustomPkgs, $Action, [int]$TimeoutMin)

    $ErrorActionPreference = 'Stop'
    $results = New-Object System.Collections.Generic.List[object]
    $workRoot = Join-Path $env:windir 'Temp\WinPloy'
    New-Item -Path $workRoot -ItemType Directory -Force | Out-Null

    function New-Result {
        param($Pkg, [bool]$Ok, [string]$Message)
        [pscustomobject]@{
            Id = $Pkg.Id; Name = $Pkg.Name
            Statut = $(if ($Ok) { 'OK' } else { 'ECHEC' })
            Message = $Message
        }
    }

    function ConvertTo-Literal {
        param([string]$Value)
        "'" + $Value.Replace("'", "''") + "'"
    }

    function Get-LogSummary {
        param([string[]]$Files)
        foreach ($file in $Files) {
            if (-not (Test-Path -LiteralPath $file)) { continue }
            $lines = @(Get-Content -LiteralPath $file -Encoding UTF8 -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -and $_ -notmatch '^[\|/\\\-\s]+$' -and $_ -notmatch '^[█▒\s\d.%KMGB/]+$' })
            if ($lines.Count) {
                $text = (($lines | Select-Object -Last 3) -join ' | ')
                $text = [regex]::Replace($text, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
                if ($text.Length -gt 500) { $text = $text.Substring(0, 500) + '...' }
                return $text
            }
        }
        return ''
    }

    # Exécute un script PowerShell dans une tâche planifiée temporaire en SYSTEM.
    # Retourne le code de sortie, ou $null en cas de dépassement du délai.
    function Invoke-AsSystem {
        param([string]$ScriptPath, [int]$Minutes)
        Import-Module ScheduledTasks
        $taskName  = "WinPloy_$([guid]::NewGuid().ToString('N'))"
        $taskArgs  = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`""
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -ExecutionTimeLimit (New-TimeSpan -Minutes $Minutes)
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        try {
            Start-ScheduledTask -TaskName $taskName
            $sw = [Diagnostics.Stopwatch]::StartNew()
            do {
                Start-Sleep -Seconds 2
                if ($sw.Elapsed.TotalMinutes -ge $Minutes) {
                    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                    return $null
                }
                $state = (Get-ScheduledTask -TaskName $taskName).State
                $last  = [uint32](Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult
                # 0x41301 = tâche en cours, 0x41303 = tâche pas encore lancée
            } while ($state -eq 'Running' -or $state -eq 'Queued' -or $last -eq 0x41301 -or $last -eq 0x41303)
            return $last
        } finally {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    # ---------- Paquets WinGet (exécutés en SYSTEM : winget échoue souvent en session WinRM) ----------
    if (@($WingetPkgs).Count -gt 0) {
        $wingetDir = Get-ChildItem (Join-Path $env:ProgramFiles 'WindowsApps') -Directory `
                        -Filter 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' -ErrorAction SilentlyContinue |
                     Sort-Object { try { [version]($_.Name -split '_')[1] } catch { [version]'0.0' } } |
                     Select-Object -Last 1
        $wingetExe = if ($wingetDir) { Join-Path $wingetDir.FullName 'winget.exe' } else { $null }

        foreach ($pkg in $WingetPkgs) {
            if (-not $wingetExe -or -not (Test-Path -LiteralPath $wingetExe -PathType Leaf)) {
                $results.Add((New-Result $pkg $false "winget.exe introuvable sur $env:COMPUTERNAME (App Installer absent)."))
                continue
            }
            if ([string]$pkg.Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') {
                $results.Add((New-Result $pkg $false "Identifiant WinGet invalide : $($pkg.Id)"))
                continue
            }

            $base    = Join-Path $workRoot ("winget_{0}" -f [guid]::NewGuid().ToString('N'))
            $logFile = "$base.log"
            $psFile  = "$base.ps1"
            $wingetArgs = if ($Action -eq 'Install') {
                @('install', '--id', $pkg.Id, '--exact', '--source', 'winget', '--silent',
                  '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
            } else {
                @('uninstall', '--id', $pkg.Id, '--exact', '--source', 'winget', '--silent', '--disable-interactivity')
            }
            $argsLiteral = ($wingetArgs | ForEach-Object { ConvertTo-Literal $_ }) -join ' '

            $wrapper = @(
                '$vclibs = Get-ChildItem (Join-Path $env:ProgramFiles ''WindowsApps'') -Directory -Filter ''Microsoft.VCLibs.140.00.UWPDesktop_*_x64__8wekyb3d8bbwe'' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1'
                'if ($vclibs) { $env:PATH = "$($vclibs.FullName);$env:PATH" }'
                "& $(ConvertTo-Literal $wingetExe) $argsLiteral 2>&1 | Out-File -LiteralPath $(ConvertTo-Literal $logFile) -Encoding utf8"
                'exit $LASTEXITCODE'
            ) -join "`r`n"

            try {
                Set-Content -LiteralPath $psFile -Value $wrapper -Encoding UTF8
                $code = Invoke-AsSystem -ScriptPath $psFile -Minutes $TimeoutMin
                $summary = Get-LogSummary @($logFile)
                $verb = if ($Action -eq 'Install') { 'Installation' } else { 'Désinstallation' }

                if ($null -eq $code) {
                    $results.Add((New-Result $pkg $false "$verb : délai de $TimeoutMin min dépassé, tâche arrêtée."))
                    continue
                }
                # 2316632161 = 0x8A150061 (déjà installé), 2316632084 = 0x8A150014 (aucun paquet trouvé),
                # 3221225781 = 0xC0000135 (DLL manquante). Écrits en décimal : 0x8A150061 serait un Int32 négatif.
                $hex = '0x{0:X8}' -f $code
                $detail = if ($summary) { " - $summary" } else { '' }
                switch ($code) {
                    0          { $results.Add((New-Result $pkg $true  "$verb terminée ($hex)$detail")) }
                    3010       { $results.Add((New-Result $pkg $true  "$verb terminée, redémarrage requis ($hex)$detail")) }
                    2316632161 { $results.Add((New-Result $pkg $true  "Déjà installé ($hex)")) }
                    2316632084 { $results.Add((New-Result $pkg ($Action -eq 'Uninstall') "Aucun paquet installé correspondant ($hex)")) }
                    3221225781 { $results.Add((New-Result $pkg $false "$verb échouée ($hex) : DLL/runtime Visual C++ manquant.")) }
                    default    { $results.Add((New-Result $pkg $false "$verb échouée ($hex)$detail")) }
                }
            } catch {
                $results.Add((New-Result $pkg $false $_.Exception.Message))
            } finally {
                Remove-Item -LiteralPath $psFile, $logFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # ---------- Paquets personnalisés (dossier déjà copié dans StageDir par la machine d'administration) ----------
    foreach ($pkg in $CustomPkgs) {
        $stage = [string]$pkg.StageDir
        try {
            $local = Join-Path $stage $pkg.Leaf
            $outLog = Join-Path $stage '_winploy_out.log'
            $errLog = Join-Path $stage '_winploy_err.log'
            switch ([IO.Path]::GetExtension($pkg.Leaf).ToLowerInvariant()) {
                '.ps1'  { $exe = 'powershell.exe'; $exeArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $local) }
                '.bat'  { $exe = 'cmd.exe';        $exeArgs = @('/c', $local) }
                '.cmd'  { $exe = 'cmd.exe';        $exeArgs = @('/c', $local) }
                '.exe'  { $exe = $local;           $exeArgs = @() }
                default { throw "Extension non supportée : $($pkg.Leaf)" }
            }

            if ($pkg.RunAs -eq 'System') {
                $psFile = Join-Path $stage '_winploy_system.ps1'
                # Start-Process redirige les flux bruts : pas de NativeCommandError autour du texte d'erreur du script.
                $argLine = ($exeArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
                $spArgs = if ($argLine) { " -ArgumentList $(ConvertTo-Literal $argLine)" } else { '' }
                @(
                    "`$p = Start-Process -FilePath $(ConvertTo-Literal $exe)$spArgs -WorkingDirectory $(ConvertTo-Literal $stage) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $(ConvertTo-Literal $outLog) -RedirectStandardError $(ConvertTo-Literal $errLog)"
                    'exit $p.ExitCode'
                ) -join "`r`n" | Set-Content -LiteralPath $psFile -Encoding UTF8
                $code = Invoke-AsSystem -ScriptPath $psFile -Minutes $TimeoutMin
                if ($null -eq $code) { throw "$($pkg.Leaf) : délai de $TimeoutMin min dépassé (SYSTEM), tâche arrêtée." }
                $mode = ' (SYSTEM)'
            } else {
                # stdin vide : un script qui attend une saisie se termine au lieu de bloquer la session.
                $stdin = Join-Path $stage '_winploy_stdin.txt'
                New-Item -Path $stdin -ItemType File -Force | Out-Null
                $sp = @{
                    FilePath = $exe; WorkingDirectory = $stage; PassThru = $true; NoNewWindow = $true
                    RedirectStandardInput = $stdin; RedirectStandardOutput = $outLog; RedirectStandardError = $errLog
                }
                if ($exeArgs.Count) { $sp.ArgumentList = ($exeArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) }
                $p = Start-Process @sp
                if (-not $p.WaitForExit($TimeoutMin * 60000)) {
                    & taskkill.exe /PID $p.Id /T /F | Out-Null
                    throw "$($pkg.Leaf) : délai de $TimeoutMin min dépassé, processus arrêté (script interactif ?)."
                }
                $code = $p.ExitCode
                $mode = ''
            }

            if ($code -in 0, 3010) {
                $reboot = if ($code -eq 3010) { ', redémarrage requis' } else { '' }
                $results.Add((New-Result $pkg $true "$($pkg.Leaf) ExitCode=$code$reboot$mode"))
            } else {
                $summary = Get-LogSummary @($errLog, $outLog)
                $results.Add((New-Result $pkg $false "$($pkg.Leaf) ExitCode=$code$mode $summary".Trim()))
            }
        } catch {
            $results.Add((New-Result $pkg $false $_.Exception.Message))
        } finally {
            if ($stage -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    return $results.ToArray()
}

# ============================================================
# Job local (un par poste) : contrôle WinRM, copie des paquets personnalisés, exécution distante
# ============================================================
$Script:JobScriptBlock = {
    param([string]$Computer, [Management.Automation.PSCredential]$Credential, $WingetPkgs, $CustomPkgs, [string]$Action,
          [string]$RemoteBlockText, [int]$TimeoutMin, [string]$DepotRoot)

    $ErrorActionPreference = 'Stop'

    function Send-Event {
        param([string]$Message, [string]$WinRMStatus = '')
        [pscustomobject]@{ __WinPloyEvent = $true; Message = $Message; WinRMStatus = $WinRMStatus }
    }

    function Test-TcpPort {
        param([string]$HostName, [int]$Port, [int]$TimeoutMs = 3000)
        $client = New-Object Net.Sockets.TcpClient
        try {
            $async = $client.BeginConnect($HostName, $Port, $null, $null)
            if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
            $client.EndConnect($async)
            return $true
        } catch {
            return $false
        } finally {
            $client.Close()
        }
    }

    # Un nom sans domaine ("admin") est essayé tel quel puis qualifié en compte local ("POSTE\admin").
    $candidates = @($null)
    if ($Credential) {
        $candidates = @($Credential)
        $user = [string]$Credential.UserName
        if ($user -notmatch '\\|@') {
            $candidates += New-Object Management.Automation.PSCredential ("$Computer\$user", $Credential.Password)
        } elseif ($user -like '.\*') {
            $candidates = @(New-Object Management.Automation.PSCredential ("$Computer\$($user.Substring(2))", $Credential.Password))
        }
    }

    Send-Event 'Vérification du port WinRM 5985...' 'Vérification...'
    if (-not (Test-TcpPort -HostName $Computer -Port 5985)) {
        throw "WinRM injoignable sur $Computer (port 5985). Vérifier que le poste est allumé et que WinRM est activé par GPO."
    }
    Send-Event 'WinRM joignable, ouverture de la session...' 'Accessible'

    $session = $null
    $lastError = ''
    $sessionOption = New-PSSessionOption -OpenTimeout 30000 -OperationTimeout 0
    foreach ($candidate in $candidates) {
        try {
            $params = @{ ComputerName = $Computer; Authentication = 'Negotiate'; SessionOption = $sessionOption }
            if ($candidate) { $params.Credential = $candidate }
            $session = New-PSSession @params
            break
        } catch {
            $lastError = $_.Exception.Message
        }
    }
    if (-not $session) {
        $who = if ($Credential) { "le compte '$($Credential.UserName)'" } else { 'le contexte courant' }
        throw "Ouverture de session WinRM refusée sur $Computer avec $who. $lastError"
    }
    Send-Event 'Session WinRM ouverte, exécution...' 'Actif'

    try {
        $failed = @()
        $staged = @()
        foreach ($pkg in $CustomPkgs) {
            try {
                $scriptPath = if ($Action -eq 'Install') { $pkg.InstallScript } else { $pkg.UninstallScript }
                if ([string]::IsNullOrWhiteSpace($scriptPath)) {
                    $what = if ($Action -eq 'Install') { "d'installation" } else { 'de désinstallation' }
                    throw "Aucun script $what défini pour ce paquet."
                }
                $srcDir = Split-Path -Path $scriptPath -Parent
                if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
                    throw "Script introuvable depuis la machine d'administration : $scriptPath"
                }
                if ($DepotRoot -and ($srcDir.TrimEnd('\') -eq $DepotRoot.TrimEnd('\'))) {
                    throw "Le script est à la racine du dépôt : tout le dépôt serait copié. Placer chaque paquet dans son propre sous-dossier."
                }

                $stage = Invoke-Command -Session $session -ScriptBlock {
                    $d = Join-Path $env:windir ("Temp\WinPloy\stage_{0}" -f [guid]::NewGuid().ToString('N'))
                    New-Item -Path $d -ItemType Directory -Force | Out-Null
                    $d
                }
                Copy-Item -Path (Join-Path $srcDir '*') -Destination $stage -ToSession $session -Recurse -Force

                $staged += [pscustomobject]@{
                    Id = $pkg.Id; Name = $pkg.Name; Leaf = (Split-Path -Path $scriptPath -Leaf)
                    StageDir = $stage; RunAs = $pkg.RunAs
                }
            } catch {
                $failed += [pscustomobject]@{ Id = $pkg.Id; Name = $pkg.Name; Statut = 'ECHEC'; Message = "Préparation : $($_.Exception.Message)" }
            }
        }

        $remote = [scriptblock]::Create($RemoteBlockText)
        $remoteResults = Invoke-Command -Session $session -ScriptBlock $remote -ArgumentList @($WingetPkgs, $staged, $Action, $TimeoutMin)
        @($failed) + @($remoteResults)
    } finally {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}

# ============================================================
# Orchestration (file d'attente + parallélisme limité)
# ============================================================
$Script:ActiveJobs     = New-Object System.Collections.ArrayList
$Script:PendingTargets = New-Object System.Collections.Queue
$Script:RunContext     = $null
$Script:LastRun        = $null
$Script:StopRequested  = $false

# Les cibles sont ajoutées à TrustedHosts du client WinRM : sans cela, toute bascule
# de Kerberos vers NTLM (compte local, SPN, DNS, contexte courant) fait échouer la session.
# Écriture unique dans le thread de l'interface, avant le lancement des jobs.
function Add-TrustedHost {
    param([string[]]$Computers)
    if (-not $Computers) { return }
    # Le lecteur WSMan: exige le service WinRM local.
    $service = Get-Service -Name WinRM -ErrorAction Stop
    if ($service.Status -ne 'Running') {
        Start-Service -Name WinRM -ErrorAction Stop
        Write-DeployLog 'Service WinRM local démarré (nécessaire pour TrustedHosts).'
    }
    $path = 'WSMan:\localhost\Client\TrustedHosts'
    $current = [string](Get-Item -Path $path -ErrorAction Stop).Value
    $items = @($current -split '\s*,\s*' | Where-Object { $_ })
    if ($items -contains '*') { return }
    $missing = @($Computers | Where-Object { $items -notcontains $_ })
    if (-not $missing) { return }
    Set-Item -Path $path -Value (@($items + $missing) -join ',') -Force -ErrorAction Stop
    Write-DeployLog "TrustedHosts WinRM : ajout de $($missing -join ', ')."
}

function Get-HostRow {
    param([string]$Name)
    foreach ($row in $Script:HostRows) { if ($row.Poste -eq $Name) { return $row } }
    return $null
}

function Format-Elapsed {
    param([datetime]$Since)
    $d = (Get-Date) - $Since
    '{0:00}:{1:00}' -f [int][Math]::Floor($d.TotalMinutes), $d.Seconds
}

function Add-ResultRow {
    param([string]$Computer, [object[]]$Rows)
    foreach ($r in $Rows) {
        $Script:ResultsCollection.Add([pscustomobject]@{
            Ordinateur = $Computer; Paquet = $r.Name; Id = $r.Id
            Statut = $r.Statut; Message = $r.Message; Horodatage = Get-Date
        })
    }
}

# État final d'un poste, calculé à partir de ses lignes de résultat.
function Set-HostFinal {
    param([string]$Computer, [string]$Duree)
    $row = Get-HostRow $Computer
    if (-not $row) { return }
    $res = @($Script:ResultsCollection | Where-Object { $_.Ordinateur -eq $Computer })
    if (-not $res.Count) { return }
    $bad = @($res | Where-Object { $_.Statut -ne 'OK' })
    if ($res | Where-Object { $_.Statut -eq 'ARRÊTÉ' }) {
        $row.Etat = 'ARRÊTÉ'
        $row.Info = [string]$res[0].Message
    } elseif (-not $bad.Count) {
        $row.Etat = 'OK'
        $row.Info = "$($res.Count) paquet(s) traité(s) avec succès."
    } else {
        $row.Etat = 'ECHEC'
        $msg = ([string]$bad[0].Message -replace '\s+', ' ').Trim()
        if ($msg.Length -gt 160) { $msg = $msg.Substring(0, 160) + '…' }
        $row.Info = if ($res.Count -gt 1) { "$($bad.Count)/$($res.Count) en échec : $msg" } else { $msg }
    }
    if ($Duree) { $row.Duree = $Duree }
}

function Complete-Host {
    param([string]$Computer, [object[]]$Rows, [string]$Duree)
    Add-ResultRow $Computer $Rows
    Set-HostFinal $Computer $Duree
    $Script:RunContext.Done++
    $selected = $ctrl.GridHosts.SelectedItem
    if ($selected -and $selected.Poste -eq $Computer) { Show-HostDetail }
}

function Start-TargetJob {
    param([string]$Computer)
    $ctx = $Script:RunContext
    $row = Get-HostRow $Computer
    try {
        $job = Start-Job -Name "WinPloy_$Computer" -ScriptBlock $Script:JobScriptBlock -ArgumentList @(
            $Computer, $ctx.Credential, $ctx.WingetPkgs, $ctx.CustomPkgs, $ctx.Action,
            $Script:RemoteActionScriptBlock.ToString(), $Script:Config.PackageTimeoutMin, (Get-DepotRoot)
        )
        [void]$Script:ActiveJobs.Add([pscustomobject]@{
            Job = $job; Computer = $Computer; Started = Get-Date
            Output = New-Object System.Collections.ArrayList
            Errors = New-Object System.Collections.ArrayList
        })
        $row.Etat = 'EN COURS'; $row.WinRM = 'Vérification…'; $row.Info = 'Contrôle WinRM…'
        Write-DeployLog "$Computer : job démarré."
    } catch {
        Complete-Host $Computer @([pscustomobject]@{ Name = '(tous)'; Id = ''; Statut = 'ECHEC'; Message = "Lancement du job impossible : $($_.Exception.Message)" })
    }
}

function Start-Deployment {
    param([string[]]$Targets, [object[]]$Packages, [string]$Action, [switch]$Retry)

    $ctrl.BtnDeploy.IsEnabled = $false
    $ctrl.BtnRetry.IsEnabled  = $false
    $ctrl.BtnStop.IsEnabled   = $true
    $Script:StopRequested = $false

    if (-not $Retry) { $Script:ResultsCollection.Clear(); $Script:HostRows.Clear() }
    foreach ($t in $Targets) {
        foreach ($old in @($Script:ResultsCollection | Where-Object { $_.Ordinateur -eq $t })) { [void]$Script:ResultsCollection.Remove($old) }
        $row = Get-HostRow $t
        if (-not $row) { $row = New-Object WinPloyHostRow; $row.Poste = $t; $Script:HostRows.Add($row) }
        $row.Etat = 'EN ATTENTE'; $row.WinRM = ''; $row.Info = 'En file d''attente.'; $row.Duree = ''
    }

    $Script:LastRun = [pscustomobject]@{ Packages = $Packages; Action = $Action }
    $Script:RunContext = [pscustomobject]@{
        Action     = $Action
        WingetPkgs = @($Packages | Where-Object { $_.Type -eq 'WinGet' } | Select-Object Id, Name)
        CustomPkgs = @($Packages | Where-Object { $_.Type -eq 'Custom' } | Select-Object Id, Name, InstallScript, UninstallScript, RunAs)
        Credential = $Script:Credential
        Total      = $Targets.Count
        Done       = 0
        JobTimeout = ($Script:Config.PackageTimeoutMin * [Math]::Max(1, $Packages.Count)) + 5
    }

    try {
        Add-TrustedHost $Targets
    } catch {
        $msg = "Mise à jour de TrustedHosts impossible : $($_.Exception.Message)"
        Write-DeployLog $msg 'ERREUR'
        Show-Message "$msg`r`n`r`nLes sessions WinRM risquent d'échouer. Une GPO « Hôtes approuvés » peut bloquer cette modification." 'TrustedHosts' 'Warning' | Out-Null
    }

    $Script:PendingTargets.Clear()
    foreach ($t in $Targets) { $Script:PendingTargets.Enqueue($t) }
    Write-DeployLog "=== $Action : $($Packages.Count) paquet(s) sur $($Targets.Count) poste(s), $($Script:Config.MaxParallel) en parallèle ==="
    Update-Summary
}

function Get-FriendlyJobFailureMessage {
    param($Job, [object[]]$JobErrors)
    $texts = @($JobErrors | ForEach-Object { $_.Exception.Message })
    foreach ($j in @($Job) + @($Job.ChildJobs)) {
        if ($j.JobStateInfo.Reason) { $texts += $j.JobStateInfo.Reason.Message }
    }
    $raw = (@($texts | Where-Object { $_ } | Select-Object -Unique)) -join ' | '

    if ($raw -match '0x8009030e') {
        return "Authentification WinRM impossible (0x8009030e). Vérifier le format du compte (DOMAINE\utilisateur ou POSTE\utilisateur). Détail : $raw"
    }
    if ($raw -match 'Access is denied|Accès refusé|logon failure|access.*denied') {
        return "Accès refusé : le compte n'a pas les droits administrateur sur le poste. Détail : $raw"
    }
    if ($raw) { return $raw }
    return "Job terminé sans résultat (état : $($Job.State))."
}

function Receive-JobOutput {
    param($Info)
    $errs = $null
    $items = @(Receive-Job -Job $Info.Job -ErrorVariable errs -ErrorAction SilentlyContinue)
    foreach ($e in @($errs)) { if ($e) { [void]$Info.Errors.Add($e) } }
    $row = Get-HostRow $Info.Computer
    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        if ($item.PSObject.Properties.Name -contains '__WinPloyEvent') {
            Write-DeployLog "$($Info.Computer) : $($item.Message)"
            if ($row) {
                $row.Info = [string]$item.Message
                if ($item.WinRMStatus) { $row.WinRM = [string]$item.WinRMStatus }
            }
        } elseif ($item.PSObject.Properties.Name -contains 'Statut') {
            [void]$Info.Output.Add($item)
        }
    }
}

function Complete-TargetJob {
    param($Info, [string]$Reason)
    Receive-JobOutput $Info
    $final = @($Info.Output)

    if ($Reason -eq 'Stopped') {
        $rows = @([pscustomobject]@{ Name = '(tous)'; Id = ''; Statut = 'ARRÊTÉ'; Message = "Arrêté par l'utilisateur. Une action déjà lancée sur le poste peut continuer." })
    } elseif ($Reason -eq 'Timeout') {
        $rows = @([pscustomobject]@{ Name = '(tous)'; Id = ''; Statut = 'ECHEC'; Message = "Délai global de $($Script:RunContext.JobTimeout) min dépassé, job arrêté." })
    } elseif (-not $final.Count) {
        $rows = @([pscustomobject]@{ Name = '(tous)'; Id = ''; Statut = 'ECHEC'; Message = (Get-FriendlyJobFailureMessage $Info.Job @($Info.Errors)) })
    } else {
        $rows = $final
    }

    Remove-Job -Job $Info.Job -Force -ErrorAction SilentlyContinue
    Complete-Host $Info.Computer $rows (Format-Elapsed $Info.Started)
    Write-DeployLog "$($Info.Computer) : terminé."
}

function Invoke-SchedulerTick {
    $ctx = $Script:RunContext
    if (-not $ctx) { return }

    if (-not $Script:StopRequested) {
        while ($Script:PendingTargets.Count -gt 0 -and $Script:ActiveJobs.Count -lt $Script:Config.MaxParallel) {
            Start-TargetJob ([string]$Script:PendingTargets.Dequeue())
        }
    } else {
        while ($Script:PendingTargets.Count -gt 0) {
            Complete-Host ([string]$Script:PendingTargets.Dequeue()) @([pscustomobject]@{ Name = '(tous)'; Id = ''; Statut = 'ARRÊTÉ'; Message = 'Non lancé (arrêt demandé).' })
        }
    }

    foreach ($info in @($Script:ActiveJobs)) {
        if ($info.Job.State -in 'Running', 'NotStarted') {
            if ($Script:StopRequested) {
                Stop-Job -Job $info.Job -ErrorAction SilentlyContinue
                Complete-TargetJob $info 'Stopped'
                $Script:ActiveJobs.Remove($info)
            } elseif (((Get-Date) - $info.Started).TotalMinutes -gt $ctx.JobTimeout) {
                Stop-Job -Job $info.Job -ErrorAction SilentlyContinue
                Complete-TargetJob $info 'Timeout'
                $Script:ActiveJobs.Remove($info)
            } else {
                Receive-JobOutput $info
                $row = Get-HostRow $info.Computer
                if ($row) { $row.Duree = Format-Elapsed $info.Started }
            }
        } else {
            Complete-TargetJob $info 'Finished'
            $Script:ActiveJobs.Remove($info)
        }
    }

    if ($Script:HostFilterMode -ne 0 -or $Script:HostFilterText) {
        [System.Windows.Data.CollectionViewSource]::GetDefaultView($Script:HostRows).Refresh()
    }

    if ($Script:ActiveJobs.Count -eq 0 -and $Script:PendingTargets.Count -eq 0) {
        $verb = if ($Script:StopRequested) { 'Arrêté' } else { 'Terminé' }
        $ctrl.LblStatus.Text = "$verb : $($ctx.Done)/$($ctx.Total) poste(s)."
        $ctrl.BtnDeploy.IsEnabled = $true
        $ctrl.BtnStop.IsEnabled = $false
        Save-DeployHistory -Results @($Script:ResultsCollection)
        Write-DeployLog "=== Opération $($verb.ToLower()). ==="
        $Script:RunContext = $null
        $Script:StopRequested = $false
    } else {
        $prefix = if ($Script:StopRequested) { 'Arrêt en cours…' } else { 'Traitement :' }
        $ctrl.LblStatus.Text = "$prefix $($ctx.Done)/$($ctx.Total) poste(s) terminé(s)"
    }
    Update-Summary
}

# ============================================================
# Interface graphique (WPF)
# ============================================================
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Ligne du tableau « Suivi par poste » : notifie l'interface à chaque changement de propriété.
if (-not ('WinPloyHostRow' -as [type])) {
    Add-Type -TypeDefinition @'
using System.ComponentModel;
public class WinPloyHostRow : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    private void Raise(string n) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(n)); }
    private string _etat = "EN ATTENTE"; private string _winrm = ""; private string _info = ""; private string _duree = "";
    public string Poste { get; set; }
    public string Etat  { get { return _etat; }  set { _etat = value;  Raise("Etat"); } }
    public string WinRM { get { return _winrm; } set { _winrm = value; Raise("WinRM"); } }
    public string Info  { get { return _info; }  set { _info = value;  Raise("Info"); } }
    public string Duree { get { return _duree; } set { _duree = value; Raise("Duree"); } }
}
'@
}

function New-XamlWindow {
    param([string]$Xaml)
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
    [Windows.Markup.XamlReader]::Load($reader)
}

function Show-Message {
    param([string]$Text, [string]$Title = 'WinPloy', [string]$Icon = 'Information', [string]$Buttons = 'OK')
    [System.Windows.MessageBox]::Show($Text, $Title, [System.Windows.MessageBoxButton]$Buttons, [System.Windows.MessageBoxImage]$Icon)
}

$Window = New-XamlWindow @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinPloy $($Script:Version)" Height="800" Width="1280" MinHeight="620" MinWidth="980"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="12" Background="#F3F4F6">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Padding" Value="12,5"/>
            <Setter Property="Margin" Value="0,0,6,0"/>
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="BorderBrush" Value="#D1D5DB"/>
            <Setter Property="Foreground" Value="#111827"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="1" CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.85"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.4"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#2563EB"/>
            <Setter Property="BorderBrush" Value="#1D4ED8"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style x:Key="Card" TargetType="Border">
            <Setter Property="Background" Value="White"/>
            <Setter Property="BorderBrush" Value="#E5E7EB"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="6"/>
            <Setter Property="Padding" Value="10"/>
        </Style>
        <Style x:Key="Section" TargetType="TextBlock">
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
        <Style TargetType="DataGrid">
            <Setter Property="IsReadOnly" Value="True"/>
            <Setter Property="SelectionMode" Value="Single"/>
            <Setter Property="CanUserAddRows" Value="False"/>
            <Setter Property="HeadersVisibility" Value="Column"/>
            <Setter Property="RowHeaderWidth" Value="0"/>
            <Setter Property="GridLinesVisibility" Value="Horizontal"/>
            <Setter Property="HorizontalGridLinesBrush" Value="#E5E7EB"/>
            <Setter Property="Background" Value="White"/>
            <Setter Property="BorderBrush" Value="#D1D5DB"/>
        </Style>
        <Style x:Key="HostRow" TargetType="DataGridRow" BasedOn="{StaticResource {x:Type DataGridRow}}">
            <Style.Triggers>
                <DataTrigger Binding="{Binding Etat}" Value="ECHEC"><Setter Property="Background" Value="#FEF2F2"/></DataTrigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="ResRow" TargetType="DataGridRow" BasedOn="{StaticResource {x:Type DataGridRow}}">
            <Style.Triggers>
                <DataTrigger Binding="{Binding Statut}" Value="ECHEC"><Setter Property="Background" Value="#FEF2F2"/></DataTrigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>

    <Grid Margin="10">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="1*" MinHeight="170"/>
            <RowDefinition Height="8"/>
            <RowDefinition Height="1.5*" MinHeight="300"/>
        </Grid.RowDefinitions>

        <Border Grid.Row="0" Style="{StaticResource Card}" Padding="10,8" Margin="0,0,0,8">
            <DockPanel>
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                    <Button x:Name="BtnSettings" Content="⚙ Réglages" ToolTip="Réglages de WinPloy"/>
                    <Button x:Name="BtnAbout" Content="À propos" Margin="0" ToolTip="Informations sur WinPloy et son auteur"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal">
                    <Button x:Name="BtnCred" Content="Identifiants…"/>
                    <TextBlock x:Name="LblCred" Text="Contexte courant" VerticalAlignment="Center" Margin="2,0,28,0" Foreground="#6B7280"/>
                    <TextBlock Text="Action :" VerticalAlignment="Center" FontWeight="SemiBold" Margin="0,0,8,0"/>
                    <RadioButton x:Name="RbInstall" Content="Installer" GroupName="Action" IsChecked="True" VerticalAlignment="Center" Margin="0,0,14,0"/>
                    <RadioButton x:Name="RbUninstall" Content="Désinstaller" GroupName="Action" VerticalAlignment="Center"/>
                </StackPanel>
            </DockPanel>
        </Border>

        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="2*"/>
                <ColumnDefinition Width="8"/>
                <ColumnDefinition Width="2*"/>
                <ColumnDefinition Width="8"/>
                <ColumnDefinition Width="1.7*"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Style="{StaticResource Card}">
                <DockPanel>
                    <TextBlock DockPanel.Dock="Top" Style="{StaticResource Section}" Text="1 · Postes Active Directory" Margin="0,0,0,8"/>
                    <Grid DockPanel.Dock="Top" Margin="0,0,0,6">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBox x:Name="TxtSearchPc" Padding="4,4" VerticalContentAlignment="Center" ToolTip="Nom (partiel) du poste. Entrée pour rechercher."/>
                        <Button x:Name="BtnSearchPc" Grid.Column="1" Content="Rechercher" Margin="6,0,0,0"/>
                        <Button x:Name="BtnLoadOu" Grid.Column="2" Content="Charger OUs" Margin="6,0,0,0"/>
                    </Grid>
                    <ComboBox x:Name="CmbOu" DockPanel.Dock="Top" Margin="0,0,0,6"/>
                    <StackPanel DockPanel.Dock="Bottom" Margin="0,6,0,0">
                        <TextBlock x:Name="LblPcFound" Text="Aucune recherche effectuée." Foreground="#6B7280" Margin="0,0,0,6"/>
                        <StackPanel Orientation="Horizontal">
                            <Button x:Name="BtnAddPc" Content="Ajouter la sélection ▶" Style="{StaticResource Primary}"/>
                            <Button x:Name="BtnAddAllPc" Content="Tout ajouter ▶▶" ToolTip="Ajouter tous les postes de la liste"/>
                        </StackPanel>
                    </StackPanel>
                    <ListBox x:Name="LstPcAll" SelectionMode="Extended" ToolTip="Double-clic = ajouter le poste"/>
                </DockPanel>
            </Border>

            <Border Grid.Column="2" Style="{StaticResource Card}">
                <DockPanel>
                    <TextBlock DockPanel.Dock="Top" Style="{StaticResource Section}" Text="2 · Applications (double-clic = modifier)" Margin="0,0,0,8"/>
                    <WrapPanel DockPanel.Dock="Top" Margin="0,0,0,6">
                        <Button x:Name="BtnRefreshCatalogue" Content="Rafraîchir" Margin="0,0,6,4" ToolTip="Recharger le catalogue partagé"/>
                        <Button x:Name="BtnAddApp" Content="＋ Ajouter une app ▾" Margin="0,0,6,4" ToolTip="Choisir le type d'application à ajouter"/>
                        <Button x:Name="BtnRemoveFromCatalogue" Content="Supprimer" Margin="0,0,0,4" ToolTip="Supprimer les applications sélectionnées du catalogue"/>
                    </WrapPanel>
                    <Grid DockPanel.Dock="Top" Margin="0,0,0,6">
                        <TextBox x:Name="TxtSearchPkg" Padding="4,3" VerticalContentAlignment="Center" ToolTip="Filtrer les applications par nom ou Id. Échap pour effacer."/>
                        <TextBlock x:Name="LblSearchPkgHint" Text="Rechercher une application…" Foreground="#9CA3AF" IsHitTestVisible="False" VerticalAlignment="Center" Margin="7,0,0,0"/>
                    </Grid>
                    <Button x:Name="BtnAddPkg" DockPanel.Dock="Bottom" Content="Ajouter au panier ▶" Style="{StaticResource Primary}" HorizontalAlignment="Left" Margin="0,6,0,0" ToolTip="Ajouter les applications sélectionnées au panier de déploiement"/>
                    <ListBox x:Name="LstCatalogue" DisplayMemberPath="Label" SelectionMode="Extended"/>
                </DockPanel>
            </Border>

            <Grid Grid.Column="4">
                <Grid.RowDefinitions>
                    <RowDefinition Height="1.4*"/>
                    <RowDefinition Height="8"/>
                    <RowDefinition Height="1*"/>
                </Grid.RowDefinitions>
                <Border Grid.Row="0" Style="{StaticResource Card}">
                    <DockPanel>
                        <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
                            <Button x:Name="BtnClearPc" DockPanel.Dock="Right" Content="Tout vider" Margin="6,0,0,0" Padding="8,3"/>
                            <Button x:Name="BtnRemovePc" DockPanel.Dock="Right" Content="Retirer" Margin="6,0,0,0" Padding="8,3"/>
                            <TextBlock x:Name="LblPcCount" Style="{StaticResource Section}" Text="3 · Postes ciblés (0)"/>
                        </DockPanel>
                        <ListBox x:Name="LstPcSelected" SelectionMode="Extended"/>
                    </DockPanel>
                </Border>
                <Border Grid.Row="2" Style="{StaticResource Card}">
                    <DockPanel>
                        <DockPanel DockPanel.Dock="Top" Margin="0,0,0,6">
                            <Button x:Name="BtnClearPkg" DockPanel.Dock="Right" Content="Vider" Margin="6,0,0,0" Padding="8,3"/>
                            <Button x:Name="BtnRemovePkg" DockPanel.Dock="Right" Content="Retirer" Margin="6,0,0,0" Padding="8,3"/>
                            <TextBlock x:Name="LblPkgCount" Style="{StaticResource Section}" Text="Panier (0)"/>
                        </DockPanel>
                        <ListBox x:Name="LstPkgSelected" DisplayMemberPath="Label" SelectionMode="Extended"/>
                    </DockPanel>
                </Border>
            </Grid>
        </Grid>

        <GridSplitter Grid.Row="2" Height="8" HorizontalAlignment="Stretch" VerticalAlignment="Center" Background="Transparent" ResizeDirection="Rows" ToolTip="Glisser pour agrandir la zone de suivi"/>

        <Border Grid.Row="3" Style="{StaticResource Card}">
            <DockPanel>
                <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
                    <Button x:Name="BtnExport" DockPanel.Dock="Right" Content="Exporter CSV" Margin="6,0,0,0" IsEnabled="False" ToolTip="Exporter les résultats détaillés"/>
                    <StackPanel Orientation="Horizontal">
                        <Button x:Name="BtnDeploy" Content="▶  Exécuter" Style="{StaticResource Primary}" Padding="22,7"/>
                        <Button x:Name="BtnStop" Content="■ Arrêter" Padding="14,7" IsEnabled="False" ToolTip="Arrêter les jobs WinPloy en cours"/>
                        <Button x:Name="BtnRetry" Content="↻ Relancer les échecs" Padding="14,7" IsEnabled="False" ToolTip="Relancer la même opération uniquement sur les postes en échec ou arrêtés"/>
                        <TextBlock x:Name="LblStatus" Text="Prêt." VerticalAlignment="Center" Margin="8,0,0,0" Foreground="#374151"/>
                    </StackPanel>
                </DockPanel>
                <ProgressBar x:Name="Progress" DockPanel.Dock="Top" Height="10" Minimum="0" Maximum="100" Foreground="#16A34A" Margin="0,0,0,8"/>
                <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
                    <TextBlock x:Name="LblCntTotal" Text="0 poste" FontWeight="SemiBold" Margin="0,0,20,0"/>
                    <TextBlock x:Name="LblCntRun" Text="● 0 en cours" Foreground="#D97706" Margin="0,0,20,0"/>
                    <TextBlock x:Name="LblCntOk" Text="✔ 0 réussi" Foreground="#15803D" Margin="0,0,20,0"/>
                    <TextBlock x:Name="LblCntFail" Text="✖ 0 échec" Foreground="#B91C1C"/>
                </StackPanel>

                <TabControl>
                    <TabItem Header="Suivi par poste">
                        <DockPanel Margin="0,8,0,0">
                            <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,6">
                                <ComboBox x:Name="CmbFilter" Width="180" SelectedIndex="0">
                                    <ComboBoxItem Content="Tous les postes"/>
                                    <ComboBoxItem Content="En cours / en attente"/>
                                    <ComboBoxItem Content="Échecs / arrêtés"/>
                                    <ComboBoxItem Content="Réussis"/>
                                </ComboBox>
                                <TextBox x:Name="TxtHostFilter" Width="200" Margin="6,0,0,0" Padding="4,2" VerticalContentAlignment="Center" ToolTip="Filtrer par nom de poste"/>
                            </StackPanel>
                            <DockPanel DockPanel.Dock="Bottom" Margin="0,6,0,0" Height="64">
                                <Button x:Name="BtnCopyDetail" DockPanel.Dock="Right" Content="Copier" VerticalAlignment="Top" Margin="6,0,0,0"/>
                                <TextBox x:Name="TxtHostDetail" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="#F9FAFB" Padding="6" Text="Sélectionne un poste pour voir le détail complet."/>
                            </DockPanel>
                            <DataGrid x:Name="GridHosts" AutoGenerateColumns="False" RowStyle="{StaticResource HostRow}">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Poste" Binding="{Binding Poste}" Width="130"/>
                                    <DataGridTemplateColumn Header="État" Width="110" SortMemberPath="Etat">
                                        <DataGridTemplateColumn.CellTemplate>
                                            <DataTemplate>
                                                <TextBlock Text="{Binding Etat}" FontWeight="SemiBold" Margin="6,2">
                                                    <TextBlock.Style>
                                                        <Style TargetType="TextBlock">
                                                            <Setter Property="Foreground" Value="#6B7280"/>
                                                            <Style.Triggers>
                                                                <DataTrigger Binding="{Binding Etat}" Value="EN COURS"><Setter Property="Foreground" Value="#D97706"/></DataTrigger>
                                                                <DataTrigger Binding="{Binding Etat}" Value="OK"><Setter Property="Foreground" Value="#15803D"/></DataTrigger>
                                                                <DataTrigger Binding="{Binding Etat}" Value="ECHEC"><Setter Property="Foreground" Value="#B91C1C"/></DataTrigger>
                                                            </Style.Triggers>
                                                        </Style>
                                                    </TextBlock.Style>
                                                </TextBlock>
                                            </DataTemplate>
                                        </DataGridTemplateColumn.CellTemplate>
                                    </DataGridTemplateColumn>
                                    <DataGridTextColumn Header="WinRM" Binding="{Binding WinRM}" Width="110"/>
                                    <DataGridTemplateColumn Header="Détail" Width="*" SortMemberPath="Info">
                                        <DataGridTemplateColumn.CellTemplate>
                                            <DataTemplate>
                                                <TextBlock Text="{Binding Info}" ToolTip="{Binding Info}" TextTrimming="CharacterEllipsis" Margin="6,2"/>
                                            </DataTemplate>
                                        </DataGridTemplateColumn.CellTemplate>
                                    </DataGridTemplateColumn>
                                    <DataGridTextColumn Header="Durée" Binding="{Binding Duree}" Width="70"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </DockPanel>
                    </TabItem>
                    <TabItem Header="Détail par paquet">
                        <DataGrid x:Name="GridResults" AutoGenerateColumns="False" Margin="0,8,0,0" RowStyle="{StaticResource ResRow}">
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="Poste" Binding="{Binding Ordinateur}" Width="130"/>
                                <DataGridTextColumn Header="Paquet" Binding="{Binding Paquet}" Width="160"/>
                                <DataGridTextColumn Header="Statut" Binding="{Binding Statut}" Width="80"/>
                                <DataGridTextColumn Header="Message" Binding="{Binding Message}" Width="*"/>
                                <DataGridTextColumn Header="Heure" Binding="{Binding Horodatage, StringFormat=HH:mm:ss}" Width="70"/>
                            </DataGrid.Columns>
                        </DataGrid>
                    </TabItem>
                    <TabItem Header="Journal">
                        <TextBox x:Name="LogBox" IsReadOnly="True" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="11" Margin="0,8,0,0"/>
                    </TabItem>
                </TabControl>
            </DockPanel>
        </Border>
    </Grid>
</Window>
"@

# Taille de départ limitée à la zone utile de l'écran (portables, mise à l'échelle 125-150 %).
$workArea = [System.Windows.SystemParameters]::WorkArea
$Window.Width  = [Math]::Min($Window.Width,  $workArea.Width  - 12)
$Window.Height = [Math]::Min($Window.Height, $workArea.Height - 12)

$ctrl = @{}
foreach ($name in 'BtnSettings', 'BtnAbout', 'BtnCred', 'LblCred', 'RbInstall', 'RbUninstall',
                  'TxtSearchPc', 'BtnSearchPc', 'BtnLoadOu', 'CmbOu', 'LblPcFound', 'BtnAddPc', 'BtnAddAllPc', 'LstPcAll',
                  'BtnRefreshCatalogue', 'BtnAddApp', 'BtnRemoveFromCatalogue', 'TxtSearchPkg', 'LblSearchPkgHint',
                  'BtnAddPkg', 'LstCatalogue', 'BtnClearPc', 'BtnRemovePc', 'LblPcCount', 'LstPcSelected',
                  'BtnClearPkg', 'BtnRemovePkg', 'LblPkgCount', 'LstPkgSelected', 'BtnExport', 'BtnDeploy', 'BtnStop',
                  'BtnRetry', 'LblStatus', 'Progress', 'LblCntTotal', 'LblCntRun', 'LblCntOk', 'LblCntFail',
                  'CmbFilter', 'TxtHostFilter', 'BtnCopyDetail', 'TxtHostDetail', 'GridHosts', 'GridResults', 'LogBox') {
    $ctrl[$name] = $Window.FindName($name)
    if (-not $ctrl[$name]) { throw "Contrôle XAML introuvable : $name" }
}
$ctrl.CmbOu.DisplayMemberPath = 'Name'
$Script:LogBox = $ctrl.LogBox
$Script:Credential = $null

$Script:PackagesSelected = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ctrl.LstPkgSelected.ItemsSource = $Script:PackagesSelected
$Script:PackagesSelected.add_CollectionChanged({ Update-Counter })

$Script:ResultsCollection = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$ctrl.GridResults.ItemsSource = $Script:ResultsCollection

$Script:HostRows = New-Object System.Collections.ObjectModel.ObservableCollection[WinPloyHostRow]
$ctrl.GridHosts.ItemsSource = $Script:HostRows
$Script:HostFilterMode = 0
$Script:HostFilterText = ''
$Script:PkgFilterText  = ''

function Update-Counter {
    $ctrl.LblPcCount.Text  = "3 · Postes ciblés ($($ctrl.LstPcSelected.Items.Count))"
    $ctrl.LblPkgCount.Text = "Panier ($($Script:PackagesSelected.Count))"
}

function Update-Summary {
    $rows  = @($Script:HostRows)
    $total = $rows.Count
    $run   = @($rows | Where-Object { $_.Etat -in 'EN COURS', 'EN ATTENTE' }).Count
    $ok    = @($rows | Where-Object { $_.Etat -eq 'OK' }).Count
    $ko    = @($rows | Where-Object { $_.Etat -in 'ECHEC', 'ARRÊTÉ' }).Count
    $ctrl.LblCntTotal.Text = "$total poste(s)"
    $ctrl.LblCntRun.Text   = "● $run en cours"
    $ctrl.LblCntOk.Text    = "✔ $ok réussi(s)"
    $ctrl.LblCntFail.Text  = "✖ $ko échec(s)"
    $ctrl.Progress.Value   = if ($total) { [int](100 * ($total - $run) / $total) } else { 0 }
    $ctrl.Progress.Foreground = if ($ko) { [System.Windows.Media.Brushes]::OrangeRed } else { [System.Windows.Media.Brushes]::ForestGreen }
    $ctrl.BtnRetry.IsEnabled  = ($ko -gt 0 -and -not $Script:RunContext)
    $ctrl.BtnExport.IsEnabled = ($Script:ResultsCollection.Count -gt 0)
}

function Show-HostDetail {
    $row = $ctrl.GridHosts.SelectedItem
    if (-not $row) { $ctrl.TxtHostDetail.Text = 'Sélectionne un poste pour voir le détail complet.'; return }
    $head = "$($row.Poste) — $($row.Etat)" + $(if ($row.Duree) { " ($($row.Duree))" } else { '' })
    $res = @($Script:ResultsCollection | Where-Object { $_.Ordinateur -eq $row.Poste })
    if (-not $res.Count) { $ctrl.TxtHostDetail.Text = "$head`r`n$($row.Info)"; return }
    $ctrl.TxtHostDetail.Text = $head + "`r`n" + (($res | ForEach-Object { "[$($_.Statut)] $($_.Paquet) : $($_.Message)" }) -join "`r`n")
}

function Set-HostFilter {
    $Script:HostFilterMode = [int]$ctrl.CmbFilter.SelectedIndex
    $Script:HostFilterText = $ctrl.TxtHostFilter.Text.Trim()
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($Script:HostRows)
    $view.Filter = [System.Predicate[object]]{
        param($r)
        if ($Script:HostFilterText -and ($r.Poste -notlike "*$($Script:HostFilterText)*")) { return $false }
        switch ($Script:HostFilterMode) {
            1       { return ($r.Etat -in 'EN COURS', 'EN ATTENTE') }
            2       { return ($r.Etat -in 'ECHEC', 'ARRÊTÉ') }
            3       { return ($r.Etat -eq 'OK') }
            default { return $true }
        }
    }
    $view.Refresh()
}

function Set-PkgFilter {
    $Script:PkgFilterText = $ctrl.TxtSearchPkg.Text.Trim()
    $ctrl.LblSearchPkgHint.Visibility = if ($ctrl.TxtSearchPkg.Text) { 'Collapsed' } else { 'Visible' }
    $view = $ctrl.LstCatalogue.Items
    $view.Filter = [System.Predicate[object]]{
        param($i)
        $t = $Script:PkgFilterText
        (-not $t) -or
        ([string]$i.Name).IndexOf($t, [StringComparison]::CurrentCultureIgnoreCase) -ge 0 -or
        ([string]$i.Id).IndexOf($t, [StringComparison]::CurrentCultureIgnoreCase) -ge 0
    }
    $view.Refresh()
}

function Update-CatalogueView {
    param([object[]]$Catalogue)
    $Script:Catalogue = @($Catalogue | Where-Object { $_ })
    $ctrl.LstCatalogue.ItemsSource = $Script:Catalogue
    $ctrl.LstCatalogue.Items.SortDescriptions.Clear()
    $ctrl.LstCatalogue.Items.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription 'Name', 'Ascending'))
    Set-PkgFilter
    for ($i = $Script:PackagesSelected.Count - 1; $i -ge 0; $i--) {
        $id = $Script:PackagesSelected[$i].Id
        $match = $Script:Catalogue | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if ($match) { $Script:PackagesSelected[$i] = $match } else { $Script:PackagesSelected.RemoveAt($i) }
    }
}

# Applique une modification du catalogue ; en cas d'erreur, recharge l'état réel du fichier.
function Invoke-CatalogueChange {
    param([scriptblock]$Change)
    try {
        Update-CatalogueView (& $Change)
    } catch {
        Write-DeployLog $_.Exception.Message 'ERREUR'
        Show-Message $_.Exception.Message 'Catalogue' 'Error' | Out-Null
        Update-CatalogueView (Import-Catalogue)
    }
}

# ---------- Dialogues ----------
function Show-ResultDetailsDialog {
    param($Result)
    $dlg = New-XamlWindow @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Détail du résultat" Width="650" Height="390" MinWidth="500" MinHeight="300"
        WindowStartupLocation="CenterOwner">
    <DockPanel Margin="12">
        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
            <Button x:Name="BtnCopy" Content="Copier" Width="80" Margin="0,0,8,0"/>
            <Button x:Name="BtnClose" Content="Fermer" Width="80" IsDefault="True" IsCancel="True"/>
        </StackPanel>
        <TextBox x:Name="TxtDetails" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                 FontFamily="Consolas" FontSize="12"/>
    </DockPanel>
</Window>
"@
    $dlg.Owner = $Window
    $details = @(
        "Ordinateur  : $($Result.Ordinateur)"
        "Paquet      : $($Result.Paquet)"
        "Identifiant : $($Result.Id)"
        "Statut      : $($Result.Statut)"
        "Date/heure  : $($Result.Horodatage)"
        ''
        'Message :'
        [string]$Result.Message
    ) -join "`r`n"
    $dlg.FindName('TxtDetails').Text = $details
    $dlg.FindName('BtnCopy').Add_Click({ try { [System.Windows.Clipboard]::SetText($details) } catch { Write-DeployLog "Copie impossible : $($_.Exception.Message)" 'ATTENTION' } })
    $dlg.FindName('BtnClose').Add_Click({ $dlg.Close() })
    [void]$dlg.ShowDialog()
}

function Show-SettingsDialog {
    $dlg = New-XamlWindow @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Réglages WinPloy" Width="650" Height="270" WindowStartupLocation="CenterOwner" ResizeMode="NoResize">
    <Grid Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/><RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions><ColumnDefinition Width="180"/><ColumnDefinition Width="*"/><ColumnDefinition Width="95"/></Grid.ColumnDefinitions>
        <TextBlock Grid.Row="0" Text="Catalogue JSON" VerticalAlignment="Center" Margin="0,0,8,10" FontWeight="SemiBold"/>
        <TextBox x:Name="TxtCataloguePath" Grid.Row="0" Grid.Column="1" Margin="0,0,8,10" VerticalContentAlignment="Center"/>
        <Button x:Name="BtnBrowse" Grid.Row="0" Grid.Column="2" Content="Parcourir..." Margin="0,0,0,10"/>
        <TextBlock Grid.Row="1" Text="Délai par paquet (min)" VerticalAlignment="Center" Margin="0,0,8,10" FontWeight="SemiBold"/>
        <TextBox x:Name="TxtTimeout" Grid.Row="1" Grid.Column="1" Width="90" HorizontalAlignment="Left" Margin="0,0,8,10"/>
        <TextBlock Grid.Row="2" Text="Postes en parallèle" VerticalAlignment="Center" Margin="0,0,8,10" FontWeight="SemiBold"/>
        <TextBox x:Name="TxtParallel" Grid.Row="2" Grid.Column="1" Width="90" HorizontalAlignment="Left" Margin="0,0,8,10"/>
        <TextBlock Grid.Row="3" Grid.ColumnSpan="3" Foreground="Gray" TextWrapping="Wrap" Margin="0,4,0,10"
                   Text="Réglages enregistrés dans ProgramData\WinPloy\config.json. Délai : 1 à 240 min. Parallélisme : 1 à 50."/>
        <StackPanel Grid.Row="4" Grid.ColumnSpan="3" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnCancel" Content="Annuler" Width="90" Margin="0,0,8,0" IsCancel="True"/>
            <Button x:Name="BtnSave" Content="Enregistrer" Width="100" IsDefault="True"/>
        </StackPanel>
    </Grid>
</Window>
"@
    $dlg.Owner = $Window
    $txtPath     = $dlg.FindName('TxtCataloguePath')
    $txtTimeout  = $dlg.FindName('TxtTimeout')
    $txtParallel = $dlg.FindName('TxtParallel')
    $txtPath.Text     = $Script:Config.CataloguePath
    $txtTimeout.Text  = [string]$Script:Config.PackageTimeoutMin
    $txtParallel.Text = [string]$Script:Config.MaxParallel

    $dlg.FindName('BtnBrowse').Add_Click({
        $fd = New-Object Microsoft.Win32.OpenFileDialog
        $fd.Filter = 'Catalogue JSON (*.json)|*.json|Tous les fichiers (*.*)|*.*'
        $fd.CheckFileExists = $false
        if ($fd.ShowDialog()) { $txtPath.Text = $fd.FileName }
    })
    $dlg.FindName('BtnSave').Add_Click({
        $path = $txtPath.Text.Trim()
        $timeout  = Get-ClampedInt $txtTimeout.Text.Trim() 1 240 -1
        $parallel = Get-ClampedInt $txtParallel.Text.Trim() 1 50 -1
        if (-not $path)          { Show-Message 'Le chemin du catalogue est obligatoire.' 'Réglages' 'Warning' | Out-Null; return }
        if ($timeout -lt 0)      { Show-Message 'Le délai doit être compris entre 1 et 240 minutes.' 'Réglages' 'Warning' | Out-Null; return }
        if ($parallel -lt 0)     { Show-Message 'Le parallélisme doit être compris entre 1 et 50.' 'Réglages' 'Warning' | Out-Null; return }
        $Script:Config.CataloguePath     = $path
        $Script:Config.PackageTimeoutMin = $timeout
        $Script:Config.MaxParallel       = $parallel
        if (-not (Save-WinPloyConfig)) { return }
        Write-DeployLog "Réglages enregistrés. Catalogue : $path"
        Update-CatalogueView (Import-Catalogue)
        $dlg.Close()
    })
    [void]$dlg.ShowDialog()
}

function Show-WingetPackageDialog {
    param($Existing)
    $dlg = New-XamlWindow @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Application WinGet" Height="250" Width="460" WindowStartupLocation="CenterOwner" ResizeMode="NoResize">
    <StackPanel Margin="12">
        <TextBlock Text="Nom affiché :"/>
        <TextBox x:Name="TxtName" Margin="0,2,0,8"/>
        <TextBlock Text="Identifiant WinGet (ex. Git.Git) :"/>
        <TextBox x:Name="TxtId" Margin="0,2,0,8"/>
        <TextBlock Foreground="Gray" TextWrapping="Wrap" Margin="0,0,0,12"
                   Text="Trouver l'identifiant : winget search &lt;nom&gt; (colonne Id)."/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnOk" Content="Enregistrer" Width="90" Margin="0,0,8,0" IsDefault="True"/>
            <Button x:Name="BtnCancel" Content="Annuler" Width="80" IsCancel="True"/>
        </StackPanel>
    </StackPanel>
</Window>
"@
    $dlg.Owner = $Window
    $dlg.Title = if ($Existing) { 'Modifier l''application WinGet' } else { 'Ajouter une application WinGet' }
    $txtName = $dlg.FindName('TxtName')
    $txtId   = $dlg.FindName('TxtId')
    if ($Existing) { $txtName.Text = $Existing.Name; $txtId.Text = $Existing.Id }

    $Script:DialogResult = $null
    $dlg.FindName('BtnOk').Add_Click({
        $name = $txtName.Text.Trim()
        $id   = $txtId.Text.Trim()
        if (-not $name -or -not $id) { Show-Message 'Nom et identifiant requis.' 'Erreur' 'Warning' | Out-Null; return }
        if ($id -notmatch $Script:WingetIdPattern) { Show-Message "Identifiant WinGet invalide : $id" 'Erreur' 'Warning' | Out-Null; return }
        $Script:DialogResult = ConvertTo-CatalogueEntry ([pscustomobject]@{ Id = $id; Name = $name })
        $dlg.Close()
    })
    [void]$dlg.ShowDialog()
    return $Script:DialogResult
}

function Test-ScriptPathInput {
    param([string]$Path, [string]$Label)
    if ($Path -notlike '\\*') { return "$Label : chemin UNC requis (\\serveur\partage\...), accessible à tous les administrateurs." }
    if ([IO.Path]::GetExtension($Path).ToLowerInvariant() -notin $Script:ScriptExtensions) { return "$Label : extension non supportée (ps1, bat, cmd, exe)." }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "$Label : fichier introuvable ($Path)." }
    if ((Split-Path $Path -Parent).TrimEnd('\') -eq (Get-DepotRoot).TrimEnd('\')) { return "$Label : placer le script dans un sous-dossier dédié (le dossier entier est copié sur le poste)." }
    return $null
}

function Show-CustomPackageDialog {
    param($Existing)
    $dlg = New-XamlWindow @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Paquet personnalisé" Height="380" Width="600" WindowStartupLocation="CenterOwner" ResizeMode="NoResize">
    <StackPanel Margin="12">
        <TextBlock Text="Nom du paquet :"/>
        <TextBox x:Name="TxtName" Margin="0,2,0,8"/>
        <TextBlock Text="Script d'installation (chemin UNC) :"/>
        <DockPanel Margin="0,2,0,8">
            <Button x:Name="BtnBrowseInstall" DockPanel.Dock="Right" Content="Parcourir..." Width="90" Margin="6,0,0,0"/>
            <TextBox x:Name="TxtInstall"/>
        </DockPanel>
        <TextBlock Text="Script de désinstallation (chemin UNC, optionnel) :"/>
        <DockPanel Margin="0,2,0,8">
            <Button x:Name="BtnBrowseUninstall" DockPanel.Dock="Right" Content="Parcourir..." Width="90" Margin="6,0,0,0"/>
            <TextBox x:Name="TxtUninstall"/>
        </DockPanel>
        <CheckBox x:Name="ChkRunAsSystem" Content="Exécuter en NT AUTHORITY\SYSTEM (tâche planifiée temporaire)" Margin="0,0,0,8"/>
        <TextBlock TextWrapping="Wrap" FontStyle="Italic" Foreground="Gray" Margin="0,4,0,12"
                   Text="Le dossier du script est copié sur le poste puis supprimé après exécution. Sans SYSTEM, le script s'exécute avec le compte de la session WinRM, pas avec l'utilisateur connecté au poste. Types : ps1, bat, cmd, exe. Codes de succès : 0 et 3010."/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnOk" Content="Enregistrer" Width="90" Margin="0,0,8,0" IsDefault="True"/>
            <Button x:Name="BtnCancel" Content="Annuler" Width="80" IsCancel="True"/>
        </StackPanel>
    </StackPanel>
</Window>
"@
    $dlg.Owner = $Window
    $txtName      = $dlg.FindName('TxtName')
    $txtInstall   = $dlg.FindName('TxtInstall')
    $txtUninstall = $dlg.FindName('TxtUninstall')
    $chkSystem    = $dlg.FindName('ChkRunAsSystem')

    if ($Existing) {
        $dlg.Title         = 'Modifier le paquet personnalisé'
        $txtName.Text      = $Existing.Name
        $txtInstall.Text   = $Existing.InstallScript
        $txtUninstall.Text = $Existing.UninstallScript
        $chkSystem.IsChecked = ($Existing.RunAs -eq 'System')
    } else {
        $dlg.Title = 'Créer un paquet personnalisé'
    }

    $browse = {
        param($target)
        $ofd = New-Object Microsoft.Win32.OpenFileDialog
        $ofd.Filter = 'Scripts / exécutables (*.ps1;*.bat;*.cmd;*.exe)|*.ps1;*.bat;*.cmd;*.exe'
        $ofd.InitialDirectory = Get-DepotRoot
        if ($ofd.ShowDialog()) { $target.Text = $ofd.FileName }
    }
    $dlg.FindName('BtnBrowseInstall').Add_Click({ & $browse $txtInstall })
    $dlg.FindName('BtnBrowseUninstall').Add_Click({ & $browse $txtUninstall })

    $Script:DialogResult = $null
    $dlg.FindName('BtnOk').Add_Click({
        $name = $txtName.Text.Trim()
        $inst = $txtInstall.Text.Trim()
        $unin = $txtUninstall.Text.Trim()
        $err = $null
        if (-not $name)     { $err = 'Nom du paquet requis.' }
        elseif (-not $inst) { $err = "Script d'installation requis." }
        else {
            $err = Test-ScriptPathInput $inst "Script d'installation"
            if (-not $err -and $unin) { $err = Test-ScriptPathInput $unin 'Script de désinstallation' }
        }
        if ($err) { Show-Message $err 'Erreur' 'Warning' | Out-Null; return }

        $id = if ($Existing) { $Existing.Id } else { 'custom:' + (($name -replace '[^\w\.-]+', '_').Trim('_')) }
        $Script:DialogResult = ConvertTo-CatalogueEntry ([pscustomobject]@{
            Id = $id; Name = $name; InstallScript = $inst; UninstallScript = $unin
            RunAs = $(if ($chkSystem.IsChecked) { 'System' } else { 'User' })
        })
        $dlg.Close()
    })
    [void]$dlg.ShowDialog()
    return $Script:DialogResult
}

# ---------- Événements ----------
$ctrl.BtnSettings.Add_Click({ Show-SettingsDialog })

$ctrl.BtnAbout.Add_Click({
    Show-Message "WinPloy $($Script:Version)`r`n`r`nDéploiement d'applications WinGet et de paquets personnalisés sur des postes Active Directory.`r`n`r`nAuteur : Constant Segretain" 'À propos de WinPloy' | Out-Null
})

$ctrl.BtnCred.Add_Click({
    $cred = Get-Credential -Message 'Identifiants WinRM (Annuler = contexte courant)'
    $Script:Credential = $cred
    $ctrl.LblCred.Text = if ($cred) { "Utilisateur : $($cred.UserName)" } else { 'Contexte courant' }
})

$ctrl.BtnLoadOu.Add_Click({
    try {
        $ous = @(Get-ADOuTree)
        $ctrl.CmbOu.Items.Clear()
        [void]$ctrl.CmbOu.Items.Add([pscustomobject]@{ Name = '(Toutes les OUs)'; DN = $null })
        foreach ($ou in $ous) { [void]$ctrl.CmbOu.Items.Add([pscustomobject]@{ Name = $ou.DistinguishedName; DN = $ou.DistinguishedName }) }
        $ctrl.CmbOu.SelectedIndex = 0
        Write-DeployLog "OUs chargées ($($ous.Count))."
    } catch { Write-DeployLog $_.Exception.Message 'ERREUR' }
})

$searchPc = {
    try {
        $ouDn = if ($ctrl.CmbOu.SelectedItem) { $ctrl.CmbOu.SelectedItem.DN } else { $null }
        $computers = @(Get-ADComputersFiltered -SearchText $ctrl.TxtSearchPc.Text -OuDN $ouDn)
        $ctrl.LstPcAll.ItemsSource = @($computers | ForEach-Object { $_.Name })
        $ctrl.LblPcFound.Text = "$($computers.Count) poste(s) trouvé(s)."
        Write-DeployLog "Recherche AD : $($computers.Count) poste(s)."
    } catch { Write-DeployLog $_.Exception.Message 'ERREUR' }
}
$ctrl.BtnSearchPc.Add_Click($searchPc)
$ctrl.TxtSearchPc.Add_KeyDown({ if ($_.Key -eq 'Return') { & $searchPc } })

function Add-PcToTarget {
    param([object[]]$Names)
    $existing = @($ctrl.LstPcSelected.Items)
    foreach ($n in $Names) {
        if ($existing -notcontains $n) { [void]$ctrl.LstPcSelected.Items.Add($n); $existing += $n }
    }
    Update-Counter
}
$ctrl.BtnAddPc.Add_Click({ Add-PcToTarget @($ctrl.LstPcAll.SelectedItems) })
$ctrl.BtnAddAllPc.Add_Click({ Add-PcToTarget @($ctrl.LstPcAll.Items) })
$ctrl.LstPcAll.Add_MouseDoubleClick({ if ($ctrl.LstPcAll.SelectedItem) { Add-PcToTarget @($ctrl.LstPcAll.SelectedItem) } })
$ctrl.BtnRemovePc.Add_Click({
    foreach ($pc in @($ctrl.LstPcSelected.SelectedItems)) { $ctrl.LstPcSelected.Items.Remove($pc) }
    Update-Counter
})
$ctrl.BtnClearPc.Add_Click({ $ctrl.LstPcSelected.Items.Clear(); Update-Counter })

$ctrl.BtnRefreshCatalogue.Add_Click({ Update-CatalogueView (Import-Catalogue) })

$ctrl.BtnAddApp.Add_Click({
    $menu = New-Object System.Windows.Controls.ContextMenu
    $miWinget = New-Object System.Windows.Controls.MenuItem -Property @{ Header = 'Application WinGet' }
    $miCustom = New-Object System.Windows.Controls.MenuItem -Property @{ Header = 'Paquet personnalisé' }
    $miWinget.Add_Click({
        $entry = Show-WingetPackageDialog
        if ($entry) { Invoke-CatalogueChange { Add-CatalogueEntry -Entry $entry } }
    })
    $miCustom.Add_Click({
        $entry = Show-CustomPackageDialog
        if ($entry) { Invoke-CatalogueChange { Add-CatalogueEntry -Entry $entry } }
    })
    [void]$menu.Items.Add($miWinget)
    [void]$menu.Items.Add($miCustom)
    $menu.PlacementTarget = $ctrl.BtnAddApp
    $menu.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
    $menu.IsOpen = $true
})

$ctrl.LstCatalogue.Add_MouseDoubleClick({
    $item = $ctrl.LstCatalogue.SelectedItem
    if (-not $item) { return }
    $oldId = $item.Id
    $entry = if ($item.Type -eq 'Custom') { Show-CustomPackageDialog -Existing $item } else { Show-WingetPackageDialog -Existing $item }
    if ($entry) { Invoke-CatalogueChange { Update-CatalogueEntry -OldId $oldId -Entry $entry } }
})

$ctrl.BtnRemoveFromCatalogue.Add_Click({
    $sel = @($ctrl.LstCatalogue.SelectedItems)
    if (-not $sel.Count) { return }
    $ids  = @($sel | ForEach-Object { $_.Id })
    $list = ($sel | ForEach-Object { "- $($_.Name)" }) -join "`r`n"
    $answer = Show-Message "Supprimer $($ids.Count) paquet(s) du catalogue ?`r`n`r`n$list`r`n`r`nLes scripts sur le partage ne sont pas supprimés." 'Confirmation' 'Warning' 'YesNo'
    if ($answer -eq 'Yes') { Invoke-CatalogueChange { Remove-CatalogueEntry -Ids $ids } }
})

$ctrl.BtnAddPkg.Add_Click({
    foreach ($item in @($ctrl.LstCatalogue.SelectedItems)) {
        if (-not ($Script:PackagesSelected | Where-Object { $_.Id -eq $item.Id })) { $Script:PackagesSelected.Add($item) }
    }
})
$ctrl.BtnRemovePkg.Add_Click({ foreach ($item in @($ctrl.LstPkgSelected.SelectedItems)) { [void]$Script:PackagesSelected.Remove($item) } })
$ctrl.BtnClearPkg.Add_Click({ $Script:PackagesSelected.Clear() })
$ctrl.TxtSearchPkg.Add_TextChanged({ Set-PkgFilter })
$ctrl.TxtSearchPkg.Add_KeyDown({ if ($_.Key -eq 'Escape') { $ctrl.TxtSearchPkg.Clear(); $_.Handled = $true } })

$ctrl.GridResults.Add_MouseDoubleClick({
    if ($ctrl.GridResults.SelectedItem) { Show-ResultDetailsDialog $ctrl.GridResults.SelectedItem }
})

$ctrl.BtnDeploy.Add_Click({
    $targets  = @($ctrl.LstPcSelected.Items | ForEach-Object { [string]$_ })
    $packages = @($Script:PackagesSelected)
    if (-not $targets.Count)  { Write-DeployLog 'Aucun poste sélectionné.' 'ERREUR'; return }
    if (-not $packages.Count) { Write-DeployLog 'Panier vide.' 'ERREUR'; return }

    $action = if ($ctrl.RbUninstall.IsChecked) { 'Uninstall' } else { 'Install' }
    if ($action -eq 'Uninstall' -or $targets.Count -gt 5) {
        $verb  = if ($action -eq 'Install') { 'Installer' } else { 'Désinstaller' }
        $names = ($packages | ForEach-Object { $_.Name }) -join ', '
        $answer = Show-Message "$verb $($packages.Count) application(s) ($names) sur $($targets.Count) poste(s) ?" "Confirmer l'opération" 'Question' 'YesNo'
        if ($answer -ne 'Yes') { return }
    }
    Start-Deployment -Targets $targets -Packages $packages -Action $action
})

$ctrl.BtnRetry.Add_Click({
    if (-not $Script:LastRun -or $Script:RunContext) { return }
    $failed = @($Script:HostRows | Where-Object { $_.Etat -in 'ECHEC', 'ARRÊTÉ' } | ForEach-Object { $_.Poste })
    if ($failed.Count) { Start-Deployment -Targets $failed -Packages $Script:LastRun.Packages -Action $Script:LastRun.Action -Retry }
})

$ctrl.GridHosts.Add_SelectionChanged({ Show-HostDetail })
$ctrl.CmbFilter.Add_SelectionChanged({ Set-HostFilter })
$ctrl.TxtHostFilter.Add_TextChanged({ Set-HostFilter })
$ctrl.BtnCopyDetail.Add_Click({
    try { [System.Windows.Clipboard]::SetText($ctrl.TxtHostDetail.Text) } catch { Write-DeployLog "Copie impossible : $($_.Exception.Message)" 'ATTENTION' }
})

$ctrl.BtnExport.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    $dlg.FileName = "WinPloy-resultats-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
    if (-not $dlg.ShowDialog()) { return }
    try {
        $Script:ResultsCollection | Select-Object Ordinateur, Paquet, Id, Statut, Message, Horodatage |
            Export-Csv -Path $dlg.FileName -NoTypeInformation -Delimiter ';' -Encoding UTF8
        Write-DeployLog "Résultats exportés : $($dlg.FileName)"
    } catch {
        Write-DeployLog "Export impossible : $($_.Exception.Message)" 'ERREUR'
    }
})

$ctrl.BtnStop.Add_Click({
    if (-not $Script:RunContext) { return }
    $answer = Show-Message "Arrêter les opérations en cours ?`r`n`r`nUne installation déjà lancée sur un poste peut continuer et doit être vérifiée sur ce poste." 'Arrêter' 'Warning' 'YesNo'
    if ($answer -ne 'Yes') { return }
    $Script:StopRequested = $true
    $ctrl.BtnStop.IsEnabled = $false
    $ctrl.LblStatus.Text = 'Arrêt en cours…'
    Write-DeployLog "=== Arrêt demandé par l'utilisateur. ==="
})

$Script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$Script:Timer.Interval = [TimeSpan]::FromMilliseconds(500)
$Script:Timer.Add_Tick({
    try { Invoke-SchedulerTick } catch { Write-DeployLog "Erreur interne du suivi : $($_.Exception.Message)" 'ERREUR' }
})

$Window.Add_Closing({
    if ($Script:RunContext) {
        $answer = Show-Message "Des opérations sont en cours. Fermer WinPloy les arrête.`r`n`r`nFermer quand même ?" 'Fermer' 'Warning' 'YesNo'
        if ($answer -ne 'Yes') { $_.Cancel = $true }
    }
})
$Window.Add_Closed({
    $Script:Timer.Stop()
    foreach ($info in @($Script:ActiveJobs)) {
        Stop-Job -Job $info.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $info.Job -Force -ErrorAction SilentlyContinue
    }
})

# ---------- Démarrage ----------
Write-DeployLog "WinPloy $($Script:Version) démarré."
Update-CatalogueView (Import-Catalogue)
Set-HostFilter
Update-Counter
Update-Summary
$Script:Timer.Start()
[void]$Window.ShowDialog()