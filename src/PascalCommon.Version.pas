unit PascalCommon.Version;

{$I pascalcommon.inc}

{ The library's version, as constants a consumer can test at compile time.

  An application may use several *-faa libraries that all depend on this one,
  and it provides a single copy of it. Each consumer states the minimum
  version it needs, so an older copy fails the build with a clear message
  instead of a missing identifier somewhere inside the consumer:

    (*$IF PASCALCOMMON_VERSION < 10400*)
      (*$MESSAGE FATAL 'pascal-db-faa needs pascal-common-faa 1.4 or later'*)
    (*$IFEND*)

  (braces instead of the parenthesized form in real code). Measured on FPC
  3.2.2: a constant declared in another unit is evaluated in $IF. Delphi
  documents constant expressions in $IF as well.

  Bump every constant here with each release, together with the version in
  packages/pascal_common_faa.lpk and CHANGELOG.md. }

interface

const
  PASCALCOMMON_VERSION_MAJOR = 1;
  PASCALCOMMON_VERSION_MINOR = 5;
  PASCALCOMMON_VERSION_PATCH = 0;

  /// major * 10000 + minor * 100 + patch: 1.4.2 is 10402.
  PASCALCOMMON_VERSION = 10500;

  PASCALCOMMON_VERSION_STRING = '1.5.0';

implementation

end.
