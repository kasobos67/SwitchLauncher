-- Run from the repository root with Lua 5.4. An optional argument selects a
-- packaged main.lua instead; host mocks isolate the theme's refresh policy.
local counts, actions, checks = {}, {}, 0
local games={}
for i=1,40 do games[i]={file="game-"..i,handle="game-"..i,name="Game "..i,title_id=string.format("%016x",i),remote=false,sources={}} end
local models={
    runtime={capabilities={}},
    preferences={reduce_motion=false,large_text=false,high_contrast=false,menu_bind={0,1,2,3},volume=100},
    profiles={{name="Player 1",handle="one",playing=true},{name="Player 2",handle="two",playing=false}},
    home={setup_ready=true,last_file="game-1",recents={{file="game-1"}},status=""},
    choices={resolution={"720p","1080p"},filter={"Bilinear"},astc={"CPU"},post_processing={"Off"},frame_gen_state=2},
    status={clock="12:00",controllers=1,version="v1.004.000",room={phase=0,members={}},launch={stage="idle"},update={},update_status={phase=0},save_sync={stage=0},keyboard={ready=false}},
    sources={generation=1},library={generation=1,scanning=false,games=games},downloads={},
    launcher_updates={phase="idle",automatic_checks=true},
}
local function clone(v)
    if type(v)~="table" then return v end
    local c={};for k,x in pairs(v) do c[k]=clone(x) end;return c
end
host={query=function(name,p)
    counts[name]=(counts[name] or 0)+1
    if name=="measure" then return #p.text*p.size*.6 end
    assert(models[name],"unexpected query: "..name);return clone(models[name])
end,draw=function()return true end,action=function(name,p)
    actions[name]=(actions[name] or 0)+1
    if name=="preferences.set" then for k,v in pairs(p) do models.preferences[k]=v end
    elseif name=="profile.choose" then
        for _,v in ipairs(models.profiles) do v.playing=v.handle==p.handle end
        models.home.last_file="game-2";models.preferences.volume=65
    elseif name=="game.delete" then
        table.remove(models.library.games,1);models.library.generation=models.library.generation+1
        models.home.last_file="game-2"
    elseif name=="launcher_updates.check" then models.launcher_updates.phase="checking"
    end
    return {ok=true}
end}
local load_app
if arg[1] then load_app=assert(loadfile(arg[1]))
else
    local function read(path) local f=assert(io.open(path,"rb"));local text=f:read("*a");f:close();return text end
    load_app=assert(load(read("src/motion.lua").."\n"..read("src/ui.lua"),"@switchlauncher"))
end
local app=load_app()
local function upvalue(fn,name,seen)
    seen=seen or {};if seen[fn] then return end;seen[fn]=true
    for i=1,100 do
        local k,v=debug.getupvalue(fn,i);if not k then break end
        if k==name then return v end
        if type(v)=="function" then local found=upvalue(v,name,seen);if found then return found end end
    end
end
local S=assert(upvalue(app.update,"S"));local U=assert(upvalue(app.update,"U"))
local A=assert(upvalue(app.input,"A"));local button=assert(upvalue(app.input,"run_button"))
local function check(ok,msg) assert(ok,msg);checks=checks+1;io.write("PASS ",msg,"\n") end
local time=0
local function tick(n,scroll)
    for i=1,n do
        time=time+1/60
        if scroll then S.strip_target=1000+((i//10)%2)*400 end
        app.update({time=time,dt=1/60})
    end
end
app.init({state={white=false,recent={},avatars={}},first_start=false})
tick(600,true)
check(counts.home==1,"HOME metadata queried once across ten seconds of scrolling")
check(counts.profiles==1 and counts.choices==1 and counts.preferences==1,"unchanged profiles, choices and preferences remain cached")
check(counts.status>=36,"live status still refreshed at least 3.6 times a second")
check((actions['launcher_updates.check'] or 0)==1,"automatic update check still starts once at boot")
models.launcher_updates.phase="available";models.launcher_updates.release={version="1.004.999"};tick(90,true)
check(U.has_update and U.target_version=="1.004.999","update icon receives an available release while scrolling")
local reads=counts.home
A("preferences.set",{volume=35,large_text=true});tick(20)
check(S.prefs.volume==35 and S.prefs.large_text,"preference changes refresh the local model")
check(counts.home==reads,"changing ordinary preferences does not rebuild HOME")
button({action="theme_white"})
check(S.state.white and counts.home==reads,"light appearance updates without metadata I/O")
local C=assert(upvalue(app.draw,"C"));check(C.base==0xebebeb,"light palette is applied immediately")
button({action="theme_black"});check(C.base==0x2d2d2d,"dark palette is applied immediately")
A("profile.choose",{handle="two"});tick(20)
check(S.profiles[2].playing and S.home.last_file=="game-2" and S.prefs.volume==65,"profile change refreshes identity, history and preferences together")
reads=counts.home;tick(120,true);check(counts.home==reads,"profile refresh returns to cached operation")

-- A source change may arrive while the user keeps scrolling beyond the watch deadline.
models.sources.generation=2;models.library.generation=2
tick(300,true)
check(S.library_watch~=nil,"catalog change remains pending during continuous motion")
S.strip=S.strip_target;S.scroll=S.scroll_target;S.strip_velocity=0;S.scroll_velocity=0;tick(30)
check(S.generation==2 and S.library_watch==nil,"deferred catalog change is applied when movement settles")

reads=counts.home
A("game.delete",{game="game-1",confirmed=true});S.library_dirty=true
S.strip=S.strip_target;S.strip_velocity=0;tick(30)
check(counts.home==reads+1 and S.game_lookup['game-1']==nil,"deleting a game updates HOME and the catalog once")
models.status.clock="12:01";models.status.controllers=3;models.status.room.phase=2
tick(20)
check(S.status.clock=="12:01" and S.status.controllers==3 and S.status.room.phase==2,"clock, controllers and multiplayer remain live")
models.status.update={version="v1.005.000",installable=true};tick(20)
check(S.modal=="update","application update notification still opens promptly")
S.modal=nil;models.status.update={};models.status.keyboard={ready=true,text="new.example",cancelled=false}
S.room_form={};S.keyboard_target={kind="room",field="host"};tick(20)
check(S.room_form.host=="new.example" and not S.keyboard_target,"keyboard replies remain live")
models.status.keyboard={ready=false};models.status.save_sync={before=false,stage=2};tick(20)
check(S.modal=="sync_after","save-sync conflict still reaches the UI")
S.modal=nil;models.status.save_sync={stage=0}
reads=counts.home;tick(3600,true)
check(counts.home==reads,"one minute of navigation causes no periodic HOME metadata reads")
S.strip=S.strip_target;S.scroll=S.scroll_target;S.strip_velocity=0;S.scroll_velocity=0;tick(45)
check(not S.library_watch,"idle catalog safety refresh completes")
S.strip=0;S.strip_target=405;S.strip_velocity=0;tick(1)
check(S.strip>0 and S.strip<40 and S.strip_velocity>0,"HOME starts moving on the first frame with the native spring")
S.prefs.reduce_motion=true;S.scroll_target=276;tick(1)
check(S.strip==405 and S.scroll==276 and S.strip_velocity==0 and S.scroll_velocity==0,"Reduce motion snaps positions and clears both velocities")
S.prefs.reduce_motion=false;S.modal=nil;S.screen="home";S.zone="games";S.focus=#S.tiles+1
S.scroll=150;S.scroll_velocity=900;app.input({key="cross"})
check(S.screen=="library" and S.scroll==0 and S.scroll_velocity==0,"opening the library clears its previous motion")
S.scroll=150;S.scroll_velocity=900;button({action="sort_title"})
check(S.scroll==0 and S.scroll_target==0 and S.scroll_velocity==0,"sorting resets the library without residual drift")
app.shutdown();check((actions['state.save'] or 0)>=3,"appearance and shutdown state are still saved")
io.write("RESULT ",checks," refresh-policy checks passed\n")
