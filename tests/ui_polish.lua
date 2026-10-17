-- Run from the repository root with Lua 5.4; optionally pass packaged main.lua.
local games={}
for i=1,40 do games[i]={file="game-"..i,handle="game-"..i,name="Game "..i,title_id=string.format("%016x",i),remote=false,sources={}} end
local function clone(v)
    if type(v)~="table" then return v end
    local copy={};for k,x in pairs(v) do copy[k]=clone(x) end;return copy
end
local models={runtime={capabilities={}},preferences={reduce_motion=false,large_text=false,high_contrast=false,menu_bind={0,1,2,3},volume=100},
    profiles={{name="Player 1",handle="one",playing=true},{name="Player 2",handle="two",playing=false}},
    home={setup_ready=true,last_file="game-1",recents={{file="game-1"}},status=""},
    choices={resolution={"720p","1080p"},filter={"Bilinear"},astc={"CPU"},frame_gen_state=2},
    status={clock="12:00",controllers=1,version="v1.004.000",room={phase=0,members={}},launch={stage="idle"},update={},update_status={phase=0},save_sync={stage=0},keyboard={ready=false}},
    sources={generation=1},library={generation=1,scanning=false,games=games},downloads={},launcher_updates={phase="current",automatic_checks=false},
    room_form={host="127.0.0.1",port=24872,nickname="Player",password=""},public_rooms={rooms={},refreshing=false,error=""},
    game_files={path="/data/prosperoeden",current="/data/prosperoeden",ok=true,folders={},info={}}}
local commands,actions={},{}
host={query=function(name,p)
    if name=="measure" then return #p.text*p.size*.6 end
    assert(models[name],"unexpected query: "..name);return clone(models[name])
end,action=function(name,p)actions[name]=(actions[name] or 0)+1;return {ok=true} end,
draw=function(kind,p)
    if kind=="cover" and models.stale_artwork then return {ok=false,error="Game is no longer in the library"} end
    commands[#commands+1]={kind=kind,p=clone(p)};return true
end}
local function read(path)local f=assert(io.open(path,"rb"));local value=f:read("*a");f:close();return value end
local app=arg[1] and assert(loadfile(arg[1]))() or assert(load(read("src/motion.lua").."\n"..read("src/ui.lua")))()
local function upvalue(fn,name,seen)
    seen=seen or {};if seen[fn] then return end;seen[fn]=true
    for i=1,100 do local key,v=debug.getupvalue(fn,i);if not key then break end
        if key==name then return v end
        if type(v)=="function" then local result=upvalue(v,name,seen);if result then return result end end
    end
end
local S=assert(upvalue(app.update,"S"));local U=assert(upvalue(app.update,"U"))
local open=assert(upvalue(app.input,"open"));local show_modal=assert(upvalue(app.input,"show_modal"))
local count,time=0,0
local function check(ok,label)assert(ok,label);count=count+1;io.write("PASS ",label,"\n")end
local function tick(n)for _=1,n do time=time+1/60;app.update({time=time,dt=1/60}) end end
local function key(value,n)app.input({key=value});if n then tick(n) end end
local function draw()
    commands={};app.draw()
    local stacks={opacity=0,clip=0,transform=0};local pop={unopacity="opacity",unclip="clip",untransform="transform"}
    for _,command in ipairs(commands) do
        if stacks[command.kind] then stacks[command.kind]=stacks[command.kind]+1
        elseif pop[command.kind] then local k=pop[command.kind];stacks[k]=stacks[k]-1;assert(stacks[k]>=0,"draw stack underflow") end
    end
    for _,v in pairs(stacks) do assert(v==0,"unbalanced drawing scope") end
end
local function has(value)for _,c in ipairs(commands) do if c.kind=="text" and c.p.text==value then return true end end;return false end
local function title_x(value)for _,c in ipairs(commands) do if c.kind=="text" and c.p.text==value then return c.p.x end end;error("title missing")end
local function mask()for _,c in ipairs(commands) do if c.kind=="rect" and c.p.w==1920 and c.p.h==1080 and c.p.color==0 then return c.p.alpha end end;return 0 end
local function borders()local n=0;for _,c in ipairs(commands) do if c.kind=="border" and c.p.w==399 and c.p.edge_alpha>0 then n=n+1 end end;return n end
app.init({state={avatars={},recent={},white=false},first_start=false});tick(180);draw();tick(2)
for _=1,4 do key("right",1) end
check(S.focus==5,"HOME selected the fifth game")
key("down");key("right");key("right");key("up")
check(S.zone=="games" and S.focus==5,"Returning from shortcuts restores the selected game")
key("down");check(S.focus==3,"Returning to shortcuts restores the previous shortcut")
draw();check(has("Open") and not has("Game settings"),"Shortcut footer contains only its usable action")
key("up");key("up");key("right");draw()
check(has("Use user") and not has("Game settings"),"Profile footer describes selecting another user")
key("down");draw();check(S.focus==5 and has("Start") and has("Game settings"),"Profiles return to the game selection with game-specific hints")
S.focus=2;S.strip=0;S.strip_target=0;tick(4);draw();key("right");draw();tick(2);draw()
check(borders()==2,"Old and new game borders overlap during the authored unfocus fade")
tick(4);draw();check(borders()==1,"Previous game border disappears after its short fade")

open("library");tick(65);S.library=25;S.scroll=920;S.scroll_target=920
open("home");open("library");tick(1)
check(S.library==25 and S.scroll_target==920,"Reopening All Software preserves its selection and scroll position")
local selected=S.games[S.library].file
table.insert(models.library.games,1,{file="new-game",handle="new-game",name="New game",title_id="0000000000009999"})
models.library.generation=2;S.library_dirty=true;tick(30)
check(S.games[S.library].file==selected,"A catalog insertion preserves the selected game by identity")

open("home");tick(20);S.zone="games";S.focus=1;S.tiles[1].name=string.rep("Long game title ",12)
local long=S.tiles[1].name;draw();tick(190);draw();local before=title_x(long)
key("l1");draw();check(title_x(long)==before,"An unrelated input does not restart the title marquee")
tick(6);draw();check(title_x(long)<before,"Long title continues scrolling after an unrelated input")
local fades=0;for _,c in ipairs(commands) do if c.kind=="gradient" and c.p.w==24 then fades=fades+1 end end
check(fades==2,"Long titles fade at both clipped edges while moving")

S.zone="shortcuts";S.focus=3;key("cross");draw();check(mask()==0,"Dialog backdrop begins transparent")
tick(4);draw();local partial=mask();check(partial>0 and partial<.68,"Dialog backdrop fades in with its surface")
check(not has("Go offline"),"Offline multiplayer hides the unavailable Go offline shortcut")
key("square");check(not actions["room.leave"],"Offline Square does not call an unavailable disconnect action")
key("circle");draw();check(S.modal_exit and mask()<=partial+.0001,"Closing during entry does not flash a fully opaque backdrop")
tick(6);draw();check(mask()<partial,"Dialog backdrop fades out on Back")
tick(8);draw();check(not S.modal and not S.modal_exit,"Dialog closes completely without leaving a drawing scope")

show_modal("choice",{values={"One","Two"}},false);tick(10);key("circle");key("cross");tick(14)
check(not S.modal,"Confirm input during a closing dialog cannot activate the underlying screen")
S.prefs.reduce_motion=true;show_modal("choice",{values={"One"}},false);draw();key("circle")
check(not S.modal,"Reduce motion closes dialogs immediately")
S.prefs.reduce_motion=false
models.status.room.phase=1;tick(30);show_modal("room",{page="choice"},false);tick(10);draw()
check(has("Go offline"),"Connecting multiplayer exposes the disconnect shortcut")
key("square");check(actions["room.leave"]==1,"Connecting multiplayer can still be cancelled")
key("circle",14)

open("about");tick(10);key("square");tick(4);draw();check(U.credits and mask()>0 and mask()<.68,"Credits uses the same fading dialog backdrop")
key("circle");tick(15);draw();check(not U.credits,"Credits also animates closed")

models.library.games={};models.library.generation=3;S.library_dirty=true;tick(30);open("library");tick(65);draw()
check(has("No software found.") and has("Open Game files"),"Empty library gives a useful setup action")
key("cross");check(S.screen=="files" and S.files.path=="/data/prosperoeden","Empty-library action opens the real host folder browser")
key("circle");check(S.screen=="library","Folder browser returns to the empty library")

S.screen="settings";S.category=2;S.content=true;S.row=9;S.choices.frame_gen_state=1;draw()
check(has("Unavailable"),"Unavailable host options retain a visible disabled state")
local explanation=false;for _,c in ipairs(commands) do if c.kind=="text" and c.p.text:find("not ready",1,true) then explanation=true end end
check(explanation,"Unavailable frame generation explains why its options cannot be changed")
open("home");tick(20);S.zone="games";S.focus=1
S.tiles={{handle="removed",file="removed",name="Removed game",title_id="0000000000000001"}};S.home_count=1
models.stale_artwork=true;draw()
check(S.library_dirty and S.home_dirty,"A cover invalidated by a native rescan uses a placeholder and schedules a refresh")
models.stale_artwork=nil
show_modal("sort",nil,false);draw()
check(#S.rows==2 and S.rows[1].action=="sort_title" and S.rows[2].action=="sort_file","Existing sorting choices remain unchanged")
io.write("RESULT ",count," UI interaction checks passed\n")
