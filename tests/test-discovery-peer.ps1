param()
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -eq 'Core') {
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoLogo -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}
$taskQa=Join-Path $PSScriptRoot 'host-qa'
[IO.Directory]::CreateDirectory($taskQa) | Out-Null
$taskSource=Join-Path $taskQa 'DiscoveryPeerTests.cs'
$taskExecutable=Join-Path $taskQa 'discovery-peer-tests.exe'
$taskCode=@'
using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using EinfachNetzwerk;
class DiscoveryPeerTests
{
    static int passed;
    static void Check(bool value,string title) { if(!value) throw new Exception(title); passed++; Console.WriteLine("PASS: "+title); }
    static NetworkItem Net(string category="Private", string address="192.168.178.24", string subnet="192.168.178.0/24", int id=16) {return new NetworkItem{Category=category,Address=address,Subnet=subnet,Id=id};}
    static IList<NetworkItem> Nets(params NetworkItem[] values) {return values;}
    static IPEndPoint Endpoint(string address="192.168.178.21", int port=41671) {return new IPEndPoint(IPAddress.Parse(address),port);}
    static string nonce="0102030405060708090a0b0c0d0e0f10";
    static byte[] Request(string value=null) {return Encoding.ASCII.GetBytes("EN-DISCOVER-1 "+(value??nonce));}
    static DiscoveryPeerShare Share(string name="Desktop", string account="Gast", string computer="TEST-NOTEBOOK", string mode="Guest") {return new DiscoveryPeerShare{Name=name,Remark=DiscoveryPeerService.MakeRemark(mode,computer,account)};}
    static byte[] Response() {return DiscoveryPeerService.BuildResponse(Request(),Endpoint("192.168.178.24",50101),16,Nets(Net(address:"192.168.178.21")),new[]{Share()},"TEST-NOTEBOOK");}
    static DiscoveryPeerAdvertisement Parse(byte[] value,IPEndPoint sender=null,string requestNonce=null,IList<NetworkItem> networks=null) {return DiscoveryPeerService.ParseResponse(value,sender??Endpoint(),requestNonce??nonce,networks??Nets(Net()));}
    static byte[] Json(object value) {return Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(value));}
    static void Main()
    {
        try { Run();Console.WriteLine("Discovery peer tests: "+passed+" passed; fake transport only; no Windows settings or live shares changed."); }
        catch(Exception error) {Console.Error.WriteLine(error);Environment.ExitCode=1;}
    }
    static void Run()
    {
        byte[] valid=Response();
        Check(valid!=null && valid.Length<=8192,"Responder emits a bounded nonce response for a physical private interface");
        DiscoveryPeerAdvertisement peer=Parse(valid);
        Check(peer!=null && peer.Address=="192.168.178.21" && peer.ComputerName=="TEST-NOTEBOOK" && peer.Shares.Length==1,"Discovery uses the actual sender and publishes public hints only");
        string wire=Encoding.UTF8.GetString(valid);
        Check(!wire.Contains("Password\"") && !wire.Contains("Path") && !wire.Contains("SID") && !wire.Contains("Verified"),"Wire schema does not contain passwords, local paths, SIDs, journals or access proofs");
        string mode,account;
        Check(DiscoveryPeerService.TryParseRemark(Share().Remark,"TEST-NOTEBOOK",out mode,out account) && mode=="Guest" && account=="Gast","Mode and actual unqualified account survive public preset parse");
        Check(DiscoveryPeerService.TryParseRemark(Share(account:"Invité",mode:"Password").Remark,"TEST-NOTEBOOK",out mode,out account) && account=="Invité" && mode=="Password","URI-escaped local account is supported without any secret");
        foreach(string bad in new[]{"EinfachNetzwerk-v1","[EinfachNetzwerk:1;mode=Guest;computer=OTHER-PC;user=Gast]","[EinfachNetzwerk:1;mode=Guest;computer=TEST-NOTEBOOK;user=TEST-NOTEBOOK%5CGast]","[EinfachNetzwerk:1;mode=Anonymous;computer=TEST-NOTEBOOK;user=Gast]","[EinfachNetzwerk:1;mode=Guest;computer=TEST-NOTEBOOK;user=Gast%]","[EinfachNetzwerk:1;mode=Guest;computer=TEST-NOTEBOOK;user=Gast%0A]","[EinfachNetzwerk:1;mode=Guest;computer=TEST-NOTEBOOK;user=Gast;password=x]","[EinfachNetzwerk:1;mode=Guest;computer=TEST-NOTEBOOK;user=%20Gast]"})
            Check(!DiscoveryPeerService.TryParseRemark(bad,"TEST-NOTEBOOK",out mode,out account),"Malformed, foreign, qualified, secret-bearing or unsupported metadata fails closed");
        Check(Parse(valid,requestNonce:new string('a',32))==null,"A response from a different scan nonce is rejected");
        Check(Parse(valid,sender:Endpoint(port:12345))==null,"Only the peer protocol's response port is accepted");
        foreach(string address in new[]{"8.8.8.8","127.0.0.1","169.254.1.2","192.168.179.21","192.168.178.0","192.168.178.255","192.168.178.24","::1"})
            Check(Parse(valid,sender:Endpoint(address))==null,"Public, unrelated, loopback, subnet, broadcast and local sender are excluded");
        Check(Parse(valid,networks:Nets(Net("Public")))==null,"A public profile cannot receive discovery advertisements");
        Check(Parse(valid,networks:Nets(Net("DomainAuthenticated")))==null,"A domain profile cannot receive discovery advertisements");
        Check(Parse(valid,networks:Nets(Net(id:0)))==null,"A missing physical interface identity fails closed");
        Check(Parse(valid,networks:Nets(Net(subnet:"192.168.0.0/8")))==null,"Overbroad RFC1918 subnet masks are rejected");
        Check(Parse(valid,networks:Nets(Net(subnet:"192.168.178.1/24")))==null,"A noncanonical subnet address is rejected");
        Check(Parse(new byte[8193])==null,"Oversized datagrams are rejected before parsing");
        Check(Parse(new byte[]{0xff,0xfe})==null,"Invalid UTF-8 cannot be interpreted as public metadata");
        Check(Parse(Encoding.UTF8.GetBytes("{broken"))==null,"Malformed JSON fails closed");
        Check(Parse(Json(new{Protocol="EN-DISCOVER-1",Nonce=nonce,ComputerName="TEST-NOTEBOOK",Shares=new[]{Share()},Address="10.1.1.2"}))==null,"A claimed address or extra packet field is rejected");
        Check(Parse(Json(new{Protocol="OTHER",Nonce=nonce,ComputerName="TEST-NOTEBOOK",Shares=new[]{Share()}}))==null,"An unrelated discovery protocol is rejected");
        Check(Parse(Json(new{Protocol="EN-DISCOVER-1",Nonce=nonce,ComputerName="TEST-NOTEBOOK",Shares=new[]{Share(),Share()}}))==null,"Duplicate remote shares cannot shadow an advertised preset");
        Check(Parse(Json(new{Protocol="EN-DISCOVER-1",Nonce=nonce,ComputerName="TEST-NOTEBOOK",Shares=new[]{Share(computer:"OTHER-PC")}}))==null,"Every share's reported computer must match the envelope");
        Check(Parse(Json(new{Protocol="EN-DISCOVER-1",Nonce=nonce,ComputerName="TEST-NOTEBOOK",Shares=Enumerable.Range(0,33).Select(i=>Share("Folder"+i)).ToArray()}))==null,"Excessive share counts are rejected");
        foreach(string name in new[]{"C$","ADMIN$","IPC$","ADMIN","IPC","D$","A\\B","../folder","Folder.",""})
            Check(Parse(Json(new{Protocol="EN-DISCOVER-1",Nonce=nonce,ComputerName="TEST-NOTEBOOK",Shares=new[]{Share(name)}}))==null,"System, invalid and non-data shares cannot be advertised");
        foreach(byte[] bad in new[]{Request(new string('A',32)),Request("short"),Encoding.ASCII.GetBytes("EN-DISCOVER-1 "+nonce+"\n"),Encoding.ASCII.GetBytes("EN-DISCOVER-2 "+nonce)})
            Check(DiscoveryPeerService.BuildResponse(bad,Endpoint("192.168.178.24",50101),16,Nets(Net(address:"192.168.178.21")),new[]{Share()},"TEST-NOTEBOOK")==null,"Invalid or command-like requests have no response");
        Check(DiscoveryPeerService.BuildResponse(Request(),Endpoint("192.168.178.24",50101),17,Nets(Net(address:"192.168.178.21")),new[]{Share()},"TEST-NOTEBOOK")==null,"A request arriving on a different interface is not answered");
        Check(DiscoveryPeerService.BuildResponse(Request(),Endpoint("192.168.178.24",50101),16,Nets(Net("Public",address:"192.168.178.21")),new[]{Share()},"TEST-NOTEBOOK")==null,"A profile change to public suppresses the responder");
        Check(DiscoveryPeerService.BuildResponse(Request(),Endpoint("192.168.178.24",50101),16,Nets(Net(address:"192.168.178.21")),new DiscoveryPeerShare[0],"TEST-NOTEBOOK")==null,"An app with no confirmed own live shares makes no publication claim");

        DateTime time=DateTime.UtcNow; int reads=0;
        DiscoveryPeerShare[] native=new[]{new DiscoveryPeerShare{Name="Desktop",Remark="EinfachNetzwerk-v1"},new DiscoveryPeerShare{Name="Other",Remark="Foreign app"},Share("Ready")};
        using(DiscoveryPeerService service=new DiscoveryPeerService(()=>Nets(Net()),()=>{reads++;return native;},()=>time,"TEST-NOTEBOOK"))
        {
            Check(service.GetPublishedShares().Length==1,"A legacy marker without protected managed inventory cannot invent an account");
            service.UpdateInventory(new[]{new ShareItem{Name="Desktop",Managed=true,Available=true,Mode="Guest",UserName="Gast",Path="C:\\SECRET",AdapterId=16},new ShareItem{Name="Other",Managed=true,Available=true,Mode="Guest",UserName="Gast"},new ShareItem{Name="Missing",Managed=true,Available=true,Mode="Guest",UserName="Gast"}});
            DiscoveryPeerShare[] published=service.GetPublishedShares();
            Check(published.Length==2 && published.Any(s=>s.Name=="Desktop") && !published.Any(s=>s.Name=="Other"||s.Name=="Missing"),"A legacy preset is overlaid only for a matching live local disk share with the exact app marker");
            Check(!new JavaScriptSerializer().Serialize(published).Contains("SECRET"),"Local inventory paths never enter the responder's output");
            int before=reads; service.GetPublishedShares();Check(reads==before,"Local share metadata has a bounded five-second cache");
            time=time.AddSeconds(6);native=new DiscoveryPeerShare[0];
            Check(service.GetPublishedShares().Length==0 && reads==before+1,"Expired metadata is freshly queried and removed shares disappear");
            native=new[]{new DiscoveryPeerShare{Name="Desktop",Remark="EinfachNetzwerk-v1"}};
            service.UpdateInventory(new[]{new ShareItem{Name="Desktop",Managed=true,Available=false,Mode="Guest",UserName="Gast"}});
            Check(service.GetPublishedShares().Length==0,"Unavailable managed entries are not published");
            service.UpdateInventory(new[]{new ShareItem{Name="Desktop",Managed=false,Available=true,Mode="Guest",UserName="Gast"}});
            Check(service.GetPublishedShares().Length==0,"Unmanaged inventory cannot retrofit a legacy account hint");
        }
        using(ManualResetEvent release=new ManualResetEvent(false))
        using(DiscoveryPeerService delayed=new DiscoveryPeerService(()=>Nets(Net()),()=>{release.WaitOne();return new[]{Share()};},()=>time,"TEST-NOTEBOOK"))
        {var watch=System.Diagnostics.Stopwatch.StartNew();Check(delayed.GetPublishedShares().Length==0 && watch.ElapsedMilliseconds<1500,"A delayed native local query times out without stale shares or blocking the GUI");release.Set();}
        using(DiscoveryPeerService failed=new DiscoveryPeerService(()=>Nets(Net()),()=>{throw new InvalidOperationException("native query failed");},()=>time,"TEST-NOTEBOOK"))
            Check(failed.GetPublishedShares().Length==0,"A failed native local query cannot publish cached or assumed shares");

        int exchanges=0;
        Func<IList<NetworkItem>,string,CancellationToken,IEnumerable<DiscoveryPeerService.Datagram>> transport=(networks,key,token)=>{
            exchanges++; byte[] data=DiscoveryPeerService.BuildResponse(Request(key),Endpoint("192.168.178.24",50101),16,Nets(Net(address:"192.168.178.21")),new[]{Share()},"TEST-NOTEBOOK");
            return new[]{new DiscoveryPeerService.Datagram{Data=data,Sender=Endpoint()},new DiscoveryPeerService.Datagram{Data=data,Sender=Endpoint()}};
        };
        Check(DiscoveryPeerService.DiscoverCore(Nets(Net()),CancellationToken.None,()=>Nets(Net()),transport).Length==1,"Fake transport verifies nonce and deduplicates repeated peer replies");
        int previousExchanges=exchanges;
        Check(DiscoveryPeerService.DiscoverCore(Nets(Net()),CancellationToken.None,()=>Nets(Net("Public")),transport).Length==0 && exchanges==previousExchanges,"A caller-provided private profile is revalidated before sending");
        Check(DiscoveryPeerService.DiscoverCore(Nets(Net()),CancellationToken.None,()=>Nets(Net(id:17)),transport).Length==0 && exchanges==previousExchanges,"A changed interface cannot reuse an earlier scan scope");
        int refresh=0;
        Check(DiscoveryPeerService.DiscoverCore(Nets(Net()),CancellationToken.None,()=>Nets(Net(++refresh==1?"Private":"Public")),transport).Length==0,"A profile change while receiving invalidates pending advertisements");
        using(CancellationTokenSource cancelled=new CancellationTokenSource())
        {cancelled.Cancel();bool threw=false;try{DiscoveryPeerService.DiscoverCore(Nets(Net()),cancelled.Token,()=>Nets(Net()),transport);}catch(OperationCanceledException){threw=true;}Check(threw,"Cancelling a discovery does not accept late results");}
    }
}
'@
[IO.File]::WriteAllText($taskSource,$taskCode,(New-Object Text.UTF8Encoding($true)))
$taskCompiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $taskCompiler /nologo /target:exe /langversion:5 /reference:System.dll /reference:System.Core.dll /reference:System.Web.Extensions.dll ('/out:'+$taskExecutable) (Join-Path $PSScriptRoot '..\src\Models.cs') (Join-Path $PSScriptRoot '..\src\NativeHomeNetworks.cs') (Join-Path $PSScriptRoot '..\src\DiscoveryPeerService.cs') $taskSource
if($LASTEXITCODE -ne 0){throw 'Discovery peer test compilation failed.'}
& $taskExecutable
if($LASTEXITCODE -ne 0){throw 'Discovery peer tests failed.'}
