unit Poseidon.Tests.ParserConsumed;

// DUnitX — a invariante AConsumed <= ABufLen dos parsers HTTP/1.
//
// POR QUE ISSO IMPORTA
//
// O dispatcher compacta o buffer de acumulacao da conexao descartando os
// AConsumed primeiros bytes. Se um parser devolvesse AConsumed MAIOR que o
// buffer que recebeu, AccumLen ficaria negativo e o proximo _ProcessRecvPlain
// faria
//
//   Move(ABuf^, LConn.AccumBuf[LConn.AccumLen], ALen)
//
// com indice negativo — uma escrita ANTES do inicio do bloco, destruindo o
// header do chunk anterior. No Linux/glibc isso aparece como
// `corrupted size vs. prev_size`.
//
// O dispatcher passou a clampar (_CompactAccum), mas o clamp e a segunda linha
// de defesa. A primeira e o parser nunca produzir esse valor. Ate aqui isso se
// sustentava apenas na leitura do codigo; estes testes exigem prova.
//
// A varredura inclui entradas hostis (corpo mentindo sobre o tamanho, chunked
// malformado, truncamento em toda posicao possivel) porque e exatamente onde
// um calculo de offset erra.

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  DUnitX.TestFramework;

type
  {$M+}
  [TestFixture]
  TParserConsumedTests = class
  private
    // Roda os dois parsers e exige 0 <= AConsumed <= ABufLen em ambos.
    procedure CheckBoth(const AWhat: string; const AReq: TBytes);
    procedure CheckBothStr(const AWhat: string; const AReq: string);
  public
    [Test] procedure SimpleGet_ConsumedWithinBuffer;
    [Test] procedure PipelinedRequests_ConsumedWithinBuffer;
    [Test] procedure PostWithBody_ConsumedWithinBuffer;
    [Test] procedure ContentLengthLies_ConsumedWithinBuffer;
    [Test] procedure Chunked_ConsumedWithinBuffer;
    [Test] procedure ChunkedMalformed_ConsumedWithinBuffer;
    [Test] procedure TruncatedAtEveryOffset_ConsumedWithinBuffer;
    [Test] procedure BinaryNoise_ConsumedWithinBuffer;
    [Test] procedure EmptyBuffer_ConsumedIsZero;
  end;

implementation

uses
  Poseidon.Net.HTTP1.Parser;

const
  CMaxHdr  = 64 * 1024;
  CMaxBody = 8 * 1024 * 1024;

procedure TParserConsumedTests.CheckBoth(const AWhat: string;
  const AReq: TBytes);
var
  LMethod, LPath, LQuery: string;
  LHeaders: TArray<TPair<string,string>>;
  LBody: TBytes;
  LKeepAlive: Boolean;
  LConsumed: Integer;
  LBad: Boolean;
  LHdrStart, LHdrEnd: Integer;
  LLen: Integer;
begin
  LLen := Length(AReq);

  LConsumed := -1;
  ParseHTTP1Request(AReq, LLen, CMaxHdr, CMaxBody, LMethod, LPath, LQuery,
    LHeaders, LBody, LKeepAlive, LConsumed, LBad);
  Assert.IsTrue(LConsumed >= 0,
    Format('%s [full]: AConsumed negativo (%d)', [AWhat, LConsumed]));
  Assert.IsTrue(LConsumed <= LLen,
    Format('%s [full]: AConsumed=%d > ABufLen=%d — AccumLen ficaria negativo',
      [AWhat, LConsumed, LLen]));

  LConsumed := -1;
  ParseHTTP1Lightweight(AReq, LLen, CMaxHdr, CMaxBody, LMethod, LPath, LQuery,
    LBody, LKeepAlive, LConsumed, LBad, LHdrStart, LHdrEnd);
  Assert.IsTrue(LConsumed >= 0,
    Format('%s [light]: AConsumed negativo (%d)', [AWhat, LConsumed]));
  Assert.IsTrue(LConsumed <= LLen,
    Format('%s [light]: AConsumed=%d > ABufLen=%d — AccumLen ficaria negativo',
      [AWhat, LConsumed, LLen]));
end;

procedure TParserConsumedTests.CheckBothStr(const AWhat: string;
  const AReq: string);
begin
  CheckBoth(AWhat, TEncoding.ASCII.GetBytes(AReq));
end;

procedure TParserConsumedTests.SimpleGet_ConsumedWithinBuffer;
begin
  CheckBothStr('get simples',
    'GET /ping HTTP/1.1'#13#10'Host: x'#13#10'Connection: keep-alive'#13#10#13#10);
end;

procedure TParserConsumedTests.PipelinedRequests_ConsumedWithinBuffer;
var
  LOne: string;
begin
  // Pipelining e o caso que EXERCITA a compactacao: o parser consome a primeira
  // requisicao e o resto tem de sobrar intacto no buffer.
  LOne := 'GET /a HTTP/1.1'#13#10'Host: x'#13#10#13#10;
  CheckBothStr('2 pipelined', LOne + LOne);
  CheckBothStr('5 pipelined', LOne + LOne + LOne + LOne + LOne);
end;

procedure TParserConsumedTests.PostWithBody_ConsumedWithinBuffer;
var
  LBody: string;
begin
  LBody := StringOfChar('x', 5000);
  CheckBothStr('post 5000',
    'POST /e HTTP/1.1'#13#10'Host: x'#13#10'Content-Length: 5000'#13#10#13#10 + LBody);
  // corpo presente porem INCOMPLETO — parser deve pedir mais, nao consumir alem
  CheckBothStr('post incompleto',
    'POST /e HTTP/1.1'#13#10'Host: x'#13#10'Content-Length: 5000'#13#10#13#10 +
    StringOfChar('x', 100));
end;

procedure TParserConsumedTests.ContentLengthLies_ConsumedWithinBuffer;
begin
  CheckBothStr('CL maior que o corpo',
    'POST /e HTTP/1.1'#13#10'Host: x'#13#10'Content-Length: 999999'#13#10#13#10'curto');
  CheckBothStr('CL menor que o corpo',
    'POST /e HTTP/1.1'#13#10'Host: x'#13#10'Content-Length: 5'#13#10#13#10 +
    StringOfChar('y', 5000));
  CheckBothStr('CL negativo',
    'POST /e HTTP/1.1'#13#10'Host: x'#13#10'Content-Length: -10'#13#10#13#10'abc');
  CheckBothStr('CL nao numerico',
    'POST /e HTTP/1.1'#13#10'Host: x'#13#10'Content-Length: abc'#13#10#13#10'abc');
  CheckBothStr('CL enorme',
    'POST /e HTTP/1.1'#13#10'Host: x'#13#10'Content-Length: 99999999999999'#13#10#13#10);
end;

procedure TParserConsumedTests.Chunked_ConsumedWithinBuffer;
begin
  CheckBothStr('chunked completo',
    'POST /e HTTP/1.1'#13#10'Host: x'#13#10'Transfer-Encoding: chunked'#13#10#13#10 +
    '5'#13#10'HELLO'#13#10'0'#13#10#13#10);
  CheckBothStr('chunked + pipelined',
    'POST /e HTTP/1.1'#13#10'Host: x'#13#10'Transfer-Encoding: chunked'#13#10#13#10 +
    '5'#13#10'HELLO'#13#10'0'#13#10#13#10 +
    'GET /b HTTP/1.1'#13#10'Host: x'#13#10#13#10);
end;

procedure TParserConsumedTests.ChunkedMalformed_ConsumedWithinBuffer;
begin
  CheckBothStr('tamanho nao-hex',
    'POST /e HTTP/1.1'#13#10'Host: x'#13#10'Transfer-Encoding: chunked'#13#10#13#10 +
    'ZZZZ'#13#10'AAAA'#13#10'0'#13#10#13#10);
  CheckBothStr('tamanho gigante',
    'POST /e HTTP/1.1'#13#10'Host: x'#13#10'Transfer-Encoding: chunked'#13#10#13#10 +
    'FFFFFFFFFFFFFFFF'#13#10'A'#13#10);
  CheckBothStr('sem chunk zero',
    'POST /e HTTP/1.1'#13#10'Host: x'#13#10'Transfer-Encoding: chunked'#13#10#13#10 +
    '5'#13#10'HELLO'#13#10);
  CheckBothStr('CL e TE juntos (smuggling)',
    'POST /e HTTP/1.1'#13#10'Host: x'#13#10'Content-Length: 6'#13#10 +
    'Transfer-Encoding: chunked'#13#10#13#10'0'#13#10#13#10);
end;

procedure TParserConsumedTests.TruncatedAtEveryOffset_ConsumedWithinBuffer;
var
  LFull: TBytes;
  I: Integer;
  LPart: TBytes;
begin
  // Corta em TODA posicao possivel. Um erro de offset por um byte costuma se
  // esconder exatamente numa fronteira especifica.
  LFull := TEncoding.ASCII.GetBytes(
    'POST /e HTTP/1.1'#13#10'Host: x'#13#10'Content-Length: 20'#13#10#13#10 +
    StringOfChar('z', 20) + 'GET /b HTTP/1.1'#13#10'Host: x'#13#10#13#10);
  for I := 0 to Length(LFull) do
  begin
    LPart := Copy(LFull, 0, I);
    CheckBoth(Format('truncado em %d/%d', [I, Length(LFull)]), LPart);
  end;
end;

procedure TParserConsumedTests.BinaryNoise_ConsumedWithinBuffer;
var
  LBuf: TBytes;
  LSeed: UInt64;
  I, J: Integer;
begin
  // PRNG deterministico (xorshift64), como o fuzzer do repo — falha
  // reproduzivel.
  LSeed := $9E3779B97F4A7C15;
  for J := 1 to 200 do
  begin
    SetLength(LBuf, 1 + (J * 7) mod 512);
    for I := 0 to High(LBuf) do
    begin
      LSeed := LSeed xor (LSeed shl 13);
      LSeed := LSeed xor (LSeed shr 7);
      LSeed := LSeed xor (LSeed shl 17);
      LBuf[I] := Byte(LSeed);
    end;
    CheckBoth(Format('ruido binario #%d', [J]), LBuf);
  end;
end;

procedure TParserConsumedTests.EmptyBuffer_ConsumedIsZero;
var
  LBuf: TBytes;
begin
  SetLength(LBuf, 0);
  CheckBoth('buffer vazio', LBuf);
end;

initialization
  TDUnitX.RegisterTestFixture(TParserConsumedTests);

end.
