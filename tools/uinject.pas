{ uinject: scripted virtual mouse (uinput) for testing TUI mouse handling
  through the real mousedev -> gpm -> ncurses path.

  Reads commands from stdin, one per line:
    m DX DY     relative move (sent in small steps)
    d L|R|M     button down        u L|R|M   button up
    c L|R|M     click              w N       wheel (+ up, - down)
    s MS        sleep              # ...     comment }
program uinject;

{$mode objfpc}{$H+}

uses
  BaseUnix, SysUtils;

const
  EV_SYN = 0; EV_KEY = 1; EV_REL = 2;
  REL_X = 0; REL_Y = 1; REL_WHEEL = 8;
  BTN_LEFT = $110; BTN_RIGHT = $111; BTN_MIDDLE = $112;
  BUS_VIRTUAL = 6;
  UI_SET_EVBIT  = $40045564;
  UI_SET_KEYBIT = $40045565;
  UI_SET_RELBIT = $40045566;
  UI_DEV_SETUP  = $405C5503;
  UI_DEV_CREATE = $5501;
  UI_DEV_DESTROY = $5502;
  STEP = 4;

type
  TInputEvent = packed record
    Sec, USec: Int64;
    Typ, Code: Word;
    Value: LongInt;
  end;

  TUInputSetup = packed record
    BusType, Vendor, Product, Version: Word;
    Name: array[0..79] of Char;
    FFEffectsMax: LongWord;
  end;

var
  Fd: cint;

procedure Emit(Typ, Code: Word; Value: LongInt; Sync: Boolean = True);
var
  Ev: TInputEvent;
begin
  FillChar(Ev, SizeOf(Ev), 0);
  Ev.Typ := Typ;
  Ev.Code := Code;
  Ev.Value := Value;
  FpWrite(Fd, Ev, SizeOf(Ev));
  if Sync then
  begin
    Ev.Typ := EV_SYN; Ev.Code := 0; Ev.Value := 0;
    FpWrite(Fd, Ev, SizeOf(Ev));
  end;
end;

procedure Pause(Ms: Integer);
begin
  Sleep(Ms);
end;

function Btn(const S: string): Word;
begin
  case UpCase(S[1]) of
    'R': Result := BTN_RIGHT;
    'M': Result := BTN_MIDDLE;
  else
    Result := BTN_LEFT;
  end;
end;

procedure Move(DX, DY: Integer);
var
  SX, SY: Integer;
begin
  while (DX <> 0) or (DY <> 0) do
  begin
    SX := DX; if SX > STEP then SX := STEP; if SX < -STEP then SX := -STEP;
    SY := DY; if SY > STEP then SY := STEP; if SY < -STEP then SY := -STEP;
    Emit(EV_REL, REL_X, SX, False);
    Emit(EV_REL, REL_Y, SY);
    Dec(DX, SX); Dec(DY, SY);
    Pause(8);
  end;
end;

var
  Setup: TUInputSetup;
  Line: string;
  P: TStringArray;
  I: Integer;
begin
  Fd := FpOpen('/dev/uinput', O_WRONLY or O_NONBLOCK);
  if Fd < 0 then
  begin
    WriteLn(StdErr, 'cannot open /dev/uinput');
    Halt(1);
  end;
  FpIOCtl(Fd, UI_SET_EVBIT, Pointer(EV_KEY));
  FpIOCtl(Fd, UI_SET_KEYBIT, Pointer(BTN_LEFT));
  FpIOCtl(Fd, UI_SET_KEYBIT, Pointer(BTN_RIGHT));
  FpIOCtl(Fd, UI_SET_KEYBIT, Pointer(BTN_MIDDLE));
  FpIOCtl(Fd, UI_SET_EVBIT, Pointer(EV_REL));
  FpIOCtl(Fd, UI_SET_RELBIT, Pointer(REL_X));
  FpIOCtl(Fd, UI_SET_RELBIT, Pointer(REL_Y));
  FpIOCtl(Fd, UI_SET_RELBIT, Pointer(REL_WHEEL));
  FillChar(Setup, SizeOf(Setup), 0);
  Setup.BusType := BUS_VIRTUAL;
  Setup.Vendor := $1209;
  Setup.Product := $35AF;
  Setup.Version := 1;
  StrPLCopy(Setup.Name, 'uinject mouse', High(Setup.Name));
  if (FpIOCtl(Fd, UI_DEV_SETUP, @Setup) < 0) or
     (FpIOCtl(Fd, UI_DEV_CREATE, nil) < 0) then
  begin
    WriteLn(StdErr, 'cannot create uinput device');
    Halt(1);
  end;
  Pause(500);   { let mousedev/gpm pick the device up }
  while not EOF(Input) do
  begin
    ReadLn(Line);
    Line := Trim(Line);
    if (Line = '') or (Line[1] = '#') then
      Continue;
    P := Line.Split([' '], TStringSplitOptions.ExcludeEmpty);
    case P[0] of
      'm': Move(StrToInt(P[1]), StrToInt(P[2]));
      'd': Emit(EV_KEY, Btn(P[1]), 1);
      'u': Emit(EV_KEY, Btn(P[1]), 0);
      'c':
        begin
          Emit(EV_KEY, Btn(P[1]), 1); Pause(40);
          Emit(EV_KEY, Btn(P[1]), 0);
        end;
      'w':
        for I := 1 to Abs(StrToInt(P[1])) do
        begin
          if StrToInt(P[1]) > 0 then Emit(EV_REL, REL_WHEEL, 1)
          else Emit(EV_REL, REL_WHEEL, -1);
          Pause(30);
        end;
      's': Pause(StrToInt(P[1]));
    end;
    Pause(20);
  end;
  Pause(200);
  FpIOCtl(Fd, UI_DEV_DESTROY, nil);
  FpClose(Fd);
end.
