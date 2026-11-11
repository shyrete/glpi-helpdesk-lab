#Requires -RunAsAdministrator
# =====================================================================================
#  Deploy-GLPILab.ps1  -  GLPI helpdesk lab (Hyper-V)
#  DC1      : Windows Server 2025  - AD DS, DNS, DHCP, file share "Compta" (labo.lan)
#  GLPI01   : Ubuntu Server 24.04  - VM created here, Ubuntu installed by hand,
#                                    then run glpi01-setup.sh inside it
#  CLIENT1  : Windows 11 (optional) - only if C:\VMs\base\BASEW11_26H1_GEN2.vhdx exists
#  Lab only: passwords are in clear text on purpose. Never reuse them outside the lab.
# =====================================================================================

Write-Host " ----------------------------------------- VARIABLES ----------------------------------"

$tenantname   = "labo"
$tenantdomain = "labo.lan"
$tenantDN     = "DC=labo,DC=lan"
$secpasswd = ConvertTo-SecureString 'Pa$$w0rd' -AsPlainText -Force
$cred   = New-Object System.Management.Automation.PSCredential ("Administrator", $secpasswd)
$adcred = New-Object System.Management.Automation.PSCredential ("Administrator@$tenantdomain", $secpasswd)
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$transcriptPath = "C:\VMs\Logs\" + $tenantname + "_GLPI_" + $timestamp + ".log"

Write-Host " --- Paths -----------------------------"
$vmPath           = "C:\VMs"
$baseServerPath   = "C:\VMs\base\BASESRV2025.vhdx"  # sysprepped Windows Server 2025 (check the extension: .vhdx)
$baseClientPath   = "C:\VMs\base\BASEW11_26H1_GEN2.vhdx"  # sysprepped Windows 11 Gen2 - optional
# Finds the Ubuntu Server 24.04 ISO in C:\VMs\Iso, whatever the point version (24.04.x)
$ubuntuIsoPath    = (Get-ChildItem -Path "C:\VMs\Iso" -Filter "ubuntu-24.04*server*.iso" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName

Write-Host " --- Network (host NAT so GLPI can download Docker images) -----------------------------"
$switchName    = "My_NAT_Switch"
$natName       = "My_NAT"
$natPrefix     = "192.168.100.0/24"
$gateway       = "192.168.100.1"        # IP of the host on the switch = gateway of the lab
$prefixLength  = 24
$dc1IP         = "192.168.100.10"
$glpiIP        = "192.168.100.30"

Write-Host " --- DHCP (for CLIENT1 and for the Ubuntu installer) -----------------------------"
$dhcpScopeId          = "192.168.100.0"
$dhcpScopeStartRange  = "192.168.100.100"
$dhcpScopeEndRange    = "192.168.100.200"
$dhcpSubnetMask       = "255.255.255.0"

Write-Host " --- Windows 11 client (optional) -----------------------------"
# Local admin account that exists in your Windows 11 base image (often NOT "Administrator" on Win11)
$clientCred = New-Object System.Management.Automation.PSCredential ("Administrator", $secpasswd)

Write-Host " --- Lab content for the GLPI tickets -----------------------------"
$labUsers = @("jdupont", "mmartin", "lpeeters", "sjanssens", "adurand")

New-Item -Path "C:\VMs\Logs" -ItemType Directory -Force | Out-Null
Start-Transcript -Path $transcriptPath -Append
Write-Host "=== Script started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="


Write-Host " ----------------------------------------- Helper functions ----------------------------------"

# Waits until the VM answers through PowerShell Direct (replaces most fixed Start-Sleep)
function WaitFor-VM {
    param($VMName, $Credential, $TimeoutSeconds = 600)
    Write-Host " ------- Waiting for $VMName to answer ---------"
    $elapsed = 0
    $ok = $false
    do {
        Start-Sleep -Seconds 10
        $elapsed += 10
        try {
            Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock { $true } -ErrorAction Stop | Out-Null
            $ok = $true
        } catch { }
    } until ($ok -or $elapsed -ge $TimeoutSeconds)
    if ($ok) { Write-Host " ------- $VMName is ready ($elapsed s) ---------" }
    else     { Write-Host " ------- WARNING: $VMName did not answer after $TimeoutSeconds s ---------" }
}

# Waits until Active Directory really answers on DC1 (the VM can answer before AD is up)
function WaitFor-AD {
    param($VMName, $Credential, $TimeoutSeconds = 900)
    Write-Host " ------- Waiting for Active Directory on $VMName ---------"
    $elapsed = 0
    $ok = $false
    do {
        Start-Sleep -Seconds 15
        $elapsed += 15
        try {
            Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock { Get-ADDomain | Out-Null } -ErrorAction Stop
            $ok = $true
        } catch { }
    } until ($ok -or $elapsed -ge $TimeoutSeconds)
    if ($ok) { Write-Host " ------- Active Directory is ready ($elapsed s) ---------" }
    else     { Write-Host " ------- WARNING: Active Directory not ready after $TimeoutSeconds s ---------" }
}


Write-Host " ----------------------------------------- Pre-checks ----------------------------------"

if (-not (Test-Path $baseServerPath)) { Write-Host " ------- ERROR: $baseServerPath not found. Stopping. ---------"; Stop-Transcript; return }
if (-not $ubuntuIsoPath)             { Write-Host " ------- ERROR: no ubuntu-24.04*server*.iso in C:\VMs\Iso. Download Ubuntu Server 24.04 first. Stopping. ---------"; Stop-Transcript; return }
Write-Host " ------- Ubuntu ISO found: $ubuntuIsoPath ---------"
$deployClient = Test-Path $baseClientPath
if (-not $deployClient) { Write-Host " ------- INFO: no Windows 11 base image, CLIENT1 will be skipped ---------" }
foreach ($vm in @("DC1", "GLPI01", "CLIENT1")) {
    if (Get-VM -Name $vm -ErrorAction SilentlyContinue) { Write-Host " ------- ERROR: a VM named $vm already exists. Delete it first. Stopping. ---------"; Stop-Transcript; return }
}


Write-Host " ----------------------------------------- Host network: switch + NAT ----------------------------------"

if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
    Write-Host " ------- Creating internal switch $switchName ---------"
    New-VMSwitch -Name $switchName -SwitchType Internal
} else {
    Write-Host " ------- Switch $switchName already exists, keeping it ---------"
}

if (-not (Get-NetIPAddress -IPAddress $gateway -ErrorAction SilentlyContinue)) {
    Write-Host " ------- Giving the host the gateway IP $gateway ---------"
    New-NetIPAddress -IPAddress $gateway -PrefixLength $prefixLength -InterfaceAlias "vEthernet ($switchName)"
}

$existingNat = Get-NetNat -ErrorAction SilentlyContinue
if ($existingNat | Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $natPrefix }) {
    Write-Host " ------- NAT for $natPrefix already exists, keeping it ---------"
} elseif ($existingNat) {
    Write-Host " ------- WARNING: another NAT already exists ($($existingNat.InternalIPInterfaceAddressPrefix)). Windows supports only one. ---------"
    Write-Host " ------- Remove it with Remove-NetNat or change the lab subnet, then run again. Stopping. ---------"
    Stop-Transcript; return
} else {
    Write-Host " ------- Creating NAT $natName for $natPrefix ---------"
    New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix $natPrefix
}


Write-Host " ----------------------------------------- Creating DISKS ----------------------------------"

New-VHD -Path "$vmPath\DC1.vhdx" -ParentPath $baseServerPath -Differencing
New-VHD -Path "$vmPath\GLPI01.vhdx" -SizeBytes 30GB -Dynamic
if ($deployClient) { New-VHD -Path "$vmPath\CLIENT1.vhdx" -ParentPath $baseClientPath -Differencing }


Write-Host " ----------------------------------------- Creating VMS ----------------------------------"

Write-Host " ------- Creating DC1 ---------"
New-VM -Name "DC1" -MemoryStartupBytes 2GB -Generation 2 -VHDPath "$vmPath\DC1.vhdx" -SwitchName $switchName
Set-VM -Name "DC1" -AutomaticCheckpointsEnabled $false
Set-VMProcessor -VMName "DC1" -Count 4
Start-VM -Name "DC1"

Write-Host " ------- Creating GLPI01 (Ubuntu, boots on the ISO - started later) ---------"
New-VM -Name "GLPI01" -MemoryStartupBytes 2GB -Generation 2 -VHDPath "$vmPath\GLPI01.vhdx" -SwitchName $switchName
Set-VM -Name "GLPI01" -AutomaticCheckpointsEnabled $false
Set-VMProcessor -VMName "GLPI01" -Count 2
Set-VMFirmware -VMName "GLPI01" -SecureBootTemplate "MicrosoftUEFICertificateAuthority"   # needed to boot Linux on Gen2
Add-VMDvdDrive -VMName "GLPI01" -Path $ubuntuIsoPath
Set-VMFirmware -VMName "GLPI01" -FirstBootDevice (Get-VMDvdDrive -VMName "GLPI01")

if ($deployClient) {
    Write-Host " ------- Creating CLIENT1 (Windows 11 needs a vTPM) ---------"
    New-VM -Name "CLIENT1" -MemoryStartupBytes 4GB -Generation 2 -VHDPath "$vmPath\CLIENT1.vhdx" -SwitchName $switchName
    Set-VM -Name "CLIENT1" -AutomaticCheckpointsEnabled $false
    Set-VMProcessor -VMName "CLIENT1" -Count 2
    Set-VMKeyProtector -VMName "CLIENT1" -NewLocalKeyProtector
    Enable-VMTPM -VMName "CLIENT1"
    # Started after DHCP is ready on DC1
}

WaitFor-VM -VMName "DC1" -Credential $cred


Write-Host " ----------------------------------------- Assigning Fixed Ip to DC1 ----------------------------------"

Invoke-Command -VMName "DC1" -ScriptBlock {
    Set-NetIPInterface -InterfaceAlias "Ethernet" -Dhcp Disabled
    New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress $Using:dc1IP -PrefixLength $Using:prefixLength -DefaultGateway $Using:gateway
    Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses ($Using:dc1IP)
} -Credential $cred


Write-Host " ----------------------------------------- Renaming and restarting DC1 ----------------------------------"

Invoke-Command -VMName "DC1" -ScriptBlock {
    Rename-Computer -NewName "DC1" -Restart
} -Credential $cred

Start-Sleep -Seconds 30
WaitFor-VM -VMName "DC1" -Credential $cred


Write-Host " ----------------------------------------- Deploying Active Directory for Domain ----------------------------------"

Write-Host " ------- Adding Role ---------"

Invoke-Command -VMName "DC1" -ScriptBlock {
    Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
} -Credential $cred

Write-Host " ------- Configuring a new Forest ---------"

Invoke-Command -VMName "DC1" -ScriptBlock {
    Import-Module ADDSDeployment
    Install-ADDSForest -CreateDnsDelegation:$false -DatabasePath "C:\Windows\NTDS" -DomainMode "Win2025" -DomainName $Using:tenantdomain `
    -DomainNetbiosName $Using:tenantname -ForestMode "Win2025" -InstallDns:$true -LogPath "C:\Windows\NTDS" -NoRebootOnCompletion:$false `
    -SysvolPath "C:\Windows\SYSVOL" -Force:$true -SafeModeAdministratorPassword $Using:secpasswd
} -Credential $cred

Start-Sleep -Seconds 60
WaitFor-AD -VMName "DC1" -Credential $adcred


Write-Host " ----------------------------------------- Configuring DNS ----------------------------------"

Write-Host " ------- Reverse lookup zone + forwarders (internet names for the lab) ---------"

Invoke-Command -VMName "DC1" -ScriptBlock {
    Add-DnsServerPrimaryZone -NetworkID "$Using:dhcpScopeId/$Using:prefixLength" -ReplicationScope "Forest"
    Add-DnsServerForwarder -IPAddress "1.1.1.1", "8.8.8.8"
} -Credential $adcred

Write-Host " ------- Adding DNS record glpi.$tenantdomain ---------"

Invoke-Command -VMName "DC1" -ScriptBlock {
    Add-DnsServerResourceRecordA -ZoneName $Using:tenantdomain -Name "glpi" -IPv4Address $Using:glpiIP -CreatePtr
} -Credential $adcred


Write-Host " ----------------------------------------- Deploying DHCP on DC1 ----------------------------------"

Write-Host " ------- Adding Role ---------"

Invoke-Command -VMName "DC1" -ScriptBlock {
    Install-WindowsFeature -Name DHCP -IncludeManagementTools
} -Credential $adcred

Write-Host " ------- Authorizing DHCP in Active Directory ---------"

Invoke-Command -VMName "DC1" -ScriptBlock {
    Add-DhcpServerInDC -DnsName "DC1.$Using:tenantdomain" -IPAddress $Using:dc1IP
    Add-DhcpServerSecurityGroup -ErrorAction SilentlyContinue
    # Removes the "complete DHCP configuration" warning in Server Manager
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12" -Name "ConfigurationState" -Value 2
    Restart-Service DHCPServer -Force
} -Credential $adcred

Write-Host " ------- Creating DHCP Scope ---------"

Invoke-Command -VMName "DC1" -ScriptBlock {
    param($scopeId, $startRange, $endRange, $mask, $router, $dns, $tenantdomain)
    Add-DhcpServerv4Scope -Name "Lab-GLPI" -StartRange $startRange -EndRange $endRange -SubnetMask $mask -State Active
    Set-DhcpServerv4OptionValue -ScopeId $scopeId -Router $router -DnsServer $dns -DnsDomain $tenantdomain
} -ArgumentList $dhcpScopeId, $dhcpScopeStartRange, $dhcpScopeEndRange, $dhcpSubnetMask, $gateway, $dc1IP, $tenantdomain -Credential $adcred


Write-Host " ----------------------------------------- Creating lab content for the GLPI tickets ----------------------------------"

Write-Host " ------- OUs ---------"

Invoke-Command -VMName "DC1" -ScriptBlock {
    New-ADOrganizationalUnit -Name "Service"    -Path $Using:tenantDN
    New-ADOrganizationalUnit -Name "Employes"   -Path $Using:tenantDN
    New-ADOrganizationalUnit -Name "Desactives" -Path $Using:tenantDN
} -Credential $adcred

Write-Host " ------- Service account svc-glpi (GLPI reads AD with it) ---------"

Invoke-Command -VMName "DC1" -ScriptBlock {
    New-ADUser -Name "svc-glpi" -SamAccountName "svc-glpi" -UserPrincipalName "svc-glpi@$Using:tenantdomain" `
        -Path "OU=Service,$Using:tenantDN" -AccountPassword $Using:secpasswd -Enabled $true `
        -PasswordNeverExpires $true -CannotChangePassword $true
} -Credential $adcred

Write-Host " ------- Test users ---------"

Invoke-Command -VMName "DC1" -ScriptBlock {
    foreach ($user in $Using:labUsers) {
        New-ADUser -Name $user -SamAccountName $user -UserPrincipalName "$user@$Using:tenantdomain" `
            -Path "OU=Employes,$Using:tenantDN" -AccountPassword $Using:secpasswd -Enabled $true
        Write-Host "   user $user created"
    }
} -Credential $adcred

Write-Host " ------- Group G_Compta (empty on purpose: tickets 2 and 3) ---------"

Invoke-Command -VMName "DC1" -ScriptBlock {
    New-ADGroup -Name "G_Compta" -GroupScope Global -GroupCategory Security -Path "OU=Employes,$Using:tenantDN"
} -Credential $adcred

Write-Host " ------- Share Compta: wide share permission, strict NTFS ---------"

Invoke-Command -VMName "DC1" -ScriptBlock {
    New-Item -Path "C:\Shares\Compta" -ItemType Directory -Force
    New-SmbShare -Name "Compta" -Path "C:\Shares\Compta" -ChangeAccess "$Using:tenantname\Domain Users"
    icacls "C:\Shares\Compta" /inheritance:r /grant "Administrators:(OI)(CI)F" /grant "SYSTEM:(OI)(CI)F" /grant "$Using:tenantname\G_Compta:(OI)(CI)M"
} -Credential $adcred

Write-Host " ------- Account lockout policy (ticket 1) ---------"

Invoke-Command -VMName "DC1" -ScriptBlock {
    Set-ADDefaultDomainPasswordPolicy -Identity $Using:tenantdomain -LockoutThreshold 5 `
        -LockoutDuration 00:15:00 -LockoutObservationWindow 00:15:00
} -Credential $adcred


if ($deployClient) {
    Write-Host " ----------------------------------------- Deploying CLIENT1 ----------------------------------"

    Start-VM -Name "CLIENT1"
    WaitFor-VM -VMName "CLIENT1" -Credential $clientCred

    Write-Host " ------- Renaming CLIENT1 and joining the domain ---------"

    Invoke-Command -VMName "CLIENT1" -ScriptBlock {
        Add-Computer -NewName "CLIENT1" -DomainName $Using:tenantdomain -Credential $Using:adcred -Force -Restart
    } -Credential $clientCred
}


Write-Host " ----------------------------------------- Starting GLPI01 on the Ubuntu ISO ----------------------------------"

Start-VM -Name "GLPI01"


Write-Host " ----------------------------------------- Summary ----------------------------------"

Write-Host " DC1      : $dc1IP  - domain $tenantdomain - Administrator / Pa`$`$w0rd"
Write-Host " GLPI01   : will be $glpiIP after glpi01-setup.sh - http://glpi.$tenantdomain"
if ($deployClient) { Write-Host " CLIENT1  : DHCP - joined to $tenantdomain" }
Write-Host ""
Write-Host " NEXT STEPS FOR GLPI01 (Ubuntu cannot be configured by PowerShell Direct):"
Write-Host "  1. Hyper-V Manager > GLPI01 > Connect, install Ubuntu Server 24.04"
Write-Host "     - network: leave DHCP (DC1 gives an IP), tick 'Install OpenSSH server', user: shyrete"
Write-Host "  2. After reboot: Hyper-V Manager > GLPI01 > Settings > DVD drive > None"
Write-Host "  3. From this host:  scp .\glpi01-setup.sh shyrete@<DHCP IP of GLPI01>:~"
Write-Host "  4. On GLPI01:       sudo bash ~/glpi01-setup.sh"
Write-Host "  5. Open http://glpi.$tenantdomain from CLIENT1 (or http://$glpiIP from the host)"

Write-Host "=== Script finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Stop-Transcript
