 (*
 * Hedgewars, a free turn based strategy game
 * Copyright (c) 2004-2015 Andrey Korotaev <unC0Rr@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; version 2 of the License
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 *)

{$INCLUDE "options.inc"}

unit uTeams;
interface
uses sysutils, uConsts, uInputHandler, uRandom, uFloat, uStats,
     uCollisions, uSound, uStore, uTypes, uScript, uRenderUtils
     {$IFDEF USE_TOUCH_INTERFACE}, uWorld{$ENDIF};


procedure initModule;
procedure freeModule;

function  AddTeam(TeamColor: Longword): PTeam;
procedure SwitchHedgehog;
procedure AfterSwitchHedgehog;
procedure InitTeams;
function  TeamSize(p: PTeam): Longword;
procedure RecountTeamHealth(team: PTeam);
procedure RecountClanHealth(clan: PClan);
procedure RecountAllTeamsHealth();
procedure RestoreHog(HH: PHedgehog);

procedure RestoreTeamsFromSave;
function  CheckForWin: boolean;
procedure TeamGoneEffect(var Team: TTeam);
procedure SwitchCurrentHedgehog(newHog: PHedgehog);

procedure SwitchClan(p: PTeam; c: PClan);
function GetClanColor(i: Integer): LongInt;
procedure SplitClans;
procedure UpdateClanVisuals(clan: PClan);
function AddEmptyClan(color: LongInt): PClan;

var MaxTeamHealth: LongInt;

implementation
uses uLocale, uAmmos, uChat, uVariables, uUtils, uIO, uCaptions, uCommands, uDebug,
    uGearsUtils, uGearsList, uVisualGearsList, uTextures
    {$IFDEF USE_TOUCH_INTERFACE}, uTouch{$ENDIF};

var GameOver: boolean;
    NextClan: boolean;


function FindTeamIndex(p: PTeam): Integer;
var
  i: LongInt;
begin
  FindTeamIndex:=-1;
  for i:=0 to Pred(cMaxTeams) do
        if (TeamsArray[i] = p) then
          begin
            FindTeamIndex := i;
          end;
end;

procedure SwitchClan(p: PTeam; c: PClan);
var oldClan: PClan;
    found: Boolean;
    i: LongInt;
begin
  if (p = nil) or (c = nil) then
  begin
    AddFileLog('call to SwitchClan with null pointers');
    exit;
  end;

  (* already in desired clan *)
  if p^.Clan = c then exit;

  AddFileLog('changing team ' + p^.TeamName + ' to clan with color=' + IntToStr(c^.Color));

  oldClan := p^.Clan;
  p^.Clan := c;

  (* add team to new clan *)
  with p^.Clan^ do
  begin
    Teams[TeamsNumber]:=p;
    inc(TeamsNumber);
  end;

  (* remove team from old clan *)
  with oldClan^ do
  begin
    found := false;
    for i := 0 to Pred(TeamsNumber) - 1 do
    begin
      if found or (Teams[i] = p) then
      begin
        Teams[i] := Teams[i + 1];
        found := true;
      end;
    end;
    dec(TeamsNumber);
  end;

  RecountAllTeamsHealth;
  UpdateClanVisuals(c);

  //InitTeams;

  SpawnClansArray := ClansArray;
end;

function AddEmptyClan(color: LongInt): PClan;
var clan: PClan;
begin
  (* add clan to data structure *)
  AddFileLog('adding new empty clan with color=' + IntToStr(color));
  new(clan);
  FillChar(clan^, sizeof(TClan), 0);
  ClansArray[ClansCount] := clan;
  inc(ClansCount);

  (* init clan *)
  clan^.ClanIndex := Pred(ClansCount);
  clan^.Color := Color;
  clan^.TagTeamIndex := 0;
  clan^.Flawless := true;
  clan^.TurnNumber := 0;
  clan^.HealthTex:= makeHealthBarTexture(cTeamHealthWidth + 5, TeamsArray[0]^.NameTagTex^.h, clan^.Color);

  AddEmptyClan := clan;

end;

procedure UpdateClanVisuals(clan: PClan);
var team : PTeam;
    hh   : PHedgehog;
    i, j : LongInt;
begin
  if clan = nil then exit;
  if clan^.TeamsNumber = 0 then exit;

  (* update all teams in clan *)
  for i:= 0 to Pred(clan^.TeamsNumber) do
  begin
    team:= clan^.Teams[i];
    AddFileLog('updating in clan color=' + IntToStr(clan^.Color) + ' team: ' + team^.TeamName);
    for j:= 0 to Pred(cMaxHHIndex) do
    begin
      hh:= @(team^.Hedgehogs[j]);
      if (hh^.Gear <> nil) or (hh^.GearHidden <> nil) then
      begin
        AddFileLog('updating hh with name "' + hh^.Name + '" with health=' + IntToStr(hh^.Gear^.Health));
        FreeAndNilTexture(hh^.NameTagTex);
        hh^.NameTagTex := RenderStringTex(ansistring(hh^.Name), clan^.Color, fnt16);
        FreeAndNilTexture(hh^.HealthTagTex);
        hh^.HealthTagTex := RenderStringTex(ansistring(IntToStr(hh^.Gear^.Health)), clan^.Color, fnt16);
      end;
    end;
    FreeAndNilTexture(team^.NameTagTex);
    team^.NameTagTex:= RenderStringTex(ansistring(team^.TeamName), clan^.Color, fnt16);
  end;

  (* init texture of clan *)
  FreeAndNilTexture(clan^.HealthTex);
  clan^.HealthTex:= makeHealthBarTexture(cTeamHealthWidth + 5, clan^.Teams[0]^.NameTagTex^.h, clan^.Color);

end;

procedure SplitClans;
{split all clans into individual teams (one clan per team)}
var 
clan: PClan;
i: LongInt;
NewClan: PClan;
ClanColor: LongInt;
team: PTeam;
begin
  if (TeamsCount < 2) or ((GameFlags and gfOneClanMode) <> 0) then exit;
  (* split clans with more than a single team *)
  for i := 0 to Pred(ClansCount) do
  begin
    clan := ClansArray[i];
    (* add new clan for each additional team *)
    while clan^.TeamsNumber > 1 do
    begin
      (* next clan color *)
      ClanColor := GetClanColor(ClansCount);
      (* add a new clan *)
      NewClan := AddEmptyClan(ClanColor);
      (* move last team in this clan to new clan *)
      team := clan^.Teams[Pred(clan^.TeamsNumber)];
      SwitchClan(team, NewClan);
    end;
  end;

  for i := 0 to Pred(ClansCount) do
  begin
    clan := ClansArray[i];
    clan^.Color := GetClanColor(i);
    UpdateClanVisuals(clan);
  end;

end;

function GetClanColor(i: Integer): LongInt;
const
    ClanColors: array[0..11] of LongInt = ($ffa6cee3,
      $ff1f78b4, 
      $ffb2df8a, 
      $ff33a02c, 
      $fffb9a99, 
      $ffe31a1c, 
      $fffdbf6f,
      $ffff7f00, 
      $ffcab2d6, 
      $ff6a3d9a, 
      $ffffff99, 
      $ffb15928);
begin
  GetClanColor := $ffffffff;
  if (i >= 0) and (i < 12) then
    GetClanColor := ClanColors[i];
end;

function CheckForWin: boolean;
var AliveClan: PClan;
    s, ts: ansistring;
    t, AliveCount, i, j: LongInt;
begin
CheckForWin:= false;
AliveCount:= 0;
for t:= 0 to Pred(ClansCount) do
    if ClansArray[t]^.ClanHealth > 0 then
        begin
        inc(AliveCount);
        AliveClan:= ClansArray[t]
        end;

if (TeamsCount > 1) and (AliveCount = 1) and ((GameFlags and gfOneClanMode) = 0) then
  begin
    SplitClans;
    AliveCount:= 0;
    for t:= 0 to Pred(ClansCount) do
      if ClansArray[t]^.ClanHealth > 0 then
      begin
        inc(AliveCount);
        AliveClan:= ClansArray[t]
      end;
  end;

if (AliveCount > 1) or ((AliveCount = 1) and ((GameFlags and gfOneClanMode) <> 0)) then
    exit;
CheckForWin:= true;

TurnTimeLeft:= 0;
ReadyTimeLeft:= 0;

// if the game ends during a multishot, do last TurnReaction
if (not bBetweenTurns) and isInMultiShoot then
    TurnReaction();

if not GameOver then
    begin
    if AliveCount = 0 then
        begin // draw
        AddCaption(trmsg[sidDraw], cWhiteColor, capgrpGameState);
        SendStat(siGameResult, shortstring(trmsg[sidDraw]));
        AddGear(0, 0, gtATFinishGame, 0, _0, _0, 3000)
        end
    else // win
        with AliveClan^ do
            begin
            ts:= ansistring(Teams[0]^.TeamName);
            if TeamsNumber = 1 then
                s:= FormatA(trmsg[sidWinner], ts)  // team wins
            else
                s:= FormatA(trmsg[sidWinner], ts); // clan wins

            for j:= 0 to Pred(TeamsNumber) do
                with Teams[j]^ do
                    for i:= 0 to cMaxHHIndex do
                        with Hedgehogs[i] do
                            if (Gear <> nil) then
                                Gear^.State:= gstWinner;
            if Flawless then
                AddVoice(sndFlawless, Teams[0]^.voicepack)
            else
                AddVoice(sndVictory, Teams[0]^.voicepack);

            AddCaption(s, cWhiteColor, capgrpGameState);
            SendStat(siGameResult, shortstring(s));
            AddGear(0, 0, gtATFinishGame, 0, _0, _0, 3000)
            end;
    SendStats;
    end;
GameOver:= true
end;

procedure SwitchHedgehog;
var c, i, t: LongWord;
    PrevHH, PrevTeam : LongWord;
begin
TargetPoint.X:= NoPointX;
if checkFails(CurrentTeam <> nil, 'nil Team', true) then exit;
with CurrentHedgehog^ do
    if (PreviousTeam <> nil) and PlacingHogs and Unplaced then
        begin
        Unplaced:= false;
        if Gear <> nil then
           begin
           DeleteCI(Gear);
           FindPlace(Gear, false, 0, LAND_WIDTH, true);
           if Gear <> nil then
               AddCI(Gear)
           end
        end;

PreviousTeam:= CurrentTeam;

with CurrentHedgehog^ do
    begin
    if Gear <> nil then
        begin
        MultiShootAttacks:= 0;
        Gear^.Message:= 0;
        Gear^.Z:= cHHZ;
        RemoveGearFromList(Gear);
        InsertGearToList(Gear)
        end
    end;
// Try to make the ammo menu viewed when not your turn be a bit more useful for per-hog-ammo mode
with CurrentTeam^ do
    if ((GameFlags and gfPerHogAmmo) <> 0) and (not ExtDriven) and (CurrentHedgehog^.BotLevel = 0) then
        begin
        c:= CurrHedgehog;
        repeat
            begin
            inc(c);
            if c > cMaxHHIndex then
                c:= 0
            end
        until (c = CurrHedgehog) or (Hedgehogs[c].Gear <> nil) and (Hedgehogs[c].Effects[heFrozen] < 50255);
        LocalAmmo:= Hedgehogs[c].AmmoStore
        end;

c:= CurrentTeam^.Clan^.ClanIndex;
repeat
    with ClansArray[c]^ do
        if (CurrTeam = TagTeamIndex) and ((GameFlags and gfTagTeam) <> 0) then
            begin
            TagTeamIndex:= Pred(TagTeamIndex) mod TeamsNumber;
            CurrTeam:= Pred(CurrTeam) mod TeamsNumber;
            inc(c);
            NextClan:= true;
            end;

    if (GameFlags and gfTagTeam) = 0 then
        inc(c);

    if c = ClansCount then
        begin
        if not PlacingHogs then
            inc(TotalRounds);
        c:= 0
        end;

    with ClansArray[c]^ do
        begin
        PrevTeam:= CurrTeam;
        repeat
            CurrTeam:= Succ(CurrTeam) mod TeamsNumber;
            CurrentTeam:= Teams[CurrTeam];
            with CurrentTeam^ do
                begin
                PrevHH:= CurrHedgehog mod HedgehogsNumber; // prevent infinite loop when CurrHedgehog = 7, but HedgehogsNumber < 8 (team is destroyed before its first turn)
                repeat
                    CurrHedgehog:= Succ(CurrHedgehog) mod HedgehogsNumber;
                until ((Hedgehogs[CurrHedgehog].Gear <> nil) and (Hedgehogs[CurrHedgehog].Effects[heFrozen] < 256)) or (CurrHedgehog = PrevHH)
                end
        until ((CurrentTeam^.Hedgehogs[CurrentTeam^.CurrHedgehog].Gear <> nil) and (CurrentTeam^.Hedgehogs[CurrentTeam^.CurrHedgehog].Effects[heFrozen] < 256)) or (PrevTeam = CurrTeam) or ((CurrTeam = TagTeamIndex) and ((GameFlags and gfTagTeam) <> 0))
        end;
        if (CurrentTeam^.Hedgehogs[CurrentTeam^.CurrHedgehog].Gear = nil) or (CurrentTeam^.Hedgehogs[CurrentTeam^.CurrHedgehog].Effects[heFrozen] > 255) then
            begin
            with CurrentTeam^.Clan^ do
                for t:= 0 to Pred(TeamsNumber) do
                    with Teams[t]^ do
                        for i:= 0 to Pred(HedgehogsNumber) do
                            with Hedgehogs[i] do
                                begin
                                if Effects[heFrozen] > 255 then Effects[heFrozen]:= max(255,Effects[heFrozen]-50000);
                                if (Gear <> nil) and (Effects[heFrozen] < 256) and (CurrentTeam^.Hedgehogs[CurrentTeam^.CurrHedgehog].Effects[heFrozen] > 255) then
                                    CurrHedgehog:= i
                                end;
            if (CurrentTeam^.Hedgehogs[CurrentTeam^.CurrHedgehog].Gear = nil) or (CurrentTeam^.Hedgehogs[CurrentTeam^.CurrHedgehog].Effects[heFrozen] > 255) then
                inc(CurrentTeam^.Clan^.TurnNumber);
            end
until (CurrentTeam^.Hedgehogs[CurrentTeam^.CurrHedgehog].Gear <> nil) and (CurrentTeam^.Hedgehogs[CurrentTeam^.CurrHedgehog].Effects[heFrozen] < 256);

SwitchCurrentHedgehog(@(CurrentTeam^.Hedgehogs[CurrentTeam^.CurrHedgehog]));
{$IFDEF USE_TOUCH_INTERFACE}
if (Ammoz[CurrentHedgehog^.CurAmmoType].Ammo.Propz and ammoprop_NoCrosshair) = 0 then
    begin
    if not(arrowUp.show) then
        begin
        animateWidget(@arrowUp, true, true);
        animateWidget(@arrowDown, true, true);
        end;
    end
else
    if arrowUp.show then
        begin
        animateWidget(@arrowUp, true, false);
        animateWidget(@arrowDown, true, false);
        end;
{$ENDIF}
AmmoMenuInvalidated:= true;
end;

procedure AfterSwitchHedgehog;
var i, t: LongInt;
    CurWeapon: PAmmo;
    w: real;
    vg: PVisualGear;
    s: ansistring;
begin
if PlacingHogs then
    begin
    PlacingHogs:= false;
    for t:= 0 to Pred(TeamsCount) do
        for i:= 0 to cMaxHHIndex do
            if (TeamsArray[t]^.Hedgehogs[i].Gear <> nil) and (TeamsArray[t]^.Hedgehogs[i].Unplaced) then
                PlacingHogs:= true;

    if not PlacingHogs then // Reset  various things I mucked with
        begin
        for i:= 0 to ClansCount do
            if ClansArray[i] <> nil then
                ClansArray[i]^.TurnNumber:= 0;
        ResetWeapons
        end
    end;

inc(CurrentTeam^.Clan^.TurnNumber);
with CurrentTeam^.Clan^ do
    for t:= 0 to Pred(TeamsNumber) do
        with Teams[t]^ do
            for i:= 0 to Pred(HedgehogsNumber) do
                with Hedgehogs[i] do
                    if Effects[heFrozen] > 255 then
                        Effects[heFrozen]:= max(255,Effects[heFrozen]-50000);

CurWeapon:= GetCurAmmoEntry(CurrentHedgehog^);
if CurWeapon^.Count = 0 then
    CurrentHedgehog^.CurAmmoType:= amNothing;

with CurrentHedgehog^ do
    begin
    with Gear^ do
        begin
        Z:= cCurrHHZ;
        State:= gstHHDriven;
        Active:= true;
        Power:= 0;
        LastDamage:= nil
        end;
    RemoveGearFromList(Gear);
    InsertGearToList(Gear);
    FollowGear:= Gear
    end;

if (GameFlags and gfDisableWind) = 0 then
    begin
    cWindSpeed:= rndSign(GetRandomf * 2 * cMaxWindSpeed);
    w:= hwFloat2Float(cWindSpeed);
    vg:= AddVisualGear(0, 0, vgtSmoothWindBar);
    if vg <> nil then vg^.dAngle:= w;
    AddFileLog('Wind = '+FloatToStr(cWindSpeed));
    end;

ApplyAmmoChanges(CurrentHedgehog^);

if (not CurrentTeam^.ExtDriven) and (CurrentHedgehog^.BotLevel = 0) then
    SetBinds(CurrentTeam^.Binds);

bShowFinger:= true;

if PlacingHogs then
    begin
    if CurrentHedgehog^.Unplaced then
        TurnTimeLeft:= 15000
    else TurnTimeLeft:= 0
    end
else if ((GameFlags and gfTagTeam) <> 0) and (not NextClan) then
    begin
    if TagTurnTimeLeft <> 0 then
        TurnTimeLeft:= TagTurnTimeLeft;
    TagTurnTimeLeft:= 0;
    end
else
    begin
    TurnTimeLeft:= cHedgehogTurnTime;
    TagTurnTimeLeft:= 0;
    NextClan:= false;
    end;

if (TurnTimeLeft > 0) and (CurrentHedgehog^.BotLevel = 0) then
    begin
    if CurrentTeam^.ExtDriven then
        begin
        if GetRandom(2) = 0 then
             AddVoice(sndIllGetYou, CurrentTeam^.voicepack)
        else AddVoice(sndJustYouWait, CurrentTeam^.voicepack)
        end
    else
        begin
        GetRandom(2); // needed to avoid extdriven desync
        AddVoice(sndYesSir, CurrentTeam^.voicepack);
        end;
    if cHedgehogTurnTime < 1000000 then
        ReadyTimeLeft:= cReadyDelay;
    s:= ansistring(CurrentTeam^.TeamName);
    AddCaption(FormatA(trmsg[sidReady], s), cWhiteColor, capgrpGameState)
    end
else
    begin
    if TurnTimeLeft > 0 then
        begin
        if GetRandom(2) = 0 then
             AddVoice(sndIllGetYou, CurrentTeam^.voicepack)
        else AddVoice(sndJustYouWait, CurrentTeam^.voicepack)
        end;
    ReadyTimeLeft:= 0
    end;
end;

function AddTeam(TeamColor: Longword): PTeam;
var team: PTeam;
    c, t: LongInt;
begin
if checkFails(TeamsCount < cMaxTeams, 'Too many teams', true) then exit(nil);
New(team);
if checkFails(team <> nil, 'AddTeam: team = nil', true) then exit(nil);
FillChar(team^, sizeof(TTeam), 0);
team^.AttackBar:= 2;
team^.CurrHedgehog:= 0;
team^.Flag:= 'hedgewars';

TeamsArray[TeamsCount]:= team;
inc(TeamsCount);

for t:= 0 to cKbdMaxIndex do
    team^.Binds[t]:= DefaultBinds[t];

c:= Pred(ClansCount);
while (c >= 0) and (ClansArray[c]^.Color <> TeamColor) do dec(c);
if c < 0 then
    begin
    new(team^.Clan);
    FillChar(team^.Clan^, sizeof(TClan), 0);
    ClansArray[ClansCount]:= team^.Clan;
    inc(ClansCount);
    with team^.Clan^ do
        begin
        ClanIndex:= Pred(ClansCount);
        Color:= TeamColor;
        TagTeamIndex:= 0;
        Flawless:= true
        end
    end
else
    begin
    team^.Clan:= ClansArray[c];
    end;

with team^.Clan^ do
    begin
    Teams[TeamsNumber]:= team;
    inc(TeamsNumber)
    end;

// mirror changes into array for clans to spawn
SpawnClansArray:= ClansArray;

CurrentTeam:= team;
AddTeam:= team;
end;

procedure RecountAllTeamsHealth;
var t: LongInt;
begin
for t:= 0 to Pred(TeamsCount) do
    RecountTeamHealth(TeamsArray[t])
end;

procedure InitTeams;
var i, t: LongInt;
    th, h: LongInt;
begin

for t:= 0 to Pred(TeamsCount) do
    with TeamsArray[t]^ do
        begin
        if (not ExtDriven) and (Hedgehogs[0].BotLevel = 0) then
            begin
            LocalClan:= Clan^.ClanIndex;
            LocalTeam:= t;
            LocalAmmo:= Hedgehogs[0].AmmoStore
            end;
        th:= 0;
        for i:= 0 to cMaxHHIndex do
            if Hedgehogs[i].Gear <> nil then
                inc(th, Hedgehogs[i].Gear^.Health);
        if th > MaxTeamHealth then
            MaxTeamHealth:= th;
        // Some initial King buffs
        if (GameFlags and gfKing) <> 0 then
            begin
            Hedgehogs[0].King:= true;
            Hedgehogs[0].Hat:= 'crown';
            Hedgehogs[0].Effects[hePoisoned] := 0;
            h:= Hedgehogs[0].Gear^.Health;
            Hedgehogs[0].Gear^.Health:= hwRound(int2hwFloat(th)*_0_375);
            if Hedgehogs[0].Gear^.Health > h then
                begin
                dec(th, h);
                inc(th, Hedgehogs[0].Gear^.Health);
                if th > MaxTeamHealth then
                    MaxTeamHealth:= th
                end
            else
                Hedgehogs[0].Gear^.Health:= h;
            Hedgehogs[0].InitialHealth:= Hedgehogs[0].Gear^.Health
            end;
        end;

RecountAllTeamsHealth
end;

function  TeamSize(p: PTeam): Longword;
var i, value: Longword;
begin
value:= 0;
for i:= 0 to cMaxHHIndex do
    if p^.Hedgehogs[i].Gear <> nil then
        inc(value);
TeamSize:= value;
end;

procedure RecountClanHealth(clan: PClan);
var i: LongInt;
begin
with clan^ do
    begin
    ClanHealth:= 0;
    for i:= 0 to Pred(TeamsNumber) do
        inc(ClanHealth, Teams[i]^.TeamHealth)
    end
end;

procedure RecountTeamHealth(team: PTeam);
var i: LongInt;
begin
with team^ do
    begin
    TeamHealth:= 0;
    for i:= 0 to cMaxHHIndex do
        if Hedgehogs[i].Gear <> nil then
            inc(TeamHealth, Hedgehogs[i].Gear^.Health)
        else if Hedgehogs[i].GearHidden <> nil then
            inc(TeamHealth, Hedgehogs[i].GearHidden^.Health);

    if TeamHealth > MaxTeamHealth then
        begin
        MaxTeamHealth:= TeamHealth;
        RecountAllTeamsHealth;
        end
    end;

RecountClanHealth(team^.Clan);

AddVisualGear(0, 0, vgtTeamHealthSorter)
end;

procedure RestoreHog(HH: PHedgehog);
begin
    HH^.Gear:=HH^.GearHidden;
    HH^.GearHidden:= nil;
    InsertGearToList(HH^.Gear);
    HH^.Gear^.State:= (HH^.Gear^.State and (not (gstHHDriven or gstInvisible or gstAttacking))) or gstAttacked;
    AddCI(HH^.Gear);
    HH^.Gear^.Active:= true;
    ScriptCall('onHogRestore', HH^.Gear^.Uid)
end;

procedure RestoreTeamsFromSave;
var t: LongInt;
begin
for t:= 0 to Pred(TeamsCount) do
   TeamsArray[t]^.ExtDriven:= false
end;

procedure TeamGoneEffect(var Team: TTeam);
var i: LongInt;
begin
    with Team do
        if skippedTurns < 3 then
            begin
            inc(skippedTurns);
            for i:= 0 to cMaxHHIndex do
                with Hedgehogs[i] do
                    if Gear <> nil then
                        Gear^.State:= Gear^.State and (not gstHHDriven);

            ParseCommand('/skip', true);
            end
        else
            for i:= 0 to cMaxHHIndex do
                with Hedgehogs[i] do
                    begin
                    if Hedgehogs[i].GearHidden <> nil then
                        RestoreHog(@Hedgehogs[i]);

                    if Gear <> nil then
                        begin
                        Gear^.Hedgehog^.Effects[heInvulnerable]:= 0;
                        Gear^.Damage:= Gear^.Health;
                        Gear^.State:= (Gear^.State or gstHHGone) and (not gstHHDriven)
                        end
                    end
end;

procedure chAddHH(var id: shortstring);
var s: shortstring;
    Gear: PGear;
begin
s:= '';
if (not isDeveloperMode) then
    exit;
if checkFails((CurrentTeam <> nil), 'Can''t add hedgehogs yet, add a team first!', true) then exit;
with CurrentTeam^ do
    begin
    if checkFails(HedgehogsNumber<=cMaxHHIndex, 'Can''t add hedgehog to "' + TeamName + '"! (already ' + intToStr(HedgehogsNumber) + ' hogs)', true) then exit;
    SplitBySpace(id, s);
    SwitchCurrentHedgehog(@Hedgehogs[HedgehogsNumber]);
    CurrentHedgehog^.BotLevel:= StrToInt(id);
    CurrentHedgehog^.Team:= CurrentTeam;
    Gear:= AddGear(0, 0, gtHedgehog, 0, _0, _0, 0);
    SplitBySpace(s, id);
    Gear^.Health:= StrToInt(s);
    if checkFails(Gear^.Health > 0, 'Invalid hedgehog health', true) then exit;
    if (GameFlags and gfSharedAmmo) <> 0 then
        CurrentHedgehog^.AmmoStore:= Clan^.ClanIndex
    else if (GameFlags and gfPerHogAmmo) <> 0 then
        begin
        AddAmmoStore;
        CurrentHedgehog^.AmmoStore:= StoreCnt - 1
        end
    else CurrentHedgehog^.AmmoStore:= TeamsCount - 1;
    CurrentHedgehog^.Gear:= Gear;
    CurrentHedgehog^.Name:= id;
    CurrentHedgehog^.InitialHealth:= Gear^.Health;
    CurrHedgehog:= HedgehogsNumber;
    inc(HedgehogsNumber)
    end
end;

procedure loadTeamBinds(s: shortstring);
var i: LongInt;
begin
    for i:= 1 to length(s) do
        if ((s[i] = '\') or
            (s[i] = '/') or
            (s[i] = ':')) then
            s[i]:= '_';

    s:= cPathz[ptTeams] + '/' + s + '.hwt';

    loadBinds('bind', s);
end;

procedure chAddTeam(var s: shortstring);
var Color: Longword;
    ts, cs: shortstring;
begin
cs:= '';
ts:= '';
if isDeveloperMode then
    begin
    SplitBySpace(s, cs);
    SplitBySpace(cs, ts);
    Color:= StrToInt(cs);

    // color is always little endian so the mask must be constant also in big endian archs
    Color:= Color or $FF000000;
    AddTeam(Color);
    
    if CurrentTeam <> nil then
        begin
        CurrentTeam^.TeamName:= ts;
        CurrentTeam^.PlayerHash:= s;
        loadTeamBinds(ts);

        if GameType in [gmtDemo, gmtSave, gmtRecord] then
            CurrentTeam^.ExtDriven:= true;

        CurrentTeam^.voicepack:= AskForVoicepack('Default')
        end
    end
end;

procedure chSetHHCoords(var x: shortstring);
var y: shortstring;
    t: Longint;
begin
    y:= '';
    if (not isDeveloperMode) or (CurrentHedgehog = nil) or (CurrentHedgehog^.Gear = nil) then
        exit;
    SplitBySpace(x, y);
    t:= StrToInt(x);
    CurrentHedgehog^.Gear^.X:= int2hwFloat(t);
    t:= StrToInt(y);
    CurrentHedgehog^.Gear^.Y:= int2hwFloat(t)
end;

procedure chBind(var id: shortstring);
begin
    if CurrentTeam = nil then
        exit;

    addBind(CurrentTeam^.Binds, id)
end;

procedure chTeamGone(var s:shortstring);
var t, i: LongInt;
    isSynced: boolean;
begin
    isSynced:= s[1] = 's';

    Delete(s, 1, 1);

    t:= 0;
    while (t < TeamsCount) and (TeamsArray[t]^.TeamName <> s) do
        inc(t);
    if t = TeamsCount then
        exit;

    TeamsArray[t]^.isGoneFlagPendingToBeSet:= true;

    if isSynced then
        begin
        for i:= 0 to Pred(TeamsCount) do
            with TeamsArray[i]^ do
                begin
                if (not hasGone) and isGoneFlagPendingToBeSet then
                    begin
                    AddChatString(#7 + '* '+ TeamName + ' is gone'); // TODO: localize
                    if not CurrentTeam^.ExtDriven then SendIPC(_S'f' + s);
                    hasGone:= true;
                    skippedTurns:= 0;
                    isGoneFlagPendingToBeSet:= false;
                    RecountTeamHealth(TeamsArray[i])
                    end;
                if hasGone and isGoneFlagPendingToBeUnset then
                    ParseCommand('/teamback s' + s, true)
                end
        end
    else
        begin
        //TeamsArray[t]^.isGoneFlagPendingToBeSet:= true;

        if (not CurrentTeam^.ExtDriven) or (CurrentTeam^.TeamName = s) or (CurrentTeam^.hasGone) then
            ParseCommand('/teamgone s' + s, true)
        end;
end;

procedure chTeamBack(var s:shortstring);
var t: LongInt;
    isSynced: boolean;
begin
    isSynced:= s[1] = 's';

    Delete(s, 1, 1);

    t:= 0;
    while (t < TeamsCount) and (TeamsArray[t]^.TeamName <> s) do
        inc(t);
    if t = TeamsCount then
        exit;

    if isSynced then
        begin
        with TeamsArray[t]^ do
            if hasGone then
                begin
                AddChatString(#8 + '* '+ TeamName + ' is back');
                if not CurrentTeam^.ExtDriven then SendIPC(_S'g' + s);
                hasGone:= false;

                RecountTeamHealth(TeamsArray[t]);

                if isGoneFlagPendingToBeUnset and (Owner = UserNick) then
                    ExtDriven:= false;

                isGoneFlagPendingToBeUnset:= false;
                end;
        end
    else
        begin
        TeamsArray[t]^.isGoneFlagPendingToBeUnset:= true;

        if not CurrentTeam^.ExtDriven then
            ParseCommand('/teamback s' + s, true);
        end;
end;


procedure chFinish(var s:shortstring);
var t: LongInt;
begin
// avoid compiler hint
s:= s;

isPaused:= false;

t:= 0;
while t < TeamsCount do
    begin
    TeamsArray[t]^.hasGone:= true;
    inc(t)
    end;

AddChatString(#7 + '* Good-bye!');
RecountAllTeamsHealth();
end;

procedure SwitchCurrentHedgehog(newHog: PHedgehog);
var oldCI, newCI: boolean;
    oldHH: PHedgehog;
begin
   if (CurrentHedgehog <> nil) and (CurrentHedgehog^.CurAmmoType = amKnife) then
       LoadHedgehogHat(CurrentHedgehog^, CurrentHedgehog^.Hat);
    oldCI:= (CurrentHedgehog <> nil) and (CurrentHedgehog^.Gear <> nil) and (CurrentHedgehog^.Gear^.CollisionIndex >= 0);
    newCI:= (newHog^.Gear <> nil) and (newHog^.Gear^.CollisionIndex >= 0);
    if oldCI then DeleteCI(CurrentHedgehog^.Gear);
    if newCI then DeleteCI(newHog^.Gear);
    oldHH:= CurrentHedgehog;
    CurrentHedgehog:= newHog;
    if oldCI then AddCI(oldHH^.Gear);
    if newCI then AddCI(newHog^.Gear)
end;


procedure chSetHat(var s: shortstring);
begin
if (not isDeveloperMode) or (CurrentTeam = nil) then exit;
with CurrentTeam^ do
    begin
    if not CurrentHedgehog^.King then
    if (s = '')
    or (((GameFlags and gfKing) <> 0) and (s = 'crown'))
    or ((Length(s) > 39) and (Copy(s,1,8) = 'Reserved') and (Copy(s,9,32) <> PlayerHash)) then
        CurrentHedgehog^.Hat:= 'NoHat'
    else
        CurrentHedgehog^.Hat:= s
    end;
end;

procedure chGrave(var s: shortstring);
begin
    if CurrentTeam = nil then
        OutError(errmsgIncorrectUse + ' "/grave"', true);
    if s[1]='"' then
        Delete(s, 1, 1);
    if s[byte(s[0])]='"' then
        Delete(s, byte(s[0]), 1);
    CurrentTeam^.GraveName:= s
end;

procedure chFort(var s: shortstring);
begin
    if CurrentTeam = nil then
        OutError(errmsgIncorrectUse + ' "/fort"', true);
    if s[1]='"' then
        Delete(s, 1, 1);
    if s[byte(s[0])]='"' then
        Delete(s, byte(s[0]), 1);
    CurrentTeam^.FortName:= s
end;

procedure chFlag(var s: shortstring);
begin
    if CurrentTeam = nil then
        OutError(errmsgIncorrectUse + ' "/flag"', true);
    if s[1]='"' then
        Delete(s, 1, 1);
    if s[byte(s[0])]='"' then
        Delete(s, byte(s[0]), 1);
    CurrentTeam^.flag:= s
end;

procedure chOwner(var s: shortstring);
begin
    if CurrentTeam = nil then
        OutError(errmsgIncorrectUse + ' "/owner"', true);

    CurrentTeam^.Owner:= s
end;

procedure chChangeTeamColor(var s: shortstring);
var Color: Longword;
clan: PClan;
i: LongInt;
cs, ts: shortstring;
begin
  if CurrentTeam = nil then
    exit;

  AddFileLog('ChangeTeamColor called: s="' + s + '"');

  Color:= StrToInt(s);

  Color:= Color or $FF000000;
  AddFileLog('ChangeTeamColor color=' + IntToHex(color, 8));
                                                     
  (* find matching clan *)
  clan := nil;
  for i := 0 to Pred(ClansCount) do
  begin
    if ClansArray[i]^.Color = Color then
      clan := ClansArray[i];
  end;

  (* no clan with this color yet, create a new one *)
  if clan = nil then
    clan := AddEmptyClan(Color);

  AddFileLog('Team ' + CurrentTeam^.TeamName + ' changes sides to clan with color ' + IntToHex(Color, 8));

  (* switch clan *)
  SwitchClan(CurrentTeam, clan);

end;

procedure chSplitClans(var s: shortstring);
begin
  SplitClans;
end;

procedure initModule;
begin
RegisterVariable('addhh', @chAddHH, false);
RegisterVariable('addteam', @chAddTeam, false);
RegisterVariable('hhcoords', @chSetHHCoords, false);
RegisterVariable('bind', @chBind, true );
RegisterVariable('teamgone', @chTeamGone, true );
RegisterVariable('teamback', @chTeamBack, true );
RegisterVariable('finish', @chFinish, true ); // all teams gone
RegisterVariable('fort'    , @chFort         , false);
RegisterVariable('grave'   , @chGrave        , false);
RegisterVariable('hat'     , @chSetHat       , false);
RegisterVariable('flag'    , @chFlag         , false);
RegisterVariable('owner'   , @chOwner        , false);

RegisterVariable('teamcolor'   , @chChangeTeamColor        , false);
RegisterVariable('splitclans'   , @chSplitClans        , false);

CurrentTeam:= nil;
PreviousTeam:= nil;
CurrentHedgehog:= nil;
TeamsCount:= 0;
ClansCount:= 0;
LocalClan:= -1;
LocalTeam:= -1;
LocalAmmo:= -1;
GameOver:= false;
NextClan:= true;
MaxTeamHealth:= 0;
end;

procedure freeModule;
var i, h: LongWord;
begin
CurrentHedgehog:= nil;
if TeamsCount > 0 then
    begin
    for i:= 0 to Pred(TeamsCount) do
        begin
        for h:= 0 to cMaxHHIndex do
            with TeamsArray[i]^.Hedgehogs[h] do
                begin
//                if Gear <> nil then
//                    DeleteGearStage(Gear, true);
                if GearHidden <> nil then
                    Dispose(GearHidden);
//                    DeleteGearStage(GearHidden, true);

                FreeAndNilTexture(NameTagTex);
                FreeAndNilTexture(HealthTagTex);
                FreeAndNilTexture(HatTex)
                end;

        with TeamsArray[i]^ do
            begin
            FreeAndNilTexture(NameTagTex);
            FreeAndNilTexture(OwnerTex);
            FreeAndNilTexture(GraveTex);
            FreeAndNilTexture(AIKillsTex);
            FreeAndNilTexture(FlagTex);
            end;

        Dispose(TeamsArray[i])
        end;
    for i:= 0 to Pred(ClansCount) do
        begin
        FreeAndNilTexture(ClansArray[i]^.HealthTex);
        Dispose(ClansArray[i])
        end
    end;
TeamsCount:= 0;
ClansCount:= 0;
end;

end.
