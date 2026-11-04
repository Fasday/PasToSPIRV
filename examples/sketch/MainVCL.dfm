object MainForm: TMainForm
  Left = 0
  Top = 0
  Caption = 'PasToSPIRV '#8212' '#1082#1072#1088#1072#1085#1076#1072#1096#1085#1099#1081' '#1101#1089#1082#1080#1079' (VCL)'
  ClientHeight = 760
  ClientWidth = 1280
  Color = clBtnFace
  Constraints.MinHeight = 480
  Constraints.MinWidth = 900
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  OnShow = FormShow
  TextHeight = 15
  object TopPanel: TPanel
    Left = 0
    Top = 0
    Width = 1280
    Height = 44
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    object RadiusLabel: TLabel
      Left = 384
      Top = 14
      Width = 60
      Height = 15
      Caption = #1056#1072#1076#1080#1091#1089': 12'
    end
    object OpenButton: TButton
      Left = 8
      Top = 9
      Width = 90
      Height = 27
      Caption = #1054#1090#1082#1088#1099#1090#1100#8230
      TabOrder = 0
      OnClick = OpenButtonClick
    end
    object TestButton: TButton
      Left = 104
      Top = 9
      Width = 160
      Height = 27
      Caption = #1058#1077#1089#1090#1086#1074#1086#1077' '#1080#1079#1086#1073#1088#1072#1078#1077#1085#1080#1077
      TabOrder = 1
      OnClick = TestButtonClick
    end
    object SizeCombo: TComboBox
      Left = 270
      Top = 11
      Width = 104
      Height = 23
      Style = csDropDownList
      TabOrder = 2
      OnChange = TestButtonClick
      Items.Strings = (
        '1280 x 720'
        '1920 x 1080'
        '3840 x 2160')
    end
    object RadiusTrack: TTrackBar
      Left = 450
      Top = 9
      Width = 150
      Height = 28
      Max = 32
      Min = 1
      Frequency = 4
      Position = 12
      TabOrder = 3
      OnChange = RadiusTrackChange
    end
    object MethodCombo: TComboBox
      Left = 608
      Top = 11
      Width = 230
      Height = 23
      Style = csDropDownList
      TabOrder = 4
    end
    object RunButton: TButton
      Left = 846
      Top = 9
      Width = 100
      Height = 27
      Caption = #1055#1086#1089#1090#1088#1086#1080#1090#1100
      Default = True
      TabOrder = 5
      OnClick = RunButtonClick
    end
    object BenchButton: TButton
      Left = 952
      Top = 9
      Width = 100
      Height = 27
      Caption = #1041#1077#1085#1095#1084#1072#1088#1082
      TabOrder = 6
      OnClick = BenchButtonClick
    end
    object SaveButton: TButton
      Left = 1058
      Top = 9
      Width = 100
      Height = 27
      Caption = #1057#1086#1093#1088#1072#1085#1080#1090#1100#8230
      TabOrder = 7
      OnClick = SaveButtonClick
    end
  end
  object OptionsPanel: TPanel
    Left = 0
    Top = 44
    Width = 1280
    Height = 40
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 4
    object OperationCombo: TComboBox
      Left = 8
      Top = 8
      Width = 256
      Height = 23
      Style = csDropDownList
      TabOrder = 0
    end
    object ThumbnailLabel: TLabel
      Left = 278
      Top = 11
      Caption = 'Fit inside:'
    end
    object ThumbnailCombo: TComboBox
      Left = 368
      Top = 8
      Width = 140
      Height = 23
      Style = csDropDownList
      TabOrder = 1
    end
    object ThumbnailHint: TLabel
      Left = 524
      Top = 11
      Caption = 'Keep aspect ratio; no upscaling'
    end
  end
  object ImagesPanel: TPanel
    Left = 0
    Top = 44
    Width = 1280
    Height = 523
    Align = alClient
    BevelOuter = bvNone
    TabOrder = 1
    OnResize = ImagesPanelResize
    object Splitter: TSplitter
      Left = 637
      Top = 0
      Width = 6
      Height = 523
      OnMoved = SplitterMoved
    end
    object SourcePanel: TPanel
      Left = 0
      Top = 0
      Width = 637
      Height = 523
      Align = alLeft
      BevelOuter = bvNone
      TabOrder = 0
      object SourceCaption: TLabel
        AlignWithMargins = True
        Left = 6
        Top = 3
        Width = 625
        Height = 15
        Margins.Left = 6
        Margins.Right = 6
        Align = alTop
        Caption = #1048#1089#1093#1086#1076#1085#1086#1077
      end
      object SourceImage: TImage
        Left = 0
        Top = 21
        Width = 637
        Height = 502
        Align = alClient
        Center = True
      end
    end
    object ResultPanel: TPanel
      Left = 643
      Top = 0
      Width = 637
      Height = 523
      Align = alClient
      BevelOuter = bvNone
      TabOrder = 1
      object ResultCaption: TLabel
        AlignWithMargins = True
        Left = 6
        Top = 3
        Width = 625
        Height = 15
        Margins.Left = 6
        Margins.Right = 6
        Align = alTop
        Caption = #1069#1089#1082#1080#1079
      end
      object ResultImage: TImage
        Left = 0
        Top = 21
        Width = 637
        Height = 502
        Align = alClient
        Center = True
      end
    end
  end
  object LogMemo: TMemo
    Left = 0
    Top = 567
    Width = 1280
    Height = 170
    Align = alBottom
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -12
    Font.Name = 'Consolas'
    Font.Style = []
    ParentFont = False
    ReadOnly = True
    ScrollBars = ssVertical
    TabOrder = 2
  end
  object StatusBar: TStatusBar
    Left = 0
    Top = 737
    Width = 1280
    Height = 23
    Panels = <>
    SimplePanel = True
  end
  object OpenDialog: TOpenDialog
    Filter = #1048#1079#1086#1073#1088#1072#1078#1077#1085#1080#1103'|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff|'#1042#1089#1077' '#1092#1072#1081#1083#1099'|*.*'
    Options = [ofHideReadOnly, ofFileMustExist, ofEnableSizing]
    Left = 40
    Top = 80
  end
  object SaveDialog: TSaveDialog
    DefaultExt = 'png'
    Filter = 'PNG|*.png'
    Options = [ofOverwritePrompt, ofHideReadOnly, ofEnableSizing]
    Left = 120
    Top = 80
  end
end
