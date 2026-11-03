unit PascalCommon.Crypto;

{$I pascalcommon.inc}

{ SHA-256, HMAC-SHA256, Base64url, hex and a constant-time comparison, the
  same on Delphi and FPC.

  Moved here in 1.17.0 from pascal-api-infra-faa's PascalApi.Crypto (its
  JWT HS256), which keeps its Pa* functions as wrappers; AES-GCM had come
  first (PascalCommon.AesGcm, 1.16.0), so the library's crypto now lives in
  one place. FPC 3.2.2's hash package has HMAC only for MD5 and SHA-1 and no
  SHA-256 at all (measured in a Lazarus 4.0 install, packages/hash/src), and
  Delphi's System.Hash/System.NetEncoding don't exist on FPC. Small enough
  to own: SHA-256 follows FIPS 180-4, HMAC RFC 2104, Base64url RFC 4648
  section 5 without padding (as JWT uses it). Checked against the FIPS 180,
  RFC 4231 and RFC 4648 vectors in PascalCommon.CryptoTests.

  PcBase64UrlDecodeStrict (1.24.0) reads only what PcBase64UrlEncode
  writes. The lenient PcBase64UrlDecode accepts padding and ignores the
  bits after the last byte (RFC 4648 section 3.5 allows either), so one
  byte string has several texts: 32 bytes are 43 characters whose last
  carries 4 bits, and "...A" and "...B" decode alike (found by
  pascal-agenda-faa's signed links on its Linux run). A signature or token
  checked as bytes then verifies under more than one spelling; the strict
  form gives each one text. The lenient one stays as it was (a behavior
  change within 1.x would break the versioning rule).

  PBKDF2-HMAC-SHA256 (RFC 8018) came in 1.18.0, for password hashing (first
  user: pascal-agenda-faa). It lives here, not in the consumer, because the
  fast form needs SHA-256's compression function: HMAC's inner and outer
  states are computed once from the key, and each iteration then costs two
  compressions and no allocation, against four compressions and three
  allocations through PcHmacSha256 (measured on FPC 3.2.2 Win64 -O2, 600,000
  iterations: about 1.9 s through PcHmacSha256, 0.8 s this way).

  SHA-512, HMAC-SHA-512 and PBKDF2-HMAC-SHA-512 came in 1.28.0, for
  pascal-kafka-faa's SCRAM-SHA-512 (RFC 5802 with SHA-512; its K3 step 5).
  The same shapes as the SHA-256 side on a 128-byte block and 64-bit words;
  HMAC-SHA-512 goes through the precomputed states too, since it has no
  older form to keep. Checked against FIPS 180-4 and RFC 4231 vectors and
  the RFC 6070 inputs on SHA-512 (recomputed with Python's hashlib).

  Arithmetic is modulo 2^32 (2^64 for SHA-512) on purpose: overflow and
  range checks are off in this unit (a Delphi test project may turn them on
  in Debug), and every SHA-256 intermediate is stored in a Cardinal, so
  FPC's 64-bit promotion of expressions can't leak extra bits. }

{$Q-}
{$R-}

interface

uses
  SysUtils;

type
  TPcSha256Digest = array[0..31] of Byte;

function PcSha256(const AData: TBytes): TPcSha256Digest;
function PcHmacSha256(const AKey, AData: TBytes): TPcSha256Digest;
function PcDigestToBytes(const ADigest: TPcSha256Digest): TBytes;
function PcBytesToHex(const ABytes: TBytes): string;

/// Base64url without padding.
function PcBase64UrlEncode(const ABytes: TBytes): string;
/// Accepts input with or without padding. Returns False on any character
/// outside the Base64url alphabet or an impossible length.
function PcBase64UrlDecode(const AText: string; out ABytes: TBytes): Boolean;
/// Only the text PcBase64UrlEncode writes (1.24.0): no padding, and the
/// bits after the last byte zero, so a byte string has one text. False
/// otherwise, ABytes nil. For signatures and tokens.
function PcBase64UrlDecodeStrict(const AText: string; out ABytes: TBytes): Boolean;

/// Compares in time independent of where the first difference is (for
/// signatures).
function PcSameBytes(const A, B: TBytes): Boolean;

/// PBKDF2 with HMAC-SHA256 (RFC 8018 section 5.2): ALength bytes derived from
/// APassword and ASalt with AIterations rounds (1.18.0). A password longer
/// than 64 bytes is hashed first, as HMAC does with a long key. Raises
/// EArgumentException when AIterations or ALength is below 1.
function PcPbkdf2HmacSha256(const APassword, ASalt: TBytes;
  AIterations, ALength: Integer): TBytes;

type
  TPcSha512Digest = array[0..63] of Byte;

/// SHA-512 (FIPS 180-4), 1.28.0.
function PcSha512(const AData: TBytes): TPcSha512Digest;
/// HMAC-SHA-512 (RFC 2104, RFC 4231), 1.28.0. A key longer than the
/// 128-byte block is hashed first.
function PcHmacSha512(const AKey, AData: TBytes): TPcSha512Digest;
/// The digest as TBytes (a name of its own, not a PcDigestToBytes overload,
/// so @PcDigestToBytes stays unambiguous for existing callers).
function PcSha512DigestToBytes(const ADigest: TPcSha512Digest): TBytes;
/// PBKDF2 with HMAC-SHA-512 (RFC 8018 section 5.2), 1.28.0: the same
/// contract as PcPbkdf2HmacSha256, blocks of 64 bytes. A password longer
/// than 128 bytes is hashed first. Raises EArgumentException when
/// AIterations or ALength is below 1.
function PcPbkdf2HmacSha512(const APassword, ASalt: TBytes;
  AIterations, ALength: Integer): TBytes;

implementation

const
  K: array[0..63] of Cardinal = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3, $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13, $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208, $90befffa, $a4506ceb, $bef9a3f7, $c67178f2);

  BASE64URL_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

function Ror(AValue: Cardinal; ABits: Integer): Cardinal; inline;
var
  LLow, LHigh: Cardinal;
begin
  LLow := AValue shr ABits;
  LHigh := AValue shl (32 - ABits);
  Result := LLow or LHigh;
end;

procedure Compress(var AState: array of Cardinal; const ABlock: PByte);
var
  W: array[0..63] of Cardinal;
  A, B, C, D, E, F, G, H, T1, T2, S0, S1: Cardinal;
  I: Integer;
begin
  for I := 0 to 15 do
    W[I] := (Cardinal(ABlock[I * 4]) shl 24) or (Cardinal(ABlock[I * 4 + 1]) shl 16) or
      (Cardinal(ABlock[I * 4 + 2]) shl 8) or Cardinal(ABlock[I * 4 + 3]);
  for I := 16 to 63 do
  begin
    S0 := Ror(W[I - 15], 7) xor Ror(W[I - 15], 18) xor (W[I - 15] shr 3);
    S1 := Ror(W[I - 2], 17) xor Ror(W[I - 2], 19) xor (W[I - 2] shr 10);
    T1 := W[I - 16] + S0;
    T1 := T1 + W[I - 7];
    W[I] := T1 + S1;
  end;

  A := AState[0]; B := AState[1]; C := AState[2]; D := AState[3];
  E := AState[4]; F := AState[5]; G := AState[6]; H := AState[7];
  for I := 0 to 63 do
  begin
    S1 := Ror(E, 6) xor Ror(E, 11) xor Ror(E, 25);
    T1 := H + S1;
    T1 := T1 + ((E and F) xor ((not E) and G));
    T1 := T1 + K[I];
    T1 := T1 + W[I];
    S0 := Ror(A, 2) xor Ror(A, 13) xor Ror(A, 22);
    T2 := S0 + ((A and B) xor (A and C) xor (B and C));
    H := G; G := F; F := E;
    E := D + T1;
    D := C; C := B; B := A;
    A := T1 + T2;
  end;
  AState[0] := AState[0] + A; AState[1] := AState[1] + B;
  AState[2] := AState[2] + C; AState[3] := AState[3] + D;
  AState[4] := AState[4] + E; AState[5] := AState[5] + F;
  AState[6] := AState[6] + G; AState[7] := AState[7] + H;
end;

function PcSha256(const AData: TBytes): TPcSha256Digest;
var
  LState: array[0..7] of Cardinal;
  LBlock: array[0..63] of Byte;
  LLen, LOffset, LRest, I: Integer;
  LBits: UInt64;
begin
  LState[0] := $6a09e667; LState[1] := $bb67ae85; LState[2] := $3c6ef372; LState[3] := $a54ff53a;
  LState[4] := $510e527f; LState[5] := $9b05688c; LState[6] := $1f83d9ab; LState[7] := $5be0cd19;

  LLen := Length(AData);
  LOffset := 0;
  while LLen - LOffset >= 64 do
  begin
    Compress(LState, @AData[LOffset]);
    Inc(LOffset, 64);
  end;

  // Padding: 0x80, zeros, then the length in bits (big-endian, 64 bits).
  LRest := LLen - LOffset;
  FillChar(LBlock, SizeOf(LBlock), 0);
  if LRest > 0 then
    Move(AData[LOffset], LBlock[0], LRest);
  LBlock[LRest] := $80;
  if LRest >= 56 then
  begin
    Compress(LState, @LBlock[0]);
    FillChar(LBlock, SizeOf(LBlock), 0);
  end;
  LBits := UInt64(LLen) * 8;
  for I := 0 to 7 do
    LBlock[63 - I] := Byte(LBits shr (I * 8));
  Compress(LState, @LBlock[0]);

  for I := 0 to 7 do
  begin
    Result[I * 4] := Byte(LState[I] shr 24);
    Result[I * 4 + 1] := Byte(LState[I] shr 16);
    Result[I * 4 + 2] := Byte(LState[I] shr 8);
    Result[I * 4 + 3] := Byte(LState[I]);
  end;
end;

function PcDigestToBytes(const ADigest: TPcSha256Digest): TBytes;
begin
  Result := nil;
  SetLength(Result, SizeOf(ADigest));
  Move(ADigest[0], Result[0], SizeOf(ADigest));
end;

function PcHmacSha256(const AKey, AData: TBytes): TPcSha256Digest;
const
  BLOCK = 64;
var
  LKey, LInner, LOuter: TBytes;
  I: Integer;
begin
  if Length(AKey) > BLOCK then
    LKey := PcDigestToBytes(PcSha256(AKey))
  else
    LKey := Copy(AKey, 0, Length(AKey));
  SetLength(LKey, BLOCK); // pads with zeros

  LInner := nil;
  SetLength(LInner, BLOCK + Length(AData));
  for I := 0 to BLOCK - 1 do
    LInner[I] := LKey[I] xor $36;
  if Length(AData) > 0 then
    Move(AData[0], LInner[BLOCK], Length(AData));

  LOuter := nil;
  SetLength(LOuter, BLOCK + SizeOf(TPcSha256Digest));
  for I := 0 to BLOCK - 1 do
    LOuter[I] := LKey[I] xor $5c;
  Result := PcSha256(LInner);
  Move(Result[0], LOuter[BLOCK], SizeOf(TPcSha256Digest));
  Result := PcSha256(LOuter);
end;

function PcBytesToHex(const ABytes: TBytes): string;
const
  HEX = '0123456789abcdef';
var
  I: Integer;
begin
  Result := '';
  SetLength(Result, Length(ABytes) * 2);
  for I := 0 to High(ABytes) do
  begin
    Result[I * 2 + 1] := HEX[(ABytes[I] shr 4) + 1];
    Result[I * 2 + 2] := HEX[(ABytes[I] and $F) + 1];
  end;
end;

function PcBase64UrlEncode(const ABytes: TBytes): string;
var
  I, LLen: Integer;
  LGroup: Cardinal;
begin
  Result := '';
  LLen := Length(ABytes);
  I := 0;
  while I + 2 < LLen do
  begin
    LGroup := (Cardinal(ABytes[I]) shl 16) or (Cardinal(ABytes[I + 1]) shl 8) or ABytes[I + 2];
    Result := Result + BASE64URL_CHARS[(LGroup shr 18) and 63 + 1] +
      BASE64URL_CHARS[(LGroup shr 12) and 63 + 1] + BASE64URL_CHARS[(LGroup shr 6) and 63 + 1] +
      BASE64URL_CHARS[LGroup and 63 + 1];
    Inc(I, 3);
  end;
  case LLen - I of
    1:
      begin
        LGroup := Cardinal(ABytes[I]) shl 16;
        Result := Result + BASE64URL_CHARS[(LGroup shr 18) and 63 + 1] +
          BASE64URL_CHARS[(LGroup shr 12) and 63 + 1];
      end;
    2:
      begin
        LGroup := (Cardinal(ABytes[I]) shl 16) or (Cardinal(ABytes[I + 1]) shl 8);
        Result := Result + BASE64URL_CHARS[(LGroup shr 18) and 63 + 1] +
          BASE64URL_CHARS[(LGroup shr 12) and 63 + 1] + BASE64URL_CHARS[(LGroup shr 6) and 63 + 1];
      end;
  end;
end;

function Base64UrlValue(C: Char): Integer;
begin
  case C of
    'A'..'Z': Result := Ord(C) - Ord('A');
    'a'..'z': Result := Ord(C) - Ord('a') + 26;
    '0'..'9': Result := Ord(C) - Ord('0') + 52;
    '-': Result := 62;
    '_': Result := 63;
  else
    Result := -1;
  end;
end;

function PcBase64UrlDecode(const AText: string; out ABytes: TBytes): Boolean;
var
  LLen, I, LCount, LValue: Integer;
  LAcc: Cardinal;
  LBits: Integer;
begin
  ABytes := nil;
  LLen := Length(AText);
  while (LLen > 0) and (AText[LLen] = '=') do
    Dec(LLen);
  // 4n + 1 characters can't come from whole bytes.
  if LLen mod 4 = 1 then
    Exit(False);
  SetLength(ABytes, (LLen * 6) div 8);
  LAcc := 0;
  LBits := 0;
  LCount := 0;
  for I := 1 to LLen do
  begin
    LValue := Base64UrlValue(AText[I]);
    if LValue < 0 then
    begin
      ABytes := nil;
      Exit(False);
    end;
    LAcc := ((LAcc shl 6) or Cardinal(LValue)) and $FFFFFF;
    Inc(LBits, 6);
    if LBits >= 8 then
    begin
      Dec(LBits, 8);
      ABytes[LCount] := Byte(LAcc shr LBits);
      Inc(LCount);
    end;
  end;
  Result := True;
end;

function PcBase64UrlDecodeStrict(const AText: string; out ABytes: TBytes): Boolean;
begin
  // Encoding again is the definition: the one text of these bytes.
  Result := PcBase64UrlDecode(AText, ABytes) and (PcBase64UrlEncode(ABytes) = AText);
  if not Result then
    ABytes := nil;
end;

function PcSameBytes(const A, B: TBytes): Boolean;
var
  I: Integer;
  LDiff: Byte;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  LDiff := 0;
  for I := 0 to High(A) do
    LDiff := LDiff or (A[I] xor B[I]);
  Result := LDiff = 0;
end;

type
  TSha256State = array[0..7] of Cardinal;

procedure InitSha256State(out AState: TSha256State);
begin
  AState[0] := $6a09e667; AState[1] := $bb67ae85; AState[2] := $3c6ef372; AState[3] := $a54ff53a;
  AState[4] := $510e527f; AState[5] := $9b05688c; AState[6] := $1f83d9ab; AState[7] := $5be0cd19;
end;

procedure StateToDigest(const AState: TSha256State; out ADigest: TPcSha256Digest);
var
  I: Integer;
begin
  for I := 0 to 7 do
  begin
    ADigest[I * 4] := Byte(AState[I] shr 24);
    ADigest[I * 4 + 1] := Byte(AState[I] shr 16);
    ADigest[I * 4 + 2] := Byte(AState[I] shr 8);
    ADigest[I * 4 + 3] := Byte(AState[I]);
  end;
end;

// The SHA-256 of (the 64-byte block already compressed into APrefix) || AData.
procedure HashAfterBlock(const APrefix: TSha256State; const AData: TBytes;
  out ADigest: TPcSha256Digest);
var
  LState: TSha256State;
  LBlock: array[0..63] of Byte;
  LLen, LOffset, LRest, I: Integer;
  LBits: UInt64;
begin
  LState := APrefix;
  LLen := Length(AData);
  LOffset := 0;
  while LLen - LOffset >= 64 do
  begin
    Compress(LState, @AData[LOffset]);
    Inc(LOffset, 64);
  end;
  LRest := LLen - LOffset;
  FillChar(LBlock, SizeOf(LBlock), 0);
  if LRest > 0 then
    Move(AData[LOffset], LBlock[0], LRest);
  LBlock[LRest] := $80;
  if LRest >= 56 then
  begin
    Compress(LState, @LBlock[0]);
    FillChar(LBlock, SizeOf(LBlock), 0);
  end;
  LBits := (UInt64(LLen) + 64) * 8;
  for I := 0 to 7 do
    LBlock[63 - I] := Byte(LBits shr (I * 8));
  Compress(LState, @LBlock[0]);
  StateToDigest(LState, ADigest);
end;

// The same for a 32-byte message: one block with fixed padding, the length
// (64 + 32) * 8 = 768 bits = $0300. AMessage and ADigest may be the same
// variable: the message is copied into the block first.
procedure HashDigestAfterBlock(const APrefix: TSha256State; const AMessage: TPcSha256Digest;
  out ADigest: TPcSha256Digest);
var
  LState: TSha256State;
  LBlock: array[0..63] of Byte;
begin
  FillChar(LBlock, SizeOf(LBlock), 0);
  Move(AMessage[0], LBlock[0], 32);
  LBlock[32] := $80;
  LBlock[62] := $03;
  LState := APrefix;
  Compress(LState, @LBlock[0]);
  StateToDigest(LState, ADigest);
end;

function PcPbkdf2HmacSha256(const APassword, ASalt: TBytes;
  AIterations, ALength: Integer): TBytes;
var
  LKey: array[0..63] of Byte;
  LPad: array[0..63] of Byte;
  LInner, LOuter: TSha256State;
  LLongKey: TPcSha256Digest;
  LFirst: TBytes;
  LU, LT: TPcSha256Digest;
  LBlocks, LBlockIndex, LDone, LCount, I, J: Integer;
begin
  if AIterations < 1 then
    raise EArgumentException.Create('PBKDF2: iterations must be 1 or more.');
  if ALength < 1 then
    raise EArgumentException.Create('PBKDF2: length must be 1 or more.');
  // HMAC's key, padded to the block; a longer one is hashed first (RFC 2104).
  FillChar(LKey, SizeOf(LKey), 0);
  if Length(APassword) > 64 then
  begin
    LLongKey := PcSha256(APassword);
    Move(LLongKey[0], LKey[0], SizeOf(LLongKey));
  end
  else if Length(APassword) > 0 then
    Move(APassword[0], LKey[0], Length(APassword));
  // The two states every HMAC with this key starts from.
  for I := 0 to 63 do
    LPad[I] := LKey[I] xor $36;
  InitSha256State(LInner);
  Compress(LInner, @LPad[0]);
  for I := 0 to 63 do
    LPad[I] := LKey[I] xor $5c;
  InitSha256State(LOuter);
  Compress(LOuter, @LPad[0]);
  FillChar(LKey, SizeOf(LKey), 0);
  FillChar(LPad, SizeOf(LPad), 0);

  Result := nil;
  SetLength(Result, ALength);
  LBlocks := (ALength + 31) div 32;
  LDone := 0;
  LFirst := nil;
  SetLength(LFirst, Length(ASalt) + 4);
  if Length(ASalt) > 0 then
    Move(ASalt[0], LFirst[0], Length(ASalt));
  for LBlockIndex := 1 to LBlocks do
  begin
    // U1 = HMAC(P, S || INT(i)), i as 32 bits big-endian.
    LFirst[Length(ASalt)] := Byte(LBlockIndex shr 24);
    LFirst[Length(ASalt) + 1] := Byte(LBlockIndex shr 16);
    LFirst[Length(ASalt) + 2] := Byte(LBlockIndex shr 8);
    LFirst[Length(ASalt) + 3] := Byte(LBlockIndex);
    HashAfterBlock(LInner, LFirst, LU);
    HashDigestAfterBlock(LOuter, LU, LU);
    LT := LU;
    for I := 2 to AIterations do
    begin
      HashDigestAfterBlock(LInner, LU, LU);
      HashDigestAfterBlock(LOuter, LU, LU);
      for J := 0 to 31 do
        LT[J] := LT[J] xor LU[J];
    end;
    LCount := ALength - LDone;
    if LCount > 32 then
      LCount := 32;
    Move(LT[0], Result[LDone], LCount);
    Inc(LDone, LCount);
  end;
end;

{ SHA-512 (1.28.0). Words are UInt64; the constants are written as pairs of
  32-bit halves (generated from the primes' roots, then checked by the FIPS
  vectors) because a hex literal above High(Int64) in a typed constant is a
  place where Delphi and FPC have disagreed, and halves leave no doubt.
  HMAC and PBKDF2 share one shape: the key's inner and outer pads are
  compressed once (HmacSha512States), then each HMAC costs only what
  follows them. }

const
  SHA512_IV: array[0..15] of Cardinal = (
    $6a09e667, $f3bcc908, $bb67ae85, $84caa73b, $3c6ef372, $fe94f82b,
    $a54ff53a, $5f1d36f1, $510e527f, $ade682d1, $9b05688c, $2b3e6c1f,
    $1f83d9ab, $fb41bd6b, $5be0cd19, $137e2179);

  SHA512_K: array[0..159] of Cardinal = (
    $428a2f98, $d728ae22, $71374491, $23ef65cd, $b5c0fbcf, $ec4d3b2f,
    $e9b5dba5, $8189dbbc, $3956c25b, $f348b538, $59f111f1, $b605d019,
    $923f82a4, $af194f9b, $ab1c5ed5, $da6d8118, $d807aa98, $a3030242,
    $12835b01, $45706fbe, $243185be, $4ee4b28c, $550c7dc3, $d5ffb4e2,
    $72be5d74, $f27b896f, $80deb1fe, $3b1696b1, $9bdc06a7, $25c71235,
    $c19bf174, $cf692694, $e49b69c1, $9ef14ad2, $efbe4786, $384f25e3,
    $0fc19dc6, $8b8cd5b5, $240ca1cc, $77ac9c65, $2de92c6f, $592b0275,
    $4a7484aa, $6ea6e483, $5cb0a9dc, $bd41fbd4, $76f988da, $831153b5,
    $983e5152, $ee66dfab, $a831c66d, $2db43210, $b00327c8, $98fb213f,
    $bf597fc7, $beef0ee4, $c6e00bf3, $3da88fc2, $d5a79147, $930aa725,
    $06ca6351, $e003826f, $14292967, $0a0e6e70, $27b70a85, $46d22ffc,
    $2e1b2138, $5c26c926, $4d2c6dfc, $5ac42aed, $53380d13, $9d95b3df,
    $650a7354, $8baf63de, $766a0abb, $3c77b2a8, $81c2c92e, $47edaee6,
    $92722c85, $1482353b, $a2bfe8a1, $4cf10364, $a81a664b, $bc423001,
    $c24b8b70, $d0f89791, $c76c51a3, $0654be30, $d192e819, $d6ef5218,
    $d6990624, $5565a910, $f40e3585, $5771202a, $106aa070, $32bbd1b8,
    $19a4c116, $b8d2d0c8, $1e376c08, $5141ab53, $2748774c, $df8eeb99,
    $34b0bcb5, $e19b48a8, $391c0cb3, $c5c95a63, $4ed8aa4a, $e3418acb,
    $5b9cca4f, $7763e373, $682e6ff3, $d6b2b8a3, $748f82ee, $5defb2fc,
    $78a5636f, $43172f60, $84c87814, $a1f0ab72, $8cc70208, $1a6439ec,
    $90befffa, $23631e28, $a4506ceb, $de82bde9, $bef9a3f7, $b2c67915,
    $c67178f2, $e372532b, $ca273ece, $ea26619c, $d186b8c7, $21c0c207,
    $eada7dd6, $cde0eb1e, $f57d4f7f, $ee6ed178, $06f067aa, $72176fba,
    $0a637dc5, $a2c898a6, $113f9804, $bef90dae, $1b710b35, $131c471b,
    $28db77f5, $23047d84, $32caab7b, $40c72493, $3c9ebe0a, $15c9bebc,
    $431d67c4, $9c100d4c, $4cc5d4be, $cb3e42b6, $597f299c, $fc657e2a,
    $5fcb6fab, $3ad6faec, $6c44198c, $4a475817);

type
  TSha512State = array[0..7] of UInt64;

function Ror64(AValue: UInt64; ABits: Integer): UInt64; inline;
begin
  Result := (AValue shr ABits) or (AValue shl (64 - ABits));
end;

procedure Compress512(var AState: TSha512State; const ABlock: PByte);
var
  W: array[0..79] of UInt64;
  A, B, C, D, E, F, G, H, T1, T2, S0, S1: UInt64;
  I, J: Integer;
begin
  for I := 0 to 15 do
  begin
    T1 := 0;
    for J := 0 to 7 do
      T1 := (T1 shl 8) or UInt64(ABlock[I * 8 + J]);
    W[I] := T1;
  end;
  for I := 16 to 79 do
  begin
    S0 := Ror64(W[I - 15], 1) xor Ror64(W[I - 15], 8) xor (W[I - 15] shr 7);
    S1 := Ror64(W[I - 2], 19) xor Ror64(W[I - 2], 61) xor (W[I - 2] shr 6);
    W[I] := W[I - 16] + S0 + W[I - 7] + S1;
  end;

  A := AState[0]; B := AState[1]; C := AState[2]; D := AState[3];
  E := AState[4]; F := AState[5]; G := AState[6]; H := AState[7];
  for I := 0 to 79 do
  begin
    S1 := Ror64(E, 14) xor Ror64(E, 18) xor Ror64(E, 41);
    T1 := H + S1 + ((E and F) xor ((not E) and G)) +
      ((UInt64(SHA512_K[I * 2]) shl 32) or UInt64(SHA512_K[I * 2 + 1])) + W[I];
    S0 := Ror64(A, 28) xor Ror64(A, 34) xor Ror64(A, 39);
    T2 := S0 + ((A and B) xor (A and C) xor (B and C));
    H := G; G := F; F := E;
    E := D + T1;
    D := C; C := B; B := A;
    A := T1 + T2;
  end;
  AState[0] := AState[0] + A; AState[1] := AState[1] + B;
  AState[2] := AState[2] + C; AState[3] := AState[3] + D;
  AState[4] := AState[4] + E; AState[5] := AState[5] + F;
  AState[6] := AState[6] + G; AState[7] := AState[7] + H;
end;

procedure InitSha512State(out AState: TSha512State);
var
  I: Integer;
begin
  for I := 0 to 7 do
    AState[I] := (UInt64(SHA512_IV[I * 2]) shl 32) or UInt64(SHA512_IV[I * 2 + 1]);
end;

procedure Sha512StateToDigest(const AState: TSha512State; out ADigest: TPcSha512Digest);
var
  I, J: Integer;
begin
  for I := 0 to 7 do
    for J := 0 to 7 do
      ADigest[I * 8 + J] := Byte(AState[I] shr (56 - J * 8));
end;

// The SHA-512 of (APrefixLength bytes already compressed into AStart) ||
// AData: APrefixLength is 0 for a plain hash, 128 after an HMAC pad.
procedure Sha512Finish(const AStart: TSha512State; APrefixLength: Integer;
  const AData: TBytes; out ADigest: TPcSha512Digest);
var
  LState: TSha512State;
  LBlock: array[0..127] of Byte;
  LLen, LOffset, LRest, I: Integer;
  LBits: UInt64;
begin
  LState := AStart;
  LLen := Length(AData);
  LOffset := 0;
  while LLen - LOffset >= 128 do
  begin
    Compress512(LState, @AData[LOffset]);
    Inc(LOffset, 128);
  end;
  // Padding: 0x80, zeros, then the length in bits as 128 bits big-endian
  // (the high 64 are zero for anything a TBytes holds).
  LRest := LLen - LOffset;
  FillChar(LBlock, SizeOf(LBlock), 0);
  if LRest > 0 then
    Move(AData[LOffset], LBlock[0], LRest);
  LBlock[LRest] := $80;
  if LRest >= 112 then
  begin
    Compress512(LState, @LBlock[0]);
    FillChar(LBlock, SizeOf(LBlock), 0);
  end;
  LBits := (UInt64(LLen) + UInt64(APrefixLength)) * 8;
  for I := 0 to 7 do
    LBlock[127 - I] := Byte(LBits shr (I * 8));
  Compress512(LState, @LBlock[0]);
  Sha512StateToDigest(LState, ADigest);
end;

// The same for a 64-byte message after one 128-byte block: one block with
// fixed padding, the length (128 + 64) * 8 = 1536 bits = $0600. AMessage
// and ADigest may be the same variable: the message is copied first.
procedure Sha512DigestAfterBlock(const APrefix: TSha512State;
  const AMessage: TPcSha512Digest; out ADigest: TPcSha512Digest);
var
  LState: TSha512State;
  LBlock: array[0..127] of Byte;
begin
  FillChar(LBlock, SizeOf(LBlock), 0);
  Move(AMessage[0], LBlock[0], 64);
  LBlock[64] := $80;
  LBlock[126] := $06;
  LState := APrefix;
  Compress512(LState, @LBlock[0]);
  Sha512StateToDigest(LState, ADigest);
end;

// HMAC's two starting states for AKey (RFC 2104): a key longer than the
// block is hashed first, a shorter one padded with zeros.
procedure HmacSha512States(const AKey: TBytes; out AInner, AOuter: TSha512State);
var
  LKey, LPad: array[0..127] of Byte;
  LLongKey: TPcSha512Digest;
  I: Integer;
begin
  FillChar(LKey, SizeOf(LKey), 0);
  if Length(AKey) > 128 then
  begin
    LLongKey := PcSha512(AKey);
    Move(LLongKey[0], LKey[0], SizeOf(LLongKey));
    FillChar(LLongKey, SizeOf(LLongKey), 0);
  end
  else if Length(AKey) > 0 then
    Move(AKey[0], LKey[0], Length(AKey));
  for I := 0 to 127 do
    LPad[I] := LKey[I] xor $36;
  InitSha512State(AInner);
  Compress512(AInner, @LPad[0]);
  for I := 0 to 127 do
    LPad[I] := LKey[I] xor $5c;
  InitSha512State(AOuter);
  Compress512(AOuter, @LPad[0]);
  FillChar(LKey, SizeOf(LKey), 0);
  FillChar(LPad, SizeOf(LPad), 0);
end;

function PcSha512(const AData: TBytes): TPcSha512Digest;
var
  LState: TSha512State;
begin
  InitSha512State(LState);
  Sha512Finish(LState, 0, AData, Result);
end;

function PcHmacSha512(const AKey, AData: TBytes): TPcSha512Digest;
var
  LInner, LOuter: TSha512State;
  LInnerDigest: TPcSha512Digest;
begin
  HmacSha512States(AKey, LInner, LOuter);
  Sha512Finish(LInner, 128, AData, LInnerDigest);
  Sha512DigestAfterBlock(LOuter, LInnerDigest, Result);
end;

function PcSha512DigestToBytes(const ADigest: TPcSha512Digest): TBytes;
begin
  Result := nil;
  SetLength(Result, SizeOf(ADigest));
  Move(ADigest[0], Result[0], SizeOf(ADigest));
end;

function PcPbkdf2HmacSha512(const APassword, ASalt: TBytes;
  AIterations, ALength: Integer): TBytes;
var
  LInner, LOuter: TSha512State;
  LFirst: TBytes;
  LU, LT: TPcSha512Digest;
  LBlocks, LBlockIndex, LDone, LCount, I, J: Integer;
begin
  if AIterations < 1 then
    raise EArgumentException.Create('PBKDF2: iterations must be 1 or more.');
  if ALength < 1 then
    raise EArgumentException.Create('PBKDF2: length must be 1 or more.');
  HmacSha512States(APassword, LInner, LOuter);

  Result := nil;
  SetLength(Result, ALength);
  LBlocks := (ALength + 63) div 64;
  LDone := 0;
  LFirst := nil;
  SetLength(LFirst, Length(ASalt) + 4);
  if Length(ASalt) > 0 then
    Move(ASalt[0], LFirst[0], Length(ASalt));
  for LBlockIndex := 1 to LBlocks do
  begin
    // U1 = HMAC(P, S || INT(i)), i as 32 bits big-endian.
    LFirst[Length(ASalt)] := Byte(LBlockIndex shr 24);
    LFirst[Length(ASalt) + 1] := Byte(LBlockIndex shr 16);
    LFirst[Length(ASalt) + 2] := Byte(LBlockIndex shr 8);
    LFirst[Length(ASalt) + 3] := Byte(LBlockIndex);
    Sha512Finish(LInner, 128, LFirst, LU);
    Sha512DigestAfterBlock(LOuter, LU, LU);
    LT := LU;
    for I := 2 to AIterations do
    begin
      Sha512DigestAfterBlock(LInner, LU, LU);
      Sha512DigestAfterBlock(LOuter, LU, LU);
      for J := 0 to 63 do
        LT[J] := LT[J] xor LU[J];
    end;
    LCount := ALength - LDone;
    if LCount > 64 then
      LCount := 64;
    Move(LT[0], Result[LDone], LCount);
    Inc(LDone, LCount);
  end;
end;

end.
