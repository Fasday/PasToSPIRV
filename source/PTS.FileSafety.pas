unit PTS.FileSafety;

{$BOOLEVAL OFF}

interface

// Identity checks are output-safety checks, not a filesystem/security sandbox.
function CanonicalFilePath(const APath: string): string;
function FileIdentityKey(const APath: string): string;
function SameFileOrPath(const ALeft, ARight: string): Boolean;
// Key equal for every spelling of one destination, existing or not: the file ID
// if it exists, otherwise the deepest existing ancestor's ID plus a folded tail.
function DestinationKey(const APath: string): string;
// Rejects alternate data streams and other ':' uses outside a drive prefix.
procedure ValidateOutputPath(const APath: string);

implementation

{$WARN SYMBOL_PLATFORM OFF}

uses
  System.SysUtils, System.IOUtils
  {$IFDEF MSWINDOWS}, Winapi.Windows{$ENDIF};

{$IFDEF MSWINDOWS}
function OpenMetadata(const APath: string): THandle;
begin
  Result := CreateFile(PChar(APath), 0, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
    nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, 0);
end;

function FinalPath(const APath: string): string;
var H: THandle; Required, Count: DWORD;
begin
  Result := '';
  H := OpenMetadata(APath);
  if H = INVALID_HANDLE_VALUE then Exit;
  try
    Required := GetFinalPathNameByHandle(H, nil, 0, 0);
    if Required = 0 then Exit;
    SetLength(Result, Required + 1);
    Count := GetFinalPathNameByHandle(H, PChar(Result), Length(Result), 0);
    if (Count = 0) or (Count >= DWORD(Length(Result))) then begin Result := ''; Exit; end;
    SetLength(Result, Count);
    if SameText(Copy(Result,1,8), '\\?\UNC\') then Result := '\\' + Copy(Result,9,MaxInt)
    else if (Copy(Result,1,4) = '\\?\') and (Length(Result) > 5) and (Result[6] = ':') then
      Delete(Result,1,4);
  finally CloseHandle(H); end;
end;
{$ENDIF}

function FileIdentityKey(const APath: string): string;
{$IFDEF MSWINDOWS}
var H: THandle; Info: TByHandleFileInformation;
{$ENDIF}
begin
  Result := '';
  if APath = '' then Exit;
  {$IFDEF MSWINDOWS}
  H := OpenMetadata(TPath.GetFullPath(APath));
  if H = INVALID_HANDLE_VALUE then Exit;
  try
    if GetFileInformationByHandle(H, Info) and
      ((Info.nFileIndexHigh <> 0) or (Info.nFileIndexLow <> 0)) then
      Result := IntToHex(Info.dwVolumeSerialNumber,8) + ':' +
        IntToHex(Info.nFileIndexHigh,8) + ':' + IntToHex(Info.nFileIndexLow,8);
  finally CloseHandle(H); end;
  {$ENDIF}
end;

function CanonicalFilePath(const APath: string): string;
var Full, Current, Parent, Tail, Resolved: string;
begin
  if APath = '' then Exit('');
  Full := TPath.GetFullPath(APath);
  Result := Full;
  {$IFDEF MSWINDOWS}
  Current := Full; Tail := '';
  while not TFile.Exists(Current) and not TDirectory.Exists(Current) do
  begin
    Parent := TPath.GetDirectoryName(Current);
    if (Parent = '') or SameText(Parent,Current) then Exit;
    Tail := TPath.Combine(TPath.GetFileName(Current),Tail);
    Current := Parent;
  end;
  Resolved := FinalPath(Current);
  if Resolved <> '' then
    if Tail = '' then Result := Resolved
    else Result := TPath.GetFullPath(TPath.Combine(Resolved,Tail));
  {$ENDIF}
end;

function FoldComponent(const AName: string): string;
var
  L: Integer;
begin
  // Win32 ignores trailing dots/spaces; NTFS names compare case-insensitively.
  L := Length(AName);
  while (L > 0) and CharInSet(AName[L], ['.', ' ']) do Dec(L);
  Result := AnsiUpperCase(Copy(AName, 1, L));
end;

function DestinationKey(const APath: string): string;
var
  Full, Current, Parent, Tail, Identity: string;
begin
  if APath = '' then Exit('');
  Full := TPath.GetFullPath(APath);
  Identity := FileIdentityKey(Full);
  if Identity <> '' then Exit('F:' + Identity);
  Current := Full;
  Tail := '';
  while not TFile.Exists(Current) and not TDirectory.Exists(Current) do
  begin
    Parent := TPath.GetDirectoryName(Current);
    if (Parent = '') or SameText(Parent, Current) then
      Exit('P:' + AnsiUpperCase(Full));
    Tail := '\' + FoldComponent(TPath.GetFileName(Current)) + Tail;
    Current := Parent;
  end;
  Identity := FileIdentityKey(Current);
  if Identity <> '' then Result := 'D:' + Identity + Tail
  else Result := 'P:' + AnsiUpperCase(CanonicalFilePath(Current)) + Tail;
end;

procedure ValidateOutputPath(const APath: string);
var
  Full: string;
  I, First: Integer;
begin
  Full := TPath.GetFullPath(APath);
  First := 1;
  if Copy(Full, 1, 4) = '\\?\' then First := 5;
  for I := First to Length(Full) do
    if (Full[I] = ':') and not ((I = First + 1) and CharInSet(Full[First], ['A'..'Z', 'a'..'z'])) then
      raise EArgumentException.Create('Output paths must not use alternate data streams or ":" : ' + APath);
  if CharInSet(Full[Length(Full)], ['\', '/']) then
    raise EArgumentException.Create('Output path must name a file: ' + APath);
end;

function SameFileOrPath(const ALeft, ARight: string): Boolean;
begin
  if (ALeft = '') or (ARight = '') then Exit(False);
  if AnsiSameText(TPath.GetFullPath(ALeft), TPath.GetFullPath(ARight)) then Exit(True);
  Result := DestinationKey(ALeft) = DestinationKey(ARight);
end;

end.
