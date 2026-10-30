unit PascalCommon.Passwords;

{$I pascalcommon.inc}

{ Password hashing: PBKDF2-HMAC-SHA256 (RFC 8018), a random salt per
  password, and a self-describing stored form, so the cost can grow later
  without invalidating the hashes already stored:

    $pbkdf2-sha256$i=<iterations>$<salt>$<hash>

  salt (16 bytes) and hash (32 bytes) in Base64url without padding. The
  password is hashed as UTF-8 bytes, the same on both compilers.

  It came from pascal-agenda-faa (Agenda.Passwords, its login and user
  creation) in 1.26.0, unchanged but for the names; promoted at the user's
  choice (its docs/design.md, "M7: design", decision 1): no rule of that
  application in it, and easy to copy wrong (the constant-time comparison,
  the strict parser, the iteration ceiling). PBKDF2 itself is
  PcPbkdf2HmacSha256 (PascalCommon.Crypto, 1.18.0); this unit adds the
  stored form, the salt (PascalCommon.Random) and the checks.

  - Verify compares in constant time and answers False for anything it can't
    read (another scheme, a cut string): it never raises on stored data.
  - NeedsRehash says when a stored hash used fewer iterations than now: a
    login re-hashes it while it has the password in hand.
  - The cost doesn't grow with the password's length: a key longer than
    HMAC's block is hashed once, before the iterations (RFC 2104).
  - PC_PASSWORD_DEFAULT_ITERATIONS is below OWASP's 600,000 on purpose: pure
    Pascal SHA-256 runs 600,000 iterations in about 0.8 s (FPC 3.2.2 Win64
    -O2, measured in pascal-agenda-faa), 210,000 in about 0.26 s. The
    stored form keeps the count, so raising it later re-hashes each password
    at its next login.
  - PC_PASSWORD_MAX_BYTES bounds what a server accepts at all, and
    PC_PASSWORD_MAX_ITERATIONS what a stored hash may ask for (a row with a
    huge count would hold the server).
  - The salt and the hash are read with the lenient PcBase64UrlDecode, as in
    the application it came from: a stored hash with a padded or otherwise
    respelled field still verifies, which costs nothing here (the stored
    text is the server's own, not something a client presents to be
    trusted).

  Not here: the policy (minimum length, which characters), and making an
  unknown user cost as much as a wrong password (the login does that, by
  verifying against a dummy hash). }

interface

uses
  SysUtils;

const
  /// About 0.26 s per hash (see above); OWASP's 2023 figure is 600,000.
  PC_PASSWORD_DEFAULT_ITERATIONS = 210000;
  /// A stored hash asking for more is refused (it would hold the server).
  PC_PASSWORD_MAX_ITERATIONS = 10000000;
  /// The longest password accepted, in UTF-8 bytes.
  PC_PASSWORD_MAX_BYTES = 1024;
  PC_PASSWORD_SALT_BYTES = 16;
  PC_PASSWORD_HASH_BYTES = 32;
  PC_PASSWORD_SCHEME = 'pbkdf2-sha256';

type
  EPcPasswordError = class(Exception);

  TPcPasswords = record
  public
    /// A new stored form, with a new random salt. Raises EPcPasswordError
    /// for an empty password or one longer than PC_PASSWORD_MAX_BYTES
    /// (UTF-8), EArgumentException for iterations outside 1 to
    /// PC_PASSWORD_MAX_ITERATIONS.
    class function Hash(const APassword: string;
      AIterations: Integer = PC_PASSWORD_DEFAULT_ITERATIONS): string; static;
    /// The same stored form for a given salt (tests, and nothing else).
    class function HashWithSalt(const APassword: string; const ASalt: TBytes;
      AIterations: Integer): string; static;
    /// True only when AStored is this scheme and APassword matches it. Never
    /// raises.
    class function Verify(const APassword, AStored: string): Boolean; static;
    /// True when AStored can't be read or used fewer than AIterations.
    class function NeedsRehash(const AStored: string;
      AIterations: Integer = PC_PASSWORD_DEFAULT_ITERATIONS): Boolean; static;
  end;

implementation

uses
  PascalCommon.Crypto,
  PascalCommon.Random,
  PascalCommon.Utf8;

type
  TStoredHash = record
    Iterations: Integer;
    Salt: TBytes;
    Hash: TBytes;
  end;

function PasswordBytes(const APassword: string): TBytes;
begin
  Result := PcStringToUtf8Bytes(APassword);
  if Length(Result) = 0 then
    raise EPcPasswordError.Create('The password is empty.');
  if Length(Result) > PC_PASSWORD_MAX_BYTES then
    raise EPcPasswordError.CreateFmt('The password is longer than %d bytes.',
      [PC_PASSWORD_MAX_BYTES]);
end;

class function TPcPasswords.HashWithSalt(const APassword: string; const ASalt: TBytes;
  AIterations: Integer): string;
begin
  if (AIterations < 1) or (AIterations > PC_PASSWORD_MAX_ITERATIONS) then
    raise EArgumentException.CreateFmt('Password iterations must be 1 to %d.',
      [PC_PASSWORD_MAX_ITERATIONS]);
  Result := '$' + PC_PASSWORD_SCHEME + '$i=' + IntToStr(AIterations) + '$' +
    PcBase64UrlEncode(ASalt) + '$' +
    PcBase64UrlEncode(PcPbkdf2HmacSha256(PasswordBytes(APassword), ASalt, AIterations,
      PC_PASSWORD_HASH_BYTES));
end;

class function TPcPasswords.Hash(const APassword: string; AIterations: Integer): string;
begin
  Result := HashWithSalt(APassword, PcRandomBytes(PC_PASSWORD_SALT_BYTES), AIterations);
end;

// Splits off the text up to the next '$' (or the end); False when there is
// nothing left.
function NextField(var ARest: string; out AField: string): Boolean;
var
  P: Integer;
begin
  Result := ARest <> '';
  if not Result then
    Exit;
  P := Pos('$', ARest);
  if P = 0 then
  begin
    AField := ARest;
    ARest := '';
  end
  else
  begin
    AField := Copy(ARest, 1, P - 1);
    ARest := Copy(ARest, P + 1, MaxInt);
  end;
end;

function DigitsOnly(const AText: string): Boolean;
var
  I: Integer;
begin
  Result := (AText <> '') and (Length(AText) <= 9);
  for I := 1 to Length(AText) do
    if (AText[I] < '0') or (AText[I] > '9') then
      Exit(False);
end;

// '$pbkdf2-sha256$i=N$salt$hash', nothing more, nothing less.
function TryParse(const AStored: string; out AHash: TStoredHash): Boolean;
var
  LRest, LField, LSalt, LHash, LIterations: string;
begin
  Result := False;
  if (Length(AStored) < 2) or (AStored[1] <> '$') then
    Exit;
  LRest := Copy(AStored, 2, MaxInt);
  if not NextField(LRest, LField) or (LField <> PC_PASSWORD_SCHEME) then
    Exit;
  if not NextField(LRest, LField) or (Copy(LField, 1, 2) <> 'i=') then
    Exit;
  LIterations := Copy(LField, 3, MaxInt);
  if not DigitsOnly(LIterations) then
    Exit;
  AHash.Iterations := StrToInt(LIterations);
  if (AHash.Iterations < 1) or (AHash.Iterations > PC_PASSWORD_MAX_ITERATIONS) then
    Exit;
  if not NextField(LRest, LSalt) or not NextField(LRest, LHash) or (LRest <> '') then
    Exit;
  if (Pos('$', LHash) > 0) or not PcBase64UrlDecode(LSalt, AHash.Salt) or
    not PcBase64UrlDecode(LHash, AHash.Hash) then
    Exit;
  Result := (Length(AHash.Salt) > 0) and (Length(AHash.Hash) = PC_PASSWORD_HASH_BYTES);
end;

class function TPcPasswords.Verify(const APassword, AStored: string): Boolean;
var
  LStored: TStoredHash;
  LPassword: TBytes;
begin
  Result := False;
  if not TryParse(AStored, LStored) then
    Exit;
  LPassword := PcStringToUtf8Bytes(APassword);
  if (Length(LPassword) = 0) or (Length(LPassword) > PC_PASSWORD_MAX_BYTES) then
    Exit;
  Result := PcSameBytes(PcPbkdf2HmacSha256(LPassword, LStored.Salt, LStored.Iterations,
    PC_PASSWORD_HASH_BYTES), LStored.Hash);
end;

class function TPcPasswords.NeedsRehash(const AStored: string; AIterations: Integer): Boolean;
var
  LStored: TStoredHash;
begin
  Result := not TryParse(AStored, LStored) or (LStored.Iterations < AIterations);
end;

end.
