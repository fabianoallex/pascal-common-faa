unit PascalCommon.SingleFlight;

{$I pascalcommon.inc}

(* Single-flight in the process: the threads that ask for the same key at the
  same time share one run of a loader (TPcSingleFlight<T>.Run).

  The first thread that calls Run for a key (the leader) runs ALoader(AArg);
  a thread that calls Run for that key while it runs waits and gets the same
  result. When the load ends the key is forgotten: the next call runs the
  loader again. It is not a cache. Uses: renewing an expired token once when
  several requests notice it together, loading a tenant's catalog on its
  first request, slow or rate-limited external calls, reconnecting once after
  an outage. One process only; across instances, pascal-redis-faa's
  TRedisLock. The design, with the reasons and the measurements, is
  docs/single-flight-design.md (decisions S1 to S10); TPcCache.GetOrLoad
  runs on it (S8).

  - Only the leader's ALoader and AArg run; a waiter's are ignored. One key
    must mean one piece of work.
  - The leader gets the loader's exception as raised. Each waiter gets a new
    one (one exception object can't be raised in several threads), built by
    the virtual WaiterException: by default the same class with the same
    message and HelpContext, built with Exception.Create, so a subclass's own
    fields stay empty. EPcSingleFlightError (the class name in
    OriginalClassName) when the class can't be built that way: what was
    raised isn't an Exception, it is a heap exception (EOutOfMemory and
    EInvalidPointer only free the instances the RTL allocates; one built with
    Create leaks, measured on both compilers), or its Create raises.
  - A loader that calls Run for its own key, in its own thread, would wait
    for itself: it raises EPcSingleFlightError instead. A cycle across two
    threads and two keys still hangs.
  - T must not be a class (EArgumentException in the constructor): every
    waiter would get the same instance and nobody could free it. Values,
    strings and records of them are copied; interfaces and dynamic arrays are
    shared, so read-only or thread-safe. T needs type information
    (GetTypeKind): an enumeration with explicit values can't be T.
  - A flight is an entry in a dictionary under one lock, with a reference
    count; the leader removes it before it wakes the waiters, and the last
    thread out frees it. The value is written before the event is set and
    read after the wait. Free a TPcSingleFlight only when no Run is running.

  Dual-compiler: the loader follows PASCALCOMMON_FUNCREFS ("reference to" on
  Delphi, "of object" on FPC 3.2.2), with a string argument because a method
  can't capture the caller's locals. A generic's method body is compiled
  where the generic is specialized, so it can't use anything declared only
  in this unit's implementation section (FPC: "Global Generic template
  references static symtable"; Delphi: E2506). The generic part is therefore
  thin: the lock, the dictionary, the wait and the exceptions live in the
  non-generic TPcSingleFlightBase. *)

interface

uses
  SysUtils,
  SyncObjs,
  Classes,
  Generics.Collections;

type
  /// Base of this unit's exceptions.
  EPcSingleFlight = class(Exception);

  /// Raised in a waiting thread when the loader's exception can't be built
  /// again (see the unit header), and for a re-entrant call.
  EPcSingleFlightError = class(EPcSingleFlight)
  private
    FOriginalClassName: string;
  public
    constructor Create(const AOriginalClassName, AMessage: string);
    property OriginalClassName: string read FOriginalClassName;
  end;

  /// A load in progress. Internal: public because TPcSingleFlight<T>'s body
  /// can't use a type declared in the implementation section.
  TPcFlight = class
  public
    Done: TEvent;
    Refs: Integer;
    LeaderThreadId: TThreadID;
    Failed: Boolean;
    /// nil when what was raised isn't an Exception.
    ErrorClass: ExceptClass;
    ErrorClassName: string;
    ErrorMessage: string;
    ErrorHelpContext: Integer;
    constructor Create; virtual;
    destructor Destroy; override;
  end;

  TPcFlightClass = class of TPcFlight;

  /// Internal (see TPcFlight).
  TPcFlightOf<T> = class(TPcFlight)
  public
    Value: T;
  end;

  /// What TPcSingleFlight<T> shares for every T. Not used directly.
  TPcSingleFlightBase = class
  private
    FLock: TCriticalSection;
    FFlights: TDictionary<string, TPcFlight>;
    FWaiting: Integer;
    procedure Remove(const AKey: string);
    function BuildWaiterException(AFlight: TPcFlight): Exception;
  protected
    /// Takes a reference to AKey's flight, creating it (of AFlightClass) when
    /// there is none: then ALeader is True and the caller runs the loader.
    function Join(const AKey: string; AFlightClass: TPcFlightClass;
      out ALeader: Boolean): TPcFlight;
    /// The leader's load ended with a value (already in the flight).
    procedure LoadSucceeded(const AKey: string; AFlight: TPcFlight);
    /// The leader's load raised AError (ExceptObject); the caller re-raises.
    procedure LoadFailed(const AKey: string; AFlight: TPcFlight; AError: TObject);
    /// A waiter waits for the flight; raises when the load failed.
    procedure Wait(AFlight: TPcFlight);
    /// Drops the caller's reference; the last one frees the flight.
    procedure Leave(AFlight: TPcFlight);
    class procedure RefuseClass;
    /// The exception a waiting thread raises when the loader raised. AClass
    /// is nil when what was raised isn't an Exception. Must return a new
    /// object; the default is described in the unit header.
    function WaiterException(AClass: ExceptClass;
      const AClassName, AMessage: string): Exception; virtual;
  public
    constructor Create;
    destructor Destroy; override;
    /// Threads waiting now for another thread's load (every key).
    function Waiting: Integer;
  end;

  /// Runs a loader once per key among the threads that ask for it at the
  /// same time. Thread-safe. See the unit header.
  TPcSingleFlight<T> = class(TPcSingleFlightBase)
  public type
    {$IFDEF PASCALCOMMON_FUNCREFS}
    TLoadFunc = reference to function(const AArg: string): T;
    {$ELSE}
    TLoadFunc = function(const AArg: string): T of object;
    {$ENDIF}
  public
    /// Raises EArgumentException when T is a class.
    constructor Create;
    /// ALoader(AArg) in the first thread that asks for AKey; the threads that
    /// ask for AKey while it runs wait and get its result or its exception.
    /// A waiter's ALoader and AArg are ignored.
    function Run(const AKey: string; const ALoader: TLoadFunc; const AArg: string): T;
  end;

implementation

uses
  PascalCommon.Threading;

const
  WAIT_FOREVER = Cardinal($FFFFFFFF);

function CurrentThreadId: TThreadID;
begin
  {$IFDEF FPC}
  Result := GetCurrentThreadId;
  {$ELSE}
  Result := TThread.CurrentThread.ThreadID;
  {$ENDIF}
end;

function IsHeapException(AClass: ExceptClass): Boolean;
begin
  {$IFDEF FPC}
  Result := AClass.InheritsFrom(EHeapMemoryError);
  {$ELSE}
  Result := AClass.InheritsFrom(EHeapException);
  {$ENDIF}
end;

{ EPcSingleFlightError }

constructor EPcSingleFlightError.Create(const AOriginalClassName, AMessage: string);
begin
  inherited Create(AMessage);
  FOriginalClassName := AOriginalClassName;
end;

{ TPcFlight }

constructor TPcFlight.Create;
begin
  inherited Create;
  Done := TEvent.Create(nil, True, False, '');
end;

destructor TPcFlight.Destroy;
begin
  Done.Free;
  inherited Destroy;
end;

{ TPcSingleFlightBase }

constructor TPcSingleFlightBase.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FFlights := TDictionary<string, TPcFlight>.Create;
end;

destructor TPcSingleFlightBase.Destroy;
begin
  FFlights.Free;
  FLock.Free;
  inherited Destroy;
end;

class procedure TPcSingleFlightBase.RefuseClass;
begin
  raise EArgumentException.Create(
    'TPcSingleFlight<T>: T must not be a class (every waiting thread would get the same instance)');
end;

function TPcSingleFlightBase.Join(const AKey: string; AFlightClass: TPcFlightClass;
  out ALeader: Boolean): TPcFlight;
begin
  FLock.Enter;
  try
    ALeader := not FFlights.TryGetValue(AKey, Result);
    if ALeader then
    begin
      Result := AFlightClass.Create;
      Result.LeaderThreadId := CurrentThreadId;
      FFlights.Add(AKey, Result);
    end
    else if Result.LeaderThreadId = CurrentThreadId then
      raise EPcSingleFlightError.Create('',
        Format('Re-entrant single-flight call for key "%s": the loader asked for its own key', [AKey]));
    Inc(Result.Refs);
  finally
    FLock.Leave;
  end;
end;

procedure TPcSingleFlightBase.Remove(const AKey: string);
begin
  FLock.Enter;
  try
    FFlights.Remove(AKey);
  finally
    FLock.Leave;
  end;
end;

procedure TPcSingleFlightBase.LoadSucceeded(const AKey: string; AFlight: TPcFlight);
begin
  // Removed before the waiters wake: a call after this starts a new flight.
  Remove(AKey);
  AFlight.Done.SetEvent;
end;

procedure TPcSingleFlightBase.LoadFailed(const AKey: string; AFlight: TPcFlight; AError: TObject);
begin
  AFlight.Failed := True;
  if AError is Exception then
  begin
    AFlight.ErrorClass := ExceptClass(AError.ClassType);
    AFlight.ErrorClassName := AError.ClassName;
    AFlight.ErrorMessage := Exception(AError).Message;
    AFlight.ErrorHelpContext := Exception(AError).HelpContext;
  end
  else
  begin
    AFlight.ErrorClass := nil;
    if AError <> nil then
      AFlight.ErrorClassName := AError.ClassName
    else
      AFlight.ErrorClassName := 'TObject';
    AFlight.ErrorMessage := 'The single-flight loader raised an object that is not an Exception';
  end;
  Remove(AKey);
  AFlight.Done.SetEvent;
end;

function TPcSingleFlightBase.WaiterException(AClass: ExceptClass;
  const AClassName, AMessage: string): Exception;
begin
  if (AClass = nil) or IsHeapException(AClass) then
    Exit(EPcSingleFlightError.Create(AClassName, AMessage));
  try
    Result := AClass.Create(AMessage);
  except
    Result := EPcSingleFlightError.Create(AClassName, AMessage);
  end;
end;

function TPcSingleFlightBase.BuildWaiterException(AFlight: TPcFlight): Exception;
begin
  Result := WaiterException(AFlight.ErrorClass, AFlight.ErrorClassName, AFlight.ErrorMessage);
  if Result = nil then
    Result := EPcSingleFlightError.Create(AFlight.ErrorClassName, AFlight.ErrorMessage)
  else if (AFlight.ErrorClass <> nil) and (Result.ClassType = AFlight.ErrorClass) then
    Result.HelpContext := AFlight.ErrorHelpContext;
end;

procedure TPcSingleFlightBase.Wait(AFlight: TPcFlight);
begin
  PcAtomicInc(FWaiting);
  try
    AFlight.Done.WaitFor(WAIT_FOREVER);
  finally
    PcAtomicDec(FWaiting);
  end;
  if AFlight.Failed then
    raise BuildWaiterException(AFlight);
end;

procedure TPcSingleFlightBase.Leave(AFlight: TPcFlight);
var
  LFree: Boolean;
begin
  FLock.Enter;
  try
    Dec(AFlight.Refs);
    LFree := AFlight.Refs = 0;
  finally
    FLock.Leave;
  end;
  if LFree then
    AFlight.Free;
end;

function TPcSingleFlightBase.Waiting: Integer;
begin
  Result := PcAtomicGet(FWaiting);
end;

{ TPcSingleFlight<T> }

constructor TPcSingleFlight<T>.Create;
begin
  inherited Create;
  if GetTypeKind(T) = tkClass then
    RefuseClass;
end;

function TPcSingleFlight<T>.Run(const AKey: string; const ALoader: TLoadFunc;
  const AArg: string): T;
var
  LFlight: TPcFlightOf<T>;
  LLeader: Boolean;
begin
  LFlight := TPcFlightOf<T>(Join(AKey, TPcFlightOf<T>, LLeader));
  try
    if LLeader then
    begin
      try
        Result := ALoader(AArg);
      except
        // Every raised object, Exception or not: the waiters must wake.
        LoadFailed(AKey, LFlight, ExceptObject);
        raise;
      end;
      LFlight.Value := Result;
      LoadSucceeded(AKey, LFlight);
    end
    else
    begin
      Wait(LFlight);
      Result := LFlight.Value;
    end;
  finally
    Leave(LFlight);
  end;
end;

end.
