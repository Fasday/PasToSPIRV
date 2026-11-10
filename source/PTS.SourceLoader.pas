unit PTS.SourceLoader;

{$BOOLEVAL OFF}

interface

uses
  System.SysUtils,
  PTS.Source;

const
  MaxSourceBytes = 8 * 1024 * 1024;
  MaxExpandedCharacters = 8 * 1024 * 1024;
  MaxSourceLines = 200000;
  MaxSourceFiles = 512;
  MaxDependencyDepth = 64;
  MaxImportsPerHeader = 4096;
  MaxDependencyEdges = 65536;

function LoadSourceProgram(const AFileName: string; const AIncludeDirectories: TArray<string>): TSourceProgram;
function LoadSourceText(const ASource, AFileName: string; const ADependencies: TArray<TSourceText>;
  const ASearchDirectories: TArray<string> = nil): TSourceProgram;

implementation

uses
  System.Classes,
  System.IOUtils,
  System.Hash,
  System.Generics.Collections,
  System.Generics.Defaults,
  PTS.Diagnostics,
  PTS.Lexer,
  PTS.Names,
  PTS.FileSafety;

type
  TImport = record
    Name: string;
    Position: TSourcePosition;
  end;

  TSourceLoader = class
  private
    FProgram: TSourceProgram;
    FRootDirectory: string;
    FIncludeDirectories: TList<string>;
    FFiles: TDictionary<string, TSourceFile>;
    FModulePaths: TDictionary<string, string>;
    FModuleStates: TDictionary<string, Integer>;
    FIncludeStack: TList<TSourceFile>;
    FModuleStack: TList<string>;
    // Fully expanded include text per physical file. Expansion is
    // context-independent, so repeated includes reuse it (no exponential work).
    FExpanded: TObjectDictionary<TSourceFile, TSourceDocument>;
    FRawBytes, FRawLines, FExpandedCharacters, FExpandedLines: Int64;
    FMemorySources: TDictionary<string, TSourceText>;
    FMemoryMode: Boolean;
    procedure Initialize;
    function ResolveMemoryFile(const AName: string; const APosition: TSourcePosition; AModule: Boolean): TSourceFile;
    function DisplayPath(const APath, AHash: string): string;
    function ReadFile(const APath: string; const APosition: TSourcePosition; ARoot: Boolean = False): TSourceFile;
    function ResolveFile(const AName: string; const APosition: TSourcePosition; AModule: Boolean): TSourceFile;
    procedure AddEdge(const APosition: TSourcePosition; ATarget: TSourceFile; const AKind: string);
    function ExpandIncludes(AFile: TSourceFile): TSourceDocument;
    function ReadHeader(ADocument: TSourceDocument; const AModuleName: string): TArray<TImport>;
    procedure LoadModule(const AImport: TImport);
    procedure CountDocument(ADocument: TSourceDocument);
  public
    constructor Create(const AFileName: string; const ADirectories: TArray<string>);
    constructor CreateText(const ASource, AFileName: string; const ADependencies: TArray<TSourceText>;
      const ADirectories: TArray<string>);
    destructor Destroy; override;
    function Load(const AFileName: string): TSourceProgram;
  end;

procedure TSourceLoader.Initialize;
begin
  FProgram := TSourceProgram.Create;
  FIncludeDirectories := TList<string>.Create;
  FFiles := TDictionary<string, TSourceFile>.Create(TIStringComparer.Ordinal);
  FModulePaths := TDictionary<string, string>.Create(TIStringComparer.Ordinal);
  FModuleStates := TDictionary<string, Integer>.Create(TIStringComparer.Ordinal);
  FIncludeStack := TList<TSourceFile>.Create;
  FModuleStack := TList<string>.Create;
  FExpanded := TObjectDictionary<TSourceFile, TSourceDocument>.Create([doOwnsValues]);
end;

// Normalizes a relative name of the virtual namespace. No exception: a search
// directory that cannot hold a dependency is skipped, not an error by itself.
function TryVirtualSourcePath(const AName: string; out APath, AError: string): Boolean;
var
  Parts: TArray<string>;
  Part: string;
  Count: Integer;
begin
  Result := False;
  AError := '';
  APath := StringReplace(AName, '\', '/', [rfReplaceAll]);
  if (APath = '') or (APath[1] = '/') or (Pos(':', APath) <> 0) or (Pos(#0, APath) <> 0) then
  begin
    AError := 'Virtual source paths must be relative and non-empty';
    Exit;
  end;
  Parts := APath.Split(['/'], TStringSplitOptions.None);
  Count := 0;
  for Part in Parts do
  begin
    if (Part = '') or (Part = '.') then
      Continue;
    if Part = '..' then
    begin
      if Count = 0 then
      begin
        AError := 'Virtual source path escapes its namespace';
        Exit;
      end;
      Dec(Count);
    end
    else
    begin
      Parts[Count] := Part;
      Inc(Count);
    end;
  end;
  if Count = 0 then
  begin
    AError := 'Virtual source paths must name a source';
    Exit;
  end;
  SetLength(Parts, Count);
  APath := string.Join('/', Parts);
  Result := True;
end;

function VirtualSourcePath(const AName: string): string;
var
  Error: string;
begin
  if not TryVirtualSourcePath(AName, Result, Error) then
    raise EArgumentException.Create(Error);
end;

constructor TSourceLoader.Create(const AFileName: string; const ADirectories: TArray<string>);
var
  Directory, RequestedDirectory, Existing: string;
  Duplicate: Boolean;
begin
  inherited Create;
  Initialize;
  FRootDirectory := TPath.GetDirectoryName(TPath.GetFullPath(AFileName));
  for RequestedDirectory in ADirectories do
  begin
    Directory := IncludeTrailingPathDelimiter(TPath.GetFullPath(RequestedDirectory));
    if not TDirectory.Exists(Directory) then
      raise EArgumentException.Create('Include directory does not exist: ' + Directory);
    Duplicate := False;
    for Existing in FIncludeDirectories do
      if AnsiSameText(Directory, Existing) or SameFileOrPath(Directory, Existing) then Duplicate := True;
    if not Duplicate then FIncludeDirectories.Add(Directory);
  end;
end;

constructor TSourceLoader.CreateText(const ASource, AFileName: string;
  const ADependencies: TArray<TSourceText>; const ADirectories: TArray<string>);
var
  Source: TSourceText;
  Directory: string;

  procedure AddSource(const AName, AText: string);
  var
    Name: string;
  begin
    Name := VirtualSourcePath(AName);
    if FMemorySources.ContainsKey(Name) then
      raise EArgumentException.Create('Duplicate virtual source: ' + Name);
    FMemorySources.Add(Name, TSourceText.Create(Name, AText));
  end;
begin
  inherited Create;
  Initialize;
  FMemoryMode := True;
  FMemorySources := TDictionary<string, TSourceText>.Create(TIStringComparer.Ordinal);
  if Length(ADependencies) >= MaxSourceFiles then
    raise EArgumentException.Create('Source file limit exceeded (512)');
  AddSource(AFileName, ASource);
  for Source in ADependencies do
    AddSource(Source.FileName, Source.Text);
  for Directory in ADirectories do
    if (Directory = '') or (Directory = '.') then
      FIncludeDirectories.Add('')
    else
      FIncludeDirectories.Add(VirtualSourcePath(Directory));
end;

destructor TSourceLoader.Destroy;
begin
  FMemorySources.Free;
  FExpanded.Free;
  FModuleStack.Free;
  FIncludeStack.Free;
  FModuleStates.Free;
  FModulePaths.Free;
  FFiles.Free;
  FIncludeDirectories.Free;
  FProgram.Free;
  inherited;
end;

function TSourceLoader.DisplayPath(const APath, AHash: string): string;
var
  I: Integer;
  Prefix: string;
begin
  if FMemoryMode then
    Exit(APath);
  Result := ExtractRelativePath(IncludeTrailingPathDelimiter(FRootDirectory), APath);
  if not TPath.IsPathRooted(Result) then Exit(StringReplace(Result, '\', '/', [rfReplaceAll]));
  for I := 0 to FIncludeDirectories.Count - 1 do
  begin
    Prefix := IncludeTrailingPathDelimiter(FIncludeDirectories[I]);
    if AnsiSameText(Copy(APath, 1, Length(Prefix)), Prefix) then
      Exit('@I' + IntToStr(I) + '/' + StringReplace(Copy(APath, Length(Prefix) + 1, MaxInt), '\', '/', [rfReplaceAll]));
  end;
  Result := '@external/' + Copy(AHash, 1, 16) + '/' + TPath.GetFileName(APath);
end;

function TSourceLoader.ReadFile(const APath: string; const APosition: TSourcePosition; ARoot: Boolean): TSourceFile;
var
  Path, Text: string;
  Bytes, RoundTrip: TBytes;
  Stream: TFileStream;
  Encoding: TUTF8Encoding;
  I, Lines: Integer;
  Hash: THashSHA2;
  Source: TSourceText;
begin
  if FMemoryMode then
  begin
    Path := VirtualSourcePath(APath);
    if not FMemorySources.TryGetValue(Path, Source) then
      raise EShaderError.Create(APosition, 'Dependency not found: ' + Path);
    Path := Source.FileName;
  end
  else
    Path := TPath.GetFullPath(APath);
  if FFiles.TryGetValue(Path, Result) then Exit;
  if FProgram.Files.Count >= MaxSourceFiles then
    raise EShaderError.Create(APosition, 'Source file limit exceeded (512)');
  try
    if FMemoryMode then
    begin
      if Length(Source.Text) > MaxSourceBytes then
        raise EShaderError.Create(APosition, 'Source input budget exceeded (8 MiB)');
      Bytes := TEncoding.UTF8.GetBytes(Source.Text);
      if FRawBytes + Length(Bytes) > MaxSourceBytes then
        raise EShaderError.Create(APosition, 'Source input budget exceeded (8 MiB)');
      if TEncoding.UTF8.GetString(Bytes) <> Source.Text then
        raise EShaderError.Create(APosition, 'Source must contain valid Unicode text');
    end
    else
    begin
      Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
      try
        if (Stream.Size > MaxSourceBytes) or (FRawBytes + Stream.Size > MaxSourceBytes) then
          raise EShaderError.Create(APosition, 'Source input budget exceeded (8 MiB)');
        SetLength(Bytes, Integer(Stream.Size));
        if Length(Bytes) > 0 then Stream.ReadBuffer(Bytes[0], Length(Bytes));
      finally
        Stream.Free;
      end;
    end;
    Encoding := TUTF8Encoding.Create(False);
    try
      try
        Text := Encoding.GetString(Bytes);
        RoundTrip := Encoding.GetBytes(Text);
      except
        on E: EEncodingError do
          raise EShaderError.Create(TSourcePosition.Create(1, 1, Path), 'Source must contain valid UTF-8: ' + E.Message);
      end;
      if (Length(RoundTrip) <> Length(Bytes)) or ((Length(Bytes) > 0) and
        not CompareMem(@RoundTrip[0], @Bytes[0], Length(Bytes))) then
        raise EShaderError.Create(TSourcePosition.Create(1, 1, Path), 'Source must contain valid UTF-8');
    finally
      Encoding.Free;
    end;
  except
    on E: EShaderError do raise;
    on E: Exception do
    begin
      if ARoot then raise;
      raise EShaderError.Create(APosition, 'Cannot read dependency "' + Path + '": ' + E.Message);
    end;
  end;
  // Physical lines; a final line terminator does not start another line.
  Lines := 0;
  for I := 1 to Length(Text) do
    if (Text[I] = #10) or ((Text[I] = #13) and ((I = Length(Text)) or (Text[I + 1] <> #10))) then Inc(Lines);
  if (Text <> '') and not CharInSet(Text[Length(Text)], [#10, #13]) then Inc(Lines);
  if FRawLines + Lines > MaxSourceLines then
    raise EShaderError.Create(APosition, 'Source line budget exceeded (200000)');
  Inc(FRawLines, Lines);
  Inc(FRawBytes, Length(Bytes));
  Result := TSourceFile.Create;
  FProgram.Files.Add(Result);
  Result.ID := FProgram.Files.Count - 1;
  Result.FullPath := Path;
  Hash := THashSHA2.Create;
  Hash.Update(Bytes);
  Result.SHA256 := LowerCase(Hash.HashAsString);
  Result.DisplayPath := DisplayPath(Path, Result.SHA256);
  Result.Raw := TSourceDocument.Create(Text, Path);
  Result.Raw.FileID := Result.ID;
  FFiles.Add(Path, Result);
end;

function TSourceLoader.ResolveFile(const AName: string; const APosition: TSourcePosition; AModule: Boolean): TSourceFile;
var
  Candidates: TList<string>;
  Name, Directory, Candidate, Existing: string;
  Duplicate: Boolean;
  I: Integer;
begin
  if FMemoryMode then
    Exit(ResolveMemoryFile(AName, APosition, AModule));
  Name := AName;
  if AModule then Name := Name + '.pasm';
  if not TPath.HasValidPathChars(Name, False) then
    raise EShaderError.Create(APosition, 'Invalid dependency path "' + AName + '"');
  if TPath.IsPathRooted(Name) or (Pos(':', Name) <> 0) then
    raise EShaderError.Create(APosition, 'Dependency paths must be relative; use -I for search directories');
  Candidates := TList<string>.Create;
  try
    try
      for I := -1 to FIncludeDirectories.Count - 1 do
      begin
        if I < 0 then Directory := TPath.GetDirectoryName(APosition.FileName)
        else Directory := FIncludeDirectories[I];
        Candidate := TPath.GetFullPath(TPath.Combine(Directory, Name));
        if not TFile.Exists(Candidate) then Continue;
        Duplicate := False;
        // The same file through another spelling/link is not an ambiguity.
        for Existing in Candidates do
          if AnsiSameText(Existing, Candidate) or SameFileOrPath(Existing, Candidate) then Duplicate := True;
        if not Duplicate then Candidates.Add(Candidate);
      end;
    except
      on E: EShaderError do raise;
      on E: Exception do
        raise EShaderError.Create(APosition, 'Invalid dependency path "' + AName + '": ' + E.Message);
    end;
    if Candidates.Count = 0 then
      raise EShaderError.Create(APosition, 'Dependency not found: ' + Name);
    if Candidates.Count > 1 then
      raise EShaderError.Create(APosition, 'Ambiguous dependency "' + Name + '": ' + string.Join(', ', Candidates.ToArray));
    Result := ReadFile(Candidates[0], APosition);
  finally
    Candidates.Free;
  end;
end;

function TSourceLoader.ResolveMemoryFile(const AName: string; const APosition: TSourcePosition;
  AModule: Boolean): TSourceFile;
var
  Name, Directory, Candidate, Found, Error, Rejected: string;
  Source: TSourceText;
  I: Integer;
begin
  Name := AName;
  if AModule then
    Name := Name + '.pasm';
  if (Name = '') or CharInSet(Name[1], ['/', '\']) or (Pos(':', Name) <> 0) then
    raise EShaderError.Create(APosition, 'Dependency paths must be relative');
  Found := '';
  Rejected := '';
  for I := -1 to FIncludeDirectories.Count - 1 do
  begin
    if I < 0 then
      Directory := Copy(APosition.FileName, 1, LastDelimiter('/', APosition.FileName))
    else if FIncludeDirectories[I] = '' then
      Directory := ''
    else
      Directory := FIncludeDirectories[I] + '/';
    // As in file mode, a directory which cannot hold the name is not searched;
    // the reason is reported only when no other directory resolves it.
    if not TryVirtualSourcePath(Directory + Name, Candidate, Error) then
    begin
      if Rejected = '' then
        Rejected := Error;
      Continue;
    end;
    if not FMemorySources.TryGetValue(Candidate, Source) then
      Continue;
    if (Found <> '') and not SameText(Found, Source.FileName) then
      raise EShaderError.Create(APosition, 'Ambiguous dependency "' + Name + '": ' + Found + ', ' + Source.FileName);
    Found := Source.FileName;
  end;
  if Found = '' then
  begin
    if Rejected <> '' then
      raise EShaderError.Create(APosition, Rejected);
    raise EShaderError.Create(APosition, 'Dependency not found: ' + Name);
  end;
  Result := ReadFile(Found, APosition);
end;

procedure TSourceLoader.AddEdge(const APosition: TSourcePosition; ATarget: TSourceFile; const AKind: string);
var
  Edge: TSourceDependency;
begin
  if FProgram.Dependencies.Count >= MaxDependencyEdges then
    raise EShaderError.Create(APosition, Format('Dependency edge budget exceeded (%d)', [MaxDependencyEdges]));
  Edge.FromID := FFiles[APosition.FileName].ID;
  Edge.ToID := ATarget.ID;
  Edge.Kind := AKind;
  Edge.Position := APosition;
  FProgram.Dependencies.Add(Edge);
end;

function CopyDocument(ASource: TSourceDocument): TSourceDocument;
begin
  // Callers mutate Text (header masking); dynamic arrays are copied explicitly.
  Result := TSourceDocument.Create('', ASource.FileName);
  Result.Text := ASource.Text;
  Result.Origins := Copy(ASource.Origins);
  Result.FileID := ASource.FileID;
end;

function LogicalLines(const AText: string): Integer;
var
  I: Integer;
begin
  if AText = '' then Exit(0);
  Result := 1;
  for I := 1 to Length(AText) do
    if AText[I] = #10 then Inc(Result);
  if AText[Length(AText)] = #10 then Dec(Result);
end;

function TSourceLoader.ExpandIncludes(AFile: TSourceFile): TSourceDocument;
var
  Lexer: TLexer;
  Token, Include: TToken;
  Includes: TDictionary<Integer, TToken>;
  Lines, ChildLines, Chain: TArray<string>;
  Origins: TList<TSourceLine>;
  Text: TStringBuilder;
  Child: TSourceDocument;
  Target: TSourceFile;
  Memo: TSourceDocument;
  I, J: Integer;
  procedure AppendLine(const AText: string; const AOrigin: TSourceLine);
  begin
    // The separator precedes every line except the first. One extra piece is the
    // empty remainder after a final newline; the exact limit is in CountDocument.
    if (Text.Length + Length(AText) + Ord(Origins.Count > 0) > MaxExpandedCharacters) or
      (Origins.Count > MaxSourceLines) then
      raise EShaderError.Create(TSourcePosition.Create(AOrigin.Line, 1, AOrigin.FileName), 'Expanded source budget exceeded');
    if Origins.Count > 0 then Text.Append(#10);
    Text.Append(AText);
    Origins.Add(AOrigin);
  end;
begin
  if FIncludeStack.Contains(AFile) then
    raise EShaderError.Create(TSourcePosition.Create(1, 1, AFile.FullPath), 'Include cycle');
  if FExpanded.TryGetValue(AFile, Memo) then Exit(CopyDocument(Memo));
  FIncludeStack.Add(AFile);
  Includes := TDictionary<Integer, TToken>.Create;
  Origins := TList<TSourceLine>.Create;
  Text := TStringBuilder.Create;
  try
    Lines := AFile.Raw.Text.Split([#10], TStringSplitOptions.None);
    Lexer := TLexer.Create(AFile.Raw);
    try
      repeat
        Token := Lexer.Next;
        if Token.Kind <> tkInclude then Continue;
        if (Trim(Copy(Lines[Token.Position.Line - 1], 1, Token.Position.Column - 1)) <> '') or
          (Trim(Copy(Lines[Token.Position.Line - 1], Token.Position.Column + Token.Length, MaxInt)) <> '') then
          raise EShaderError.Create(Token.Position, 'Include directives must occupy their own line');
        Includes.Add(Token.Position.Line, Token);
      until Token.Kind = tkEOF;
    finally
      Lexer.Free;
    end;
    for I := 0 to High(Lines) do
      if Includes.TryGetValue(I + 1, Include) then
      begin
        Target := ResolveFile(Include.Text, Include.Position, False);
        AddEdge(Include.Position, Target, 'include');
        if FIncludeStack.Contains(Target) then
        begin
          SetLength(Chain, FIncludeStack.Count + 1);
          for J := 0 to FIncludeStack.Count - 1 do Chain[J] := TPath.GetFileName(FIncludeStack[J].FullPath);
          Chain[High(Chain)] := TPath.GetFileName(Target.FullPath);
          raise EShaderError.Create(Include.Position, 'Include cycle: ' + string.Join(' -> ', Chain));
        end;
        if FIncludeStack.Count >= MaxDependencyDepth then
          raise EShaderError.Create(Include.Position, 'Include nesting limit exceeded (64)');
        Child := ExpandIncludes(Target);
        try
          ChildLines := Child.Text.Split([#10], TStringSplitOptions.None);
          for J := 0 to High(ChildLines) do AppendLine(ChildLines[J], Child.Origins[J]);
        finally
          Child.Free;
        end;
      end
      else AppendLine(Lines[I], AFile.Raw.Origins[I]);
    Result := TSourceDocument.Create('', AFile.FullPath);
    Result.Text := Text.ToString;
    Result.Origins := Origins.ToArray;
    Result.FileID := AFile.ID;
    FExpanded.Add(AFile, CopyDocument(Result));
  finally
    Text.Free;
    Origins.Free;
    Includes.Free;
    FIncludeStack.Delete(FIncludeStack.Count - 1);
  end;
end;

function TSourceLoader.ReadHeader(ADocument: TSourceDocument; const AModuleName: string): TArray<TImport>;
var
  Lexer: TLexer;
  Token: TToken;
  Imports: TList<TImport>;
  Item: TImport;
  Last, I: Integer;
  Name: string;
  procedure Next;
  begin
    Token := Lexer.Next;
  end;
  procedure Require(AKind: TTokenKind; const AMessage: string);
  begin
    if Token.Kind <> AKind then raise EShaderError.Create(Token.Position, AMessage);
  end;
  function WordIs(const AWord: string): Boolean;
  begin
    Result := (Token.Kind = tkIdentifier) and SameText(Token.Text, AWord);
  end;
begin
  Lexer := TLexer.Create(ADocument);
  Imports := TList<TImport>.Create;
  try
    Last := 0;
    Next;
    if AModuleName <> '' then
    begin
      if not WordIs('module') then
        raise EShaderError.Create(Token.Position, 'Expected module Name; declaration (.pasm is not a Delphi unit)');
      Next;
      Require(tkIdentifier, 'Expected a simple module name');
      Name := Token.Text;
      if IsReservedIdentifier(Name) then
        raise EShaderError.Create(Token.Position, 'Module names must not be reserved identifiers or built-ins');
      if not SameText(Name, AModuleName) then
        raise EShaderError.Create(Token.Position, 'Module name does not match import: expected ' + AModuleName + ', found ' + Name);
      ADocument.ModuleName := Name;
      Next;
      Require(tkSemicolon, 'Expected ";" after module name');
      Last := Token.Offset + Token.Length - 1;
      Next;
    end
    else if WordIs('module') or WordIs('unit') then
      raise EShaderError.Create(Token.Position, 'Compile a shader entry file, not a module or Delphi unit');
    if WordIs('uses') then
    begin
      Next;
      repeat
        Require(tkIdentifier, 'Expected a simple module name in uses');
        if IsReservedIdentifier(Token.Text) then
          raise EShaderError.Create(Token.Position, 'Module names must not be reserved identifiers or built-ins');
        Item.Name := Token.Text;
        Item.Position := Token.Position;
        Imports.Add(Item);
        if Imports.Count > MaxImportsPerHeader then
          raise EShaderError.Create(Token.Position, 'Uses section exceeds 4096 imports');
        Next;
        if Token.Kind <> tkComma then Break;
        Next;
      until False;
      Require(tkSemicolon, 'Expected ";" after uses');
      Last := Token.Offset + Token.Length - 1;
      Next;
    end;
    if WordIs('uses') then
      raise EShaderError.Create(Token.Position, 'Only one uses section is supported, before declarations');
    for I := 1 to Last do
      if ADocument.Text[I] <> #10 then ADocument.Text[I] := ' ';
    Result := Imports.ToArray;
  finally
    Imports.Free;
    Lexer.Free;
  end;
end;

procedure TSourceLoader.CountDocument(ADocument: TSourceDocument);
begin
  Inc(FExpandedCharacters, Length(ADocument.Text));
  Inc(FExpandedLines, LogicalLines(ADocument.Text));
  if (FExpandedCharacters > MaxExpandedCharacters) or (FExpandedLines > MaxSourceLines) then
    raise EShaderError.Create(ADocument.Position(1, 1), 'Expanded source program budget exceeded');
end;

procedure TSourceLoader.LoadModule(const AImport: TImport);
var
  FileInfo: TSourceFile;
  Path: string;
  Document: TSourceDocument;
  Imports: TArray<TImport>;
  Dependency: TImport;
  Visible: TList<string>;
  LibraryDocument: TSourceDocument;
  Name, Existing: string;
  Duplicate: Boolean;
begin
  FileInfo := ResolveFile(AImport.Name, AImport.Position, True);
  AddEdge(AImport.Position, FileInfo, 'uses');
  if FModulePaths.TryGetValue(AImport.Name, Path) then
  begin
    if not AnsiSameText(Path, FileInfo.FullPath) and
      (FMemoryMode or not SameFileOrPath(Path, FileInfo.FullPath)) then
      raise EShaderError.Create(AImport.Position, 'Conflicting files for module ' + AImport.Name);
    if FModuleStates[AImport.Name] = 1 then
      raise EShaderError.Create(AImport.Position, 'Module cycle: ' + string.Join(' -> ', FModuleStack.ToArray) + ' -> ' + AImport.Name);
    Exit;
  end;
  if FModuleStack.Count >= MaxDependencyDepth then
    raise EShaderError.Create(AImport.Position, 'Module nesting limit exceeded (64)');
  FModulePaths.Add(AImport.Name, FileInfo.FullPath);
  FModuleStates.Add(AImport.Name, 1);
  FModuleStack.Add(AImport.Name);
  Document := nil;
  try
    Document := ExpandIncludes(FileInfo);
    Imports := ReadHeader(Document, AImport.Name);
    for Dependency in Imports do LoadModule(Dependency);
    Visible := TList<string>.Create;
    try
      for Dependency in Imports do
        for LibraryDocument in FProgram.Libraries do
          if SameText(Dependency.Name, LibraryDocument.ModuleName) then
          begin
            if not Visible.Contains(LibraryDocument.ModuleName) then Visible.Add(LibraryDocument.ModuleName);
            for Name in LibraryDocument.VisibleModules do
            begin
              Duplicate := False;
              for Existing in Visible do if SameText(Existing, Name) then Duplicate := True;
              if not Duplicate then Visible.Add(Name);
            end;
          end;
      Document.VisibleModules := Visible.ToArray;
    finally
      Visible.Free;
    end;
    CountDocument(Document);
    FProgram.Libraries.Add(Document);
    Document := nil;
    FModuleStates[AImport.Name] := 2;
  finally
    Document.Free;
    FModuleStack.Delete(FModuleStack.Count - 1);
  end;
end;

function TSourceLoader.Load(const AFileName: string): TSourceProgram;
var
  RootFile: TSourceFile;
  Dependency: TImport;
begin
  if FMemoryMode then
    RootFile := ReadFile(AFileName, TSourcePosition.Create(1, 1, AFileName), True)
  else
  begin
    if not TFile.Exists(TPath.GetFullPath(AFileName)) then
      raise EFileNotFoundException.Create('Input file not found: ' + TPath.GetFullPath(AFileName));
    RootFile := ReadFile(TPath.GetFullPath(AFileName), TSourcePosition.Create(1, 1, TPath.GetFullPath(AFileName)), True);
  end;
  FProgram.Root := ExpandIncludes(RootFile);
  for Dependency in ReadHeader(FProgram.Root, '') do LoadModule(Dependency);
  CountDocument(FProgram.Root);
  Result := FProgram;
  FProgram := nil;
end;

function LoadSourceProgram(const AFileName: string; const AIncludeDirectories: TArray<string>): TSourceProgram;
var
  Loader: TSourceLoader;
begin
  Loader := TSourceLoader.Create(AFileName, AIncludeDirectories);
  try
    Result := Loader.Load(AFileName);
  finally
    Loader.Free;
  end;
end;

function LoadSourceText(const ASource, AFileName: string; const ADependencies: TArray<TSourceText>;
  const ASearchDirectories: TArray<string>): TSourceProgram;
var
  Loader: TSourceLoader;
begin
  Loader := TSourceLoader.CreateText(ASource, AFileName, ADependencies, ASearchDirectories);
  try
    Result := Loader.Load(AFileName);
  finally
    Loader.Free;
  end;
end;

end.
