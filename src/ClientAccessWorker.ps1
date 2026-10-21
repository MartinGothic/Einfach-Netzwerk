# Trusted embedded helper functions. Loaded after ShareWorker.ps1's param block.
# These actions operate on the Windows SMB CLIENT, never on a remote server.
function Load-ClientNative {
    if ('EinfachNetzwerk.NativeClientAccess' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Threading;
namespace EinfachNetzwerk {
  public sealed class ClientProbeResult {
    public bool Success, DirectoryListed, TimedOut;
    public int ErrorCode;
    public int IdentityErrorCode;
    public int JoinStatus;
    public string ServerName = "";
    public string[] ShareNames = new string[0];
    public ClientShareInfo[] Shares = new ClientShareInfo[0];
    public string Stage = "", ErrorMessage = "", ManagedErrorCode = "", ManagedErrorType = "";
  }
  public sealed class ClientShareInfo { public string Name="", Remark=""; }
  public static class NativeClientAccess {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct NETRESOURCE {
      public int dwScope, dwType, dwDisplayType, dwUsage;
      public string lpLocalName, lpRemoteName, lpComment, lpProvider;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct FIND_DATA {
      public uint attributes;
      public System.Runtime.InteropServices.ComTypes.FILETIME creation, access, write;
      public uint sizeHigh, sizeLow, reserved0, reserved1;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string name;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst=14)] public string shortName;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct WKSTA_INFO_100 {
      public uint platform;
      [MarshalAs(UnmanagedType.LPWStr)] public string name;
      [MarshalAs(UnmanagedType.LPWStr)] public string group;
      public uint major,minor;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct SHARE_INFO_1 {
      [MarshalAs(UnmanagedType.LPWStr)] public string name;
      public uint type;
      [MarshalAs(UnmanagedType.LPWStr)] public string remark;
    }
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool LogonUser(string user, string domain, string password, int type, int provider, out IntPtr token);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
    [DllImport("mpr.dll", CharSet=CharSet.Unicode)] static extern int WNetAddConnection2(ref NETRESOURCE resource, string password, string user, uint flags);
    [DllImport("mpr.dll", CharSet=CharSet.Unicode)] static extern int WNetCancelConnection2(string name, uint flags, bool force);
    [DllImport("netapi32.dll", CharSet=CharSet.Unicode)] static extern int NetGetJoinInformation(string server, out IntPtr name, out int status);
    [DllImport("netapi32.dll", CharSet=CharSet.Unicode)]
    static extern int NetWkstaGetInfo(string server, uint level, out IntPtr buffer);
    [DllImport("netapi32.dll", CharSet=CharSet.Unicode)]
    static extern int NetShareEnum(string server, uint level, out IntPtr buffer, uint maximumLength, out uint entriesRead, out uint totalEntries, ref uint resume);
    [DllImport("netapi32.dll")] static extern int NetApiBufferFree(IntPtr buffer);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr FindFirstFile(string name, out FIND_DATA data);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint GetFileAttributes(string name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool FindClose(IntPtr handle);
    static ClientProbeResult Fail(ClientProbeResult r, string stage, int code) {
      r.Stage=stage; r.ErrorCode=code; r.ErrorMessage=new Win32Exception(code).Message; return r;
    }
    static ClientProbeResult Bounded(Func<ClientProbeResult> action, int milliseconds) {
      ClientProbeResult finished=null;
      var thread=new Thread(delegate() {
        try {finished=action();}
        catch(Exception ex) {finished=new ClientProbeResult {
          Stage="ManagedException", ErrorMessage=ex.Message,
          ManagedErrorCode="HRESULT: 0x"+ex.HResult.ToString("X8"),
          ManagedErrorType=ex.GetType().FullName};}
      });
      thread.IsBackground=true; thread.Start();
      if(thread.Join(milliseconds)) return finished;
      // Do not invent a Win32 error. This deadline belongs to our own caller.
      // The background action keeps its own isolated token/finally cleanup and
      // can never overwrite this separate timeout result when it completes.
      return new ClientProbeResult {TimedOut=true, Stage="Timeout", ErrorCode=0,
        ErrorMessage="Der Windows-SMB-Verbindungstest hat sein Zeitlimit überschritten."};
    }
    static ClientProbeResult Access(string address, string share, string login, string password, bool release) {
      var r=new ClientProbeResult(); string path="\\\\"+address+"\\"+share;
      var resource=new NETRESOURCE {dwType=1, lpRemoteName=path}; bool connected=false;
      try {
        int code=WNetAddConnection2(ref resource,password ?? "",login,4);
        if(code!=0) return Fail(r,"WNetAddConnection2",code);
        connected=true; FIND_DATA data;
        IntPtr find=FindFirstFile(path+"\\*",out data);
        if(find==new IntPtr(-1)) {
          code=Marshal.GetLastWin32Error();
          if(code!=2 && code!=18) return Fail(r,"FindFirstFile",code);
          uint attributes=GetFileAttributes(path);
          if(attributes==0xffffffff) return Fail(r,"GetFileAttributes",Marshal.GetLastWin32Error());
          if((attributes & 0x10)==0) return Fail(r,"GetFileAttributes",267);
        } else FindClose(find);
        r.Success=true; r.DirectoryListed=true; r.Stage="DirectoryListed"; return r;
      } finally {
        // Used only by Probe in its isolated logon session. Connect deliberately
        // leaves the exact temporary share connection usable by Explorer.
        if(connected && release) WNetCancelConnection2(path,0,false);
      }
    }
    public static ClientProbeResult Connect(string address, string share, string login, string password) {
      return Bounded(delegate {return Access(address,share,login,password,false);},30000);
    }
    public static ClientProbeResult ServerIdentity(string address) {
      return Bounded(delegate {
        var r=new ClientProbeResult(); IntPtr buffer=IntPtr.Zero;
        try {
          // NetServerGetInfo level100 can echo the transport alias or IP.
          // Workstation level100 returns the actual Windows computer name.
          int code=NetWkstaGetInfo("\\\\"+address,100,out buffer);
          if(code!=0) return Fail(r,"NetWkstaGetInfo",code);
          if(buffer==IntPtr.Zero) return Fail(r,"NetWkstaGetInfo",13);
          var server=(WKSTA_INFO_100)Marshal.PtrToStructure(buffer,typeof(WKSTA_INFO_100));
          r.ServerName=server.name ?? ""; r.Success=true; r.Stage="NetWkstaGetInfo"; return r;
        } finally {if(buffer!=IntPtr.Zero) NetApiBufferFree(buffer);}
      },5000);
    }
    public static ClientProbeResult ListShares(string name) {
      return Bounded(delegate {
        return ListSharesCore(name);
      },15000);
    }
    static ClientProbeResult ListSharesCore(string name) {
        var r=new ClientProbeResult(); var names=new List<string>(); var shares=new List<ClientShareInfo>(); uint resume=0;
        int size=Marshal.SizeOf(typeof(SHARE_INFO_1));
        // Continue ERROR_MORE_DATA pages and free each native allocation.
        // A bounded list never reports a partial enumeration as success.
        for(int page=0;page<64;page++) {
          IntPtr buffer=IntPtr.Zero; uint read,total; uint previous=resume;
          try {
            int code=NetShareEnum("\\\\"+name,1,out buffer,65536,out read,out total,ref resume);
            if(code!=0 && code!=234) return Fail(r,"NetShareEnum",code);
            if(read>0 && buffer==IntPtr.Zero) return Fail(r,"NetShareEnum",13);
            for(uint i=0;i<read;i++) {
              var share=(SHARE_INFO_1)Marshal.PtrToStructure(new IntPtr(buffer.ToInt64()+checked((long)i*size)),typeof(SHARE_INFO_1));
              // Only ordinary disk shares; administrative shares and IPC$ are
              // not presented as user folders and no remote paths are read.
              if((share.type & 0xff)==0 && !String.IsNullOrEmpty(share.name) && !share.name.EndsWith("$",StringComparison.Ordinal)) {
                names.Add(share.name); shares.Add(new ClientShareInfo {Name=share.name,Remark=share.remark ?? ""});
              }
            }
            if(code==0) {r.ShareNames=names.ToArray();r.Shares=shares.ToArray();r.Success=true;r.Stage="NetShareEnum";return r;}
            if(read==0 && resume==previous) return Fail(r,"NetShareEnum",234);
          } finally {if(buffer!=IntPtr.Zero) NetApiBufferFree(buffer);}
        }
        return Fail(r,"NetShareEnum",234);
    }
    public static ClientProbeResult EnumerateComputer(string address, string login, string password) {
      return Bounded(delegate {
        var r=new ClientProbeResult(); IntPtr token=IntPtr.Zero;
        // Windows documents null as default credentials. Empty strings are
        // intentionally preserved for an explicit anonymous attempt. The
        // token-only identity creates an isolated LUID, never a target login.
        string user=login ?? "",domain=null; int split=user.IndexOf('\\');
        if(split>=0) {domain=user.Substring(0,split);user=user.Substring(split+1);}
        if(user.Length==0) user="EN-"+Guid.NewGuid().ToString("N").Substring(0,17);
        if(!LogonUser(user,domain,password ?? "",9,3,out token)) return Fail(r,"LogonUser",Marshal.GetLastWin32Error());
        try {
          using(WindowsIdentity.Impersonate(token)) {
            string path="\\\\"+address+"\\IPC$";
            var resource=new NETRESOURCE {dwType=0,lpRemoteName=path}; bool connected=false;
            try {
              int code=WNetAddConnection2(ref resource,password ?? "",login ?? "",4);
              if(code!=0) return Fail(r,"WNetAddConnection2-IPC",code);
              connected=true;
              // Every API stays on the pinned IP and the isolated IPC login.
              r=ListSharesCore(address);
              if(!r.Success) return r;
              IntPtr buffer=IntPtr.Zero;
              try {
                int identityCode=NetWkstaGetInfo("\\\\"+address,100,out buffer);
                r.IdentityErrorCode=identityCode;
                if(identityCode==0 && buffer!=IntPtr.Zero) {
                  var identity=(WKSTA_INFO_100)Marshal.PtrToStructure(buffer,typeof(WKSTA_INFO_100));
                  r.ServerName=identity.name ?? "";
                }
              } finally {if(buffer!=IntPtr.Zero) NetApiBufferFree(buffer);}
              return r;
            } finally {
              // Only the IPC$ this isolated token opened is released. No
              // Explorer mappings, wildcard deletion or forced disconnect.
              if(connected) WNetCancelConnection2(path,0,false);
            }
          }
        } finally {CloseHandle(token);}
      },30000);
    }
    public static ClientProbeResult JoinState() {
      return Bounded(delegate {
        IntPtr name=IntPtr.Zero;
        try {
          int status,code=NetGetJoinInformation(null,out name,out status);
          var r=new ClientProbeResult {Stage="NetGetJoinInformation",JoinStatus=status};
          if(code!=0) return Fail(r,"NetGetJoinInformation",code);
          r.Success=status==1 || status==2 || status==3;
          if(!r.Success) r.ErrorMessage="Windows hat keinen bekannten lokalen Domänenstatus zurückgegeben.";
          return r;
        } finally {if(name!=IntPtr.Zero) NetApiBufferFree(name);}
      },5000);
    }
    public static ClientProbeResult Probe(string address, string share, string login, string password) {
      return Bounded(delegate {return ProbeCore(address,share,login,password);},30000);
    }
    static ClientProbeResult ProbeCore(string address, string share, string login, string password) {
      var r=new ClientProbeResult(); IntPtr token=IntPtr.Zero;
      string user=login, domain=null;
      int split=login.IndexOf('\\');
      if(split>=0) {domain=login.Substring(0,split); user=login.Substring(split+1);}
      // A new network-only logon ID isolates all WNet state from the user's
      // Explorer sessions. Neither credentials nor a drive mapping are saved.
      if(!LogonUser(user, domain, password ?? "", 9, 3, out token)) return Fail(r,"LogonUser",Marshal.GetLastWin32Error());
      try {
        using(WindowsIdentity.Impersonate(token)) {
          return Access(address,share,login,password,true);
        }
      } finally { CloseHandle(token); }
    }
  }
}
'@
}
function Resolve-ClientHostAddresses([string]$HostName) {
    $parsed = $null
    if ([Net.IPAddress]::TryParse($HostName, [ref]$parsed)) { return @($parsed.ToString()) }
    return @([Net.Dns]::GetHostAddresses($HostName) | Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } | ForEach-Object { $_.ToString() } | Select-Object -Unique)
}
function Test-ClientUsableAddress([string]$Address, [string]$Subnet) {
    $parts=$Subnet.Split('/'); $prefix=[int]$parts[1]
    if ((Get-Subnet $Address $prefix) -ne $Subnet) { return $false }
    if ($prefix -ge 31) { return $false }
    $bytes=([Net.IPAddress]::Parse($Address)).GetAddressBytes()
    $network=([Net.IPAddress]::Parse($parts[0])).GetAddressBytes()
    $broadcast=New-Object byte[] 4
    for($i=0;$i -lt 4;$i++) {
        $bits=[Math]::Min(8,[Math]::Max(0,$prefix-8*$i))
        $mask=0; if($bits -gt 0){$mask=256-[Math]::Pow(2,8-$bits)}
        $broadcast[$i]=$network[$i] -bor (255-[int]$mask)
    }
    $networkText=([Net.IPAddress]::Parse($parts[0])).ToString()
    $broadcastText=(New-Object Net.IPAddress(,$broadcast)).ToString()
    return ($Address -ne $networkText -and $Address -ne $broadcastText)
}
function Resolve-ClientTarget($Request, [bool]$ComputerOnly = $false) {
    $remoteHost = ([string](Get-Value $Request 'RemoteHost' '')).Trim()
    $share = ([string](Get-Value $Request 'RemoteShareName' '')).Trim()
    if ($remoteHost -notmatch '^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$' -or $remoteHost.Contains('..')) { throw 'Bitte nur den Computernamen oder die private IPv4-Adresse des anderen PCs eingeben, ohne Port oder Pfad.' }
    $numeric=$null
    if ([Net.IPAddress]::TryParse($remoteHost,[ref]$numeric)) {
        if ($remoteHost -notmatch '^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$' -or $numeric.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $numeric.ToString() -cne $remoteHost) { throw 'Bitte eine vollständige IPv4-Adresse mit vier Dezimalzahlen ohne führende Nullen eingeben, zum Beispiel 192.168.178.21.' }
    }
    if (-not $ComputerOnly) { Assert-ShareName $share }
    else { $share='' }
    $mode = [string](Get-Value $Request 'Mode' 'Guest')
    if ($mode -notin @('Guest','Password')) { throw 'Bitte Ohne Passwort oder Mit Passwort auswählen.' }
    $login = ([string](Get-Value $Request 'RemoteUserName' '')).Trim()
    if (($ComputerOnly -and $mode -eq 'Guest' -and [string]::IsNullOrEmpty($login))) { $login='' }
    elseif ([string]::IsNullOrWhiteSpace($login) -or $login.Length -gt 256 -or $login -match '[/\x00-\x1f]' -or $login -notmatch '^[^\\]+(?:\\[^\\]+)?$') { throw 'Bitte den angezeigten Netzwerk-Benutzernamen des anderen PCs eingeben, zum Beispiel COMPUTER\Gast.' }
    $addresses = @(Resolve-ClientHostAddresses $remoteHost)
    if ($addresses.Count -ne 1 -or -not (Is-PrivateIPv4 ([string]$addresses[0]))) { throw 'Der Zielname muss eindeutig auf genau eine private IPv4-Adresse im Heimnetz zeigen. Bitte die IP-Adresse aus der Freigabenübersicht des anderen PCs eingeben.' }
    $all = @(Get-HomeNetworks)
    $matches = @($all | Where-Object {
        $parts = ([string]$_.Subnet).Split('/')
        $_.Category -eq 'Private' -and $parts.Length -eq 2 -and (Test-ClientUsableAddress $addresses[0] $_.Subnet) -and $addresses[0] -notin @($all | ForEach-Object {$_.Address})
    })
    $adapterId = [int](Get-Value $Request 'AdapterId' -1)
    if ($adapterId -gt 0) { $matches = @($matches | Where-Object { $_.Id -eq $adapterId }) }
    if ($matches.Count -ne 1) { throw 'Der andere PC muss im selben privaten LAN/WLAN wie dieser PC erreichbar sein. Bitte genau eine passende Heimnetzverbindung auswählen; VPN, Domänen- und öffentliche Netze werden nicht verändert.' }
    $script:Result.Networks = $all
    $script:Result.RemoteComputerName = $remoteHost
    $script:Result.RemoteAddress = [string]$addresses[0]
    $script:Result.RemoteShareName = $share
    $script:Result.LoginUserName = $login
    $script:Result.SharePath = '\\' + $addresses[0] + '\' + $share
    $script:Result.ConnectionText = "Server / IPv4: $($addresses[0])`r`nPort: 445 (TCP)`r`nFreigabe: $share`r`nDirekter Pfad: \\$($addresses[0])\$share`r`nComputername: $remoteHost`r`nAnmeldung: $login`r`nGeprüft auf: $env:COMPUTERNAME"
    Complete-WorkStep 'remote-validation'
    Add-Check 'Ziel im Heimnetz' ok ($remoteHost + ' / ' + $addresses[0] + ' über ' + $matches[0].Name + ' (' + $matches[0].Subnet + ')') 'REMOTE_LAN_TARGET'
    Complete-WorkStep 'remote-network'
    return [pscustomobject]@{ Host=$remoteHost; Address=[string]$addresses[0]; Share=$share; Login=$login; Network=$matches[0]; Mode=$mode }
}
function Set-ClientUnverifiedState {
    $script:Result.ConnectionVerified=$false; $script:Result.NativeConnectionVerified=$false
    $script:Result.NamedConnectionVerified=$false; $script:Result.RemoteComputerEnumerationVerified=$false
    $script:Result.AnonymousShareListDenied=$false
    $script:Result.RemoteShares=@(); $script:Result.NamedSharePath=''; $script:Result.RemoteName=''
}
function Get-ClientPrivateNetworks($Request) {
    $all=@(Get-HomeNetworks); $script:Result.Networks=$all
    $private=@($all | Where-Object {$_.Category -eq 'Private'})
    $adapter=[int](Get-Value $Request 'AdapterId' -1)
    if ($adapter -gt 0) {$private=@($private | Where-Object {$_.Id -eq $adapter})}
    Complete-WorkStep 'client-local-network'
    if ($private.Count -eq 0) {
        $script:Result.Success=$false; $script:Result.ErrorCode='CLIENT_PRIVATE_LAN_REQUIRED'
        $script:Result.Message='Für die Client-Vorbereitung wird ein aktives privates physisches Heimnetz benötigt. Öffentliche, VPN- und Domänennetze werden nicht verändert.'
        Add-Check 'Privates Heimnetz für den Client' error $script:Result.Message 'CLIENT_PRIVATE_LAN_REQUIRED' $false
    } else { Add-Check 'Privates Heimnetz für den Client' ok (($private | ForEach-Object {$_.Name+' / '+$_.Address}) -join '; ') 'CLIENT_PRIVATE_LAN_READY' }
    return $private
}
function Show-ClientPreparationChecks($Policy) {
    $changes=New-Object 'System.Collections.Generic.List[object]'; $unknown=[bool](Get-Value $Policy 'Unknown' $false)
    # Determine the whole configuration's confidence first. A late missing
    # property must not leave an earlier row offering an unsafe repair.
    foreach($required in @('EnableInsecureGuestLogons','RequireSecuritySignature','RequireEncryption')) {
        $value=$Policy.Configuration.PSObject.Properties[$required]
        if(($null -eq $value -and $required -ne 'RequireEncryption') -or ($null -ne $value -and $value.Value -isnot [bool])){$unknown=$true}
    }
    foreach($item in @(@{Name='EnableInsecureGuestLogons';Value=$true},@{Name='RequireSecuritySignature';Value=$false},@{Name='RequireEncryption';Value=$false})) {
        $property=$Policy.Configuration.PSObject.Properties[$item.Name]
        if ($null -eq $property) {
            if ($item.Name -eq 'RequireEncryption') {Add-Check ('Windows-Client: '+$item.Name) info 'Diese Windows-Version bietet die Einstellung nicht an.' 'CLIENT_PROPERTY_UNAVAILABLE'; continue}
            $unknown=$true; Add-Check ('Windows-Client: '+$item.Name) warning 'Windows hat diese notwendige Client-Einstellung nicht bestätigt.' 'CLIENT_POLICY_STATE_UNKNOWN' $false; continue
        }
        if ($property.Value -isnot [bool]) {$unknown=$true; Add-Check ('Windows-Client: '+$item.Name) warning 'Windows hat keinen eindeutigen booleschen Einstellungswert bestätigt.' 'CLIENT_POLICY_STATE_UNKNOWN' $false;continue}
        $before=[bool]$property.Value; $needed=$before -ne [bool]$item.Value
        $state='ok';$code='CLIENT_EFFECTIVE_SETTING';if($needed){$state='warning';$code='CLIENT_GUEST_COMPATIBILITY_REQUIRED'}
        $fixable=$needed -and $Policy.Blocks.Count -eq 0 -and -not $Policy.Managed -and -not $unknown
        Add-Check ('Windows-Client: '+$item.Name) $state ($item.Name+' = '+$before+'; für Freigaben ohne Passwort erforderlich: '+$item.Value) $code $fixable '„Zugriff auf andere Computer vorbereiten“ kann die beobachteten Client-Blockaden nach ausdrücklicher Zustimmung anpassen. Anschließend wird ein anderer Computer getrennt geprüft.'
        if($needed){$changes.Add([pscustomobject]@{Name=$item.Name;Before=$before;Expected=[bool]$item.Value;Status='Prepared'})}
    }
    if($Policy.Blocks.Count -gt 0 -or $Policy.Managed){Add-Check 'Client-Sicherheitsrichtlinien' warning ($Policy.Blocks -join ', ') 'CLIENT_MANAGED_POLICY' $false 'Verwaltete Regeln werden nicht übergangen. Ein Passwortkonto verwenden oder die Administration kontaktieren.'}
    Complete-WorkStep 'remote-policy'
    return [pscustomobject]@{Changes=@($changes.ToArray());Unknown=$unknown;CanChange=($Policy.Blocks.Count -eq 0 -and -not $Policy.Managed -and -not $unknown)}
}
function Complete-ClientPreparationSteps {
    foreach($step in @('client-local-network','remote-policy','client-snapshot','client-change','client-verification')) {Complete-WorkStep $step}
}
function Test-ClientPreparationNetwork($Networks) {
    $current=@(Get-HomeNetworks)
    foreach($original in $Networks) {
        if(@($current | Where-Object {$_.Category -eq 'Private' -and $_.Id -eq $original.Id -and [string]$_.Address -ceq [string]$original.Address -and [string]$_.Subnet -ceq [string]$original.Subnet}).Count -eq 1){return $true}
    }
    return $false
}
function Invoke-InspectClient($Request) {
    Set-ClientUnverifiedState; Publish-ClientRestoreState
    if (-not (Test-ClientWorkstationReady)) {Complete-ClientPreparationSteps;return}
    $networks=@(Get-ClientPrivateNetworks $Request)
    if($networks.Count -eq 0){Complete-ClientPreparationSteps;return}
    Write-Phase 'Windows-Einstellungen für den Zugriff auf andere Computer prüfen …'
    $policy=Get-ClientPolicyState; $observed=Show-ClientPreparationChecks $policy
    if($observed.Changes.Count -gt 0 -or $observed.Unknown -or $policy.Managed -or $policy.Blocks.Count -gt 0) {
        $script:Result.Success=$false;$script:Result.ErrorCode='CLIENT_GUEST_COMPATIBILITY_REQUIRED'
        if(-not $observed.CanChange){$script:Result.ErrorCode='CLIENT_MANAGED_POLICY';if($observed.Unknown){$script:Result.ErrorCode='CLIENT_POLICY_STATE_UNKNOWN'}}
        $script:Result.Message='Die Client-Prüfung hat Einstellungen erkannt, die Gastzugriffe blockieren können. Der Zugriff auf einen anderen Computer ist noch ungeprüft.'
    } else {
        $script:Result.Success=$true;$script:Result.ErrorCode='';$script:Result.Message='Die Windows-Client-Einstellungen sind bereit. Der Zugriff auf einen anderen Computer ist noch ungeprüft.'
        Add-Check 'Client-Vorbereitung' ok $script:Result.Message 'CLIENT_PREPARATION_READY'
    }
    Complete-ClientPreparationSteps
}
function Invoke-PrepareClient($Request) {
    Set-ClientUnverifiedState; Publish-ClientRestoreState
    if(-not [string]::IsNullOrEmpty([string](Get-Value $Request 'ProtectedPassword' ''))){throw 'Bei der Vorbereitung ohne Ziel wird kein Passwort verwendet. Bitte das Passwortfeld leer lassen.'}
    if([string](Get-Value $Request 'Mode' 'Guest') -ne 'Guest' -or -not [bool](Get-Value $Request 'AllowGuestSettings' $false)){throw 'Die Vorbereitung für Freigaben ohne Passwort benötigt deine ausdrückliche Zustimmung. Sie erlaubt Gastzugriff und entfernt eine erzwungene SMB-Signierung oder -Verschlüsselung auf diesem Windows-Client für alle SMB-Ziele.'}
    if (-not (Test-ClientWorkstationReady)) {Complete-ClientPreparationSteps;return}
    $networks=@(Get-ClientPrivateNetworks $Request)
    if($networks.Count -eq 0){Complete-ClientPreparationSteps;return}
    $policy=Get-ClientPolicyState; $observed=Show-ClientPreparationChecks $policy
    if(-not $observed.CanChange) {
        $script:Result.Success=$false;$script:Result.ErrorCode='CLIENT_MANAGED_POLICY';if($observed.Unknown){$script:Result.ErrorCode='CLIENT_POLICY_STATE_UNKNOWN'}
        $script:Result.Message='Die Client-Sicherheitsregeln sind verwaltet oder konnten nicht eindeutig bestätigt werden. Es wurde keine Einstellung verändert.'
        Complete-ClientPreparationSteps;return
    }
    $changes=@($observed.Changes)
    if([bool](Get-Value $Request 'DryRun' $false)) {
        foreach($change in $changes){Add-Check 'Geplante Client-Einstellung' info ($change.Name+': '+$change.Before+' → '+$change.Expected) 'CLIENT_DRY_RUN'}
        $script:Result.Success=$true;$script:Result.Message='Probelauf: Die erforderlichen Client-Einstellungen wurden ermittelt. Keine Windows-Einstellung und keine Netzwerk-Anmeldung wurde verändert.'
        Complete-ClientPreparationSteps;return
    }
    if($changes.Count -eq 0){
        $script:Result.Success=$true;$script:Result.ErrorCode='';$script:Result.Message='Dieser Windows-Client ist für Freigaben ohne Passwort vorbereitet. Der Zugriff auf einen anderen Computer ist noch ungeprüft.'
        Add-Check 'Client-Vorbereitung' ok $script:Result.Message 'CLIENT_PREPARATION_READY';Complete-ClientPreparationSteps;return
    }
    if(-not (Is-Administrator)){throw 'Diese Client-Vorbereitung benötigt Administratorrechte.'}
    if(-not (Test-ClientPreparationNetwork $networks)){throw 'Die private Heimnetzverbindung hat sich vor der Client-Vorbereitung verändert. Bitte erneut prüfen.'}
    Initialize-LedgerDirectory; $journal=Read-ClientJournal
    if($null -eq $journal -or $journal.Status -eq 'Restored'){$journal=[pscustomobject]@{App=$script:AppMark;Version=1;Action='RepairClient';Created=[DateTime]::UtcNow.ToString('o');Status='Prepared';Changes=@();RemoteHost='';RemoteShareName=''}}
    $active=@($journal.Changes | Where-Object {$_.Status -in @('Prepared','Applied')})
    foreach($existing in $active){if($null -eq $policy.Configuration.PSObject.Properties[$existing.Name] -or [bool]$policy.Configuration.($existing.Name) -ne [bool]$existing.Expected){throw 'Eine frühere Client-Reparatureinstellung wurde später verändert. Bitte zuerst die gespeicherte Client-Reparatur gezielt zurücknehmen und erneut prüfen.'}}
    $journal.Changes=@($active)+@($changes | Where-Object {$_.Name -notin @($active | ForEach-Object {$_.Name})})
    Write-JsonAtomic (Get-ClientJournalPath) $journal; Complete-WorkStep 'client-snapshot'
    try {
        Write-Phase 'Die bestätigten Windows-Client-Blockaden für Freigaben ohne Passwort beheben …'
        foreach($change in $changes){
            if(-not (Test-ClientPreparationNetwork $networks)){throw 'Die private Heimnetzverbindung hat sich während der Client-Vorbereitung verändert. Die Einstellungen dieses Versuchs werden zurückgenommen.'}
            Set-ClientOwnedValue $change.Name ([bool]$change.Expected)
            $entry=@($journal.Changes | Where-Object {$_.Name -eq $change.Name})[0];$entry.Status='Applied'
            Write-JsonAtomic (Get-ClientJournalPath) $journal
            Add-Check 'Client-Einstellung geändert' ok ($change.Name+': '+$change.Before+' → '+$change.Expected) 'CLIENT_COMPATIBILITY_APPLIED'
        }
        Complete-WorkStep 'client-change'
        # Verify every effective value through the supported SMB cmdlet; no
        # target account, stored password, DNS lookup or remote auth is used.
        $verified=Get-SmbClientConfiguration -ErrorAction Stop
        foreach($change in $journal.Changes | Where-Object {$_.Status -eq 'Applied'}){if($null -eq $verified.PSObject.Properties[$change.Name] -or $verified.($change.Name) -isnot [bool] -or [bool]$verified.($change.Name) -ne [bool]$change.Expected){throw ('Windows hat die Client-Vorbereitung für '+$change.Name+' nicht bestätigt.')}}
        if(-not (Test-ClientPreparationNetwork $networks)){throw 'Die private Heimnetzverbindung hat sich während der abschließenden Client-Prüfung verändert. Die Einstellungen dieses Versuchs werden zurückgenommen.'}
        $journal.Status='Committed';Write-JsonAtomic (Get-ClientJournalPath) $journal
        Publish-ClientRestoreState;Complete-WorkStep 'client-verification'
        $script:Result.Success=$true;$script:Result.ErrorCode='';$script:Result.Message='Dieser Windows-Client ist für Freigaben ohne Passwort vorbereitet. Der Zugriff auf einen anderen Computer ist noch ungeprüft.'
        Add-Check 'Client-Vorbereitung' ok $script:Result.Message 'CLIENT_PREPARATION_READY'
    } catch {
        $failure=$_
        try{$null=Restore-ClientJournal $journal @($changes | ForEach-Object {$_.Name});Add-Check 'Client-Vorbereitung zurückgenommen' info 'Die Einstellungen dieses Versuchs wurden nach fehlgeschlagener Prüfung wiederhergestellt. Frühere eigene Reparaturen bleiben erhalten.' 'CLIENT_FAILED_REPAIR_ROLLED_BACK'}
        catch{Add-Check 'Client-Rücknahme' error 'Die automatische Rücknahme ist unvollständig. Das geschützte Journal bleibt für Client-Reparatur zurücknehmen erhalten.' 'CLIENT_ROLLBACK_INCOMPLETE' $true}
        Publish-ClientRestoreState;throw $failure
    }
}
function Test-ClientPort([string]$Address) {
    $tcp = New-Object Net.Sockets.TcpClient
    try {
        $pending = $tcp.BeginConnect($Address,445,$null,$null)
        try { if (-not $pending.AsyncWaitHandle.WaitOne(3000)) { return $false }; $tcp.EndConnect($pending); return $tcp.Connected }
        catch { return $false }
        finally { $pending.AsyncWaitHandle.Close() }
    } finally { $tcp.Close() }
}
function Get-ClientDiagnosticCode([Management.Automation.ErrorRecord]$Failure) {
    $codes=New-Object 'System.Collections.Generic.List[string]'
    if ($Failure.FullyQualifiedErrorId) {$codes.Add('PowerShell: '+$Failure.FullyQualifiedErrorId)}
    $ex=$Failure.Exception;$depth=0
    while($null -ne $ex -and $depth -lt 16) {
        $codes.Add('HRESULT['+$depth+']: 0x'+$ex.HResult.ToString('X8',[Globalization.CultureInfo]::InvariantCulture))
        if($ex -is [ComponentModel.Win32Exception]){$codes.Add('Win32['+$depth+']: '+$ex.NativeErrorCode)}
        $ex=$ex.InnerException;$depth++
    }
    return ($codes -join '; ')
}
function Get-ClientNativeJoinState { Load-ClientNative; return [EinfachNetzwerk.NativeClientAccess]::JoinState() }
function Get-ClientPolicyState {
    $blocks = New-Object 'System.Collections.Generic.List[string]'
    $unknown=$false
    try {$config = Get-SmbClientConfiguration -ErrorAction Stop}
    catch {
        $config=[pscustomobject]@{};$unknown=$true;$blocks.Add('SMB-Client-Konfiguration nicht bestätigt')
        Add-Check 'SMB-Client-Konfiguration lesen' warning $_.Exception.Message (Get-ClientDiagnosticCode $_) $false 'Der native Windows-Zugriff kann weiterhin geprüft werden. Sicherheitsregeln werden ohne bestätigte Konfiguration nicht automatisch geändert.'
    }
    $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation'
    foreach ($item in @(
        @{ Name='AllowInsecureGuestAuth'; BlockValue=0 },
        @{ Name='RequireSecuritySignature'; BlockValue=1 },
        @{ Name='RequireEncryption'; BlockValue=1 }
    )) {
        try {$snapshot = Get-RegistrySnapshot $policyPath $item.Name}
        catch {
            $unknown=$true;$blocks.Add('Richtlinie '+$item.Name+' nicht bestätigt')
            Add-Check 'Client-Richtlinie lesen' warning $_.Exception.Message (Get-ClientDiagnosticCode $_) $false 'Die Verwaltungsrichtlinie konnte nicht bestätigt werden. Der Zugriff wird trotzdem mit den bestehenden Windows-Regeln geprüft; automatische Sicherheitsänderungen sind gesperrt.'
            continue
        }
        if ($snapshot.Exists) {
            Add-Check 'Verwaltete SMB-Client-Richtlinie' info ($item.Name + ' = ' + [string]$snapshot.Value) 'CLIENT_POLICY_VALUE'
            if ([int]$snapshot.Value -eq $item.BlockValue) { $blocks.Add($item.Name) }
        }
    }
    # MDM or domain control may reapply policies. Do not circumvent it by
    # changing registry policy keys or the policy database.
    $managed=$false
    try {
        $system = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 5 -ErrorAction Stop
        $managed=[bool]$system.PartOfDomain
    } catch {
        Add-Check 'Windows-Verwaltungsstatus lesen' warning $_.Exception.Message (Get-ClientDiagnosticCode $_) $false 'Die lokale WMI-Abfrage ist fehlgeschlagen oder hat ihr Zeitlimit erreicht. Der Status wird zusätzlich über die native Windows-Domänenfunktion geprüft.'
        try {
            $join = Get-ClientNativeJoinState
            if ($join.Success -and $join.JoinStatus -in @(1,2,3)) {
                $managed=$join.JoinStatus -eq 3
                $detail='Windows bestätigt: kein Domänen-PC.';if($managed){$detail='Windows bestätigt: dieser PC ist einer Domäne beigetreten.'}
                Add-Check 'Nativer Windows-Verwaltungsstatus' ok $detail 'CLIENT_NATIVE_JOIN_CONFIRMED'
            } else {
                $unknown=$true;$blocks.Add('Verwaltungsstatus nicht bestätigt')
                $code='APP: CLIENT_JOIN_STATUS_UNKNOWN'
                if ([bool](Get-Value $join 'TimedOut' $false)) {$code='APP: CLIENT_JOIN_STATUS_TIMEOUT'}
                elseif($join.ErrorCode -ne 0){$code=Format-ClientNativeCode ([int]$join.ErrorCode)}
                elseif([string](Get-Value $join 'ManagedErrorCode' '') -ne ''){$code=[string]$join.ManagedErrorCode}
                Add-Check 'Nativer Windows-Verwaltungsstatus' warning $join.ErrorMessage $code $false 'Prüfen und Verbinden bleiben möglich. Ohne bestätigten Verwaltungsstatus werden Sicherheitsregeln nicht automatisch geändert.'
            }
        } catch {
            $unknown=$true;$blocks.Add('Verwaltungsstatus nicht bestätigt')
            Add-Check 'Nativer Windows-Verwaltungsstatus' warning $_.Exception.Message (Get-ClientDiagnosticCode $_) $false 'Prüfen und Verbinden bleiben möglich. Ohne bestätigten Verwaltungsstatus werden Sicherheitsregeln nicht automatisch geändert.'
        }
    }
    try {
        $enroll = 'HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts'
        if (Test-Path -LiteralPath $enroll) {
            if (@(Get-ChildItem -LiteralPath $enroll -ErrorAction Stop).Count -gt 0) { $managed = $true }
        }
        $cloudJoin='HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo'
        if (Test-Path -LiteralPath $cloudJoin) {
            if (@(Get-ChildItem -LiteralPath $cloudJoin -ErrorAction Stop).Count -gt 0) { $managed=$true }
        }
    } catch {
        $unknown=$true;$blocks.Add('Geräteverwaltung nicht bestätigt')
        Add-Check 'Geräteverwaltung lesen' warning $_.Exception.Message (Get-ClientDiagnosticCode $_) $false 'Die Geräteverwaltung konnte nicht vollständig geprüft werden. Automatische Änderungen der Client-Sicherheitsregeln sind gesperrt; der native Zugriff bleibt prüfbar.'
    }
    if ($managed) { $blocks.Add('Domäne oder Geräteverwaltung') }
    return [pscustomobject]@{ Configuration=$config; Blocks=@($blocks.ToArray()); Managed=$managed; Unknown=$unknown }
}
function Show-ClientPolicyChecks($State, [string]$Mode) {
    $cfg = $State.Configuration
    foreach ($name in @('EnableInsecureGuestLogons','RequireSecuritySignature','RequireEncryption')) {
        if ($null -eq $cfg.PSObject.Properties[$name]) {
            Add-Check ('Windows-Client: ' + $name) info 'Diese Windows-Version bietet die Einstellung nicht an.' 'CLIENT_PROPERTY_UNAVAILABLE'
            continue
        }
        $value = [bool]$cfg.$name
        $blocking = $Mode -eq 'Guest' -and (($name -eq 'EnableInsecureGuestLogons' -and -not $value) -or ($name -ne 'EnableInsecureGuestLogons' -and $value))
        Add-Check ('Windows-Client: ' + $name) info ([string]$value) 'CLIENT_EFFECTIVE_SETTING' ($blocking -and $State.Blocks.Count -eq 0) 'Dies ist die aktuelle Einstellung. Erst ein echter Windows-Verbindungstest zeigt, ob sie diesen Zugriff blockiert. Nur bei einem bestätigten Gast-Block kann die Client-Kompatibilität mit ausdrücklicher Zustimmung angepasst werden.'
    }
    if ($State.Blocks.Count -gt 0) { Add-Check 'Client-Sicherheitsrichtlinien' warning ($State.Blocks -join ', ') 'CLIENT_MANAGED_POLICY' $false 'Diese Richtlinien werden nicht übergangen. Bitte ein Passwortkonto verwenden oder die zuständige Administration kontaktieren.' }
    Complete-WorkStep 'remote-policy'
}
function Get-ClientJournalPath { return (Join-Path $script:LedgerRoot 'client-state.json') }
function Read-ClientJournal {
    $file = Get-ClientJournalPath
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    Assert-LedgerProtection
    $record = [IO.File]::ReadAllText($file,[Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([string](Get-Value $record 'App' '') -ne $script:AppMark -or [int](Get-Value $record 'Version' 0) -ne 1 -or [string](Get-Value $record 'Action' '') -ne 'RepairClient') { throw 'Das Client-Reparaturjournal ist unbekannt oder beschädigt. Es werden keine Einstellungen verändert.' }
    if ($null -eq $record.PSObject.Properties['Changes'] -or [string](Get-Value $record 'Status' '') -notin @('Prepared','Committed','Restored')) { throw 'Das Client-Reparaturjournal enthält keinen gültigen Änderungsstatus.' }
    $changes = @(Get-Value $record 'Changes' @())
    if ($changes.Count -lt 1 -or $changes.Count -gt 3) { throw 'Das Client-Reparaturjournal enthält unbekannte Einstellungen.' }
    $names = @()
    foreach ($change in $changes) {
        if ($change.Name -notin @('EnableInsecureGuestLogons','RequireSecuritySignature','RequireEncryption') -or $change.Name -in $names -or $change.Before -isnot [bool] -or $change.Expected -isnot [bool] -or $change.Status -notin @('Prepared','Applied','Restored','Preserved')) { throw 'Das Client-Reparaturjournal enthält ungültige Daten.' }
        if (($change.Name -eq 'EnableInsecureGuestLogons' -and ($change.Before -ne $false -or $change.Expected -ne $true)) -or ($change.Name -ne 'EnableInsecureGuestLogons' -and ($change.Before -ne $true -or $change.Expected -ne $false))) { throw 'Das Client-Reparaturjournal entspricht keiner eigenen Gast-Kompatibilitätsänderung.' }
        $names += $change.Name
    }
    return $record
}
function Publish-ClientRestoreState {
    $script:Result.ClientRepairAvailable = $false
    $script:Result.ClientBackupPath = ''
    $record = Read-ClientJournal
    if ($null -ne $record -and @($record.Changes | Where-Object { $_.Status -in @('Prepared','Applied') }).Count -gt 0) {
        $script:Result.ClientRepairAvailable = $true
        $script:Result.ClientBackupPath = Get-ClientJournalPath
    }
}
function Get-ClientChanges($Configuration) {
    $changes = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in @(@{Name='EnableInsecureGuestLogons'; Value=$true},@{Name='RequireSecuritySignature'; Value=$false},@{Name='RequireEncryption'; Value=$false})) {
        if ($null -eq $Configuration.PSObject.Properties[$item.Name]) {
            if ($item.Name -ne 'RequireEncryption') { throw ('Diese Windows-Version bietet ' + $item.Name + ' nicht an. Die Gast-Kompatibilität kann nicht automatisch eingerichtet werden.') }
            continue
        }
        $before = [bool]$Configuration.($item.Name)
        if ($before -ne [bool]$item.Value) { $changes.Add([pscustomobject]@{ Name=$item.Name; Before=$before; Expected=[bool]$item.Value; Status='Prepared' }) }
    }
    return @($changes.ToArray())
}
function Set-ClientOwnedValue([string]$Name, [bool]$Value) {
    if ($Name -notin @('EnableInsecureGuestLogons','RequireSecuritySignature','RequireEncryption')) { throw 'Unbekannte SMB-Client-Einstellung.' }
    $command = Get-Command Set-SmbClientConfiguration -ErrorAction Stop
    if (-not $command.Parameters.ContainsKey($Name)) { throw ('Diese Windows-Version kann ' + $Name + ' nicht über die unterstützte Windows-Schnittstelle ändern.') }
    $args = @{ Force=$true; ErrorAction='Stop' }; $args[$Name]=$Value
    Set-SmbClientConfiguration @args | Out-Null
    $cfg = Get-SmbClientConfiguration -ErrorAction Stop
    if ($null -eq $cfg.PSObject.Properties[$Name] -or [bool]$cfg.$Name -ne $Value) { throw ('Windows hat ' + $Name + ' nicht übernommen. Eine aktive Richtlinie kann die Einstellung blockieren.') }
}
function Restore-ClientJournal($Journal, [string[]]$OnlyNames = @()) {
    $preserved = $false
    foreach ($change in @($Journal.Changes)) {
        if ($OnlyNames.Count -gt 0 -and $change.Name -notin $OnlyNames) { continue }
        if ($change.Status -notin @('Prepared','Applied')) { continue }
        $cfg = Get-SmbClientConfiguration -ErrorAction Stop
        if ($null -eq $cfg.PSObject.Properties[$change.Name]) { $preserved=$true; $change.Status='Preserved'; Add-Check 'Client-Rücknahme' warning ($change.Name + ' wird von dieser Windows-Version nicht mehr angeboten.') 'CLIENT_RESTORE_UNAVAILABLE'; continue }
        $current = [bool]$cfg.($change.Name)
        if ($current -eq [bool]$change.Before) { $change.Status='Restored' }
        elseif ($current -eq [bool]$change.Expected) { Set-ClientOwnedValue $change.Name ([bool]$change.Before); $change.Status='Restored'; Add-Check 'Client-Rücknahme' ok ($change.Name + ' = ' + $change.Before) 'CLIENT_SETTING_RESTORED' }
        else { $preserved=$true; $change.Status='Preserved'; Add-Check 'Client-Rücknahme' warning ($change.Name + ': eine spätere fremde Änderung bleibt erhalten.') 'CLIENT_FOREIGN_SETTING_PRESERVED' }
        Write-JsonAtomic (Get-ClientJournalPath) $Journal
    }
    $Journal.Status='Restored'
    if (@($Journal.Changes | Where-Object { $_.Status -in @('Prepared','Applied') }).Count -gt 0) { $Journal.Status='Committed' }
    Write-JsonAtomic (Get-ClientJournalPath) $Journal
    Publish-ClientRestoreState
    return (-not $preserved)
}
function Add-ClientExistingSessions($Target) {
    try {
        $matches = @(Get-SmbConnection -ErrorAction Stop | Where-Object { $_.ServerName -ieq $Target.Host -or $_.ServerName -ieq $Target.Address })
        foreach ($session in $matches) {
            Add-Check 'Bereits offene Windows-Verbindung' info ($session.ServerName + '\' + $session.ShareName + '; Benutzer: ' + $session.UserName + '; offene Zugriffe: ' + $session.NumOpens) 'CLIENT_EXISTING_SESSION' $false 'Der Test verwendet eine getrennte Anmeldung und lässt diese bestehende Verbindung erhalten. Wenn Explorer weiterhin ein anderes Konto verwendet, zuerst die betroffenen Explorer-Fenster und Dateien schließen; keine pauschale Trennung aller Verbindungen durchführen.'
        }
    } catch { Add-Check 'Bestehende Windows-Verbindungen' info 'Die aktiven SMB-Sitzungen konnten nicht gelesen werden. Der Test verändert sie nicht.' 'CLIENT_SESSION_INVENTORY_UNAVAILABLE' }
}
function Test-ClientNativeAccess($Request, $Target, [bool]$Connect = $false) {
    Load-ClientNative
    $secret = ''
    if ($Target.Mode -eq 'Password') {
        $secret = Unprotect-Password $Request
        if ([string]::IsNullOrEmpty($secret)) { throw 'Bitte das Netzwerk-Passwort des anderen PCs eingeben; eine Windows-PIN ist kein Netzwerk-Passwort.' }
    }
    $script:Secret = $secret
    try {
        if ($Connect) { return [EinfachNetzwerk.NativeClientAccess]::Connect($Target.Address,$Target.Share,$Target.Login,$secret) }
        return [EinfachNetzwerk.NativeClientAccess]::Probe($Target.Address,$Target.Share,$Target.Login,$secret)
    }
    finally { $secret=$null; $script:Secret=$null }
}
function Test-ClientComputerNative($Request,$Target) {
    Load-ClientNative; $secret=''
    if($Target.Mode -eq 'Password') {
        $secret=Unprotect-Password $Request
        if([string]::IsNullOrEmpty($secret)){throw 'Bitte das Netzwerk-Passwort des anderen PCs eingeben; eine Windows-PIN ist kein Netzwerk-Passwort.'}
    }
    $script:Secret=$secret
    try{return [EinfachNetzwerk.NativeClientAccess]::EnumerateComputer($Target.Address,[string]$Target.Login,$secret)}
    finally{$secret=$null;$script:Secret=$null}
}
function Test-ClientPinnedNetwork($Target) {
    $current=@(Get-HomeNetworks)
    $matches=@($current | Where-Object {
        $_.Id -eq $Target.Network.Id -and $_.Category -eq 'Private' -and
        [string]$_.Address -ceq [string]$Target.Network.Address -and [string]$_.Subnet -ceq [string]$Target.Network.Subnet -and
        (Test-ClientUsableAddress $Target.Address $_.Subnet) -and $Target.Address -notin @($current | ForEach-Object {$_.Address})
    })
    return $matches.Count -eq 1
}
function Get-ClientShareSuggestion([string]$Name,[string]$Remark,[string]$ActualComputerName) {
    $item=[pscustomobject]@{Name=$Name;Remark=$Remark;SuggestedUserName='';AccessMode='';MetadataVerified=$false}
    $type='EinfachNetzwerk.NetworkDiscovery' -as [type]
    if($null -eq $type -or [string]::IsNullOrEmpty($ActualComputerName)){return $item}
    $mode='';$login=''
    if([EinfachNetzwerk.NetworkDiscovery]::TryParseMetadata($Remark,$ActualComputerName,[ref]$mode,[ref]$login)) {
        $item.AccessMode=$mode;$item.SuggestedUserName=$login;$item.MetadataVerified=$true
    }
    return $item
}
function Invoke-EnumerateComputer($Request) {
    Set-ClientUnverifiedState; Publish-ClientRestoreState
    if([string](Get-Value $Request 'Mode' 'Guest') -eq 'Guest' -and -not [string]::IsNullOrEmpty([string](Get-Value $Request 'ProtectedPassword' ''))){throw 'Bei einer Freigabenliste ohne Passwort muss das Passwortfeld leer sein.'}
    if(-not (Test-ClientWorkstationReady)){Complete-WorkStep 'remote-enumeration';return}
    $target=Resolve-ClientTarget $Request $true
    # Computer enumeration is not a selected data share and is never marked
    # as directory access, even after an authenticated, complete native list.
    $script:Result.SharePath='';$script:Result.RemoteShareName=''
    $script:Result.ConnectionText='Server / IPv4: '+$target.Address+"`r`nPort: 445 (TCP)`r`nComputer: "+$target.Host+"`r`nFreigabenliste noch ungeprüft."
    if(-not (Test-ClientPort $target.Address)) {
        $script:Result.Success=$false;$script:Result.ErrorCode='REMOTE_PORT_UNREACHABLE'
        $script:Result.Message='Der andere PC antwortet nicht auf SMB-Port 445. Bitte dessen Freigabe, Firewall, Stromversorgung und gemeinsames Heimnetz prüfen.'
        Add-Check 'SMB-Port am anderen PC' error $script:Result.Message 'REMOTE_PORT_UNREACHABLE' $false 'Die Client-Vorbereitung kann einen ausgeschalteten PC, Router-Isolierung oder eine Firewall des anderen PCs nicht aufheben.'
        foreach($step in @('remote-port','remote-policy','remote-enumeration')){Complete-WorkStep $step};return
    }
    Add-Check 'SMB-Port am anderen PC' ok ($target.Address+':445 ist erreichbar.') 'REMOTE_PORT_REACHABLE';Complete-WorkStep 'remote-port'
    $policy=Get-ClientPolicyState;Show-ClientPolicyChecks $policy $target.Mode
    if([bool](Get-Value $Request 'DryRun' $false)) {
        $script:Result.Success=$true;$script:Result.Message='Probelauf: Computer und Windows-Client-Einstellungen geprüft. Es wurde keine Freigabenliste gelesen und keine Netzwerk-Anmeldung ausgeführt.'
        Complete-WorkStep 'remote-enumeration';return
    }
    if(-not (Test-ClientPinnedNetwork $target)) {
        $script:Result.Success=$false;$script:Result.ErrorCode='CLIENT_ENUMERATION_NETWORK_CHANGED'
        $script:Result.Message='Die private Heimnetzverbindung hat sich vor der Anmeldung verändert. Bitte erneut suchen.'
        Add-Check 'Heimnetz vor dem Zugriff' error $script:Result.Message 'CLIENT_ENUMERATION_NETWORK_CHANGED' $false
        Complete-WorkStep 'remote-enumeration';return
    }
    Write-Phase 'Die Freigabenliste des ausgewählten Computers mit einer getrennten Windows-Anmeldung lesen …'
    $probe=Test-ClientComputerNative $Request $target
    Complete-WorkStep 'remote-enumeration'
    if(-not [bool]$probe.Success) {
        $nativeCode=Format-ClientNativeCode ([int]$probe.ErrorCode);$type='System.ComponentModel.Win32Exception'
        if([bool](Get-Value $probe 'TimedOut' $false)){$nativeCode='APP: CLIENT_COMPUTER_ENUMERATION_TIMEOUT';$type='System.TimeoutException'}
        elseif([string](Get-Value $probe 'ManagedErrorCode' '') -ne ''){$nativeCode=[string]$probe.ManagedErrorCode;$type=[string]$probe.ManagedErrorType}
        $script:Result.Success=$false;$script:Result.ErrorCode=$nativeCode;$script:Result.ErrorType=$type
        $nativeDetail='Die Freigabenliste konnte bei '+$probe.Stage+' nicht gelesen werden: '+$probe.ErrorMessage+' ('+$nativeCode+').'
        $script:Result.Message=$nativeDetail
        # This is an optional anonymous computer-list query, not a selected
        # folder access failure. Only the exact native list-stage denial is
        # informational: authentication, named guest, password and other
        # native/managed failures retain their original error severity.
        if($target.Mode -eq 'Guest' -and [string]$target.Login -ceq '' -and
            [string]$probe.Stage -ceq 'NetShareEnum' -and [int]$probe.ErrorCode -eq 5 -and
            -not [bool](Get-Value $probe 'TimedOut' $false) -and
            [string](Get-Value $probe 'ManagedErrorCode' '') -ceq '') {
            $script:Result.AnonymousShareListDenied=$true
            $script:Result.Message='Windows erlaubt die Freigabenliste nicht ohne Benutzername. Einzelne freigegebene Ordner können trotzdem erreichbar sein. Der Ordnerzugriff ist hier noch ungeprüft.'
            $next='Freigabenliste mit Netzwerk-Konto prüfen. Verwende ein vom anderen Computer gemeldetes oder selbst eingegebenes Konto. Alternativ einen bekannten Freigabenamen direkt prüfen.'
            Add-Check 'Windows-Freigabenliste des Computers' info ($script:Result.Message+"`r`n"+$nativeDetail) $nativeCode $false $next
            return
        }
        $next='Den Netzwerk-Benutzernamen des anderen PCs verwenden. Danach die Freigabenliste erneut prüfen. Eine leere anonyme Anmeldung wird vom anderen Windows-PC möglicherweise nicht zugelassen.'
        $fixable=$false
        if($target.Mode -eq 'Guest' -and (Test-ClientGuestPolicyFailure ([int]$probe.ErrorCode))){$fixable=$policy.Blocks.Count -eq 0 -and -not $policy.Managed -and -not [bool](Get-Value $policy 'Unknown' $false);$next='Der Windows-Client hat eine Gast-Blockade bestätigt. „Zugriff auf andere Computer vorbereiten“ kann die beobachteten Client-Einstellungen nach ausdrücklicher Zustimmung anpassen.'}
        Add-Check 'Windows-Freigabenliste des Computers' error $script:Result.Message $nativeCode $fixable $next
        return
    }
    $actualName=([string](Get-Value $probe 'ServerName' '')).Trim();$numeric=$null
    if($actualName -notmatch '^(?=.{1,15}$)[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$' -or [Net.IPAddress]::TryParse($actualName,[ref]$numeric)){$actualName=''}
    if($actualName -ne ''){$script:Result.RemoteComputerName=$actualName;$script:Result.RemoteName=$actualName}
    $items=New-Object 'System.Collections.Generic.List[object]'
    foreach($share in @(Get-Value $probe 'Shares' @())) {
        $name=[string](Get-Value $share 'Name' '')
        if([string]::IsNullOrEmpty($name) -or $name.EndsWith('$',[StringComparison]::Ordinal)){continue}
        $items.Add((Get-ClientShareSuggestion $name ([string](Get-Value $share 'Remark' '')) $actualName))
    }
    $script:Result.RemoteShares=@($items.ToArray());$script:Result.RemoteComputerEnumerationVerified=$true
    $script:Result.Success=$true;$script:Result.ErrorCode='';$script:Result.ErrorType='';$script:Result.ErrorStackTrace=''
    $script:Result.Message='Windows hat die vollständige Freigabenliste des anderen Computers gelesen. Wähle einen Ordner oder ein Laufwerk aus; dessen Zugriff wird anschließend getrennt geprüft.'
    $script:Result.ConnectionText='Server / IPv4: '+$target.Address+"`r`nPort: 445 (TCP)`r`nComputer: "+$script:Result.RemoteComputerName+"`r`nGefundene Freigaben: "+$items.Count+"`r`nOrdnerzugriff noch ungeprüft."
    Add-Check 'Windows-Freigabenliste des Computers' ok ($target.Address+': vollständige Liste mit '+$items.Count+' normalen Freigaben gelesen. Es wurde keine Datenfreigabe geöffnet.') 'REMOTE_COMPUTER_ENUMERATION_VERIFIED'
    if($actualName -eq ''){
        $identityCode=[int](Get-Value $probe 'IdentityErrorCode' 0)
        $code='CLIENT_ENUMERATION_IDENTITY_UNCONFIRMED';if($identityCode -ne 0){$code=Format-ClientNativeCode $identityCode}
        Add-Check 'Tatsächlicher Computername' info 'Die Freigabenliste ist über die geprüfte IP lesbar. Der tatsächliche Windows-Computername wurde nicht bestätigt; gemeldete Benutzervorschläge werden nicht übernommen.' $code
    }
}
function Test-ClientGuestPolicyFailure([int]$Code) {
    # Exact Microsoft SDK codes: general guest policy, signing required,
    # and encryption unsupported for guest. No message-based guessing.
    return ($Code -in @(1272,-1067646973,-1067646972))
}
function Format-ClientNativeCode([int]$Code) {
    if ($Code -ge 0) { return ('Win32: ' + $Code) }
    $unsigned=[int64]$Code -band [int64]4294967295
    return ('Win32: ' + $Code + '; DWORD: 0x' + $unsigned.ToString('X8',[Globalization.CultureInfo]::InvariantCulture))
}
function Publish-ClientProbeResult($Probe, $Target) {
    $script:Result.NativeConnectionVerified = [bool]$Probe.Success -and [bool]$Probe.DirectoryListed
    $script:Result.ConnectionVerified = $script:Result.NativeConnectionVerified
    $script:Result.Success = $script:Result.NativeConnectionVerified
    if ($script:Result.NativeConnectionVerified) {
        $script:Result.ErrorCode=''; $script:Result.ErrorType=''; $script:Result.ErrorStackTrace=''
        $script:Result.Message='Windows hat die Verbindung zum anderen PC und das Auflisten der Freigabe wirklich bestätigt.'
        Add-Check 'Echter Windows-Client-Zugriff' ok ('\\' + $Target.Address + '\' + $Target.Share + ': Windows-SMB-Anmeldung und Ordnerliste funktionieren. Bestehende Verbindungen bleiben erhalten.') 'WINDOWS_NATIVE_ACCESS_VERIFIED'
    } else {
        $nativeCode = Format-ClientNativeCode ([int]$Probe.ErrorCode)
        $errorType='System.ComponentModel.Win32Exception'
        $timedOut=[bool](Get-Value $Probe 'TimedOut' $false)
        if ($timedOut) {$nativeCode='APP: CLIENT_NATIVE_TIMEOUT';$errorType='System.TimeoutException'}
        elseif ([string](Get-Value $Probe 'ManagedErrorCode' '') -ne '') {$nativeCode=[string]$Probe.ManagedErrorCode;$errorType=[string]$Probe.ManagedErrorType}
        $detail = 'Windows-Zugriff scheitert bei ' + $Probe.Stage + ': ' + $Probe.ErrorMessage + ' (' + $nativeCode + ').'
        $script:Result.Message=$detail; $script:Result.ErrorCode=$nativeCode; $script:Result.ErrorType=$errorType
        $next='Bitte Benutzername und Freigabename aus der Übersicht des anderen PCs verwenden und dessen Fehlerbericht prüfen.'
        if ($timedOut) {$next='Der andere PC kann ausgeschaltet sein, schlafen oder die Verbindung blockieren. Das ist ein Zeitlimit des Programms, kein von Windows zurückgegebener Fehlercode. Bitte beide PCs im selben Heimnetz wach halten und erneut prüfen.'}
        elseif (Test-ClientGuestPolicyFailure ([int]$Probe.ErrorCode)) { $next='Windows blockiert den Gastzugriff, weil Gast-Anmeldungen oder die dafür ungeeignete erzwungene Signierung/Verschlüsselung eingestellt sind. Die ausdrücklich bestätigte Client-Reparatur kann die Gast-Kompatibilität auf diesem zugreifenden PC herstellen.' }
        elseif ($Probe.ErrorCode -eq 384) { $next='Windows meldet eine nicht unterstützte ältere SMB-Verbindung. Am anderen PC SMB 2/3 aktivieren oder dessen Software aktualisieren. SMB 1 wird nicht installiert.' }
        elseif ($Probe.ErrorCode -eq 1326 -or $Probe.ErrorCode -eq 86) { $next='Die Anmeldung wurde abgewiesen. Benutzername und Passwort des freigebenden PCs prüfen, keine Windows-PIN verwenden.' }
        elseif ($Probe.ErrorCode -eq 67) { $next='Der Freigabename wurde auf dem anderen PC nicht gefunden. Den Namen genau aus dessen Freigabenübersicht kopieren.' }
        elseif ($Probe.ErrorCode -eq 5) { $next='Windows meldet Zugriff verweigert. Am freigebenden PC die Freigabe- und Ordnerrechte für das verwendete Netzwerk-Konto prüfen.' }
        elseif ($Probe.ErrorCode -eq 1219) { $next='Windows meldet eine Anmeldung mit einem anderen Konto. Bestehende Verbindungen bleiben erhalten; betroffene Explorer-Fenster und Dateien schließen und die Anmeldung gezielt prüfen.' }
        Add-Check 'Echter Windows-Client-Zugriff' error $detail ([string]$script:Result.ErrorCode) ($Target.Mode -eq 'Guest') $next
    }
}
function Complete-ClientNameSteps {
    foreach ($step in @('client-name-validation','client-name-connect','client-name-enumeration')) { Complete-WorkStep $step }
}
function Get-ClientServerIdentity($Target) {
    Load-ClientNative
    return [EinfachNetzwerk.NativeClientAccess]::ServerIdentity($Target.Address)
}
function Connect-ClientNamedGuest($Target, [string]$Name, [string]$Login) {
    Load-ClientNative
    # This path is deliberately restricted to the user's selected passwordless
    # account. A stored/entered password is never sent to a DNS-resolved name.
    return [EinfachNetzwerk.NativeClientAccess]::Connect($Name,$Target.Share,$Login,'')
}
function Get-ClientNamedShares([string]$Name) {
    Load-ClientNative
    return [EinfachNetzwerk.NativeClientAccess]::ListShares($Name)
}
function Test-ClientNameBinding($Target, [string]$Name) {
    $addresses=@(Resolve-ClientHostAddresses $Name)
    if ($addresses.Count -ne 1 -or [string]$addresses[0] -cne [string]$Target.Address -or -not (Is-PrivateIPv4 ([string]$addresses[0]))) { return $false }
    # Re-read the physical private network immediately before each named API.
    # A changed route, network category, adapter or subnet stops named access.
    $current=@(Get-HomeNetworks)
    $matches=@($current | Where-Object {
        $_.Id -eq $Target.Network.Id -and $_.Category -eq 'Private' -and
        [string]$_.Address -ceq [string]$Target.Network.Address -and
        [string]$_.Subnet -ceq [string]$Target.Network.Subnet -and
        (Test-ClientUsableAddress $Target.Address $_.Subnet) -and
        $Target.Address -notin @($current | ForEach-Object {$_.Address})
    })
    return ($matches.Count -eq 1)
}
function Set-ClientNameFailure([string]$Code,[string]$Message,[string]$NextStep='') {
    $script:Result.NamedConnectionVerified=$false
    $script:Result.NamedAccessCode=$Code
    $script:Result.NamedAccessMessage=$Message
    Add-Check 'Windows-Zugriff über den Computernamen' warning $Message $Code $false $NextStep
    # A failure to enumerate the computer name cannot invalidate the separately
    # verified direct-IP share connection or replace its native error fields.
    if ($script:Result.NativeConnectionVerified) { $script:Result.Message='Die Freigabe funktioniert über ihre IP-Adresse. Der Zugriff über den Computernamen ist noch nicht bestätigt: ' + $Message }
}
function Publish-ClientNamedNativeFailure($Probe) {
    $code=Format-ClientNativeCode ([int]$Probe.ErrorCode)
    if ([bool](Get-Value $Probe 'TimedOut' $false)) { $code='APP: CLIENT_NAME_NATIVE_TIMEOUT' }
    elseif ([string](Get-Value $Probe 'ManagedErrorCode' '') -ne '') { $code=[string]$Probe.ManagedErrorCode }
    $message='Der Namenszugriff scheitert bei ' + $Probe.Stage + ': ' + $Probe.ErrorMessage + ' (' + $code + ').'
    $next='Der direkte IP-Pfad bleibt verfügbar. Die Dienste, Namensauflösung und Freigabenliste des anderen PCs prüfen; Windows-Sicherheitsregeln bleiben unverändert.'
    if ([int]$Probe.ErrorCode -eq 1219) { $next='Windows verwendet für diesen Computernamen bereits ein anderes Konto. Betroffene Explorer-Fenster und Dateien schließen und die Anmeldung gezielt prüfen. Bestehende SMB-Verbindungen werden nicht pauschal getrennt.' }
    Set-ClientNameFailure $code $message $next
}
function Invoke-ClientNamedAccess($Request,$Target) {
    if (-not [bool](Get-Value $Request 'AllowNameConnection' $false)) { Complete-ClientNameSteps; return }
    $script:Result.NamedConnectionVerified=$false
    $script:Result.RemoteName=''; $script:Result.NamedSharePath=''
    $script:Result.NamedAccessCode=''; $script:Result.NamedAccessMessage=''
    if ($Target.Mode -ne 'Guest' -or -not [string]::IsNullOrEmpty([string](Get-Value $Request 'ProtectedPassword' ''))) {
        Set-ClientNameFailure 'CLIENT_NAME_PASSWORD_MODE_SKIPPED' 'Der Namenszugriff wird ausschließlich ohne Passwort eingerichtet. Die Passwortanmeldung bleibt an die geprüfte IP-Adresse gebunden.'
        Complete-ClientNameSteps; return
    }
    if (-not $script:Result.NativeConnectionVerified -or [bool](Get-Value $Request 'DryRun' $false)) {
        Complete-ClientNameSteps; return
    }
    try {
        Write-Phase 'Den tatsächlichen Computernamen am geprüften IP-Ziel lesen …'
        $identity=Get-ClientServerIdentity $Target
        if (-not [bool]$identity.Success) { Publish-ClientNamedNativeFailure $identity; Complete-ClientNameSteps; return }
        $name=([string]$identity.ServerName).Trim()
        $parsed=$null
        if ($name -notmatch '^(?=.{1,15}$)[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$' -or [Net.IPAddress]::TryParse($name,[ref]$parsed)) {
            Set-ClientNameFailure 'CLIENT_NAME_IDENTITY_INVALID' 'Der andere PC hat keinen geeigneten kurzen Windows-Computernamen bestätigt.'
            Complete-ClientNameSteps; return
        }
        $loginParts=([string]$Target.Login).Split('\')
        $loginDomain=''; $loginUser=$loginParts[$loginParts.Length-1]
        if ($loginParts.Length -eq 2) { $loginDomain=$loginParts[0] }
        if (-not [string]::IsNullOrEmpty($loginDomain) -and $loginDomain -ine $name) {
            Set-ClientNameFailure 'CLIENT_NAME_ACCOUNT_MISMATCH' ('Der eingegebene Benutzername gehört zu ' + $loginDomain + ', das geprüfte IP-Ziel heißt jedoch ' + $name + '.') 'Den aktuellen Benutzernamen aus der Freigabenübersicht des anderen PCs verwenden. Das Programm wechselt kein Netzwerk-Konto und erhält den funktionierenden IP-Pfad.'
            Complete-ClientNameSteps; return
        }
        if ($Target.Host -ine $name -and $loginDomain -ine $name) {
            Set-ClientNameFailure 'CLIENT_NAME_IDENTITY_MISMATCH' ('Das geprüfte IP-Ziel heißt ' + $name + ', aber dieser Name stimmt nicht mit dem eingegebenen Ziel oder Netzwerk-Benutzernamen überein.') 'Den aktuellen Computernamen und Benutzernamen aus der Freigabenübersicht des anderen PCs verwenden. Der funktionierende IP-Pfad bleibt erhalten.'
            Complete-ClientNameSteps; return
        }
        $script:Result.RemoteName=$name
        $script:Result.NamedSharePath='\\' + $name + '\' + $Target.Share
        if (-not (Test-ClientNameBinding $Target $name)) {
            Set-ClientNameFailure 'CLIENT_NAME_TARGET_CHANGED' 'Der Computername zeigt nicht eindeutig auf dieselbe geprüfte IP-Adresse im gleichen privaten Heimnetz.'
            Complete-ClientNameSteps; return
        }
        Add-Check 'Computername und IP geprüft' ok ($name + ' / ' + $Target.Address + ': Windows-Computername und eindeutige Heimnetzadresse stimmen überein.') 'CLIENT_NAME_TARGET_VERIFIED'
        Complete-WorkStep 'client-name-validation'
        $namedLogin=[string]$Target.Login
        if ([string]::IsNullOrEmpty($loginDomain)) { $namedLogin=$name + '\' + $loginUser }
        Write-Phase 'Die ausgewählte Anmeldung auch für den Computernamen verbinden …'
        $probe=Connect-ClientNamedGuest $Target $name $namedLogin
        Complete-WorkStep 'client-name-connect'
        if (-not ([bool]$probe.Success -and [bool]$probe.DirectoryListed)) { Publish-ClientNamedNativeFailure $probe; Complete-ClientNameSteps; return }
        Add-Check 'Freigabe über Computernamen geöffnet' ok ($script:Result.NamedSharePath + ': Windows-Anmeldung und Ordnerliste funktionieren; Anmeldung: ' + $namedLogin + '; Passwort leer.') 'WINDOWS_NATIVE_NAMED_SHARE_VERIFIED'
        if (-not (Test-ClientNameBinding $Target $name)) {
            Set-ClientNameFailure 'CLIENT_NAME_TARGET_CHANGED' 'Die Namensauflösung oder das Heimnetz hat sich vor dem Lesen der Freigabenliste verändert.'
            Complete-ClientNameSteps; return
        }
        Write-Phase 'Die Freigabenliste des Computernamens mit Windows lesen …'
        $shares=Get-ClientNamedShares $name
        Complete-WorkStep 'client-name-enumeration'
        if (-not [bool]$shares.Success) { Publish-ClientNamedNativeFailure $shares; return }
        $script:Result.RemoteComputerEnumerationVerified=$true
        $namedItems=New-Object 'System.Collections.Generic.List[object]'
        foreach($entry in @(Get-Value $shares 'Shares' @())) {
            $namedItems.Add((Get-ClientShareSuggestion ([string]$entry.Name) ([string]$entry.Remark) $name))
        }
        $script:Result.RemoteShares=@($namedItems.ToArray())
        if ($Target.Share -notin @($shares.ShareNames)) {
            Set-ClientNameFailure 'CLIENT_NAME_SHARE_NOT_LISTED' ('Windows hat die Freigabenliste von ' + $name + ' gelesen, aber die ausgewählte Freigabe ' + $Target.Share + ' ist darin nicht enthalten.')
            return
        }
        $script:Result.NamedConnectionVerified=$true
        $script:Result.NamedAccessCode='WINDOWS_NATIVE_NAME_ACCESS_VERIFIED'
        $script:Result.NamedAccessMessage='Windows hat den Zugriff über den Computernamen, die ausgewählte Freigabe und die Freigabenliste bestätigt.'
        $script:Result.LoginUserName=$namedLogin
        $script:Result.Message='Die Freigabe funktioniert über IP-Adresse und Computernamen. Auch die Freigabenliste des anderen PCs wurde mit Windows geöffnet.'
        $script:Result.ConnectionText += "`r`nGeprüfter Computername: $name`r`nGeprüfter Namenspfad: $($script:Result.NamedSharePath)`r`nFreigabenliste: \\$name"
        Add-Check 'Freigabenliste über Computernamen geöffnet' ok ('\\' + $name + ': vollständige Windows-Freigabenliste gelesen; ausgewählte Freigabe vorhanden. ' + $script:Result.NamedSharePath) 'WINDOWS_NATIVE_NAME_ACCESS_VERIFIED'
    } catch {
        Set-ClientNameFailure (Get-ClientDiagnosticCode $_) ('Der Namenszugriff konnte nicht vollständig geprüft werden: ' + $_.Exception.Message) 'Der separat geprüfte IP-Pfad bleibt erhalten. Den Fehlerbericht mit dem ursprünglichen Windows-Fehlercode exportieren.'
        Complete-ClientNameSteps
    }
}
function Complete-ClientServiceBlockedSteps {
    foreach ($step in @('remote-validation','remote-network','remote-policy','remote-port','remote-probe','client-snapshot','client-change','client-verification','client-name-validation','client-name-connect','client-name-enumeration','client-local-network','remote-enumeration')) { Complete-WorkStep $step }
}
function Test-ClientWorkstationReady {
    # The production worker always supplies the trusted native SCM helper.
    # Older isolated function fixtures intentionally omit it; no WMI fallback
    # or actual Windows service query is introduced into those fixtures.
    if (-not (Get-Command Get-ServiceNativeSnapshot -ErrorAction SilentlyContinue)) { return $true }
    Write-Phase 'Arbeitsstationsdienst auf diesem zugreifenden PC prüfen …'
    try {
        $service = Get-ServiceNativeSnapshot 'LanmanWorkstation'
        if ($null -eq $service) { throw 'Windows hat keinen Status für den Arbeitsstationsdienst zurückgegeben.' }
        if ([bool]$service.Exists -and [string]$service.State -eq 'Running' -and [string]$service.StartMode -in @('Auto','Manual')) {
            $nativeCode=[string](Get-Value $service 'Win32ExitCode' 0)
            $specificCode=[string](Get-Value $service 'ServiceSpecificExitCode' 0)
            Add-Check 'Arbeitsstationsdienst auf diesem PC' ok ('LanmanWorkstation auf '+$env:COMPUTERNAME+': '+[string]$service.State+'; Start: '+[string]$service.StartMode+'; Windows-Code: '+$nativeCode+'; Dienst-Code: '+$specificCode) 'SERVICE_WORKSTATION_READY'
            return $true
        }
        $nativeCode = [string](Get-Value $service 'Win32ExitCode' 0)
        $specificCode = [string](Get-Value $service 'ServiceSpecificExitCode' 0)
        $detail = 'Der Arbeitsstationsdienst (LanmanWorkstation) auf diesem zugreifenden PC ' + $env:COMPUTERNAME + ' ist nicht bereit. Zustand: ' + [string]$service.State + '; Starttyp: ' + [string]$service.StartMode + '; Windows-Code: ' + $nativeCode + '; Dienst-Code: ' + $specificCode + '. Der Dienst wird für den Zugriff auf andere Computer benötigt. Es wurde noch keine SMB-Anmeldung versucht und keine Sicherheitsregel geändert.'
        $script:Result.Success = $false
        $script:Result.Message = $detail
        $script:Result.ErrorCode = 'SERVICE_WORKSTATION_NOT_RUNNING'
        Add-Check 'Arbeitsstationsdienst auf diesem PC' error $detail 'SERVICE_WORKSTATION_NOT_RUNNING' $true 'Windows-Dienste auf diesem zugreifenden PC reparieren. Der freigebende Computer muss wegen dieses lokalen Fehlers nicht geändert werden.'
        # Keep the exact observed SCM exit numbers, including zero. A stopped
        # service with exit 0 must not be reported as an invented Win32 error.
        Add-Check 'Windows-Dienststatus: LanmanWorkstation' info ('Windows-Code: ' + $nativeCode + '; Dienst-Code: ' + $specificCode) ('Win32: ' + $nativeCode + '; Service: ' + $specificCode)
    } catch {
        $script:Result.Success = $false
        $script:Result.Message = 'Der Arbeitsstationsdienst auf diesem zugreifenden PC konnte nicht geprüft werden: ' + $_.Exception.Message + '. Es wurde keine SMB-Anmeldung und keine Änderung der Client-Sicherheitsregeln ausgeführt.'
        $script:Result.ErrorCode = 'SERVICE_WORKSTATION_QUERY_FAILED'
        $script:Result.ErrorType = $_.Exception.GetType().FullName
        $script:Result.ErrorStackTrace = [string]$_.ScriptStackTrace
        Add-Check 'Arbeitsstationsdienst prüfen' error $script:Result.Message (Get-ClientDiagnosticCode $_) $false 'Windows-Dienste auf diesem PC prüfen und den Fehlerbericht mit dem ursprünglichen Windows-Fehlercode exportieren.'
    }
    $script:Result.ConnectionVerified = $false
    $script:Result.NativeConnectionVerified = $false
    $script:Result.NamedConnectionVerified = $false
    $script:Result.NamedSharePath = ''
    $script:Result.RemoteName = ''
    $script:Result.RemoteComputerEnumerationVerified = $false
    $script:Result.AnonymousShareListDenied = $false
    $script:Result.RemoteShares = @()
    Complete-ClientServiceBlockedSteps
    return $false
}
function Invoke-InspectRemote($Request, [bool]$Connect = $false) {
    $script:Result.AnonymousShareListDenied=$false
    Publish-ClientRestoreState
    if (-not (Test-ClientWorkstationReady)) { return }
    $target = Resolve-ClientTarget $Request
    Write-Phase 'Den anderen PC auf TCP-Port 445 prüfen …'
    if (-not (Test-ClientPort $target.Address)) {
        $script:Result.Success=$false; $script:Result.Message='Der andere PC antwortet nicht auf SMB-Port 445. Bitte dessen Freigabe, Firewall, Stromversorgung und gemeinsames Heimnetz prüfen.'
        Add-Check 'SMB-Port am anderen PC' error $script:Result.Message 'REMOTE_PORT_UNREACHABLE' $false 'Die Client-Reparatur kann einen ausgeschalteten PC, Router-Isolierung oder eine Firewall des anderen PCs nicht aufheben.'
        Complete-WorkStep 'remote-port'; Complete-WorkStep 'remote-policy'; Complete-WorkStep 'remote-probe'; Complete-ClientNameSteps; return
    }
    Add-Check 'SMB-Port am anderen PC' ok ($target.Address + ':445 ist erreichbar.') 'REMOTE_PORT_REACHABLE'
    Complete-WorkStep 'remote-port'
    Write-Phase 'Windows-Client-Sicherheitsregeln lesen …'
    $policy = Get-ClientPolicyState
    Show-ClientPolicyChecks $policy $target.Mode
    Write-Phase 'Bestehende Windows-SMB-Verbindungen prüfen …'
    Add-ClientExistingSessions $target
    if ([bool](Get-Value $Request 'DryRun' $false)) {
        $script:Result.Success=$true; $script:Result.Message='Probelauf: Ziel und Windows-Client-Richtlinien geprüft. Es wurde keine SMB-Anmeldung und keine Konfigurationsänderung ausgeführt.'
        Complete-WorkStep 'remote-probe'; Complete-ClientNameSteps; return
    }
    Write-Phase 'Den Zugriff mit dem echten Windows-SMB-Client prüfen …'
    $probe = Test-ClientNativeAccess $Request $target $Connect
    Publish-ClientProbeResult $probe $target
    if ($Connect -and $script:Result.NativeConnectionVerified) {
        $script:Result.Message='Die Freigabe ist für deinen aktuellen Windows-Benutzer verbunden und wurde wirklich geöffnet. Der direkte IP-Pfad kann jetzt im Explorer verwendet werden.'
        Add-Check 'Für Explorer verbunden' ok $script:Result.SharePath 'CLIENT_CURRENT_SESSION_CONNECTED' $false 'Diesen direkten Freigabepfad öffnen. Das Öffnen des bloßen Computernamens zeigt die separate Freigabenliste und kann unabhängig davon durch Namensauflösung oder Berechtigungen scheitern.'
        Invoke-ClientNamedAccess $Request $target
    }
    else { Complete-ClientNameSteps }
    Complete-WorkStep 'remote-probe'
}
function Invoke-ConnectRemote($Request) { Invoke-InspectRemote $Request $true }
function Invoke-RepairClient($Request) {
    $script:Result.AnonymousShareListDenied=$false
    Publish-ClientRestoreState
    if (-not (Test-ClientWorkstationReady)) { return }
    $target = Resolve-ClientTarget $Request
    Write-Phase 'Den anderen PC auf TCP-Port 445 prüfen …'
    if (-not (Test-ClientPort $target.Address)) { throw 'Der andere PC antwortet nicht auf SMB-Port 445. Erst dessen Freigabe und die Verbindung im gemeinsamen Heimnetz prüfen; Client-Sicherheitsregeln werden dafür nicht gelockert.' }
    Complete-WorkStep 'remote-port'
    Write-Phase 'Windows-Client-Sicherheitsregeln lesen …'
    $policy = Get-ClientPolicyState
    Show-ClientPolicyChecks $policy $target.Mode
    Write-Phase 'Bestehende Windows-SMB-Verbindungen prüfen …'
    Add-ClientExistingSessions $target
    $isDryRun=[bool](Get-Value $Request 'DryRun' $false)
    if (-not $isDryRun) {
        Write-Phase 'Vor jeder Einstellungsänderung den echten Windows-Zugriff prüfen …'
        $initialProbe = Test-ClientNativeAccess $Request $target
        if (($initialProbe.Success -and $initialProbe.DirectoryListed) -or $target.Mode -eq 'Password' -or -not (Test-ClientGuestPolicyFailure ([int]$initialProbe.ErrorCode))) {
            Publish-ClientProbeResult $initialProbe $target
            foreach ($step in @('remote-probe','client-snapshot','client-change','client-verification')) { Complete-WorkStep $step }
            if ($script:Result.NativeConnectionVerified) {
                Add-Check 'Keine Client-Änderung erforderlich' ok 'Der echte Windows-Zugriff funktioniert mit den aktuellen Sicherheitsregeln. Gastzugriff, Signierung und Verschlüsselung wurden nicht verändert.' 'CLIENT_REPAIR_NOT_NEEDED'
            } else {
                Add-Check 'Keine pauschale Sicherheitsänderung' info 'Windows hat keinen bestätigten Gast-Richtlinienblock gemeldet. Die bestehenden Sicherheitsregeln bleiben erhalten; die genaue Windows-Fehlermeldung zeigt den nächsten Schritt.' 'CLIENT_POLICY_CHANGE_NOT_APPLICABLE'
            }
            return
        }
        $initialCode=Format-ClientNativeCode ([int]$initialProbe.ErrorCode)
        Add-Check 'Windows-Zugriff vor der Reparatur' warning ($initialProbe.ErrorMessage + ' (' + $initialCode + ')') $initialCode $true 'Der Gast-Richtlinienblock wurde durch den nativen Windows-Client bestätigt.'
    }
    if ($target.Mode -eq 'Password') {
        foreach ($step in @('remote-probe','client-snapshot','client-change','client-verification')) { Complete-WorkStep $step }
        $script:Result.Success=$true; $script:Result.Message='Probelauf: Im Passwortmodus bleiben Gastzugriff, Signierung und Verschlüsselung unverändert. Keine Windows-Anmeldung ausgeführt.'
        Add-Check 'Passwortmodus' info 'Im Passwortmodus bleiben Gastzugriff, Signierung und Verschlüsselung des Windows-Clients unverändert.' 'CLIENT_PASSWORD_POLICY_UNCHANGED'
        return
    }
    if (-not [bool](Get-Value $Request 'AllowGuestSettings' $false)) { throw 'Die Gast-Reparatur benötigt deine ausdrückliche Zustimmung. Sie erlaubt Gastzugriff und entfernt eine erzwungene SMB-Signierung oder -Verschlüsselung auf diesem Windows-Client für alle SMB-Ziele.' }
    if ($policy.Blocks.Count -gt 0) { throw ('Verwaltete Sicherheitsrichtlinien werden nicht übergangen: ' + ($policy.Blocks -join ', ') + '. Bitte den Passwortmodus verwenden oder die Administration kontaktieren.') }
    $changes = @(Get-ClientChanges $policy.Configuration)
    if ($isDryRun) {
        foreach ($change in $changes) { Add-Check 'Geplante Client-Einstellung' info ($change.Name + ': ' + $change.Before + ' → ' + $change.Expected) 'CLIENT_DRY_RUN' }
        $script:Result.Success=$true; $script:Result.Message='Probelauf: Die erforderlichen Gast-Client-Einstellungen wurden ermittelt. Keine Windows-Einstellungen oder Anmeldungen wurden verändert.'
        foreach ($step in @('remote-probe','client-snapshot','client-change','client-verification')) { Complete-WorkStep $step }
        return
    }
    if (-not (Is-Administrator)) { throw 'Diese Client-Reparatur benötigt Administratorrechte.' }
    # Get-ClientPolicyState already confirmed local domain/MDM/cloud ownership
    # with a bounded query. Do not repeat an unbounded WMI query here.
    Initialize-LedgerDirectory
    $journal = Read-ClientJournal
    if ($null -eq $journal -or $journal.Status -eq 'Restored') {
        $journal = [pscustomobject]@{ App=$script:AppMark; Version=1; Action='RepairClient'; Created=[DateTime]::UtcNow.ToString('o'); Status='Prepared'; Changes=@(); RemoteHost=$target.Host; RemoteShareName=$target.Share }
    }
    $active = @($journal.Changes | Where-Object { $_.Status -in @('Prepared','Applied') })
    foreach ($existing in $active) {
        if ($null -eq $policy.Configuration.PSObject.Properties[$existing.Name] -or [bool]$policy.Configuration.($existing.Name) -ne [bool]$existing.Expected) { throw 'Eine frühere Client-Reparatureinstellung wurde später verändert. Bitte zuerst die gespeicherte Client-Reparatur gezielt zurücknehmen und erneut prüfen.' }
    }
    $journal.Changes = @($active) + @($changes | Where-Object { $_.Name -notin @($active | ForEach-Object {$_.Name}) })
    if ($changes.Count -gt 0) { Write-JsonAtomic (Get-ClientJournalPath) $journal }
    Complete-WorkStep 'client-snapshot'
    try {
        Write-Phase 'Windows-Client für den bestätigten Gastzugriff einstellen …'
        foreach ($change in $changes) {
            Set-ClientOwnedValue $change.Name ([bool]$change.Expected)
            $entry = @($journal.Changes | Where-Object { $_.Name -eq $change.Name })[0]
            $entry.Status='Applied'
            Write-JsonAtomic (Get-ClientJournalPath) $journal
            Add-Check 'Client-Einstellung geändert' ok ($change.Name + ': ' + $change.Before + ' → ' + $change.Expected) 'CLIENT_COMPATIBILITY_APPLIED'
        }
        Complete-WorkStep 'client-change'
        $probe = $null
        for ($attempt=1; $attempt -le 3; $attempt++) {
            Write-Phase ('Windows-Zugriff nach der Client-Reparatur prüfen (' + $attempt + '/3) …')
            $probe = Test-ClientNativeAccess $Request $target
            $script:Result.RetryCount=$attempt-1
            if ($probe.Success -and $probe.DirectoryListed) { break }
            if ([bool](Get-Value $probe 'TimedOut' $false)) { break }
        }
        Publish-ClientProbeResult $probe $target
        Complete-WorkStep 'remote-probe'; Complete-WorkStep 'client-verification'
        if (-not $script:Result.NativeConnectionVerified) {
            if ($changes.Count -gt 0) {
                # Persist the complete journal throughout rollback so an older
                # successful repair never loses its ownership record, even if
                # saving a later update fails.
                $null = Restore-ClientJournal $journal @($changes | ForEach-Object {$_.Name})
                Add-Check 'Client-Reparatur zurückgenommen' info 'Der Zugriff ist weiterhin nicht bestätigt. Die Einstellungen dieses Versuchs wurden wiederhergestellt; frühere erfolgreiche Reparaturen bleiben erhalten.' 'CLIENT_FAILED_REPAIR_ROLLED_BACK'
            }
            Publish-ClientRestoreState
            return
        }
        if ($journal.Changes.Count -gt 0) { $journal.Status='Committed'; Write-JsonAtomic (Get-ClientJournalPath) $journal }
        Publish-ClientRestoreState
    } catch {
        $failure = $_
        if ($changes.Count -gt 0) {
            try {
                $null = Restore-ClientJournal $journal @($changes | ForEach-Object {$_.Name})
            } catch { Add-Check 'Client-Rücknahme' error 'Die automatische Rücknahme ist unvollständig. Das geschützte Journal bleibt für Client-Reparatur zurücknehmen erhalten.' 'CLIENT_ROLLBACK_INCOMPLETE' $true }
        }
        Publish-ClientRestoreState
        throw $failure
    }
}
function Invoke-RestoreClient($Request) {
    $script:Result.AnonymousShareListDenied=$false
    $journal = Read-ClientJournal
    if ($null -eq $journal) {
        $script:Result.Success=$true; $script:Result.Message='Es ist keine gespeicherte Client-Reparatur vorhanden.'; Publish-ClientRestoreState
        foreach ($step in @('client-snapshot','client-change','client-verification')) { Complete-WorkStep $step }
        return
    }
    Write-Phase 'Windows-Client-Sicherheitsregeln vor der Rücknahme lesen …'
    $policy = Get-ClientPolicyState
    if ($policy.Managed -or [bool](Get-Value $policy 'Unknown' $false)) { throw 'Der Verwaltungsstatus dieses PCs ist verwaltet oder konnte nicht bestätigt werden. Die gespeicherten Einstellungen werden nicht automatisch geändert; bitte den Fehlerbericht prüfen oder die Administration kontaktieren.' }
    if ([bool](Get-Value $Request 'DryRun' $false)) {
        $script:Result.Success=$true; $script:Result.Message='Probelauf: Nur die gespeicherten eigenen Client-Einstellungen würden zurückgenommen; spätere fremde Änderungen bleiben erhalten.'; Publish-ClientRestoreState
        foreach ($step in @('client-snapshot','client-change','client-verification')) { Complete-WorkStep $step }
        return
    }
    if (-not (Is-Administrator)) { throw 'Die Client-Rücknahme benötigt Administratorrechte.' }
    Write-Phase 'Die gespeicherten Client-Einstellungen gezielt zurücknehmen …'
    $restored = Restore-ClientJournal $journal
    $script:Result.Success=$true
    $script:Result.Message='Die gespeicherten Client-Einstellungen wurden zurückgenommen. Freigaben und Dateien bleiben erhalten.'
    if (-not $restored) { $script:Result.Message='Die eigenen Client-Einstellungen wurden zurückgenommen; spätere fremde oder nicht mehr angebotene Einstellungen bleiben erhalten.' }
    foreach ($step in @('client-snapshot','client-change','client-verification')) { Complete-WorkStep $step }
}
