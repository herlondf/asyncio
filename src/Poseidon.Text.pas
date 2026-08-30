unit Poseidon.Text;

// Fast UTF-16 -> UTF-8 conversion for the response hot path.
//
// WHY: TEncoding.UTF8.GetBytes measures 22 MB/s on Linux x86-64 (BDS 22,
// Ubuntu 24.04) - about 4.4 ms for a 100 KB body. On a response-heavy server
// that single call dominates everything else: a 100 KB JSON reply measured
// 456 req/s through TEncoding versus 9319 req/s when the body was already
// bytes. A plain scalar loop with an ASCII fast path reaches 191 MB/s, i.e.
// 8.7x, with no SIMD and no platform-specific code.
//
// This is a COMPLETE encoder, not an ASCII-only shortcut: 1/2/3-byte BMP
// sequences and surrogate pairs are all handled, and an unpaired surrogate
// becomes U+FFFD (the same substitution TEncoding performs) rather than
// producing invalid UTF-8. Output is byte-for-byte identical to
// TEncoding.UTF8.GetBytes for every well-formed input.

interface

uses
  {$IFDEF FPC}
  SysUtils;
  {$ELSE}
  System.SysUtils;
  {$ENDIF}

// UTF-8 encodes AValue. Returns nil for an empty string.
function PoseidonUTF8Bytes(const AValue: string): TBytes;

// UTF-8 encodes AValue into ABuffer starting at AOffset, growing ABuffer only
// if needed. Returns the number of bytes written. Lets callers that already
// own a pooled buffer avoid the extra allocation entirely.
function PoseidonUTF8BytesInto(const AValue: string; var ABuffer: TBytes;
  AOffset: Integer): Integer;

implementation

{$IFDEF FPC}
{$MODE DELPHI}
{$ENDIF}

const
  // Worst case per UTF-16 code unit. A surrogate PAIR is 2 units producing
  // 4 bytes, so 3 bytes/unit bounds every case.
  CMaxBytesPerUnit = 3;
  CReplacement = $FFFD;

  CHighSurrogateFirst = $D800;
  CHighSurrogateLast  = $DBFF;
  CLowSurrogateFirst  = $DC00;
  CLowSurrogateLast   = $DFFF;

function _Encode(ASrc: PChar; ALen: Integer; ADst: PByte): Integer;
var
  I: Integer;
  LOut: Integer;
  LCh: Cardinal;
  LLow: Cardinal;
begin
  LOut := 0;
  I := 0;
  while I < ALen do
  begin
    LCh := Cardinal(Word(ASrc[I]));

    if LCh < $80 then
    begin
      ADst[LOut] := Byte(LCh);
      Inc(LOut);
      Inc(I);
      Continue;
    end;

    if LCh < $800 then
    begin
      ADst[LOut]     := Byte($C0 or (LCh shr 6));
      ADst[LOut + 1] := Byte($80 or (LCh and $3F));
      Inc(LOut, 2);
      Inc(I);
      Continue;
    end;

    if (LCh >= CHighSurrogateFirst) and (LCh <= CHighSurrogateLast) then
    begin
      // Needs a following low surrogate to form a code point above the BMP.
      if I + 1 < ALen then
        LLow := Cardinal(Word(ASrc[I + 1]))
      else
        LLow := 0;
      if (LLow >= CLowSurrogateFirst) and (LLow <= CLowSurrogateLast) then
      begin
        LCh := $10000 + ((LCh - CHighSurrogateFirst) shl 10)
                      + (LLow - CLowSurrogateFirst);
        ADst[LOut]     := Byte($F0 or  (LCh shr 18));
        ADst[LOut + 1] := Byte($80 or ((LCh shr 12) and $3F));
        ADst[LOut + 2] := Byte($80 or ((LCh shr 6) and $3F));
        ADst[LOut + 3] := Byte($80 or  (LCh and $3F));
        Inc(LOut, 4);
        Inc(I, 2);
        Continue;
      end;
      // Unpaired high surrogate - substitute, matching TEncoding's behaviour.
      LCh := CReplacement;
    end
    else if (LCh >= CLowSurrogateFirst) and (LCh <= CLowSurrogateLast) then
      // Low surrogate with no preceding high surrogate.
      LCh := CReplacement;

    ADst[LOut]     := Byte($E0 or  (LCh shr 12));
    ADst[LOut + 1] := Byte($80 or ((LCh shr 6) and $3F));
    ADst[LOut + 2] := Byte($80 or  (LCh and $3F));
    Inc(LOut, 3);
    Inc(I);
  end;
  Result := LOut;
end;

function PoseidonUTF8Bytes(const AValue: string): TBytes;
var
  LLen: Integer;
  LWritten: Integer;
begin
  LLen := Length(AValue);
  if LLen = 0 then
    Exit(nil);

  // Deliberately sized at the worst case rather than from an exact pre-count.
  // An exact-size pass was tried and measured (see utf8-encode-bench): the gain
  // did not justify the failure mode. If a pre-count ever UNDER-counts by one
  // byte, _Encode writes past the end of the block - which is precisely the
  // heap-corruption class this server is being hardened against. Worst-case
  // sizing cannot overflow by construction; shrinking afterwards does not
  // reallocate, so the only cost is transient address space.
  SetLength(Result, LLen * CMaxBytesPerUnit);
  LWritten := _Encode(PChar(AValue), LLen, PByte(Result));
  SetLength(Result, LWritten);
end;

function PoseidonUTF8BytesInto(const AValue: string; var ABuffer: TBytes;
  AOffset: Integer): Integer;
var
  LLen: Integer;
  LNeed: Integer;
begin
  LLen := Length(AValue);
  if LLen = 0 then
    Exit(0);

  LNeed := AOffset + LLen * CMaxBytesPerUnit;
  if Length(ABuffer) < LNeed then
    SetLength(ABuffer, LNeed);

  Result := _Encode(PChar(AValue), LLen, PByte(ABuffer) + AOffset);
end;

end.
