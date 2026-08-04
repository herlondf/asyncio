unit Poseidon.Tests.Text;

// DUnitX unit tests for Poseidon.Text (PoseidonUTF8Bytes).
//
// The encoder replaces TEncoding.UTF8.GetBytes on the response hot path, so the
// bar is EQUIVALENCE, not "looks right": every case asserts byte-for-byte
// equality against TEncoding for the same input. A silent divergence here would
// corrupt every response body.
//
// Covers:
//   empty / pure ASCII               → 1-byte path
//   Latin-1 accents (pt-BR payloads) → 2-byte path
//   CJK                              → 3-byte path
//   emoji (surrogate pair)           → 4-byte path
//   unpaired high / low surrogate    → U+FFFD substitution, same as TEncoding
//   mixed + long buffer              → boundary between paths
//   PoseidonUTF8BytesInto            → offset write, buffer growth, no clobber

interface

uses
  DUnitX.TestFramework;

type
  {$M+}
  [TestFixture]
  TPoseidonTextTests = class
  private
    procedure AssertSameAsTEncoding(const AWhat, AValue: string);
  public
    [Test] procedure Encode_Empty_ReturnsNil;
    [Test] procedure Encode_PureAscii_MatchesTEncoding;
    [Test] procedure Encode_PortugueseAccents_MatchesTEncoding;
    [Test] procedure Encode_CJK_MatchesTEncoding;
    [Test] procedure Encode_EmojiSurrogatePair_MatchesTEncoding;
    [Test] procedure Encode_UnpairedHighSurrogate_MatchesTEncoding;
    [Test] procedure Encode_UnpairedLowSurrogate_MatchesTEncoding;
    [Test] procedure Encode_HighSurrogateAtEnd_MatchesTEncoding;
    [Test] procedure Encode_MixedScripts_MatchesTEncoding;
    [Test] procedure Encode_LargeJsonBody_MatchesTEncoding;
    [Test] procedure EncodeInto_WritesAtOffset_LeavesPrefixIntact;
    [Test] procedure EncodeInto_GrowsBufferWhenTooSmall;
    [Test] procedure EncodeInto_EmptyString_WritesNothing;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  Poseidon.Text;

procedure TPoseidonTextTests.AssertSameAsTEncoding(const AWhat, AValue: string);
var
  LMine: TBytes;
  LRef: TBytes;
  I: Integer;
begin
  LMine := PoseidonUTF8Bytes(AValue);
  LRef := TEncoding.UTF8.GetBytes(AValue);
  Assert.AreEqual(Length(LRef), Length(LMine),
    AWhat + ': tamanho difere de TEncoding.UTF8');
  for I := 0 to High(LRef) do
    if LMine[I] <> LRef[I] then
      Assert.Fail(Format('%s: byte %d difere (obtido $%.2x, esperado $%.2x)',
        [AWhat, I, LMine[I], LRef[I]]));
end;

procedure TPoseidonTextTests.Encode_Empty_ReturnsNil;
begin
  Assert.AreEqual<Integer>(0, Length(PoseidonUTF8Bytes('')));
end;

procedure TPoseidonTextTests.Encode_PureAscii_MatchesTEncoding;
begin
  AssertSameAsTEncoding('ascii',
    '{"id":1,"status":"autorizado","protocolo":"135000000001"}');
end;

procedure TPoseidonTextTests.Encode_PortugueseAccents_MatchesTEncoding;
begin
  // Caminho de 2 bytes — o caso comum em payload fiscal brasileiro.
  AssertSameAsTEncoding('acentos',
    'EMISSÃO DE NOTA FISCAL — CONTRIBUINTE ISENTO, OPERAÇÃO NÃO TRIBUTÁVEL. '
    + 'Endereço: Praça São João, 1º andar. Ação/Coração/Ãêîõü çÇ');
end;

procedure TPoseidonTextTests.Encode_CJK_MatchesTEncoding;
begin
  // Caminho de 3 bytes.
  AssertSameAsTEncoding('cjk', '日本語テスト 中文测试 한국어');
end;

procedure TPoseidonTextTests.Encode_EmojiSurrogatePair_MatchesTEncoding;
begin
  // Caminho de 4 bytes (par surrogate).
  AssertSameAsTEncoding('emoji', 'nota fiscal ' + #$D83D#$DE00 + ' ok '
    + #$D83D#$DCC4 + #$D83E#$DD16);
end;

procedure TPoseidonTextTests.Encode_UnpairedHighSurrogate_MatchesTEncoding;
begin
  // High surrogate sem o low seguinte -> U+FFFD, igual ao TEncoding.
  AssertSameAsTEncoding('high solto', 'antes' + #$D83D + 'depois');
end;

procedure TPoseidonTextTests.Encode_UnpairedLowSurrogate_MatchesTEncoding;
begin
  AssertSameAsTEncoding('low solto', 'antes' + #$DE00 + 'depois');
end;

procedure TPoseidonTextTests.Encode_HighSurrogateAtEnd_MatchesTEncoding;
begin
  // Fim da string no meio de um par — nao pode ler alem do buffer.
  AssertSameAsTEncoding('high no fim', 'texto' + #$D83D);
end;

procedure TPoseidonTextTests.Encode_MixedScripts_MatchesTEncoding;
begin
  AssertSameAsTEncoding('misto',
    'ASCII ' + 'ação' + ' 日本 ' + #$D83D#$DE00 + ' fim');
end;

procedure TPoseidonTextTests.Encode_LargeJsonBody_MatchesTEncoding;
var
  LBuilder: TStringBuilder;
  LId: Integer;
begin
  LBuilder := TStringBuilder.Create;
  try
    LBuilder.Append('{"docs":[');
    for LId := 1 to 2000 do
    begin
      if LId > 1 then LBuilder.Append(',');
      LBuilder.AppendFormat(
        '{"id":%d,"emitente":"EMPRESA AÇÃO LTDA","obs":"operação nº %d"}',
        [LId, LId]);
    end;
    LBuilder.Append(']}');
    AssertSameAsTEncoding('json grande', LBuilder.ToString);
  finally
    LBuilder.Free;
  end;
end;

procedure TPoseidonTextTests.EncodeInto_WritesAtOffset_LeavesPrefixIntact;
var
  LBuf: TBytes;
  LWritten: Integer;
  LRef: TBytes;
  I: Integer;
begin
  SetLength(LBuf, 64);
  for I := 0 to High(LBuf) do
    LBuf[I] := $AA;

  LWritten := PoseidonUTF8BytesInto('ação', LBuf, 8);
  LRef := TEncoding.UTF8.GetBytes('ação');

  Assert.AreEqual<Integer>(Length(LRef), LWritten, 'bytes escritos');
  for I := 0 to 7 do
    Assert.AreEqual(Byte($AA), LBuf[I], Format('prefixo %d foi sobrescrito', [I]));
  for I := 0 to High(LRef) do
    Assert.AreEqual(LRef[I], LBuf[8 + I], Format('byte %d no offset', [I]));
end;

procedure TPoseidonTextTests.EncodeInto_GrowsBufferWhenTooSmall;
var
  LBuf: TBytes;
  LWritten: Integer;
begin
  SetLength(LBuf, 2);
  LWritten := PoseidonUTF8BytesInto('texto bem maior que dois bytes', LBuf, 0);
  Assert.AreEqual(30, LWritten);
  Assert.IsTrue(Length(LBuf) >= LWritten, 'buffer nao cresceu o suficiente');
end;

procedure TPoseidonTextTests.EncodeInto_EmptyString_WritesNothing;
var
  LBuf: TBytes;
begin
  SetLength(LBuf, 4);
  Assert.AreEqual(0, PoseidonUTF8BytesInto('', LBuf, 0));
end;

initialization
  TDUnitX.RegisterTestFixture(TPoseidonTextTests);

end.
