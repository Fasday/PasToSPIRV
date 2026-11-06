unit PTS.Component;

interface

uses
  System.Classes, PTS.Source, PTS.Compiler;

type
  TShaderCompilerComponent = class(TComponent)
  private
    FSourceName: string;
    FBindingsUnit: string;
    FEntryPointName: string;
    FOptimize: Boolean;
    FSearchDirectories: TStringList;
    function GetSearchDirectories: TStrings;
    procedure SetSearchDirectories(const Value: TStrings);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function Compile(const Source: string;
      const Dependencies: TArray<TSourceText> = nil): TCompilationResult;
  published
    property SourceName: string read FSourceName write FSourceName;
    property BindingsUnit: string read FBindingsUnit write FBindingsUnit;
    property EntryPointName: string read FEntryPointName write FEntryPointName;
    property Optimize: Boolean read FOptimize write FOptimize default False;
    property SearchDirectories: TStrings read GetSearchDirectories write SetSearchDirectories;
  end;

implementation

constructor TShaderCompilerComponent.Create(AOwner: TComponent);
begin
  inherited;
  FSourceName := 'shader.pas';
  FEntryPointName := 'Main';
  FSearchDirectories := TStringList.Create;
end;

destructor TShaderCompilerComponent.Destroy;
begin
  FSearchDirectories.Free;
  inherited;
end;

function TShaderCompilerComponent.GetSearchDirectories: TStrings;
begin
  Result := FSearchDirectories;
end;

procedure TShaderCompilerComponent.SetSearchDirectories(const Value: TStrings);
begin
  FSearchDirectories.Assign(Value);
end;

function TShaderCompilerComponent.Compile(const Source: string;
  const Dependencies: TArray<TSourceText>): TCompilationResult;
begin
  Result := TShaderCompiler.CompileText(Source, FSourceName, Dependencies,
    FSearchDirectories.ToStringArray, FBindingsUnit, FOptimize, FEntryPointName);
end;

end.
