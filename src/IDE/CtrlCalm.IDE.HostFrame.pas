unit CtrlCalm.IDE.HostFrame;

{ The frame the IDE embeds in the Ctrl+Calm dockable tool window. The IDE
  creates it from INTACustomDockableForm.GetFrameClass; the mixer view is added
  to it in FrameCreated. }

interface

uses
  System.Classes, Vcl.Controls, Vcl.Forms;

type
  TCalmHostFrame = class(TFrame)
  end;

implementation

{$R *.dfm}

end.
