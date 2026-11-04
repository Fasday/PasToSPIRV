unit PTS.Lexer;

{$BOOLEVAL OFF}

interface

uses
  PTS.Diagnostics,
  PTS.Source;

type
  TTokenKind = (tkEOF, tkIdentifier, tkInteger, tkReal, tkPlus, tkMinus,
    tkStar, tkSlash, tkEqual, tkNotEqual, tkLess, tkLessEqual, tkGreater,
    tkGreaterEqual, tkAssign, tkColon, tkSemicolon, tkComma, tkDot,
    tkLeftParen, tkRightParen, tkLeftBracket, tkRightBracket, tkInclude, tkDouble);

  TToken = record
    Kind: TTokenKind;
    Text: string;
    Position: TSourcePosition;
    Offset: Integer; // 1-based in this document, before source mapping.
    Length: Integer;
    // State of {$B}/{$BOOLEVAL} at this token: True = complete Boolean evaluation.
    CompleteBoolEval: Boolean;
  end;

  TLexer = class
  private
    FSource: string;
    FDocument: TSourceDocument; // Non-owning, optional origin map.
    FIndex: Integer;
    FLine: Integer;
    FColumn: Integer;
    FCompleteBoolEval: Boolean;
    function Current: Char;
    function TryReadBoolEval: Boolean;
    function Peek: Char;
    procedure Advance;
    procedure SkipTrivia;
    function Position: TSourcePosition;
    function ReadInclude: TToken;
  public
    constructor Create(const ASource: string); overload;
    constructor Create(ADocument: TSourceDocument); overload;
    function Next: TToken;
  end;

implementation

uses
  System.SysUtils,
  PTS.Names;

function IsDigit(C: Char): Boolean;
begin
  Result := CharInSet(C, ['0'..'9']);
end;

function IsHexDigit(C: Char): Boolean;
begin
  Result := CharInSet(C, ['0'..'9', 'a'..'f', 'A'..'F']);
end;

function IsIdentifierStart(C: Char): Boolean;
begin
  Result := CharInSet(C, ['a'..'z', 'A'..'Z', '_']);
end;

constructor TLexer.Create(const ASource: string);
begin
  inherited Create;
  FSource := ASource;
  FIndex := 1;
  FLine := 1;
  FColumn := 1;
end;

constructor TLexer.Create(ADocument: TSourceDocument);
begin
  inherited Create;
  FDocument := ADocument;
  FSource := ADocument.Text;
  FIndex := 1;
  FLine := 1;
  FColumn := 1;
end;

function TLexer.Position: TSourcePosition;
begin
  if FDocument <> nil then Result := FDocument.Position(FLine, FColumn)
  else Result := TSourcePosition.Create(FLine, FColumn);
end;

function TLexer.Current: Char;
begin
  if FIndex <= Length(FSource) then
    Result := FSource[FIndex]
  else
    Result := #0;
end;

function TLexer.Peek: Char;
begin
  if FIndex < Length(FSource) then
    Result := FSource[FIndex + 1]
  else
    Result := #0;
end;

procedure TLexer.Advance;
begin
  if Current = #13 then
  begin
    Inc(FLine);
    FColumn := 1;
  end
  else if Current = #10 then
  begin
    if (FIndex = 1) or (FSource[FIndex - 1] <> #13) then
      Inc(FLine);
    FColumn := 1;
  end
  else
    Inc(FColumn);
  Inc(FIndex);
end;

procedure TLexer.SkipTrivia;
var
  Start: TSourcePosition;
begin
  while True do
  begin
    while CharInSet(Current, [#9, #10, #13, ' ']) do
      Advance;
    Start := Position;
    if (Current = '/') and (Peek = '/') then
    begin
      while not CharInSet(Current, [#0, #10, #13]) do
        Advance;
      if (Current = #0) and (FIndex <= Length(FSource)) then
        raise EShaderError.Create(Position, 'NUL characters are not allowed');
    end
    else if Current = '{' then
    begin
      if Peek = '$' then Break;
      Advance;
      while not CharInSet(Current, [#0, '}']) do
        Advance;
      if (Current = #0) and (FIndex <= Length(FSource)) then
        raise EShaderError.Create(Position, 'NUL characters are not allowed');
      if Current = #0 then
        raise EShaderError.Create(Start, 'Unterminated comment');
      Advance;
    end
    else if (Current = '(') and (Peek = '*') then
    begin
      if (FIndex + 2 <= Length(FSource)) and (FSource[FIndex + 2] = '$') then Break;
      Advance;
      Advance;
      while (Current <> #0) and not ((Current = '*') and (Peek = ')')) do
        Advance;
      if (Current = #0) and (FIndex <= Length(FSource)) then
        raise EShaderError.Create(Position, 'NUL characters are not allowed');
      if Current = #0 then
        raise EShaderError.Create(Start, 'Unterminated comment');
      Advance;
      Advance;
    end
    else
      Break;
  end;
end;

function TLexer.ReadInclude: TToken;
var
  Brace: Boolean;
  Start, KeywordStart: Integer;
  Keyword, Path: string;
  Quote: Char;
  Closed: Boolean;
begin
  Result.Position := Position;
  Result.Offset := FIndex;
  Brace := Current = '{';
  Advance;
  if not Brace then Advance;
  Advance; // '$'
  while CharInSet(Current, [' ', #9]) do Advance;
  KeywordStart := FIndex;
  while CharInSet(Current, ['a'..'z', 'A'..'Z']) do Advance;
  Keyword := Copy(FSource, KeywordStart, FIndex - KeywordStart);
  if not SameText(Keyword, 'I') and not SameText(Keyword, 'INCLUDE') then
    raise EShaderError.Create(Result.Position,
      'Compiler directives are not supported except $I/$INCLUDE');
  Start := FIndex;
  while True do
  begin
    if CharInSet(Current, [#0, #10, #13]) then
      raise EShaderError.Create(Result.Position, 'Unterminated include directive');
    if (Brace and (Current = '}')) or (not Brace and (Current = '*') and (Peek = ')')) then Break;
    Advance;
  end;
  Path := Trim(Copy(FSource, Start, FIndex - Start));
  Advance;
  if not Brace then Advance;
  if (Path = '+') or (Path = '-') then
    raise EShaderError.Create(Result.Position,
      'Compiler directives are not supported except $I/$INCLUDE');
  if Path = '' then raise EShaderError.Create(Result.Position, 'Include filename is empty');
  if CharInSet(Path[1], ['''', '"']) then
  begin
    Quote := Path[1];
    Keyword := '';
    Start := 2;
    Closed := False;
    while Start <= Length(Path) do
    begin
      if Path[Start] = Quote then
      begin
        if (Start < Length(Path)) and (Path[Start + 1] = Quote) then Inc(Start)
        else
        begin
          Closed := True;
          Break;
        end;
      end;
      Keyword := Keyword + Path[Start];
      Inc(Start);
    end;
    if not Closed or (Trim(Copy(Path, Start + 1, MaxInt)) <> '') then
      raise EShaderError.Create(Result.Position, 'Malformed quoted include filename');
    Path := Keyword;
  end
  else if (Pos(' ', Path) <> 0) or (Pos(#9, Path) <> 0) then
    raise EShaderError.Create(Result.Position, 'Include filenames containing spaces must be quoted');
  if (Path = '') or (Pos(#0, Path) <> 0) then
    raise EShaderError.Create(Result.Position, 'Include filename is empty or invalid');
  Result.Kind := tkInclude;
  Result.Text := Path;
  Result.Length := FIndex - Result.Offset;
end;

// {$B+} {$B-} {$BOOLEVAL ON} {$BOOLEVAL OFF} and the (*$...*) forms. Like Delphi,
// a local switch affecting the following text of this document; includes are
// textual, so the state continues through them. Returns False (position
// unchanged) for anything else, which ReadInclude then accepts or rejects.
function TLexer.TryReadBoolEval: Boolean;
var
  SavedIndex, SavedLine, SavedColumn, KeywordStart: Integer;
  Brace: Boolean;
  Keyword, Argument: string;
  Start: TSourcePosition;
begin
  Result := False;
  SavedIndex := FIndex; SavedLine := FLine; SavedColumn := FColumn;
  Start := Position;
  Brace := Current = '{';
  Advance;
  if not Brace then Advance;
  Advance; // '$'
  KeywordStart := FIndex;
  while CharInSet(Current, ['a'..'z', 'A'..'Z']) do Advance;
  Keyword := UpperCase(Copy(FSource, KeywordStart, FIndex - KeywordStart));
  if (Keyword <> 'B') and (Keyword <> 'BOOLEVAL') then
  begin
    FIndex := SavedIndex; FLine := SavedLine; FColumn := SavedColumn;
    Exit;
  end;
  if Keyword = 'B' then
  begin
    if not CharInSet(Current, ['+', '-']) then
      raise EShaderError.Create(Start, 'Expected {$B+} or {$B-}');
    Argument := Current;
    Advance;
  end
  else
  begin
    while CharInSet(Current, [' ', #9]) do Advance;
    KeywordStart := FIndex;
    while CharInSet(Current, ['a'..'z', 'A'..'Z']) do Advance;
    Argument := UpperCase(Copy(FSource, KeywordStart, FIndex - KeywordStart));
    if (Argument <> 'ON') and (Argument <> 'OFF') then
      raise EShaderError.Create(Start, 'Expected {$BOOLEVAL ON} or {$BOOLEVAL OFF}');
  end;
  while CharInSet(Current, [' ', #9]) do Advance;
  if Brace and (Current = '}') then Advance
  else if not Brace and (Current = '*') and (Peek = ')') then begin Advance; Advance; end
  else
    raise EShaderError.Create(Start, 'Only one $B/$BOOLEVAL switch per directive is supported');
  FCompleteBoolEval := (Argument = '+') or (Argument = 'ON');
  Result := True;
end;

function TLexer.Next: TToken;
var
  Start: Integer;
  C: Char;
begin
  SkipTrivia;
  while (((Current = '{') and (Peek = '$')) or ((Current = '(') and (Peek = '*') and
    (FIndex + 2 <= Length(FSource)) and (FSource[FIndex + 2] = '$'))) and TryReadBoolEval do
    SkipTrivia;
  Result.CompleteBoolEval := FCompleteBoolEval;
  Result.Position := Position;
  Start := FIndex;
  Result.Offset := Start;
  Result.Length := 0;
  C := Current;
  if ((C = '{') and (Peek = '$')) or ((C = '(') and (Peek = '*') and
    (FIndex + 2 <= Length(FSource)) and (FSource[FIndex + 2] = '$')) then
    Exit(ReadInclude);
  if C = #0 then
  begin
    if FIndex <= Length(FSource) then
      raise EShaderError.Create(Result.Position, 'NUL characters are not allowed');
    Result.Kind := tkEOF;
    Result.Text := '<end of file>';
    Exit;
  end;
  if IsIdentifierStart(C) then
  begin
    repeat
      Advance;
    until not (IsIdentifierStart(Current) or IsDigit(Current));
    Result.Kind := tkIdentifier;
    if FIndex - Start > MaxIdentifierLength then
      raise EShaderError.Create(Result.Position,
        Format('Identifiers are limited to %d characters', [MaxIdentifierLength]));
  end
  else if IsDigit(C) or (C = '$') then
  begin
    Result.Kind := tkInteger;
    if C = '$' then
    begin
      Advance;
      if not IsHexDigit(Current) then
        raise EShaderError.Create(Result.Position, 'Expected hexadecimal digits');
      while IsHexDigit(Current) do
        Advance;
    end
    else
    begin
      while IsDigit(Current) do
        Advance;
      if (Current = '.') and IsDigit(Peek) then
      begin
        Result.Kind := tkReal;
        Advance;
        while IsDigit(Current) do
          Advance;
      end;
      if CharInSet(Current, ['e', 'E']) then
      begin
        Result.Kind := tkReal;
        Advance;
        if CharInSet(Current, ['+', '-']) then
          Advance;
        if not IsDigit(Current) then
          raise EShaderError.Create(Result.Position, 'Expected exponent digits');
        while IsDigit(Current) do
          Advance;
      end;
    end;
    if (C <> '$') and CharInSet(Current, ['d', 'D']) then
    begin
      Result.Kind := tkDouble;
      Advance;
    end;
    if IsIdentifierStart(Current) then
      raise EShaderError.Create(Result.Position, 'Invalid numeric literal');
  end
  else
  begin
    Advance;
    case C of
      '+': Result.Kind := tkPlus;
      '-': Result.Kind := tkMinus;
      '*': Result.Kind := tkStar;
      '/': Result.Kind := tkSlash;
      '=': Result.Kind := tkEqual;
      ';': Result.Kind := tkSemicolon;
      ',': Result.Kind := tkComma;
      '.': Result.Kind := tkDot;
      '(': Result.Kind := tkLeftParen;
      ')': Result.Kind := tkRightParen;
      '[': Result.Kind := tkLeftBracket;
      ']': Result.Kind := tkRightBracket;
      ':':
        if Current = '=' then
        begin
          Advance;
          Result.Kind := tkAssign;
        end
        else
          Result.Kind := tkColon;
      '<':
        if Current = '=' then
        begin
          Advance;
          Result.Kind := tkLessEqual;
        end
        else if Current = '>' then
        begin
          Advance;
          Result.Kind := tkNotEqual;
        end
        else
          Result.Kind := tkLess;
      '>':
        if Current = '=' then
        begin
          Advance;
          Result.Kind := tkGreaterEqual;
        end
        else
          Result.Kind := tkGreater;
    else
      raise EShaderError.Create(Result.Position,
        Format('Unsupported character "%s"', [C]));
    end;
  end;
  Result.Text := Copy(FSource, Start, FIndex - Start);
  Result.Length := FIndex - Start;
end;

end.
