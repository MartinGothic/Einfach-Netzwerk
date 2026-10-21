param([string]$HelperPath=(Join-Path $PSScriptRoot '..\src\ClientAccessWorker.ps1'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
# Isolated native fixtures and request tests; never create an actual SMB login,
# change a Windows policy, disconnect a user session or touch a real share.
$helper=[IO.File]::ReadAllText((Resolve-Path $HelperPath),[Text.Encoding]::UTF8)
$worker=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\src\ShareWorker.ps1'),[Text.Encoding]::UTF8)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($helper,[ref]$tokens,[ref]$errors)
if(@($errors).Count -gt 0){throw ('Client helper syntax: '+(($errors | ForEach-Object {$_.Message}) -join '; '))}
$workerAst=[Management.Automation.Language.Parser]::ParseInput($worker,[ref]$tokens,[ref]$errors)
foreach($name in @('Get-Value','Add-Check','Is-PrivateIPv4','Get-Subnet','Assert-ShareName')) {
    $fn=$workerAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    Invoke-Expression $fn.Extent.Text
}
Invoke-Expression $helper
$native=[regex]::Match($helper,"Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@",[Text.RegularExpressions.RegexOptions]::Singleline).Groups[1].Value
$native=$native.Replace('namespace EinfachNetzwerk {','namespace EinfachNetzwerkNameFixture {')
$native=[regex]::Replace($native,'\[DllImport\("netapi32.dll", CharSet=CharSet.Unicode\)\]\s*static extern int NetWkstaGetInfo\([^;]+;', 'static int NetWkstaGetInfo(string server,uint level,out IntPtr buffer) { return FixtureNative.Identity(server,level,out buffer); }')
$native=[regex]::Replace($native,'\[DllImport\("netapi32.dll", CharSet=CharSet.Unicode\)\]\s*static extern int NetShareEnum\([^;]+;', 'static int NetShareEnum(string server,uint level,out IntPtr buffer,uint maximumLength,out uint read,out uint total,ref uint resume) { return FixtureNative.Enum(server,level,out buffer,maximumLength,out read,out total,ref resume); }')
$native=[regex]::Replace($native,'\[DllImport\("netapi32.dll"\)\]\s*static extern int NetApiBufferFree\([^;]+;', 'static int NetApiBufferFree(IntPtr buffer) { return FixtureNative.Free(buffer); }')
$fixture=@'
namespace EinfachNetzwerkNameFixture {
  public sealed class SharePage {
    public int Code; public string[] Names=new string[0]; public uint[] Types=new uint[0];
    public bool Advance=true, MissingBuffer;
  }
  public static class FixtureNative {
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential,CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
    struct Wksta { public uint Platform; public string Name,Group; public uint Major,Minor; }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential,CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
    struct Share { public string Name;public uint Type;public string Remark; }
    static readonly System.Collections.Generic.Dictionary<System.IntPtr,int> buffers=new System.Collections.Generic.Dictionary<System.IntPtr,int>();
    public static SharePage[] Pages=new SharePage[0];
    public static int Calls,Freed,IdentityCode;
    public static string IdentityName="TEST-NOTEBOOK",LastServer="";
    public static int Outstanding {get{return buffers.Count;}}
    public static void Reset() {if(buffers.Count!=0)throw new System.InvalidOperationException("Native allocation leaked");Calls=Freed=IdentityCode=0;LastServer="";IdentityName="TEST-NOTEBOOK";Pages=new SharePage[0];}
    public static int Identity(string server,uint level,out System.IntPtr buffer) {
      LastServer=server;buffer=System.IntPtr.Zero;
      if(level!=100)return 124;if(IdentityCode!=0)return IdentityCode;
      var item=new Wksta {Platform=500,Name=IdentityName,Group="WORKGROUP",Major=10,Minor=0};
      buffer=System.Runtime.InteropServices.Marshal.AllocHGlobal(System.Runtime.InteropServices.Marshal.SizeOf(typeof(Wksta)));
      System.Runtime.InteropServices.Marshal.StructureToPtr(item,buffer,false);buffers.Add(buffer,-1);return 0;
    }
    public static int Enum(string server,uint level,out System.IntPtr buffer,uint maximumLength,out uint read,out uint total,ref uint resume) {
      LastServer=server;buffer=System.IntPtr.Zero;read=total=0;
      if(level!=1)return 124;if(Calls>=Pages.Length)throw new System.InvalidOperationException("Unexpected native enumeration call");
      var page=Pages[Calls++];read=(uint)page.Names.Length;total=read;
      if(page.Advance)resume++;
      if(read>0 && !page.MissingBuffer) {
        int size=System.Runtime.InteropServices.Marshal.SizeOf(typeof(Share));
        buffer=System.Runtime.InteropServices.Marshal.AllocHGlobal(checked((int)read*size));
        for(int i=0;i<read;i++) {
          var share=new Share {Name=page.Names[i],Type=i<page.Types.Length?page.Types[i]:0,Remark="fixture"};
          System.Runtime.InteropServices.Marshal.StructureToPtr(share,new System.IntPtr(buffer.ToInt64()+i*size),false);
        }
        buffers.Add(buffer,(int)read);
      }
      return page.Code;
    }
    public static int Free(System.IntPtr buffer) {
      int count=buffers[buffer];
      if(count<0)System.Runtime.InteropServices.Marshal.DestroyStructure(buffer,typeof(Wksta));
      else {
        int size=System.Runtime.InteropServices.Marshal.SizeOf(typeof(Share));
        for(int i=0;i<count;i++)System.Runtime.InteropServices.Marshal.DestroyStructure(new System.IntPtr(buffer.ToInt64()+i*size),typeof(Share));
      }
      System.Runtime.InteropServices.Marshal.FreeHGlobal(buffer);buffers.Remove(buffer);Freed++;return 0;
    }
  }
}
'@
Add-Type -TypeDefinition ($native+[Environment]::NewLine+$fixture)
$script:Count=0
function Assert([bool]$Value,[string]$Why){if(-not $Value){throw $Why};$script:Count++}
function Reset-Test {
    $script:Checks=New-Object 'System.Collections.Generic.List[object]'
    $script:Result=[ordered]@{Success=$false;Message='';ErrorCode='';ErrorType='';ErrorStackTrace='';NativeConnectionVerified=$false;ConnectionVerified=$false;Networks=@();RemoteComputerName='';RemoteAddress='';RemoteShareName='';LoginUserName='';SharePath='';ConnectionText='';NamedConnectionVerified=$false;RemoteName='';NamedSharePath='';NamedAccessCode='';NamedAccessMessage=''}
    $script:MockNets=@([pscustomobject]@{Id=17;Name='Ethernet';Address='192.168.178.24';Subnet='192.168.178.0/24';Category='Private'})
    $script:Request=[pscustomobject]@{RemoteHost='192.168.178.21';RemoteShareName='Desktop';RemoteUserName='TEST-NOTEBOOK\Gast';Mode='Guest';AdapterId=17;AllowNameConnection=$true;ProtectedPassword='';DryRun=$false}
    $script:Identity=[pscustomobject]@{Success=$true;ServerName='TEST-NOTEBOOK';Stage='NetWkstaGetInfo';ErrorCode=0;ErrorMessage='';TimedOut=$false}
    $script:NamedProbe=[pscustomobject]@{Success=$true;DirectoryListed=$true;Stage='DirectoryListed';ErrorCode=0;ErrorMessage='';TimedOut=$false}
    $script:Shares=[pscustomobject]@{Success=$true;ShareNames=@('Desktop','Pictures');Stage='NetShareEnum';ErrorCode=0;ErrorMessage='';TimedOut=$false}
    $script:IpCode=0;$script:Port=$true;$script:Dns=@('192.168.178.21');$script:DnsChangeAfter=-1;$script:NetworkChangeAfter=-1
    $script:IpCalls=$script:IdentityCalls=$script:NameCalls=$script:EnumCalls=$script:DnsCalls=$script:NetCalls=0
    $script:NameLogin='';$script:Steps=New-Object 'System.Collections.Generic.List[string]'
}
function Complete-WorkStep([string]$Name){$script:Steps.Add($Name)}
function Write-Phase([string]$Text){}
function Publish-ClientRestoreState{}
function Get-HomeNetworks {
    $script:NetCalls++
    if($script:NetworkChangeAfter -ge 0 -and $script:NetCalls -gt $script:NetworkChangeAfter){$script:MockNets[0].Category='Public'}
    return $script:MockNets
}
function Resolve-ClientHostAddresses([string]$HostName) {
    if($HostName -eq '192.168.178.21'){return @($HostName)}
    $script:DnsCalls++
    if($script:DnsChangeAfter -ge 0 -and $script:DnsCalls -gt $script:DnsChangeAfter){return @('192.168.178.22')}
    return $script:Dns
}
function Get-ClientPolicyState{return [pscustomobject]@{Configuration=[pscustomobject]@{EnableInsecureGuestLogons=$false;RequireSecuritySignature=$true;RequireEncryption=$true};Blocks=@();Managed=$false}}
function Get-SmbConnection{return @()}
function Test-ClientPort{return $script:Port}
function Test-ClientNativeAccess($Request,$Target,[bool]$Connect=$false) {
    $script:IpCalls++
    return [pscustomobject]@{Success=($script:IpCode -eq 0);DirectoryListed=($script:IpCode -eq 0);Stage='WNetAddConnection2';ErrorCode=$script:IpCode;ErrorMessage=('IP error '+$script:IpCode);TimedOut=$false}
}
function Get-ClientServerIdentity($Target){$script:IdentityCalls++;return $script:Identity}
function Connect-ClientNamedGuest($Target,[string]$Name,[string]$Login){$script:NameCalls++;$script:NameLogin=$Login;return $script:NamedProbe}
function Get-ClientNamedShares([string]$Name){$script:EnumCalls++;return $script:Shares}
function Set-ClientOwnedValue {throw 'Named repair must not change Windows policies.'}
function WNetCancelConnection2 {throw 'Named repair must not disconnect user sessions.'}

[EinfachNetzwerkNameFixture.FixtureNative]::Reset()
$identity=[EinfachNetzwerkNameFixture.NativeClientAccess]::ServerIdentity('192.168.178.21')
Assert ($identity.Success -and $identity.ServerName -eq 'TEST-NOTEBOOK' -and $identity.Stage -eq 'NetWkstaGetInfo') 'Actual workstation identity was not returned.'
Assert ([EinfachNetzwerkNameFixture.FixtureNative]::LastServer -eq '\\192.168.178.21' -and [EinfachNetzwerkNameFixture.FixtureNative]::Freed -eq 1 -and [EinfachNetzwerkNameFixture.FixtureNative]::Outstanding -eq 0) 'Pinned identity query or native cleanup wrong.'
[EinfachNetzwerkNameFixture.FixtureNative]::Reset();[EinfachNetzwerkNameFixture.FixtureNative]::IdentityCode=5
$identity=[EinfachNetzwerkNameFixture.NativeClientAccess]::ServerIdentity('192.168.178.21')
Assert (-not $identity.Success -and $identity.ErrorCode -eq 5) 'Original identity error lost.'
[EinfachNetzwerkNameFixture.FixtureNative]::Reset()
$page1=New-Object EinfachNetzwerkNameFixture.SharePage;$page1.Code=234;$page1.Names=@('Desktop','IPC$','Printer');$page1.Types=@(0,3,1)
$page2=New-Object EinfachNetzwerkNameFixture.SharePage;$page2.Names=@('Pictures','C$');$page2.Types=@(0,2147483648)
[EinfachNetzwerkNameFixture.FixtureNative]::Pages=@($page1,$page2)
$shares=[EinfachNetzwerkNameFixture.NativeClientAccess]::ListShares('TEST-NOTEBOOK')
Assert ($shares.Success -and (@($shares.ShareNames) -join ',') -eq 'Desktop,Pictures') 'Complete paged disk-share enumeration wrong.'
Assert ([EinfachNetzwerkNameFixture.FixtureNative]::Calls -eq 2 -and [EinfachNetzwerkNameFixture.FixtureNative]::Freed -eq 2 -and [EinfachNetzwerkNameFixture.FixtureNative]::Outstanding -eq 0) 'ERROR_MORE_DATA allocations leaked or pages skipped.'
[EinfachNetzwerkNameFixture.FixtureNative]::Reset();$page=New-Object EinfachNetzwerkNameFixture.SharePage;$page.Code=5;$page.Names=@('UntrustedPartial');[EinfachNetzwerkNameFixture.FixtureNative]::Pages=@($page)
$shares=[EinfachNetzwerkNameFixture.NativeClientAccess]::ListShares('TEST-NOTEBOOK')
Assert (-not $shares.Success -and $shares.ErrorCode -eq 5 -and @($shares.ShareNames).Count -eq 0) 'Failed enum published partial list or lost original code.'
Assert ([EinfachNetzwerkNameFixture.FixtureNative]::Freed -eq 1 -and [EinfachNetzwerkNameFixture.FixtureNative]::Outstanding -eq 0) 'Native error allocation leaked.'
[EinfachNetzwerkNameFixture.FixtureNative]::Reset();$page=New-Object EinfachNetzwerkNameFixture.SharePage;$page.Code=234;$page.Advance=$false;[EinfachNetzwerkNameFixture.FixtureNative]::Pages=@($page)
$shares=[EinfachNetzwerkNameFixture.NativeClientAccess]::ListShares('TEST-NOTEBOOK')
Assert (-not $shares.Success -and $shares.ErrorCode -eq 234 -and [EinfachNetzwerkNameFixture.FixtureNative]::Calls -eq 1) 'No-progress ERROR_MORE_DATA loop was not stopped.'
[EinfachNetzwerkNameFixture.FixtureNative]::Reset();$page=New-Object EinfachNetzwerkNameFixture.SharePage;$page.Names=@('Desktop');$page.MissingBuffer=$true;[EinfachNetzwerkNameFixture.FixtureNative]::Pages=@($page)
$shares=[EinfachNetzwerkNameFixture.NativeClientAccess]::ListShares('TEST-NOTEBOOK')
Assert (-not $shares.Success -and $shares.ErrorCode -eq 13) 'Malformed native buffer was accepted.'

Reset-Test;Invoke-ConnectRemote $script:Request
Assert ($script:Result.Success -and $script:Result.NativeConnectionVerified -and $script:Result.ConnectionVerified -and $script:Result.NamedConnectionVerified) 'Named guest login and independent IP result were not verified.'
Assert ($script:IdentityCalls -eq 1 -and $script:NameCalls -eq 1 -and $script:EnumCalls -eq 1 -and $script:NameLogin -ceq 'TEST-NOTEBOOK\Gast') 'Automatic name repair did not use explicit passwordless account once.'
Assert ($script:Result.SharePath -ceq '\\192.168.178.21\Desktop' -and $script:Result.NamedSharePath -ceq '\\TEST-NOTEBOOK\Desktop' -and $script:Result.RemoteName -ceq 'TEST-NOTEBOOK') 'Named repair replaced pinned IP path or published wrong name path.'
Assert ($script:DnsCalls -eq 2 -and $script:NetCalls -eq 3) 'Name/IP/network binding not rechecked before each named native API.'
foreach($step in @('client-name-validation','client-name-connect','client-name-enumeration')){Assert ($step -in $script:Steps) ('Named progress step missing: '+$step)}
foreach($bad in @('192.168.178.21','.', '..','NOTEBOOK/MARTIN','NOTEBOOK\MARTIN','NOTEBOOK.MARTIN','TOO-LONG-COMPUTER-NAME',"NOTEBOOK`nMARTIN")) {
    Reset-Test;$script:Identity.ServerName=$bad;Invoke-ConnectRemote $script:Request
    Assert ($script:Result.Success -and -not $script:Result.NamedConnectionVerified -and $script:NameCalls -eq 0 -and $script:EnumCalls -eq 0 -and $script:Result.NamedAccessCode -eq 'CLIENT_NAME_IDENTITY_INVALID') ('Unsafe workstation name accepted: '+$bad)
}
Reset-Test;$script:Identity.ServerName='DIFFERENT-PC';Invoke-ConnectRemote $script:Request
Assert ($script:Result.Success -and $script:NameCalls -eq 0 -and $script:Result.NamedAccessCode -eq 'CLIENT_NAME_ACCOUNT_MISMATCH') 'Guest account domain was trusted instead of actual IP-target identity.'
Reset-Test;$script:Request.RemoteHost='TEST-NOTEBOOK';$script:Request.RemoteUserName='OTHER\Gast';Invoke-ConnectRemote $script:Request
Assert ($script:Result.Success -and $script:NameCalls -eq 0 -and $script:Result.NamedAccessCode -eq 'CLIENT_NAME_ACCOUNT_MISMATCH') 'Named login silently rewrote an explicitly selected foreign account domain.'
Reset-Test;$script:Request.RemoteHost='TEST-NOTEBOOK';$script:Request.RemoteUserName='Gast';Invoke-ConnectRemote $script:Request
Assert ($script:Result.NamedConnectionVerified -and $script:NameLogin -eq 'TEST-NOTEBOOK\Gast') 'Explicit actual host name could not qualify unqualified guest account.'
foreach($badAddresses in @(@('192.168.178.22'),@('192.168.178.21','192.168.178.22'),@('8.8.8.8'),@('192.168.178.24'),@('192.168.179.21'),@())) {
    Reset-Test;$script:Dns=$badAddresses;Invoke-ConnectRemote $script:Request
    Assert ($script:Result.Success -and $script:NameCalls -eq 0 -and $script:Result.NamedAccessCode -eq 'CLIENT_NAME_TARGET_CHANGED') 'Unsafe/ambiguous changed DNS name was authenticated.'
}
Reset-Test;$script:DnsChangeAfter=1;Invoke-ConnectRemote $script:Request
Assert ($script:Result.Success -and $script:NameCalls -eq 1 -and $script:EnumCalls -eq 0 -and -not $script:Result.NamedConnectionVerified -and $script:Result.NamedAccessCode -eq 'CLIENT_NAME_TARGET_CHANGED') 'Changed DNS target enumerated after name connect.'
Reset-Test;$script:NetworkChangeAfter=1;Invoke-ConnectRemote $script:Request
Assert ($script:Result.Success -and $script:NameCalls -eq 0 -and $script:Result.NamedAccessCode -eq 'CLIENT_NAME_TARGET_CHANGED') 'Network switched to public but named authentication continued.'
foreach($code in @(5,53,67,1219,1326)) {
    Reset-Test;$script:NamedProbe.Success=$false;$script:NamedProbe.DirectoryListed=$false;$script:NamedProbe.Stage='WNetAddConnection2';$script:NamedProbe.ErrorCode=$code;Invoke-ConnectRemote $script:Request
    Assert ($script:Result.Success -and $script:Result.NativeConnectionVerified -and -not $script:Result.NamedConnectionVerified -and $script:Result.ErrorCode -eq '' -and $script:Result.NamedAccessCode -eq ('Win32: '+$code) -and $script:EnumCalls -eq 0) ('Name error invalidated IP access, enumerated, or lost original code: '+$code)
}
Reset-Test;$script:NamedProbe.Success=$false;$script:NamedProbe.TimedOut=$true;Invoke-ConnectRemote $script:Request
Assert ($script:Result.Success -and -not $script:Result.NamedConnectionVerified -and $script:Result.NamedAccessCode -eq 'APP: CLIENT_NAME_NATIVE_TIMEOUT' -and $script:EnumCalls -eq 0) 'Named deadline invented a Windows code or erased IP success.'
foreach($code in @(5,53,1219)) {
    Reset-Test;$script:Shares.Success=$false;$script:Shares.ErrorCode=$code;Invoke-ConnectRemote $script:Request
    Assert ($script:Result.Success -and -not $script:Result.NamedConnectionVerified -and $script:NameCalls -eq 1 -and $script:EnumCalls -eq 1 -and $script:Result.NamedAccessCode -eq ('Win32: '+$code)) ('Root-list failure was hidden by direct named-share success: '+$code)
}
Reset-Test;$script:Shares.ShareNames=@('Pictures');Invoke-ConnectRemote $script:Request
Assert ($script:Result.Success -and -not $script:Result.NamedConnectionVerified -and $script:Result.NamedAccessCode -eq 'CLIENT_NAME_SHARE_NOT_LISTED') 'Unrelated share list incorrectly verified selected named share.'
Reset-Test;$script:Identity.Success=$false;$script:Identity.ErrorCode=5;Invoke-ConnectRemote $script:Request
Assert ($script:Result.Success -and $script:NameCalls -eq 0 -and $script:Result.NamedAccessCode -eq 'Win32: 5') 'Unavailable actual target identity silently trusted a name.'
Reset-Test;$script:Identity.Success=$false;$script:Identity.TimedOut=$true;Invoke-ConnectRemote $script:Request
Assert ($script:Result.Success -and $script:NameCalls -eq 0 -and $script:Result.NamedAccessCode -eq 'APP: CLIENT_NAME_NATIVE_TIMEOUT') 'Identity deadline attempted name authentication.'
Reset-Test;$script:Request.AllowNameConnection=$false;Invoke-ConnectRemote $script:Request
Assert ($script:Result.Success -and $script:IdentityCalls -eq 0 -and $script:NameCalls -eq 0 -and $script:EnumCalls -eq 0 -and -not $script:Result.NamedConnectionVerified) 'Disabled name repair still touched named SMB.'
Reset-Test;$script:Request.Mode='Password';Invoke-ConnectRemote $script:Request
Assert ($script:Result.Success -and $script:IdentityCalls -eq 0 -and $script:NameCalls -eq 0 -and $script:EnumCalls -eq 0) 'Password mode sent credentials to named DNS target.'
Reset-Test;$script:Request.ProtectedPassword='encrypted-secret-marker';Invoke-ConnectRemote $script:Request
Assert ($script:Result.Success -and $script:IdentityCalls -eq 0 -and $script:NameCalls -eq 0) 'Guest request carrying secret attempted named login.'
Reset-Test;$script:Request.DryRun=$true;Invoke-ConnectRemote $script:Request
Assert ($script:Result.Success -and $script:IpCalls -eq 0 -and $script:IdentityCalls -eq 0 -and $script:NameCalls -eq 0 -and $script:EnumCalls -eq 0) 'Dry run authenticated a named or IP session.'
Reset-Test;Invoke-InspectRemote $script:Request
Assert ($script:Result.Success -and $script:IpCalls -eq 1 -and $script:IdentityCalls -eq 0 -and $script:NameCalls -eq 0 -and $script:EnumCalls -eq 0) 'Readonly isolated inspect created current named login.'
Reset-Test;$script:IpCode=1272;Invoke-ConnectRemote $script:Request
Assert (-not $script:Result.Success -and $script:Result.ErrorCode -eq 'Win32: 1272' -and $script:IdentityCalls -eq 0 -and $script:NameCalls -eq 0) 'Failed pinned-IP login still tried named login or hid original failure.'
Reset-Test;$script:Port=$false;Invoke-ConnectRemote $script:Request
Assert (-not $script:Result.Success -and $script:IpCalls -eq 0 -and $script:IdentityCalls -eq 0 -and $script:NameCalls -eq 0) 'Offline target attempted SMB login.'
Write-Host ('Client name access: '+$script:Count+' isolated checks passed; no real SMB login or Windows setting changed.')
