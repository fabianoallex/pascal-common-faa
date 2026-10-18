unit PascalCommon.AesGcm;

{$I pascalcommon.inc}

{ AES (FIPS-197) in Galois/Counter Mode (NIST SP 800-38D), the same on
  Delphi and FPC: PcAesGcmEncrypt and PcAesGcmDecrypt, authenticated
  encryption with additional data, 128-bit tags.

  For secrets at rest: pascal-api-infra-faa seals its JWT signing keys with
  it (its docs/jwt-keys-design.md). Neither RTL has AES (FPC 3.2.2's hash
  package has none, Delphi's System.Hash only hashes), so it is written
  here, with no dependency, and checked against the test vectors of
  McGrew and Viega's GCM specification and FIPS-197 appendix C, each one
  recomputed with OpenSSL (Python's cryptography 50) before it went in.

  Keys of 16, 24 or 32 bytes (AES-128, -192, -256). A nonce of 12 bytes is
  the fast, recommended case (PcRandomBytes(PC_AES_GCM_NONCE_BYTES), from
  PascalCommon.Random); other lengths go through GHASH as the standard
  says. A nonce must never repeat under one key: a random 12-byte nonce is
  safe for about 2^32 messages per key.

  Timing: the S-box is a table lookup indexed by key and data bytes, which
  a process sharing the CPU cache can in principle observe; AES-NI or a
  bitsliced AES would avoid it. GHASH multiplies with masks, without a
  branch on the data. Fine for secrets decrypted now and then (a key
  reload); not for an endpoint that decrypts what any client sends, many
  times a second. Decrypt compares the tag in constant time and returns
  nothing when it doesn't match.

  The S-box is computed in initialization (generator 3 of GF(2^8) and the
  affine map), not typed in: no shared state is created lazily. }

interface

uses
  SysUtils;

const
  PC_AES_GCM_TAG_BYTES = 16;
  PC_AES_GCM_NONCE_BYTES = 12;

/// APlain encrypted with AKey (16, 24 or 32 bytes) and ANonce (at least one
/// byte; 12 recommended, never repeated under one key), AAad authenticated
/// but not encrypted. The result has APlain's length; ATag is 16 bytes.
/// EArgumentException for a key or nonce of the wrong length.
function PcAesGcmEncrypt(const AKey, ANonce, APlain, AAad: TBytes; out ATag: TBytes): TBytes;

/// The inverse: True and APlain when ATag matches; False and APlain nil when
/// it doesn't (a wrong key, nonce or AAD, a changed ciphertext, a tag that
/// isn't 16 bytes). EArgumentException for a key or nonce of the wrong
/// length.
function PcAesGcmDecrypt(const AKey, ANonce, ACipher, AAad, ATag: TBytes;
  out APlain: TBytes): Boolean;

/// One AES block (16 bytes) encrypted with AKey: FIPS-197's cipher, for
/// tests. EArgumentException for a key or block of the wrong length.
function PcAesEncryptBlock(const AKey, ABlock: TBytes): TBytes;

implementation

type
  TBlock = array[0..15] of Byte;

  TKeySchedule = record
    Rounds: Integer;
    Words: array[0..59] of Cardinal; // 4 * (14 + 1)
  end;

var
  GSBox: array[0..255] of Byte;

function RotL8(AValue: Integer; AShift: Integer): Integer;
begin
  Result := ((AValue shl AShift) or (AValue shr (8 - AShift))) and $FF;
end;

procedure BuildSBox;
var
  P, Q, X: Integer;
begin
  // p walks GF(2^8)* by multiplying by 3; q is p's inverse (dividing by 3).
  P := 1;
  Q := 1;
  repeat
    if (P and $80) <> 0 then
      P := (P xor (P shl 1) xor $1B) and $FF
    else
      P := (P xor (P shl 1)) and $FF;
    Q := (Q xor (Q shl 1)) and $FF;
    Q := (Q xor (Q shl 2)) and $FF;
    Q := (Q xor (Q shl 4)) and $FF;
    if (Q and $80) <> 0 then
      Q := Q xor $09;
    X := Q xor RotL8(Q, 1) xor RotL8(Q, 2) xor RotL8(Q, 3) xor RotL8(Q, 4);
    GSBox[P] := Byte(X xor $63);
  until P = 1;
  GSBox[0] := $63; // 0 has no inverse
end;

function SubWord(AWord: Cardinal): Cardinal;
begin
  Result := (Cardinal(GSBox[(AWord shr 24) and $FF]) shl 24) or
    (Cardinal(GSBox[(AWord shr 16) and $FF]) shl 16) or
    (Cardinal(GSBox[(AWord shr 8) and $FF]) shl 8) or
    Cardinal(GSBox[AWord and $FF]);
end;

procedure ExpandKey(const AKey: TBytes; out ASchedule: TKeySchedule);
const
  RCON: array[1..10] of Byte = ($01, $02, $04, $08, $10, $20, $40, $80, $1B, $36);
var
  LNk, I: Integer;
  LTemp: Cardinal;
begin
  LNk := Length(AKey) div 4;
  if (Length(AKey) <> 16) and (Length(AKey) <> 24) and (Length(AKey) <> 32) then
    raise EArgumentException.CreateFmt('AES: a key has 16, 24 or 32 bytes, not %d', [Length(AKey)]);
  ASchedule.Rounds := LNk + 6;
  for I := 0 to LNk - 1 do
    ASchedule.Words[I] := (Cardinal(AKey[4 * I]) shl 24) or (Cardinal(AKey[4 * I + 1]) shl 16) or
      (Cardinal(AKey[4 * I + 2]) shl 8) or Cardinal(AKey[4 * I + 3]);
  for I := LNk to 4 * (ASchedule.Rounds + 1) - 1 do
  begin
    LTemp := ASchedule.Words[I - 1];
    if I mod LNk = 0 then
      // RotWord; Cardinal() keeps the shift in 32 bits on 64-bit FPC.
      LTemp := SubWord(Cardinal(LTemp shl 8) or (LTemp shr 24)) xor (Cardinal(RCON[I div LNk]) shl 24)
    else if (LNk > 6) and (I mod LNk = 4) then
      LTemp := SubWord(LTemp);
    ASchedule.Words[I] := ASchedule.Words[I - LNk] xor LTemp;
  end;
end;

function XTime(AValue: Byte): Byte;
begin
  if (AValue and $80) <> 0 then
    Result := Byte(((AValue shl 1) xor $1B) and $FF)
  else
    Result := Byte((AValue shl 1) and $FF);
end;

procedure AddRoundKey(var AState: TBlock; const ASchedule: TKeySchedule; ARound: Integer);
var
  C: Integer;
  LWord: Cardinal;
begin
  for C := 0 to 3 do
  begin
    LWord := ASchedule.Words[4 * ARound + C];
    AState[4 * C] := AState[4 * C] xor Byte(LWord shr 24);
    AState[4 * C + 1] := AState[4 * C + 1] xor Byte((LWord shr 16) and $FF);
    AState[4 * C + 2] := AState[4 * C + 2] xor Byte((LWord shr 8) and $FF);
    AState[4 * C + 3] := AState[4 * C + 3] xor Byte(LWord and $FF);
  end;
end;

// The state is column-major: byte r of column c is AState[4 * c + r].
procedure EncryptBlock(const ASchedule: TKeySchedule; var AState: TBlock);
var
  LRound, I, C, R: Integer;
  LOld: TBlock;
  A0, A1, A2, A3, LAll: Byte;
begin
  AddRoundKey(AState, ASchedule, 0);
  for LRound := 1 to ASchedule.Rounds do
  begin
    for I := 0 to 15 do
      AState[I] := GSBox[AState[I]];
    // ShiftRows: row r moves left by r.
    LOld := AState;
    for C := 0 to 3 do
      for R := 1 to 3 do
        AState[4 * C + R] := LOld[4 * ((C + R) mod 4) + R];
    if LRound < ASchedule.Rounds then
      for C := 0 to 3 do
      begin
        A0 := AState[4 * C];
        A1 := AState[4 * C + 1];
        A2 := AState[4 * C + 2];
        A3 := AState[4 * C + 3];
        LAll := A0 xor A1 xor A2 xor A3;
        AState[4 * C] := A0 xor LAll xor XTime(A0 xor A1);
        AState[4 * C + 1] := A1 xor LAll xor XTime(A1 xor A2);
        AState[4 * C + 2] := A2 xor LAll xor XTime(A2 xor A3);
        AState[4 * C + 3] := A3 xor LAll xor XTime(A3 xor A0);
      end;
    AddRoundKey(AState, ASchedule, LRound);
  end;
end;

// X := X * H in GF(2^128), SP 800-38D's algorithm 1, with masks instead of
// branches on the bits.
procedure GfMul(var X: TBlock; const H: TBlock);
var
  Z, V: TBlock;
  I, J: Integer;
  LMask, LLsb: Byte;
begin
  FillChar(Z, SizeOf(Z), 0);
  V := H;
  for I := 0 to 127 do
  begin
    LMask := Byte(0 - ((X[I div 8] shr (7 - I mod 8)) and 1));
    for J := 0 to 15 do
      Z[J] := Z[J] xor (V[J] and LMask);
    LLsb := Byte(0 - (V[15] and 1));
    for J := 15 downto 1 do
      V[J] := Byte((V[J] shr 1) or ((V[J - 1] and 1) shl 7));
    V[0] := Byte(V[0] shr 1);
    V[0] := V[0] xor ($E1 and LLsb);
  end;
  X := Z;
end;

// Y := (Y xor each 16-byte block of AData, the last one zero-padded) * H.
procedure GHashUpdate(var Y: TBlock; const H: TBlock; const AData: TBytes);
var
  LOffset, I, LCount: Integer;
begin
  LOffset := 0;
  while LOffset < Length(AData) do
  begin
    LCount := Length(AData) - LOffset;
    if LCount > 16 then
      LCount := 16;
    for I := 0 to LCount - 1 do
      Y[I] := Y[I] xor AData[LOffset + I];
    GfMul(Y, H);
    Inc(LOffset, 16);
  end;
end;

procedure PutBitLength(var ABlock: TBlock; AOffset: Integer; AByteCount: Int64);
var
  LBits: UInt64;
  I: Integer;
begin
  LBits := UInt64(AByteCount) * 8;
  for I := 7 downto 0 do
  begin
    ABlock[AOffset + I] := Byte(LBits and $FF);
    LBits := LBits shr 8;
  end;
end;

procedure Inc32(var ACounter: TBlock);
var
  I: Integer;
begin
  for I := 15 downto 12 do
  begin
    ACounter[I] := Byte((ACounter[I] + 1) and $FF);
    if ACounter[I] <> 0 then
      Exit;
  end;
end;

// The hash subkey H and the pre-counter block J0.
procedure Prepare(const ASchedule: TKeySchedule; const ANonce: TBytes; out H, J0: TBlock);
var
  LLengths: TBlock;
  I: Integer;
begin
  if Length(ANonce) = 0 then
    raise EArgumentException.Create('AES-GCM: an empty nonce');
  FillChar(H, SizeOf(H), 0);
  EncryptBlock(ASchedule, H);
  FillChar(J0, SizeOf(J0), 0);
  if Length(ANonce) = PC_AES_GCM_NONCE_BYTES then
  begin
    for I := 0 to 11 do
      J0[I] := ANonce[I];
    J0[15] := 1;
  end
  else
  begin
    GHashUpdate(J0, H, ANonce);
    FillChar(LLengths, SizeOf(LLengths), 0);
    PutBitLength(LLengths, 8, Length(ANonce));
    for I := 0 to 15 do
      J0[I] := J0[I] xor LLengths[I];
    GfMul(J0, H);
  end;
end;

// AData xor the key stream from the counter after J0 (GCTR with inc32(J0)).
function Ctr(const ASchedule: TKeySchedule; const J0: TBlock; const AData: TBytes): TBytes;
var
  LCounter, LStream: TBlock;
  LOffset, I, LCount: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AData));
  LCounter := J0;
  LOffset := 0;
  while LOffset < Length(AData) do
  begin
    Inc32(LCounter);
    LStream := LCounter;
    EncryptBlock(ASchedule, LStream);
    LCount := Length(AData) - LOffset;
    if LCount > 16 then
      LCount := 16;
    for I := 0 to LCount - 1 do
      Result[LOffset + I] := AData[LOffset + I] xor LStream[I];
    Inc(LOffset, 16);
  end;
end;

function ComputeTag(const ASchedule: TKeySchedule; const H, J0: TBlock;
  const AAad, ACipher: TBytes): TBytes;
var
  S, LLengths, LMask: TBlock;
  I: Integer;
begin
  FillChar(S, SizeOf(S), 0);
  GHashUpdate(S, H, AAad);
  GHashUpdate(S, H, ACipher);
  FillChar(LLengths, SizeOf(LLengths), 0);
  PutBitLength(LLengths, 0, Length(AAad));
  PutBitLength(LLengths, 8, Length(ACipher));
  for I := 0 to 15 do
    S[I] := S[I] xor LLengths[I];
  GfMul(S, H);
  LMask := J0;
  EncryptBlock(ASchedule, LMask);
  Result := nil;
  SetLength(Result, PC_AES_GCM_TAG_BYTES);
  for I := 0 to 15 do
    Result[I] := S[I] xor LMask[I];
end;

function PcAesGcmEncrypt(const AKey, ANonce, APlain, AAad: TBytes; out ATag: TBytes): TBytes;
var
  LSchedule: TKeySchedule;
  H, J0: TBlock;
begin
  ExpandKey(AKey, LSchedule);
  Prepare(LSchedule, ANonce, H, J0);
  Result := Ctr(LSchedule, J0, APlain);
  ATag := ComputeTag(LSchedule, H, J0, AAad, Result);
end;

function PcAesGcmDecrypt(const AKey, ANonce, ACipher, AAad, ATag: TBytes;
  out APlain: TBytes): Boolean;
var
  LSchedule: TKeySchedule;
  H, J0: TBlock;
  LExpected: TBytes;
  LDiff: Byte;
  I: Integer;
begin
  APlain := nil;
  ExpandKey(AKey, LSchedule);
  Prepare(LSchedule, ANonce, H, J0);
  if Length(ATag) <> PC_AES_GCM_TAG_BYTES then
    Exit(False);
  LExpected := ComputeTag(LSchedule, H, J0, AAad, ACipher);
  // Constant time: every byte is compared whatever the first difference.
  LDiff := 0;
  for I := 0 to PC_AES_GCM_TAG_BYTES - 1 do
    LDiff := LDiff or (LExpected[I] xor ATag[I]);
  Result := LDiff = 0;
  if Result then
    APlain := Ctr(LSchedule, J0, ACipher);
end;

function PcAesEncryptBlock(const AKey, ABlock: TBytes): TBytes;
var
  LSchedule: TKeySchedule;
  LState: TBlock;
  I: Integer;
begin
  if Length(ABlock) <> 16 then
    raise EArgumentException.CreateFmt('AES: a block has 16 bytes, not %d', [Length(ABlock)]);
  ExpandKey(AKey, LSchedule);
  for I := 0 to 15 do
    LState[I] := ABlock[I];
  EncryptBlock(LSchedule, LState);
  Result := nil;
  SetLength(Result, 16);
  for I := 0 to 15 do
    Result[I] := LState[I];
end;

initialization
  BuildSBox;

end.
