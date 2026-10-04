{ Shared compiler directives (dual Delphi / Free Pascal).

  Every unit of the library includes this file right after 'unit ...;'. On
  Delphi it doesn't change the mode; on FPC it enables Delphi mode (long
  strings, Delphi-style generics, advanced records).

  PASCALCOMMON_WINDOWS: defined when the target is Windows, on either compiler
  (Delphi defines MSWINDOWS; FPC defines WINDOWS). }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

{$IFDEF MSWINDOWS}
  {$DEFINE PASCALCOMMON_WINDOWS}
{$ENDIF}
{$IFDEF WINDOWS}
  {$IFNDEF PASCALCOMMON_WINDOWS}
    {$DEFINE PASCALCOMMON_WINDOWS}
  {$ENDIF}
{$ENDIF}

{ PASCALCOMMON_FUNCREFS: the library's public callbacks are "reference to" —
  they accept a closure OR a method. Always on in Delphi. FPC 3.2.2 (stable)
  has no "reference to", so the same types become "of object" there: the
  portable subset is "pass a method". FPC compiler with function references
  (trunk/3.3+): define PASCALCOMMON_FPC_FUNCREFS in the project to get the
  same API as Delphi. }
{$IFNDEF FPC}
  {$DEFINE PASCALCOMMON_FUNCREFS}
{$ELSE}
  {$IFDEF PASCALCOMMON_FPC_FUNCREFS}
    {$MODESWITCH FUNCTIONREFERENCES}
    {$MODESWITCH ANONYMOUSFUNCTIONS}
    {$DEFINE PASCALCOMMON_FUNCREFS}
  {$ENDIF}
{$ENDIF}
