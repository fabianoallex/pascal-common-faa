unit PascalCommon.ThreadPool;

{$I pascalcommon.inc}

{ A monitor (lock + condition variable, TPcMonitor) and a thread pool
  (TPcThreadPool, with a process-wide instance in PcPool) for Delphi and Free
  Pascal.

  Moved from the copies in Pipes/AMQP/Redis.Threading, which were identical
  line by line (measured 2026-10-03), plus QueueDepth from Pipes. A separate
  unit from PascalCommon.Threading so a library that only needs atomics
  (pascal-db-faa) doesn't link a pool.

  System.Threading (TTask) and System.TMonitor are not used because neither
  exists in FPC.

  TPcMonitor covers the subset of System.TMonitor the libraries used:
  Enter/Leave/Wait/PulseAll. It uses one event per "generation": each
  PulseAll signals the current generation's manual-reset event and starts a
  new one for later waiters, so no wakeup is lost. Waiters may wake up
  spuriously; callers always re-check their condition in a loop with a
  deadline.

  TPcThreadPool runs work items (TPcWorkItem.Execute) and replaces
  TTask.Run. It grows on demand up to MaxWorkers; workers stay alive until
  the pool is destroyed (no idle exit). Work items are objects because "of
  object" method pointers don't capture local variables the way closures
  would, and FPC 3.2.2 has no closures. An exception raised by an item is
  swallowed (the same contract as TTask), so it can't kill the worker.
  Destroy runs every item already queued before it returns, and Queue after
  Destroy has started frees the item without running it. The donors' Pipes
  header and test said Destroy discarded the queued items; measured in F3, it
  never did (its worker loop looks at the queue before the shutdown flag).

  The helper classes (the monitor's wait generation, the pool's worker
  thread) are private nested types: they are not part of the API.

  PcPool is created in this unit's initialization, not lazily. The donors
  created it on first use with double-checked locking whose first read had no
  memory barrier: fine on x86/x64, the same family of race as the
  TClock/TSleep one fixed in pascal-db-faa 5c853c6 on weakly ordered CPUs.
  Creating it is cheap (no thread starts before the first Queue). It is
  freed in this unit's finalization, which joins every worker. Units are
  finalized in the reverse order of their initialization, so a unit that
  uses this one is finalized first, while PcPool still works: that is where
  a consumer drains its own in-flight items (the tests check it on both
  compilers, in PascalCommon.ThreadPoolTests' finalization). Items still
  running after that keep running until PcPool joins them, so they must not
  touch anything their unit's finalization already freed. }

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  Generics.Collections;

const
  /// Timeout meaning "no timeout", for TPcMonitor.Wait.
  PC_WAIT_INFINITE = Cardinal($FFFFFFFF);

type
  TPcMonitor = class
  private type
    { One wait "generation": a manual-reset event shared by the waiters that
      went to sleep before the same PulseAll. Refs counts the owner (the
      monitor, while it is the current generation) plus the waiters; the last
      one to let go frees it. }
    TGen = class
    public
      Event: TEvent;
      Refs: Integer;
      constructor Create;
      destructor Destroy; override;
    end;
  private
    FLock: TCriticalSection;
    FGen: TGen;
    // Releases one reference (call holding FLock).
    procedure ReleaseGen(AGen: TGen);
  public
    constructor Create;
    /// Assumes there are no waiters left.
    destructor Destroy; override;
    procedure Enter;
    procedure Leave;
    /// Releases the lock, waits for a PulseAll (or the timeout) and takes the
    /// lock again. Call it HOLDING the lock. It may wake up spuriously:
    /// re-check the condition in a loop with a deadline.
    procedure Wait(ATimeoutMs: Cardinal);
    /// Wakes every waiter. Call it HOLDING the lock.
    procedure PulseAll;
  end;

  { A unit of work queued on the pool. The pool takes ownership: after
    Execute (whether it raises or not), the worker frees the item. }
  TPcWorkItem = class
  public
    procedure Execute; virtual; abstract;
  end;

  TPcThreadPool = class
  private type
    TWorker = class(TThread)
    private
      FPool: TPcThreadPool;
    protected
      procedure Execute; override;
    public
      constructor Create(APool: TPcThreadPool);
    end;
  private
    FLock: TCriticalSection;
    FWork: TEvent;                       // auto-reset: one SetEvent wakes one worker
    FQueue: TQueue<TPcWorkItem>;
    FWorkers: TList<TWorker>;
    FIdle: Integer;                      // workers asleep (under FLock)
    FMaxWorkers: Integer;
    FShutdown: Boolean;
    /// The worker loop: returns False when the pool is shutting down.
    function Fetch(out AItem: TPcWorkItem): Boolean;
  public
    /// AMaxWorkers = 0 uses the default: max(16, 4 x cores). Work items may
    /// block on I/O for seconds (the target use case), hence the generous
    /// ceiling; limit the work in flight in the layer above if needed.
    constructor Create(AMaxWorkers: Integer = 0);
    /// Runs every item already queued (the workers drain the queue before
    /// they exit), then joins the workers. With a long queue it takes as long
    /// as the queue does.
    destructor Destroy; override;
    /// Queues the item and makes sure a worker will take it (starts one if
    /// all are busy and the ceiling allows). Takes ownership of the item;
    /// after Destroy has started, the item is freed without running.
    procedure Queue(AItem: TPcWorkItem);
    /// Items waiting for a free worker (not counting the running ones). For
    /// PcPool, this counts the items of every library sharing it.
    function QueueDepth: Integer;
    /// The most workers this pool will start: the value given to Create, or
    /// the default it computed (max(16, 4 x cores)). Since 1.1.0.
    property MaxWorkers: Integer read FMaxWorkers;
  end;

/// The process-wide pool, shared by every library that uses it. Created in
/// this unit's initialization and freed in its finalization (see the unit
/// header for what that means to a consumer). It is meant for work that may
/// block, such as user callbacks. Work that another thread waits for
/// synchronously (an actor answering requests) belongs on a TPcThreadPool of
/// its own: with the shared ceiling, one library's slow callbacks would
/// become another library's timeouts.
function PcPool: TPcThreadPool;

implementation

{ TPcMonitor.TGen }

constructor TPcMonitor.TGen.Create;
begin
  inherited Create;
  Event := TEvent.Create(nil, True, False, ''); // manual-reset
  Refs := 1;
end;

destructor TPcMonitor.TGen.Destroy;
begin
  Event.Free;
  inherited;
end;

{ TPcMonitor }

constructor TPcMonitor.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FGen := TGen.Create; // Refs = 1: the monitor's own reference
end;

destructor TPcMonitor.Destroy;
begin
  FGen.Free;
  FLock.Free;
  inherited;
end;

procedure TPcMonitor.Enter;
begin
  FLock.Enter;
end;

procedure TPcMonitor.Leave;
begin
  FLock.Leave;
end;

procedure TPcMonitor.ReleaseGen(AGen: TGen);
begin
  Dec(AGen.Refs);
  if AGen.Refs = 0 then
    AGen.Free; // only happens to old generations (the monitor holds the current one)
end;

procedure TPcMonitor.Wait(ATimeoutMs: Cardinal);
var
  LGen: TGen;
begin
  // Take the current generation BEFORE releasing the lock: a PulseAll between
  // the Leave and the WaitFor signals exactly this event, which stays set
  // (manual reset), so the wakeup isn't lost.
  LGen := FGen;
  Inc(LGen.Refs);
  FLock.Leave;
  try
    LGen.Event.WaitFor(ATimeoutMs);
  finally
    FLock.Enter;
    ReleaseGen(LGen);
  end;
end;

procedure TPcMonitor.PulseAll;
var
  LOld: TGen;
begin
  LOld := FGen;
  LOld.Event.SetEvent;  // wakes whoever took this generation
  FGen := TGen.Create;  // later waiters sleep on the new one
  ReleaseGen(LOld);     // drops the monitor's reference to the old one
end;

{ TPcThreadPool.TWorker }

constructor TPcThreadPool.TWorker.Create(APool: TPcThreadPool);
begin
  FPool := APool;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TPcThreadPool.TWorker.Execute;
var
  LItem: TPcWorkItem;
begin
  while FPool.Fetch(LItem) do
  begin
    try
      LItem.Execute;
    except
      // An exception in a work item must not kill the worker (the same
      // contract as TTask: the exception is swallowed).
    end;
    LItem.Free;
  end;
end;

{ TPcThreadPool }

constructor TPcThreadPool.Create(AMaxWorkers: Integer);
begin
  inherited Create;
  if AMaxWorkers <= 0 then
  begin
    AMaxWorkers := TThread.ProcessorCount * 4;
    if AMaxWorkers < 16 then
      AMaxWorkers := 16;
  end;
  FMaxWorkers := AMaxWorkers;
  FLock := TCriticalSection.Create;
  FWork := TEvent.Create(nil, False, False, ''); // auto-reset
  FQueue := TQueue<TPcWorkItem>.Create;
  FWorkers := TList<TWorker>.Create;
end;

destructor TPcThreadPool.Destroy;
var
  LWorker: TWorker;
begin
  FLock.Enter;
  try
    FShutdown := True;
  finally
    FLock.Leave;
  end;
  FWork.SetEvent; // each worker that wakes up signals again (cascade) and exits
  for LWorker in FWorkers do
  begin
    LWorker.WaitFor;
    LWorker.Free;
  end;
  FWorkers.Free;
  // Defensive: the workers drain the queue before they exit (Fetch looks at
  // the queue before FShutdown), so this only frees something if no worker
  // was ever started.
  while FQueue.Count > 0 do
    FQueue.Dequeue.Free;
  FQueue.Free;
  FWork.Free;
  FLock.Free;
  inherited;
end;

function TPcThreadPool.Fetch(out AItem: TPcWorkItem): Boolean;
begin
  AItem := nil;
  FLock.Enter;
  while True do
  begin
    if FQueue.Count > 0 then
    begin
      AItem := FQueue.Dequeue;
      if FQueue.Count > 0 then
        FWork.SetEvent; // pass the baton: there is more work, wake another one
      FLock.Leave;
      Exit(True);
    end;
    if FShutdown then
    begin
      FWork.SetEvent;   // cascade: wake the next one so it exits too
      FLock.Leave;
      Exit(False);
    end;
    Inc(FIdle);
    FLock.Leave;
    FWork.WaitFor(PC_WAIT_INFINITE);
    FLock.Enter;
    Dec(FIdle);
  end;
end;

procedure TPcThreadPool.Queue(AItem: TPcWorkItem);
begin
  FLock.Enter;
  try
    if FShutdown then
    begin
      AItem.Free;
      Exit;
    end;
    FQueue.Enqueue(AItem);
    if (FIdle = 0) and (FWorkers.Count < FMaxWorkers) then
      FWorkers.Add(TWorker.Create(Self)) // serves it without relying on the event
    else
      FWork.SetEvent;
  finally
    FLock.Leave;
  end;
end;

function TPcThreadPool.QueueDepth: Integer;
begin
  FLock.Enter;
  try
    Result := FQueue.Count;
  finally
    FLock.Leave;
  end;
end;

{ --- Process-wide pool --- }

var
  GPool: TPcThreadPool;

function PcPool: TPcThreadPool;
begin
  Result := GPool;
end;

initialization
  // Created here, single-threaded, never lazily: see the unit header.
  GPool := TPcThreadPool.Create;

finalization
  FreeAndNil(GPool);

end.
