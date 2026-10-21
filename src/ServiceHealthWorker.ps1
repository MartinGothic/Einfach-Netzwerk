# Trusted embedded helper functions; local Service Control Manager only.
# No WMI/CIM dependency, no StopService, no service deletion/recreation.
function Load-ServiceHealthNative {
    if ('EinfachNetzwerk.NativeServiceHealth' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
namespace EinfachNetzwerk {
 public sealed class ServiceHealthSnapshot {
  public string Name="", State="", StartMode="";
  public bool Exists, Delayed;
  public uint StateValue, StartValue, Win32ExitCode, ServiceSpecificExitCode;
  public string[] Dependencies=new string[0];
 }
 public static class NativeServiceHealth {
  [StructLayout(LayoutKind.Sequential)] struct STATUS {
   public uint type,state,accepted,win32,specific,checkpoint,waitHint,processId,flags;
  }
  [StructLayout(LayoutKind.Sequential)] struct CONFIG {
   public uint type,start,error; public IntPtr binary,group; public uint tag;
   public IntPtr dependencies,account,display;
  }
  [StructLayout(LayoutKind.Sequential)] struct DELAYED { [MarshalAs(UnmanagedType.Bool)] public bool delayed; }
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenSCManager(string machine,string database,uint access);
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenService(IntPtr scm,string name,uint access);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool CloseServiceHandle(IntPtr handle);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool QueryServiceStatusEx(IntPtr service,int level,out STATUS status,uint size,out uint needed);
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryServiceConfig(IntPtr service,IntPtr config,uint size,out uint needed);
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryServiceConfig2(IntPtr service,uint level,IntPtr config,uint size,out uint needed);
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ChangeServiceConfig(IntPtr service,uint type,uint start,uint error,string binary,string group,IntPtr tag,string dependencies,string account,string password,string display);
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool ChangeServiceConfig2(IntPtr service,uint level,ref DELAYED config);
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool StartService(IntPtr service,uint argc,IntPtr argv);
  static void Fail(string name,int code) { throw new Win32Exception(code,name+": "+new Win32Exception(code).Message); }
  static void Allowed(string name) {
   if(name!="LanmanServer" && name!="LanmanWorkstation" && name!="FDResPub" && name!="fdPHost") throw new ArgumentException("Nicht unterstützter Netzwerkdienst.");
  }
  static IntPtr Manager() { IntPtr scm=OpenSCManager(null,null,1);if(scm==IntPtr.Zero) Fail("Service Control Manager",Marshal.GetLastWin32Error());return scm; }
  static STATUS Status(IntPtr service,string name) {
   STATUS status;uint needed;
   if(!QueryServiceStatusEx(service,0,out status,(uint)Marshal.SizeOf(typeof(STATUS)),out needed)) Fail(name,Marshal.GetLastWin32Error());
   return status;
  }
  static string State(uint value) { string[] values={"Unknown","Stopped","StartPending","StopPending","Running","ContinuePending","PausePending","Paused"}; return value<values.Length?values[value]:"Unknown"; }
  public static ServiceHealthSnapshot Read(string name) {
   if(String.IsNullOrEmpty(name) || name.IndexOfAny(new char[]{'\\','/','\0'})>=0) throw new ArgumentException("Ungültiger Dienstname.");
   IntPtr scm=Manager(),service=IntPtr.Zero,buffer=IntPtr.Zero,delay=IntPtr.Zero;
   try {
    service=OpenService(scm,name,1|4);
    if(service==IntPtr.Zero) {
     int code=Marshal.GetLastWin32Error(); if(code==1060) return new ServiceHealthSnapshot {Name=name,Exists=false,State="Missing",StartMode="Unknown",Win32ExitCode=1060};
     Fail(name,code);
    }
    STATUS status=Status(service,name);uint size;
    QueryServiceConfig(service,IntPtr.Zero,0,out size);
    int queryCode=Marshal.GetLastWin32Error();
    if(queryCode!=122 || size==0 || size>8192) Fail(name,queryCode==0?13:queryCode);
    buffer=Marshal.AllocHGlobal((int)size);
    if(!QueryServiceConfig(service,buffer,size,out size)) Fail(name,Marshal.GetLastWin32Error());
    CONFIG config=(CONFIG)Marshal.PtrToStructure(buffer,typeof(CONFIG));
    var dependencies=new List<string>();IntPtr next=config.dependencies;
    if(next!=IntPtr.Zero) {
     int consumed=0;
     while(Marshal.ReadInt16(next)!=0 && consumed<8192) {
      string value=Marshal.PtrToStringUni(next); if(value==null) break;
      dependencies.Add(value);int bytes=(value.Length+1)*2; consumed+=bytes;next=IntPtr.Add(next,bytes);
     }
    }
    bool delayed=false;
    // Kernel/filesystem dependencies (Srv2/SrvNet) have no delayed-auto flag.
    if((config.type & 0x30)!=0) {
     delay=Marshal.AllocHGlobal(4);
     if(!QueryServiceConfig2(service,3,delay,4,out size)) Fail(name,Marshal.GetLastWin32Error());
     delayed=Marshal.ReadInt32(delay)!=0;
    }
    string start=config.start==0?"Boot":config.start==1?"System":config.start==2?"Auto":config.start==3?"Manual":config.start==4?"Disabled":"Unknown";
    return new ServiceHealthSnapshot {Name=name,Exists=true,State=State(status.state),StateValue=status.state,
      StartMode=start,StartValue=config.start,Delayed=delayed,Win32ExitCode=status.win32,ServiceSpecificExitCode=status.specific,Dependencies=dependencies.ToArray()};
   } finally {if(delay!=IntPtr.Zero) Marshal.FreeHGlobal(delay);if(buffer!=IntPtr.Zero) Marshal.FreeHGlobal(buffer);if(service!=IntPtr.Zero) CloseServiceHandle(service);CloseServiceHandle(scm);}
  }
  public static void SetStart(string name,uint start,bool delayed) {
   Allowed(name);if(start<2 || start>4 || (delayed && start!=2)) throw new ArgumentException("Ungültiger Dienststarttyp.");
   ServiceHealthSnapshot before=Read(name);if(!before.Exists) Fail(name,1060);
   IntPtr scm=Manager(),service=IntPtr.Zero;
   try {
    service=OpenService(scm,name,2|1);if(service==IntPtr.Zero) Fail(name,Marshal.GetLastWin32Error());
    ApplyStartOwned(before,start,delayed,delegate {return Read(name);},delegate(uint value) {
      if(!ChangeServiceConfig(service,0xffffffff,value,0xffffffff,null,null,IntPtr.Zero,null,null,null,null)) Fail(name,Marshal.GetLastWin32Error());
    },delegate(bool value) {
      var information=new DELAYED {delayed=value};if(!ChangeServiceConfig2(service,3,ref information)) Fail(name,Marshal.GetLastWin32Error());
    });
   } finally {if(service!=IntPtr.Zero) CloseServiceHandle(service);CloseServiceHandle(scm);}
  }
  static bool Pair(ServiceHealthSnapshot value,uint start,bool delayed) { return value.Exists && value.StartValue==start && value.Delayed==delayed; }
  static void RequirePair(Func<ServiceHealthSnapshot> read,uint start,bool delayed) {
   if(!Pair(read(),start,delayed)) throw new InvalidOperationException("Der Dienststarttyp wurde zwischenzeitlich verändert. Die fremde Änderung bleibt erhalten.");
  }
  // Config and delayed-start are separate SCM calls. Track every own interim
  // pair so failure of the second call does not leave the first change behind.
  // Test doubles exercise this exact transaction without touching real SCM.
  internal static void ApplyStartOwned(ServiceHealthSnapshot before,uint start,bool delayed,
      Func<ServiceHealthSnapshot> read,Action<uint> writeStart,Action<bool> writeDelayed) {
   uint ownStart=before.StartValue;bool ownDelayed=before.Delayed;
   var owned=new List<ServiceHealthSnapshot>();
   try {
    if(ownStart==2 && ownDelayed && start!=2) {
     RequirePair(read,ownStart,ownDelayed);
     owned.Add(new ServiceHealthSnapshot {Exists=true,StartValue=ownStart,Delayed=false});
     writeDelayed(false);ownDelayed=false;
    }
    if(ownStart!=start) {
     RequirePair(read,ownStart,ownDelayed);
     owned.Add(new ServiceHealthSnapshot {Exists=true,StartValue=start,Delayed=ownDelayed});
     writeStart(start);ownStart=start;
    }
    if(start==2 && ownDelayed!=delayed) {
     RequirePair(read,ownStart,ownDelayed);
     owned.Add(new ServiceHealthSnapshot {Exists=true,StartValue=ownStart,Delayed=delayed});
     writeDelayed(delayed);ownDelayed=delayed;
    }
    RequirePair(read,start,delayed);
   } catch(Exception failure) {
    try {
     ServiceHealthSnapshot actual=read();bool own=false;
     foreach(ServiceHealthSnapshot item in owned) {if(Pair(actual,item.StartValue,item.Delayed)) {own=true;break;}}
     if(!Pair(actual,before.StartValue,before.Delayed) && own) {
      uint currentStart=actual.StartValue;bool currentDelayed=actual.Delayed;
      if(currentStart==2 && currentDelayed && before.StartValue!=2) {
       RequirePair(read,currentStart,currentDelayed);writeDelayed(false);currentDelayed=false;
      }
      if(currentStart!=before.StartValue) {
       RequirePair(read,currentStart,currentDelayed);writeStart(before.StartValue);currentStart=before.StartValue;
      }
      if(before.StartValue==2 && currentDelayed!=before.Delayed) {
       RequirePair(read,currentStart,currentDelayed);writeDelayed(before.Delayed);currentDelayed=before.Delayed;
      }
      RequirePair(read,before.StartValue,before.Delayed);
     }
     // Unknown pairs are deliberately untouched. Only a state written by this
     // exact transaction is eligible for compensating configuration changes.
    } catch(Exception rollback) {
     throw new AggregateException("Die eigene teilweise Dienststarttypänderung konnte nicht vollständig zurückgenommen werden.",failure,rollback);
    }
    throw;
   }
  }
  public static void EnsureRunning(string name,int milliseconds) {
   Allowed(name);if(milliseconds<1000 || milliseconds>30000) throw new ArgumentException("Ungültiges Dienst-Zeitlimit.");
   IntPtr scm=Manager(),service=IntPtr.Zero;var deadline=Stopwatch.StartNew();bool startSent=false;
   try {
    service=OpenService(scm,name,0x10|4);if(service==IntPtr.Zero) Fail(name,Marshal.GetLastWin32Error());
    while(true) {
     STATUS status=Status(service,name);
     if(status.state==4) return;
     if(status.state==1) {
      if(startSent) Fail(name,status.win32==0?1067:(int)status.win32);
      if(!StartService(service,0,IntPtr.Zero)) {int code=Marshal.GetLastWin32Error();if(code!=1056) Fail(name,code);}
      startSent=true;
     } else if(status.state==7 || status.state==6 || status.state==5) {
      // Never restart/stop a running or paused service just to hide the fault.
      Fail(name,1061);
     }
     if(deadline.ElapsedMilliseconds>=milliseconds) Fail(name,1053);
     Thread.Sleep(200);
    }
   } finally {if(service!=IntPtr.Zero) CloseServiceHandle(service);CloseServiceHandle(scm);}
  }
 }
}
'@
}
function Get-ServiceNativeSnapshot([string]$Name) {
    Load-ServiceHealthNative
    return [EinfachNetzwerk.NativeServiceHealth]::Read($Name)
}
function Set-ServiceNativeStart([string]$Name, [int]$StartValue, [bool]$Delayed) {
    Load-ServiceHealthNative
    [EinfachNetzwerk.NativeServiceHealth]::SetStart($Name, [uint32]$StartValue, $Delayed)
}
function Start-ServiceNative([string]$Name) {
    Load-ServiceHealthNative
    [EinfachNetzwerk.NativeServiceHealth]::EnsureRunning($Name, 20000)
}
function Get-ServiceHealthNames { return @('LanmanServer','LanmanWorkstation','FDResPub','fdPHost') }
function Get-ServiceRepairUserSid { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
function Assert-ServiceRepairIdentity($Request) {
    if ([string](Get-Value $Request 'OriginalUserSid' '') -ne (Get-ServiceRepairUserSid)) { throw 'Die Dienstereparatur muss im ursprünglichen Windows-Benutzerkonto ausgeführt werden.' }
}
function Get-ServiceFailureNumber([Management.Automation.ErrorRecord]$Failure) {
    $exception=$Failure.Exception; $depth=0
    while ($null -ne $exception -and $depth -lt 16) {
        if ($exception -is [ComponentModel.Win32Exception]) { return [int]$exception.NativeErrorCode }
        $exception=$exception.InnerException; $depth++
    }
    return 0
}
function Get-ServiceFailureGuidance([int]$Code) {
    switch ($Code) {
        2114 { return 'Der lokale Serverdienst läuft nicht. Die Dienstereparatur startet ihn und prüft anschließend SMB-Port 445.' }
        1058 { return 'Der benötigte Netzwerkdienst ist deaktiviert. Die Dienstereparatur sichert seinen Starttyp und aktiviert ausschließlich diesen Netzwerkdienst.' }
        1068 { return 'Ein abhängiger Windows-Dienst oder Treiber konnte nicht starten. Die Abhängigkeiten werden einzeln angezeigt; fremde Systemdienste werden nicht umkonfiguriert.' }
        1075 { return 'Eine eingetragene Dienstabhängigkeit fehlt oder wurde zum Löschen markiert. Prüfe die angezeigte Abhängigkeit und exportiere den Fehlerbericht.' }
        1069 { return 'Die Dienstanmeldung ist fehlerhaft. Das Programm ersetzt keine Dienstkonten oder deren Passwörter. Exportiere den Bericht für eine gezielte Windows-Reparatur.' }
        1053 { return 'Windows hat den Dienst nicht rechtzeitig gestartet. Der tatsächliche Dienststatus wird erneut gelesen. Bei weiter bestehendem Fehler den Bericht exportieren und Windows nach dem Speichern neu starten.' }
        1060 { return 'Der Windows-Dienst fehlt. Unterstützte Erkennungsdienste können aus geprüften Windows-Originalen wiederhergestellt werden. Ein fehlender Serverdienst wird nicht neu angelegt; sein vorhandener ServiceDll-Eintrag kann gezielt repariert werden.' }
        1072 { return 'Windows hat den Dienst zum Löschen markiert. Speichere deine Arbeit und starte Windows selbst neu; das Programm erzwingt keinen Neustart.' }
        1066 { return 'Der Dienst meldet einen eigenen Fehlercode. Dieser Code und seine Abhängigkeiten stehen im Fehlerbericht.' }
        2 { return 'Windows findet eine benötigte Datei oder Dienstkonfiguration nicht. Die erweiterte Reparatur prüft fehlende Originaleinträge; beschädigte Systemdateien werden im Bericht ausgewiesen.' }
        5 { return 'Die Dienstereparatur braucht Administratorrechte desselben Windows-Benutzers. Verwaltete Windows-Richtlinien werden nicht übergangen.' }
        default { return 'Lies den genauen Windows-Fehlercode und exportiere den Bericht. Laufende Dienste bleiben erhalten; ein fehlgeschlagener Start wird nicht als Erfolg angezeigt.' }
    }
}
function Get-ServerServiceMetadataJson { return [EinfachNetzwerk.ServiceConfigurationRecovery]::ReadServerMetadataJson() }
function Get-ServerServiceOriginalPlan { return ([EinfachNetzwerk.ServiceConfigurationRecovery]::GetPlanJson('LanmanServer') | ConvertFrom-Json) }
function Repair-ServerServiceMetadata { $null=[EinfachNetzwerk.ServiceConfigurationRecovery]::Repair('LanmanServer') }
function Restore-ServerServiceMetadata([string]$Before, [string]$Expected) { return ([EinfachNetzwerk.ServiceConfigurationRecovery]::RestoreServerMetadataJson($Before,$Expected) | ConvertFrom-Json) }
function Test-ServiceMetadataValueSame($First, $Second) {
    if ($null -eq $First -or $null -eq $Second -or [bool]$First.Exists -ne [bool]$Second.Exists) { return $false }
    if (-not [bool]$First.Exists) { return $true }
    if ([string]$First.Kind -cne [string]$Second.Kind) { return $false }
    switch ([string]$First.Kind) {
        { $_ -in @('String','ExpandString') } { return ([string]$First.Text -ceq [string]$Second.Text) }
        'MultiString' { return ((ConvertTo-Json -InputObject @($First.Strings) -Compress) -ceq (ConvertTo-Json -InputObject @($Second.Strings) -Compress)) }
        { $_ -in @('DWord','QWord') } { return ([long]$First.Number -eq [long]$Second.Number) }
        default { return ([string]$First.Binary -ceq [string]$Second.Binary) }
    }
}
function Test-ServiceMetadataJsonSame([string]$First, [string]$Second) {
    $one=$First | ConvertFrom-Json; $two=$Second | ConvertFrom-Json
    foreach ($name in @('ServiceDll','ServiceDllUnloadOnStop')) {
        $firstValue=@($one.Values | Where-Object {$_.Name -eq $name})
        $secondValue=@($two.Values | Where-Object {$_.Name -eq $name})
        if ($firstValue.Count -ne 1 -or $secondValue.Count -ne 1 -or -not (Test-ServiceMetadataValueSame $firstValue[0] $secondValue[0])) { return $false }
    }
    return $true
}
function Get-ServiceMetadataExpected([string]$Before, $Plan) {
    if ([string]$Plan.Name -ne 'LanmanServer' -or @($Plan.RegistryValues).Count -ne 2) { throw 'Die Windows-Originalkonfiguration enthält keine gültige gezielte Serverdienstreparatur.' }
    $snapshot=$Before | ConvertFrom-Json; $snapshot.ParametersKeyExists=$true
    foreach ($name in @('ServiceDll','ServiceDllUnloadOnStop')) {
        $planned=@($Plan.RegistryValues | Where-Object { $_.Name -eq $name -and $_.Path -eq 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' })
        $value=@($snapshot.Values | Where-Object {$_.Name -eq $name})
        if ($planned.Count -ne 1 -or $value.Count -ne 1) { throw 'Die Windows-Originalkonfiguration enthält fremde oder doppelte Serverdienstwerte.' }
        $value[0].Exists=$true; $value[0].Kind=[string]$planned[0].Kind
        if ($name -eq 'ServiceDll') { $value[0].Text=[string]$planned[0].Value }
        else { $value[0].Number=[long]$planned[0].Value }
    }
    return (ConvertTo-Json -InputObject $snapshot -Depth 10 -Compress)
}
function Test-ServerServiceMetadataNeedsRepair([string]$Metadata) {
    $snapshot=$Metadata | ConvertFrom-Json
    $dll=@($snapshot.Values | Where-Object {$_.Name -eq 'ServiceDll'})
    $unload=@($snapshot.Values | Where-Object {$_.Name -eq 'ServiceDllUnloadOnStop'})
    if ($dll.Count -ne 1 -or $unload.Count -ne 1 -or -not $dll[0].Exists -or -not $unload[0].Exists) { return $true }
    if ($dll[0].Kind -notin @('String','ExpandString') -or $unload[0].Kind -ne 'DWord' -or [long]$unload[0].Number -ne 1) { return $true }
    try {
        $expected=[IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('System')) 'srvsvc.dll'))
        $actual=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$dll[0].Text))
        return ($actual -ine $expected)
    } catch { return $true }
}
function Assert-ServiceOriginalFiles($Plan) {
    foreach ($file in @($Plan.DllPath,(Join-Path ([Environment]::GetFolderPath('System')) 'svchost.exe'))) {
        $signature=Get-AuthenticodeSignature -LiteralPath $file -ErrorAction Stop
        if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') { throw 'Die originale Microsoft-Datei des Serverdiensts konnte nicht verifiziert werden. Es wird keine fremde Dienstdatei geladen.' }
    }
}
function Get-ServiceHealthNetworks {
    # The Service Control Manager and native network APIs remain available when
    # the WMI-backed SMB/network PowerShell providers are stalled.
    $items=[EinfachNetzwerk.NativeHomeNetworks]::ReadJson() | ConvertFrom-Json
    # Windows PowerShell 5.1 emits a JSON array as one pipeline object. Unroll
    # it explicitly so Networks remains NetworkItem[], including 0/1/N items.
    foreach ($item in $items) { $item }
}
function Resolve-ServiceHealthNetwork($Request) {
    $all=@(Get-ServiceHealthNetworks)
    $script:Result.Networks=$all
    $matches=@($all | Where-Object { $_.Category -eq 'Private' })
    $adapter=[int](Get-Value $Request 'AdapterId' -1)
    if ($adapter -gt 0) { $matches=@($matches | Where-Object { $_.Id -eq $adapter }) }
    if ($matches.Count -ne 1) { throw 'Bitte genau eine aktive private LAN/WLAN-Verbindung auswählen. Für die Dienstereparatur werden keine VPN-, Domänen- oder öffentlichen Netze verwendet.' }
    $script:Result.Address=[string]$matches[0].Address
    return $matches[0]
}
function Test-ServiceHealthPort([string]$Address) {
    $tcp=New-Object Net.Sockets.TcpClient
    try {
        $pending=$tcp.BeginConnect($Address,445,$null,$null)
        try { if (-not $pending.AsyncWaitHandle.WaitOne(3000)) { return $false }; $tcp.EndConnect($pending); return $tcp.Connected }
        catch { return $false }
        finally { $pending.AsyncWaitHandle.Close() }
    } finally { $tcp.Close() }
}
function Get-ServiceHealthJournalPath { return (Join-Path $script:LedgerRoot 'service-state.json') }
function Read-ServiceHealthJournal {
    $path=Get-ServiceHealthJournalPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    Assert-LedgerProtection
    Assert-NoReparse $path
    $record=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([string](Get-Value $record 'App' '') -ne $script:AppMark -or [int](Get-Value $record 'Version' 0) -ne 1 -or [string](Get-Value $record 'Action' '') -ne 'RepairServices') { throw 'Das Dienstereparaturjournal ist unbekannt oder beschädigt. Es werden keine Starttypen verändert.' }
    if ([string](Get-Value $record 'Status' '') -notin @('Prepared','Committed','Restored','Failed')) { throw 'Das Dienstereparaturjournal enthält keinen gültigen Änderungsstatus.' }
    $changes=@(Get-Value $record 'Changes' @()); $configurations=@(Get-Value $record 'Configurations' @()); $names=@()
    if (($changes.Count + $configurations.Count) -lt 1 -or $changes.Count -gt 4 -or $configurations.Count -gt 1) { throw 'Das Dienstereparaturjournal enthält unbekannte Einstellungen.' }
    foreach ($change in $changes) {
        if ([string](Get-Value $change 'Name' '') -notin @(Get-ServiceHealthNames) -or $change.Name -in $names) { throw 'Das Dienstereparaturjournal enthält einen fremden oder mehrfach eingetragenen Dienst.' }
        $names+=@($change.Name)
        foreach ($part in @('Before','Expected')) {
            $value=Get-Value $change $part
            if ($null -eq $value -or (Get-Value $value 'StartValue') -isnot [int] -or $value.StartValue -notin @(2,3,4) -or (Get-Value $value 'Delayed') -isnot [bool] -or ($value.Delayed -and $value.StartValue -ne 2)) { throw 'Das Dienstereparaturjournal enthält einen ungültigen Starttyp.' }
        }
        if ([string](Get-Value $change 'Status' '') -notin @('Prepared','Applied','Restored','ExternalChange')) { throw 'Das Dienstereparaturjournal enthält einen ungültigen Dienststatus.' }
    }
    foreach ($configuration in $configurations) {
        if ([string](Get-Value $configuration 'Name' '') -ne 'LanmanServerMetadata' -or [string](Get-Value $configuration 'Status' '') -notin @('Prepared','Applied','Restored','ExternalChange')) { throw 'Das Dienstereparaturjournal enthält eine fremde Serverdienstkonfiguration.' }
        foreach ($part in @('Before','Expected')) {
            $text=Get-Value $configuration $part
            if ($text -isnot [string] -or [string]::IsNullOrWhiteSpace($text) -or $text.Length -gt 262144) { throw 'Die gespeicherte Serverdienstkonfiguration hat ein ungültiges Format.' }
            $data=$text | ConvertFrom-Json
            if ((Get-Value $data 'ParametersKeyExists') -isnot [bool] -or @(Get-Value $data 'Values' @()).Count -ne 2) { throw 'Die gespeicherte Serverdienstkonfiguration enthält unbekannte Werte.' }
            foreach ($name in @('ServiceDll','ServiceDllUnloadOnStop')) {
                $entries=@($data.Values | Where-Object {$_.Name -eq $name})
                if ($entries.Count -ne 1 -or (Get-Value $entries[0] 'Exists') -isnot [bool]) { throw 'Die gespeicherte Serverdienstkonfiguration enthält fremde oder doppelte Werte.' }
            }
        }
    }
    return $record
}
function Publish-ServiceHealthRestoreState {
    $script:Result.ServiceRepairAvailable=$false; $script:Result.ServiceBackupPath=''
    try {
        $journal=Read-ServiceHealthJournal
        if ($null -ne $journal -and (@($journal.Changes | Where-Object { $_.Status -in @('Prepared','Applied') }).Count + @(Get-Value $journal 'Configurations' @() | Where-Object { $_.Status -in @('Prepared','Applied') }).Count) -gt 0) {
            $script:Result.ServiceRepairAvailable=$true; $script:Result.ServiceBackupPath=Get-ServiceHealthJournalPath
        }
    } catch { Add-Check 'Dienstereparaturjournal' warning $_.Exception.Message 'SERVICE_JOURNAL_INVALID' $false 'Prüfen und Starten bleiben möglich. Ein beschädigtes Änderungsjournal muss vor neuen Starttypänderungen durch die Administration geprüft werden.' }
}
function Add-ServiceDependencyChecks($Service) {
    foreach ($dependency in @($Service.Dependencies)) {
        if ([string]::IsNullOrWhiteSpace([string]$dependency)) { continue }
        if ($dependency.StartsWith('+')) { Add-Check ('Abhängigkeit von ' + $Service.Name) info $dependency 'SERVICE_DEPENDENCY_GROUP' $false 'Windows verwaltet diese Dienstgruppe selbst. Das Programm ändert keine Treiber- oder Gruppenstarttypen.'; continue }
        try {
            $state=Get-ServiceNativeSnapshot $dependency
            $status='warning'; if ($state.Exists -and $state.State -eq 'Running') { $status='ok' }
            $code='SERVICE_DEPENDENCY_STATE'; if (-not $state.Exists) { $code='Win32: 1060' }
            Add-Check ('Abhängigkeit von ' + $Service.Name) $status ($dependency + ': ' + $state.State + '; Start: ' + $state.StartMode) $code $false 'Windows startet die eingetragenen Abhängigkeiten selbst. Ihre Konfiguration wird nicht automatisch verändert.'
        } catch { Add-Check ('Abhängigkeit von ' + $Service.Name) warning ($dependency + ': ' + $_.Exception.Message) ('Win32: ' + (Get-ServiceFailureNumber $_)) $false 'Die Abhängigkeit konnte nicht gelesen werden. Der ursprüngliche Fehler bleibt im Bericht erhalten.' }
    }
}
function Add-LocalServiceHealthChecks($Request=$null, $Network=$null) {
    $script:Result.ServiceHealthVerified=$false
    $script:Result.ConnectionVerified=$false; $script:Result.NativeConnectionVerified=$false
    Publish-ServiceHealthRestoreState
    $running=$true; $metadataReady=$true; $snapshots=New-Object 'System.Collections.Generic.List[object]'; $firstCode=''
    foreach ($name in @(Get-ServiceHealthNames)) {
        try {
            $service=Get-ServiceNativeSnapshot $name; $snapshots.Add($service)
            $state='ok'; $code='SERVICE_RUNNING'; $fix=$false; $next=''
            if (-not $service.Exists -or $service.State -ne 'Running') {
                $running=$false; $state='error'; $fix=$true
                $number=[int]$service.Win32ExitCode
                if (-not $service.Exists) { $number=1060 }
                elseif ($service.StartMode -eq 'Disabled') { $number=1058 }
                elseif ($number -eq 0 -and $name -eq 'LanmanServer' -and $service.State -eq 'Stopped') { $number=2114 }
                $code='SERVICE_STOPPED'; if ($number -ne 0) { $code='Win32: ' + $number }
                $next=Get-ServiceFailureGuidance $number
                if ($number -eq 1072) { $script:Result.RestartRequired=$true }
                if ([string]::IsNullOrEmpty($firstCode)) { $firstCode=$code }
            }
            $detail=$service.State + '; Start: ' + $service.StartMode + '; Windows-Code: ' + $service.Win32ExitCode + '; Dienst-Code: ' + $service.ServiceSpecificExitCode
            Add-Check $name $state $detail $code $fix $next
            if ($state -ne 'ok') { Add-ServiceDependencyChecks $service }
            if ($name -eq 'LanmanServer' -and $service.Exists) {
                try {
                    $metadata=Get-ServerServiceMetadataJson
                    if (Test-ServerServiceMetadataNeedsRepair $metadata) {
                        $metadataReady=$false
                        Add-Check 'Konfiguration des Serverdiensts' error 'ServiceDll oder ServiceDllUnloadOnStop fehlt oder entspricht nicht der benötigten Windows-Originalkonfiguration.' 'SERVICE_SERVER_METADATA_INVALID' $true 'Die erweiterte Dienstereparatur ergänzt ausschließlich geprüfte Originaleinträge dieses Windows. Bestehende Freigaben und SMB-Sicherheitsregeln bleiben erhalten.'
                        if ([string]::IsNullOrEmpty($firstCode)) { $firstCode='SERVICE_SERVER_METADATA_INVALID' }
                    } else { Add-Check 'Konfiguration des Serverdiensts' ok 'Die benötigten Serverdienst-Einträge sind vorhanden.' 'SERVICE_SERVER_METADATA_PRESENT' }
                } catch { $metadataReady=$false; Add-Check 'Konfiguration des Serverdiensts' warning $_.Exception.Message 'SERVICE_SERVER_METADATA_QUERY_FAILED' $false 'Die benötigten Serverdienst-Einträge konnten nicht gelesen werden. Bitte den Bericht exportieren.'; if ([string]::IsNullOrEmpty($firstCode)) { $firstCode='SERVICE_SERVER_METADATA_QUERY_FAILED' } }
            }
        } catch {
            $running=$false; $code='SERVICE_QUERY_FAILED'; $number=Get-ServiceFailureNumber $_
            if ($number -gt 0) { $code='Win32: ' + $number }
            if ([string]::IsNullOrEmpty($firstCode)) { $firstCode=$code; Set-FailureDetails $_ }
            Add-Check $name error $_.Exception.Message $code $false (Get-ServiceFailureGuidance $number)
        }
    }
    if ($null -eq $Network) {
        try { $Network=Resolve-ServiceHealthNetwork $Request }
        catch { Add-Check 'Heimnetz für Diensteprüfung' warning $_.Exception.Message 'SERVICE_PRIVATE_NETWORK_REQUIRED' $false 'Eine aktive private LAN/WLAN-Verbindung auswählen und erneut prüfen.' }
    }
    $port=$false
    if ($null -ne $Network) {
        $port=Test-ServiceHealthPort ([string]$Network.Address)
        if ($port) { Add-Check 'Lokaler SMB-Port 445' ok ($Network.Address + ':445 antwortet auf diesem PC.') 'SERVICE_LOCAL_PORT_READY' }
        else { Add-Check 'Lokaler SMB-Port 445' error ($Network.Address + ':445 antwortet auf diesem PC nicht.') 'SERVICE_LOCAL_PORT_CLOSED' $true 'Zuerst den lokalen Serverdienst reparieren. Bleibt der Port danach geschlossen, die Freigabenprüfung für Firewall und SMB ausführen; keine Sicherheitssoftware pauschal ausschalten.'; if ([string]::IsNullOrEmpty($firstCode)) { $firstCode='SERVICE_LOCAL_PORT_CLOSED' } }
    } elseif ([string]::IsNullOrEmpty($firstCode)) { $firstCode='SERVICE_PRIVATE_NETWORK_REQUIRED' }
    $script:Result.ServiceHealthVerified=$running -and $port -and $metadataReady
    if (-not $script:Result.ServiceHealthVerified -and [string]::IsNullOrEmpty([string]$script:Result.ErrorCode)) { $script:Result.ErrorCode=$firstCode; $script:Result.ErrorType='WindowsServiceHealth' }
    return [pscustomobject]@{ Services=@($snapshots.ToArray()); Network=$Network; Running=$running; PortReady=$port; MetadataReady=$metadataReady; Verified=($running -and $port -and $metadataReady) }
}
function Invoke-InspectLocalServices($Request) {
    Write-Phase 'Lokale Windows-Netzwerkdienste direkt über Windows prüfen …'
    $health=Add-LocalServiceHealthChecks $Request
    $script:Result.Success=$health.Verified
    if ($health.Verified) { $script:Result.Message='Die lokalen Netzwerkdienste laufen und SMB-Port 445 antwortet auf diesem PC. Der Zugriff eines anderen Geräts muss separat geprüft werden.' }
    else { $script:Result.Message='Die lokalen Netzwerkdienste sind noch nicht bereit. Die genaue Ursache und passende Reparatur stehen in der Prüfung.' }
    foreach ($step in @('service-validation','service-snapshot','service-start','service-verification')) { Complete-WorkStep $step }
}
function Set-ServiceStartOwned($Change, [bool]$Restore=$false) {
    $desired=$Change.Expected; if ($Restore) { $desired=$Change.Before }
    Set-ServiceNativeStart $Change.Name ([int]$desired.StartValue) ([bool]$desired.Delayed)
    $verify=Get-ServiceNativeSnapshot $Change.Name
    if (-not $verify.Exists -or [int]$verify.StartValue -ne [int]$desired.StartValue -or [bool]$verify.Delayed -ne [bool]$desired.Delayed) { throw ('Der Starttyp von ' + $Change.Name + ' wurde von Windows nicht vollständig übernommen.') }
}
function Undo-ServiceStartChanges($Changes, $Journal) {
    foreach ($change in @($Changes)) {
        try {
            $current=Get-ServiceNativeSnapshot $change.Name
            if (-not $current.Exists -or [int]$current.StartValue -ne [int]$change.Expected.StartValue -or [bool]$current.Delayed -ne [bool]$change.Expected.Delayed) {
                $change.Status='ExternalChange'
                Add-Check 'Dienststarttyp beibehalten' warning ($change.Name + ': Der Starttyp wurde zwischenzeitlich verändert und bleibt erhalten.') 'SERVICE_EXTERNAL_CHANGE' $false 'Fremde Änderungen werden nicht überschrieben.'
                continue
            }
            Set-ServiceStartOwned $change $true; $change.Status='Restored'
            Add-Check 'Dienststarttyp zurückgenommen' ok $change.Name 'SERVICE_START_ROLLED_BACK' $false 'Bereits laufende Dienste bleiben gestartet. Das Programm beendet keine laufenden Netzwerkverbindungen.'
        } catch { Add-Check 'Dienststarttyp zurücknehmen' error ($change.Name + ': ' + $_.Exception.Message) ('Win32: ' + (Get-ServiceFailureNumber $_)) $false 'Der Starttyp konnte nicht vollständig zurückgenommen werden. Das Journal bleibt für eine spätere gezielte Rücknahme erhalten.' }
    }
    if ($null -ne $Journal) { Write-JsonAtomic (Get-ServiceHealthJournalPath) $Journal }
}
function Undo-ServiceMetadataChanges($Configurations, $Journal) {
    foreach ($configuration in @($Configurations)) {
        try {
            $outcome=Restore-ServerServiceMetadata ([string]$configuration.Before) ([string]$configuration.Expected)
            if (Test-ServiceMetadataJsonSame (Get-ServerServiceMetadataJson) ([string]$configuration.Before)) {
                $configuration.Status='Restored'
                Add-Check 'Serverdienstkonfiguration zurückgenommen' ok 'Die eigenen Änderungen an ServiceDll und ServiceDllUnloadOnStop wurden zurückgenommen. Laufende Dienste bleiben erhalten.' 'SERVICE_METADATA_RESTORED'
            } elseif (@($outcome.Preserved).Count -gt 0) {
                $configuration.Status='ExternalChange'
                Add-Check 'Serverdienstkonfiguration beibehalten' warning ('Zwischenzeitlich fremd geändert: ' + (@($outcome.Preserved) -join ', ')) 'SERVICE_METADATA_EXTERNAL_CHANGE' $false 'Fremde Dienstkonfiguration wird nicht überschrieben.'
            } else { throw 'Windows bestätigt die zurückgenommene Serverdienstkonfiguration noch nicht.' }
        } catch { Add-Check 'Serverdienstkonfiguration zurücknehmen' error $_.Exception.Message 'SERVICE_METADATA_RESTORE_FAILED' $false 'Die geschützte Sicherung bleibt für eine spätere gezielte Rücknahme erhalten.' }
    }
    if ($null -ne $Journal) { Write-JsonAtomic (Get-ServiceHealthJournalPath) $Journal }
}
function Invoke-RepairLocalServices($Request) {
    $network=Resolve-ServiceHealthNetwork $Request
    Write-Phase 'Vor der Reparatur die lokalen Netzwerkdienste prüfen …'
    $baselineStart=$script:Checks.Count
    $health=Add-LocalServiceHealthChecks $Request $network
    Complete-WorkStep 'service-validation'
    if ($health.Verified) {
        $script:Result.Success=$true; $script:Result.Message='Die lokalen Netzwerkdienste und SMB-Port 445 funktionieren bereits. Es wurden keine Windows-Einstellungen geändert.'
        foreach ($step in @('service-snapshot','service-start','service-verification')) { Complete-WorkStep $step }; return
    }
    $changes=New-Object 'System.Collections.Generic.List[object]'
    foreach ($service in @($health.Services)) {
        if (-not $service.Exists) { continue }
        if ($service.StartValue -notin @(2,3,4)) { throw ('Der Starttyp von ' + $service.Name + ' ist unbekannt. Es wird keine Systemkonfiguration übergangen.') }
        $expected=[int]$service.StartValue
        if ($service.Name -in @('LanmanServer','LanmanWorkstation','FDResPub')) { $expected=2 }
        elseif ($service.StartMode -eq 'Disabled') { $expected=3 }
        # Preserve a valid delayed-auto choice, unless leaving automatic mode.
        $delayed=[bool]$service.Delayed; if ($expected -ne 2) { $delayed=$false }
        if ([int]$service.StartValue -ne $expected -or [bool]$service.Delayed -ne $delayed) {
            $changes.Add([pscustomobject]@{ Name=$service.Name; Before=[pscustomobject]@{StartValue=[int]$service.StartValue;Delayed=[bool]$service.Delayed}; Expected=[pscustomobject]@{StartValue=$expected;Delayed=$delayed}; Status='Prepared' })
        }
    }
    if ([bool](Get-Value $Request 'DryRun' $false)) {
        foreach ($change in @($changes.ToArray())) { Add-Check 'Geplanter Dienststarttyp' info ($change.Name + ': ' + $change.Before.StartValue + ' → ' + $change.Expected.StartValue) 'SERVICE_DRY_RUN' }
        $script:Result.Success=$true; $script:Result.Message='Probelauf: Die benötigten Netzwerkdienste und Starttypen wurden geprüft. Keine Dienste oder Windows-Einstellungen wurden verändert.'
        foreach ($step in @('service-snapshot','service-start','service-verification')) { Complete-WorkStep $step }; return
    }
    if (-not (Is-Administrator)) { throw (New-Object ComponentModel.Win32Exception(5,'Diese Dienstereparatur benötigt Administratorrechte.')) }
    Assert-ServiceRepairIdentity $Request
    Assert-PersonalPolicyChanges
    Initialize-LedgerDirectory
    # Reconstruction of discovery services requires separate explicit consent.
    # The Server repair below only writes its two known DLL metadata values;
    # LanmanServer/Workstation and unrelated dependencies are never rebuilt.
    if (Advanced-Repair $Request) { Repair-RequiredServiceConfigurations $Request }
    foreach ($name in @(Get-ServiceHealthNames)) {
        $current=Get-ServiceNativeSnapshot $name
        if (-not $current.Exists) { throw (New-Object ComponentModel.Win32Exception(1060,($name + ': Der Windows-Dienst fehlt.'))) }
    }
    $metadataChanges=New-Object 'System.Collections.Generic.List[object]'
    if (-not $health.MetadataReady) {
        if (-not (Advanced-Repair $Request)) { throw 'Die benötigten Originaleinträge des Serverdiensts sind unvollständig. Bitte die gezielte erweiterte Dienstereparatur erlauben.' }
        $before=Get-ServerServiceMetadataJson
        if (Test-ServerServiceMetadataNeedsRepair $before) {
            $plan=Get-ServerServiceOriginalPlan
            Assert-ServiceOriginalFiles $plan
            $metadataChanges.Add([pscustomobject]@{Name='LanmanServerMetadata';Before=$before;Expected=(Get-ServiceMetadataExpected $before $plan);Status='Prepared'})
        }
    }
    $journal=Read-ServiceHealthJournal
    $active=@(); $activeConfigurations=@()
    if ($null -ne $journal) { $active=@($journal.Changes | Where-Object { $_.Status -in @('Prepared','Applied') }); $activeConfigurations=@(Get-Value $journal 'Configurations' @() | Where-Object {$_.Status -in @('Prepared','Applied')}) }
    foreach ($prior in $active) {
        $current=Get-ServiceNativeSnapshot $prior.Name
        if (-not $current.Exists -or [int]$current.StartValue -ne [int]$prior.Expected.StartValue -or [bool]$current.Delayed -ne [bool]$prior.Expected.Delayed) { throw 'Ein früher reparierter Dienststarttyp wurde später verändert. Bitte zuerst die gespeicherte Dienstereparatur gezielt zurücknehmen.' }
    }
    foreach ($prior in $activeConfigurations) {
        if (-not (Test-ServiceMetadataJsonSame (Get-ServerServiceMetadataJson) ([string]$prior.Expected))) { throw 'Eine früher reparierte Serverdienstkonfiguration wurde später verändert. Bitte zuerst die gespeicherte Dienstereparatur gezielt zurücknehmen.' }
    }
    if (($changes.Count + $metadataChanges.Count) -gt 0) {
        if ($null -eq $journal -or ($active.Count + $activeConfigurations.Count) -eq 0) { $journal=[pscustomobject]@{App=$script:AppMark;Version=1;Action='RepairServices';Created=[DateTime]::UtcNow.ToString('o');Status='Prepared';Changes=@();Configurations=@()} }
        $journal.Changes=@($active)+@($changes.ToArray() | Where-Object {$_.Name -notin @($active | ForEach-Object {$_.Name})})
        if ($null -eq $journal.PSObject.Properties['Configurations']) { $journal | Add-Member -NotePropertyName Configurations -NotePropertyValue @() }
        $journal.Configurations=@($activeConfigurations)+@($metadataChanges.ToArray() | Where-Object {$_.Name -notin @($activeConfigurations | ForEach-Object {$_.Name})})
        Write-JsonAtomic (Get-ServiceHealthJournalPath) $journal
    }
    Complete-WorkStep 'service-snapshot'
    try {
        foreach ($configuration in @($metadataChanges.ToArray())) {
            Write-Phase 'Fehlende Serverdienst-Einträge aus geprüften Windows-Originalen ergänzen …'
            Repair-ServerServiceMetadata
            if (-not (Test-ServiceMetadataJsonSame (Get-ServerServiceMetadataJson) ([string]$configuration.Expected))) { throw 'Windows hat die gezielte Serverdienstkonfiguration nicht vollständig übernommen.' }
            $configuration.Status='Applied'; Write-JsonAtomic (Get-ServiceHealthJournalPath) $journal
            Add-Check 'Serverdienstkonfiguration repariert' ok 'ServiceDll und ServiceDllUnloadOnStop wurden gesichert und aus den geprüften Originalen dieses Windows wiederhergestellt.' 'SERVICE_SERVER_METADATA_REPAIRED'
        }
        foreach ($change in @($changes.ToArray())) {
            Write-Phase ('Starttyp von ' + $change.Name + ' gesichert einstellen …')
            Set-ServiceStartOwned $change; $change.Status='Applied'
            Write-JsonAtomic (Get-ServiceHealthJournalPath) $journal
            Add-Check 'Netzwerkdienst aktiviert' ok $change.Name 'SERVICE_START_CONFIGURED'
        }
        foreach ($name in @('LanmanWorkstation','LanmanServer','fdPHost','FDResPub')) {
            Write-Phase ('Lokalen Netzwerkdienst ' + $name + ' starten …')
            $before=Get-ServiceNativeSnapshot $name
            if ($before.State -eq 'Running') { Add-Check 'Laufender Dienst beibehalten' ok $name 'SERVICE_ALREADY_RUNNING'; continue }
            try {
                Start-ServiceNative $name
                $after=Get-ServiceNativeSnapshot $name
                if ($after.State -ne 'Running') { throw (New-Object ComponentModel.Win32Exception(1067,($name + ': Windows bestätigt keinen laufenden Dienst.'))) }
                Add-Check 'Netzwerkdienst gestartet' ok $name 'SERVICE_STARTED'
            } catch {
                $failure=$_; $number=Get-ServiceFailureNumber $failure
                if ($number -eq 1072) { $script:Result.RestartRequired=$true }
                Add-Check $name error $failure.Exception.Message ('Win32: ' + $number) $false (Get-ServiceFailureGuidance $number)
                $failedService=Get-ServiceNativeSnapshot $name
                if ($number -eq 1066 -or [long]$failedService.ServiceSpecificExitCode -ne 0) { Add-Check 'Diensteigenen Fehlercode' error ($name + ': ' + $failedService.ServiceSpecificExitCode) ('Service: ' + $failedService.ServiceSpecificExitCode) $false (Get-ServiceFailureGuidance 1066) }
                Add-ServiceDependencyChecks $failedService
                throw $failure
            }
        }
        Complete-WorkStep 'service-start'
        Write-Phase 'Laufende Netzwerkdienste und lokalen SMB-Port 445 bestätigen …'
        $script:Result.ErrorCode=''; $script:Result.ErrorType=''; $script:Result.ErrorStackTrace=''
        $verified=Add-LocalServiceHealthChecks $Request $network
        Complete-WorkStep 'service-verification'
        if (-not $verified.Verified) { throw 'Die lokalen Dienste oder SMB-Port 445 sind nach dem Start noch nicht bereit. Die Freigabenprüfung muss die verbleibende Ursache prüfen.' }
        if ($null -ne $journal -and ($changes.Count + $metadataChanges.Count) -gt 0) { $journal.Status='Committed'; Write-JsonAtomic (Get-ServiceHealthJournalPath) $journal }
        # Initial failures remain as labelled history, rather than poisoning a
        # later fresh successful service/port verification in the same result.
        for ($index=$baselineStart; $index -lt $script:Checks.Count; $index++) {
            $check=$script:Checks[$index]
            if ($check.State -eq 'error') { $check.State='info'; $check.Detail='Vor der Reparatur: ' + $check.Detail }
        }
        Publish-ServiceHealthRestoreState
        $script:Result.Success=$true
        $script:Result.Message='Die lokalen Netzwerkdienste laufen jetzt und SMB-Port 445 antwortet. Bereits laufende Dienste und bestehende Freigaben wurden erhalten. Den Zugriff vom anderen Gerät bitte anschließend separat prüfen.'
    } catch {
        $failure=$_
        if ($changes.Count -gt 0) { Undo-ServiceStartChanges @($changes.ToArray() | Where-Object {$_.Status -in @('Prepared','Applied')}) $journal }
        if ($metadataChanges.Count -gt 0) { Undo-ServiceMetadataChanges @($metadataChanges.ToArray() | Where-Object {$_.Status -in @('Prepared','Applied')}) $journal }
        if ($null -ne $journal) { $journal.Status='Failed'; try { Write-JsonAtomic (Get-ServiceHealthJournalPath) $journal } catch { Add-Check 'Dienstereparaturjournal' error $_.Exception.Message 'SERVICE_JOURNAL_WRITE_FAILED' } }
        Publish-ServiceHealthRestoreState
        throw $failure
    }
}
function Invoke-RestoreLocalServices($Request) {
    if (-not (Is-Administrator) -and -not [bool](Get-Value $Request 'DryRun' $false)) { throw (New-Object ComponentModel.Win32Exception(5,'Diese Dienstereparatur-Rücknahme benötigt Administratorrechte.')) }
    Assert-ServiceRepairIdentity $Request
    Assert-PersonalPolicyChanges
    $journal=Read-ServiceHealthJournal
    Complete-WorkStep 'service-validation'; Complete-WorkStep 'service-snapshot'
    if ($null -eq $journal) { throw 'Es gibt keine gespeicherten Dienststarttypen zum Zurücknehmen.' }
    $changes=@($journal.Changes | Where-Object {$_.Status -in @('Prepared','Applied')})
    $configurations=@(Get-Value $journal 'Configurations' @() | Where-Object {$_.Status -in @('Prepared','Applied')})
    if ([bool](Get-Value $Request 'DryRun' $false)) {
        $script:Result.Success=$true; $script:Result.Message='Probelauf: Nur gespeicherte eigene Dienststarttypen würden zurückgenommen. Laufende Dienste werden nicht beendet.'
    } else {
        Undo-ServiceStartChanges $changes $journal
        Undo-ServiceMetadataChanges $configurations $journal
        if ((@($changes | Where-Object {$_.Status -in @('Prepared','Applied')}).Count + @($configurations | Where-Object {$_.Status -in @('Prepared','Applied')}).Count) -gt 0) { throw 'Mindestens eine gespeicherte Dienstereinstellung konnte nicht zurückgenommen werden. Das Journal bleibt erhalten.' }
        $journal.Status='Restored'; Write-JsonAtomic (Get-ServiceHealthJournalPath) $journal
        $script:Result.Success=$true; $script:Result.Message='Die gespeicherten eigenen Dienststarttypen wurden zurückgenommen. Zwischenzeitlich fremd geänderte Starttypen und laufende Dienste bleiben erhalten.'
    }
    Complete-WorkStep 'service-start'
    $null=Add-LocalServiceHealthChecks $Request
    Publish-ServiceHealthRestoreState
    Complete-WorkStep 'service-verification'
}
