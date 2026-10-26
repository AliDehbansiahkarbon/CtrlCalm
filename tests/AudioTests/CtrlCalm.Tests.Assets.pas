unit CtrlCalm.Tests.Assets;

{ Verifies the bundled sound assets: every recorded catalog sound has a file,
  the file parses with the production WAV parser, and it matches the checksum
  and metadata recorded in assets/sounds/manifest.json. }

interface

implementation

uses
  System.SysUtils, System.Classes, System.IOUtils, System.JSON, System.Hash,
  CtrlCalm.TestFramework, CtrlCalm.Core.Types, CtrlCalm.Audio.Wav;

function AssetsFolder: string;
var
  Dir: string;
  I: Integer;
begin
  Dir := ExtractFilePath(ParamStr(0));
  for I := 0 to 8 do
  begin
    if FileExists(TPath.Combine(Dir, 'assets\sounds\manifest.json')) then
      Exit(TPath.Combine(Dir, 'assets'));
    Dir := ExtractFilePath(ExcludeTrailingPathDelimiter(Dir));
  end;
  Result := '';
end;

procedure Register;
begin
  RegisterTest('Assets', 'ManifestCoversCatalogWithProvenance',
    procedure
    var
      Root, Json: string;
      Doc: TJSONValue;
      Items: TJSONArray;
      Item: TJSONValue;
      O: TJSONObject;
      S: TSoundId;
      Found: Boolean;
      Key: string;
    begin
      Root := AssetsFolder;
      Check(Root <> '', 'assets folder with manifest.json not found');
      Json := TFile.ReadAllText(TPath.Combine(Root, 'sounds\manifest.json'), TEncoding.UTF8);
      Doc := TJSONObject.ParseJSONValue(Json);
      try
        Items := (Doc as TJSONObject).GetValue('sounds') as TJSONArray;
        CheckEquals(16, Items.Count, 'manifest entries');
        for S := Low(TSoundId) to High(TSoundId) do
        begin
          Found := False;
          for Item in Items do
          begin
            O := Item as TJSONObject;
            if O.GetValue<string>('id') <> SoundKey(S) then
              Continue;
            Found := True;
            Key := SoundKey(S);
            Check(O.GetValue<string>('license') <> '', Key + ' license');
            Check(O.GetValue<string>('creator') <> '', Key + ' creator');
            if SoundDef(S).Kind = skRecorded then
            begin
              CheckEquals(SoundDef(S).FileName, O.GetValue<string>('file'), Key + ' file name');
              Check(O.GetValue<string>('sourceUrl').StartsWith('https://'), Key + ' source url');
              Check(O.GetValue<string>('licenseUrl').StartsWith('https://'), Key + ' license url');
              Check(O.GetValue<string>('originalFilename') <> '', Key + ' original file');
              Check(O.GetValue<string>('acquired') <> '', Key + ' acquisition date');
              Check(O.GetValue<string>('processing') <> '', Key + ' processing notes');
              Check(Length(O.GetValue<string>('sha256')) = 64, Key + ' checksum');
            end;
          end;
          Check(Found, SoundKey(S) + ' missing from manifest');
        end;
        Check(FileExists(TPath.Combine(Root, 'ATTRIBUTION.md')), 'ATTRIBUTION.md');
        Check(FileExists(TPath.Combine(Root, 'LICENSES.md')), 'LICENSES.md');
      finally
        Doc.Free;
      end;
    end);

  RegisterTest('Assets', 'BundledFilesParseAndMatchChecksums',
    procedure
    var
      Root, Json, FileName: string;
      Doc: TJSONValue;
      Item: TJSONValue;
      O: TJSONObject;
      Info: TWavInfo;
      Err: string;
      Total: Int64;
      Count: Integer;
    begin
      Root := AssetsFolder;
      Check(Root <> '', 'assets folder not found');
      Json := TFile.ReadAllText(TPath.Combine(Root, 'sounds\manifest.json'), TEncoding.UTF8);
      Doc := TJSONObject.ParseJSONValue(Json);
      Total := 0;
      Count := 0;
      try
        for Item in ((Doc as TJSONObject).GetValue('sounds') as TJSONArray) do
        begin
          O := Item as TJSONObject;
          if O.GetValue<string>('kind') <> 'recorded' then
            Continue;
          FileName := TPath.Combine(Root, 'sounds\' + O.GetValue<string>('file'));
          Check(ParseWavFile(FileName, Info, Err), FileName + ': ' + Err);
          Check(Info.DurationSeconds >= 9, FileName + ' long enough to loop');
          CheckNear(O.GetValue<Double>('durationSeconds'), Info.DurationSeconds, 0.01, FileName + ' duration');
          CheckEquals(O.GetValue<string>('sha256'), THashSHA2.GetHashStringFromFile(FileName), FileName + ' checksum');
          Inc(Total, TFile.GetSize(FileName));
          Inc(Count);
        end;
      finally
        Doc.Free;
      end;
      CheckEquals(13, Count, 'recorded sounds');
      Report('assets', Format('%d recorded loops, %.1f MB', [Count, Total / 1048576]));
    end);
end;

initialization
  Register;

end.
