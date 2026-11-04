unit PTS.Project;

{$BOOLEVAL OFF}

interface

type
  TBuildStatistics = record
    Built: Integer;
    Cached: Integer;
  end;

function BuildProject(const AFileName: string; AForce: Boolean; const ACompilerIdentity: string): TBuildStatistics;

implementation

uses
  System.SysUtils, System.Classes, System.JSON, System.IOUtils, System.Hash,
  System.Generics.Collections, System.Generics.Defaults,
  PTS.Source, PTS.SourceLoader, PTS.Compiler, PTS.FileSafety, PTS.Bindings;

type
  TEntry = class
    Source, Output, Reflection, Bindings, Cache, UnitName: string;
    Optimize: Boolean;
    ProgramSource: TSourceProgram;
    destructor Destroy; override;
  end;

destructor TEntry.Destroy;
begin ProgramSource.Free; inherited; end;

function TextProperty(O: TJSONObject; const Key: string; const Default: string = ''): string;
var V: TJSONValue;
begin
  V := O.GetValue(Key);
  if V = nil then Exit(Default);
  if not (V is TJSONString) then raise EArgumentException.Create('Project property must be a string: ' + Key);
  Result := V.Value;
end;

function BoolProperty(O: TJSONObject; const Key: string; Default: Boolean): Boolean;
var V: TJSONValue;
begin
  V := O.GetValue(Key);
  if V = nil then Exit(Default);
  if not (V is TJSONBool) then raise EArgumentException.Create('Project property must be Boolean: ' + Key);
  Result := SameText(V.Value, 'true');
end;

procedure CheckProperties(O: TJSONObject; const Allowed: string);
var P: TJSONPair; Seen: TDictionary<string, Boolean>;
begin
  // GetValue would silently use the first of duplicate keys; reject them instead.
  Seen := TDictionary<string, Boolean>.Create;
  try
    for P in O do
    begin
      if Pos('|' + P.JsonString.Value + '|', Allowed) = 0 then
        raise EArgumentException.Create('Unknown project property: ' + P.JsonString.Value);
      if Seen.ContainsKey(P.JsonString.Value) then
        raise EArgumentException.Create('Duplicate project property: ' + P.JsonString.Value);
      Seen.Add(P.JsonString.Value, True);
    end;
  finally Seen.Free; end;
end;

function Resolve(const Base, Name: string): string;
begin
  if Name = '' then Exit('');
  Result := TPath.GetFullPath(TPath.Combine(Base, Name));
end;

function DigestFile(const Path: string): string;
begin Result := LowerCase(THashSHA2.GetHashStringFromFile(Path)); end;

function Fingerprint(E: TEntry; const Directories: TArray<string>; const Identity: string): string;
var
  B: TStringBuilder; F: TSourceFile; D: TSourceDocument; Edge: TSourceDependency; S: string;
begin
  B := TStringBuilder.Create;
  try
    B.AppendLine('PasToSPIRV-project-v1').AppendLine(CompilerVersion).AppendLine(Identity);
    // Profile attributes are in the hashed source snapshot.
    B.AppendLine('source-selected-compute-profile/std430-v2').AppendLine(BoolToStr(E.Optimize,True)).AppendLine(E.UnitName);
    for S in Directories do B.AppendLine(S);
    for F in E.ProgramSource.Files do B.AppendLine(F.DisplayPath).AppendLine(F.SHA256);
    for D in E.ProgramSource.Libraries do B.AppendLine(D.ModuleName).AppendLine(IntToStr(D.FileID));
    for Edge in E.ProgramSource.Dependencies do
      B.AppendLine(Format('%d:%d:%s:%d:%d',[Edge.FromID,Edge.ToID,Edge.Kind,Edge.Position.Line,Edge.Position.Column]));
    Result := LowerCase(THashSHA2.GetHashString(B.ToString));
  finally B.Free; end;
end;

function CacheValid(E: TEntry; const Key: string): Boolean;
var V: TJSONValue; O: TJSONObject;
begin
  Result := False;
  if not TFile.Exists(E.Cache) or not TFile.Exists(E.Output) or not TFile.Exists(E.Reflection) then Exit;
  if TFile.GetSize(E.Cache) > 65536 then Exit;
  if (E.Bindings <> '') and not TFile.Exists(E.Bindings) then Exit;
  V := nil;
  try
    try
      V := TJSONObject.ParseJSONValue(TFile.ReadAllText(E.Cache, TEncoding.UTF8));
      if not (V is TJSONObject) then Exit;
      O := TJSONObject(V);
      if TextProperty(O,'key') <> Key then Exit;
      if TextProperty(O,'spirv_sha256') <> DigestFile(E.Output) then Exit;
      if TextProperty(O,'reflection_sha256') <> DigestFile(E.Reflection) then Exit;
      if (E.Bindings <> '') and (TextProperty(O,'bindings_sha256') <> DigestFile(E.Bindings)) then Exit;
      Result := True;
    except
      on E: Exception do Result := False; // Damaged/unreadable cache is a miss, not a source error.
    end;
  finally V.Free; end;
end;

procedure WriteText(const Path, Text: string);
begin
  TDirectory.CreateDirectory(TPath.GetDirectoryName(Path));
  TFile.WriteAllBytes(Path,TEncoding.UTF8.GetBytes(Text));
end;

function BuildProject(const AFileName: string; AForce: Boolean; const ACompilerIdentity: string): TBuildStatistics;
var
  ProjectPath, Base, Key: string;
  RootValue: TJSONValue; Root, Item, Cache: TJSONObject;
  Entries: TObjectList<TEntry>; E: TEntry;
  InputPaths, OutputPaths: TDictionary<string,Boolean>;
  Directories: TArray<string>; V: TJSONValue; A: TJSONArray;
  FileInfo: TSourceFile; Document: TSourceDocument;
  C: TCompilationResult; I: Integer; Total: Int64; DefaultOptimize: Boolean;
  procedure RegisterInput(const Name: string);
  begin
    InputPaths.AddOrSetValue(DestinationKey(Name),True);
    InputPaths.AddOrSetValue('C:' + AnsiUpperCase(CanonicalFilePath(Name)),True);
  end;
  procedure RegisterOutput(const Name: string);
  var Key, Canonical: string;
  begin
    if Name = '' then Exit;
    ValidateOutputPath(Name);
    // Compare destinations, not spellings: also catches outputs that do not exist yet.
    Key := DestinationKey(Name);
    Canonical := 'C:' + AnsiUpperCase(CanonicalFilePath(Name));
    if InputPaths.ContainsKey(Key) or InputPaths.ContainsKey(Canonical) then
      raise EArgumentException.Create('Project output collides with an input: ' + Name);
    if OutputPaths.ContainsKey(Key) or OutputPaths.ContainsKey(Canonical) then
      raise EArgumentException.Create('Duplicate project output: ' + Name);
    OutputPaths.Add(Key,True);
    OutputPaths.AddOrSetValue(Canonical,True);
  end;
begin
  Result := Default(TBuildStatistics);
  ProjectPath := TPath.GetFullPath(AFileName); Base := TPath.GetDirectoryName(ProjectPath);
  if TFile.GetSize(ProjectPath) > 1024 * 1024 then raise EArgumentException.Create('Project JSON exceeds 1 MiB');
  RootValue := TJSONObject.ParseJSONValue(TFile.ReadAllText(ProjectPath,TEncoding.UTF8));
  Entries := TObjectList<TEntry>.Create(True);
  InputPaths := TDictionary<string,Boolean>.Create(TIStringComparer.Ordinal);
  OutputPaths := TDictionary<string,Boolean>.Create(TIStringComparer.Ordinal);
  try
    if not (RootValue is TJSONObject) then raise EArgumentException.Create('Expected a project JSON object');
    Root := TJSONObject(RootValue);
    CheckProperties(Root,'|format_version|include_directories|optimize|entries|');
    V := Root.GetValue('format_version');
    if (V = nil) or not (V is TJSONNumber) or (V.Value <> '1') then raise EArgumentException.Create('Project format_version must be 1');
    DefaultOptimize := BoolProperty(Root,'optimize',False);
    V := Root.GetValue('include_directories');
    if V <> nil then
    begin
      if not (V is TJSONArray) then raise EArgumentException.Create('include_directories must be an array');
      A := TJSONArray(V); SetLength(Directories,A.Count);
      for I := 0 to A.Count - 1 do
      begin
        if not (A.Items[I] is TJSONString) then raise EArgumentException.Create('Include directories must be strings');
        Directories[I] := Resolve(Base,A.Items[I].Value);
      end;
    end;
    V := Root.GetValue('entries');
    if not (V is TJSONArray) then raise EArgumentException.Create('entries must be an array');
    A := TJSONArray(V);
    if (A.Count = 0) or (A.Count > 256) then raise EArgumentException.Create('Project must contain 1..256 entries');
    RegisterInput(ProjectPath); Total := 0;
    for I := 0 to A.Count - 1 do
    begin
      if not (A.Items[I] is TJSONObject) then raise EArgumentException.Create('Entry must be an object');
      Item := TJSONObject(A.Items[I]); CheckProperties(Item,'|source|output|reflection|bindings|optimize|');
      E := TEntry.Create; Entries.Add(E);
      E.Source := Resolve(Base,TextProperty(Item,'source'));
      E.Output := Resolve(Base,TextProperty(Item,'output'));
      if (E.Source = '') or (E.Output = '') then raise EArgumentException.Create('Entry source and output are required');
      E.Reflection := Resolve(Base,TextProperty(Item,'reflection'));
      if E.Reflection = '' then E.Reflection := ChangeFileExt(E.Output,'.json');
      E.Bindings := Resolve(Base,TextProperty(Item,'bindings'));
      if E.Bindings <> '' then
      begin
        if not SameText(TPath.GetExtension(E.Bindings),'.pas') then raise EArgumentException.Create('Bindings require .pas');
        E.UnitName := TPath.GetFileNameWithoutExtension(E.Bindings);
        if E.UnitName = '' then raise EArgumentException.Create('Bindings require a unit name');
        // Same rules as generation, but before any entry writes artifacts.
        ValidateUnitName(E.UnitName);
      end;
      E.Cache := E.Output + '.cache.json'; E.Optimize := BoolProperty(Item,'optimize',DefaultOptimize);
      // Re-resolve even on a cache hit: a new shadowing/ambiguous module must not be ignored.
      E.ProgramSource := LoadSourceProgram(E.Source,Directories);
      Inc(Total,Length(E.ProgramSource.Root.Text));
      for Document in E.ProgramSource.Libraries do Inc(Total,Length(Document.Text));
      if Total > 32 * 1024 * 1024 then raise EArgumentException.Create('Project expanded source budget exceeds 32 Mi characters');
      for FileInfo in E.ProgramSource.Files do RegisterInput(FileInfo.FullPath);
    end;
    for E in Entries do
    begin
      RegisterOutput(E.Output); RegisterOutput(E.Reflection); RegisterOutput(E.Bindings); RegisterOutput(E.Cache);
    end;
    for E in Entries do
    begin
      Key := Fingerprint(E,Directories,ACompilerIdentity);
      if not AForce and (ACompilerIdentity <> '') and CacheValid(E,Key) then
      begin Inc(Result.Cached); Continue; end;
      C := TShaderCompiler.CompileResolved(E.ProgramSource,E.UnitName,E.Optimize);
      TDirectory.CreateDirectory(TPath.GetDirectoryName(E.Output));
      TFile.WriteAllBytes(E.Output,C.SPIRV); WriteText(E.Reflection,C.Reflection);
      if E.Bindings <> '' then WriteText(E.Bindings,C.Bindings);
      Cache := TJSONObject.Create;
      try
        Cache.AddPair('key',Key); Cache.AddPair('compiler_version',CompilerVersion);
        Cache.AddPair('spirv_sha256',DigestFile(E.Output));
        Cache.AddPair('reflection_sha256',DigestFile(E.Reflection));
        if E.Bindings <> '' then Cache.AddPair('bindings_sha256',DigestFile(E.Bindings));
        WriteText(E.Cache,Cache.Format(2));
      finally Cache.Free; end;
      Inc(Result.Built);
    end;
  finally
    OutputPaths.Free; InputPaths.Free; Entries.Free; RootValue.Free;
  end;
end;

end.
