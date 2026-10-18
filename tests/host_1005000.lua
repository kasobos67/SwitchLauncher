-- Regression checks for the official 1.005.000 Lua contract, including its
-- deliberately unexposed native frame_gen_method/MihawkGen state fields.
local function clone(value)
    if type(value)~="table" then return value end
    local copy={};for k,v in pairs(value) do copy[k]=clone(v) end;return copy
end
local game={file="/data/prosperoeden/roms/Game/base.nsp",handle="game-1",name="A game",title_id="0100000000000001",sources={},mods=2}
local model={runtime={capabilities={}},preferences={volume=100,menu_volume=100,renderer=1,frame_gen=false,
    frame_gen_target=0,frame_gen_multiplier=0,speed_limit=0,update_notices=false,reduce_motion=false,
    menu_bind={0,1,2,3},large_text=false,high_contrast=false},
    choices={resolution={"720p","1080p"},filter={"Bilinear"},astc={"CPU"},post_processing={"Off","Clean"},
        frame_gen_state=1,speed_limit={100,150,200,300,0}},
    profiles={{name="Player 1",handle="one",playing=true}},
    home={setup_ready=true,status="",recents={{file=game.file}}},
    status={clock="12:00",version="v1.005.000",controllers=1,room={phase=0},launch={stage="idle"},
        update={version="v1.006.000",installable=true},update_status={phase=0},save_sync={stage=0},keyboard={ready=false}},
    library={generation=1,scanning=false,games={game}},sources={generation=1},
    launcher_updates={phase="current",automatic_checks=false},downloads={},setup={save_transfer=false},
    game_settings={speed_limit=-1,performance={-1,-1,-1,-1,-1,-1,-1,-1},docked=true,frame_gen=-1,frame_gen_target=-1,frame_gen_multiplier=-1,post_processing=-1},
    mods={enabled=true,folder="/data/prosperoeden/roms/Game/mods",mods={
        {name="Patch",kind="Patch",enabled=true,cheats={}},
        {name="Combined",kind="Patch / Cheats",enabled=true,cheats={{name="Health",enabled=true}}},
        {name="Cheats only",kind="Cheats",enabled=true,cheats_only=true,cheats={{name="Coins",enabled=true}}}}},
    cheats={enabled=true,folder="/data/prosperoeden/roms/Game/cheats",cheats={
        {mod="Combined",name="Health",enabled=true},{mod="Cheats only",name="Coins",enabled=true}}}}
local actions,commands={},{}
host={query=function(name,args)
    if name=="measure" then return #args.text*args.size*.55 end
    if name=="game_settings" then model.game_preset_context=true end
    if name=="preferences" then model.game_preset_context=false end
    if name=="choices" and model.game_preset_context then local choices=clone(model.choices);choices.post_processing[3]="Game-local preset";return choices end
    assert(model[name],"Unexpected host query "..name);return clone(model[name])
end,action=function(name,args)
    args=args or {};actions[#actions+1]={name=name,args=clone(args)}
    if name=="preferences.set" then
        for k,v in pairs(args) do assert(model.preferences[k]~=nil,"Unexposed host field "..k);model.preferences[k]=v end
    elseif name=="game_settings.set" then
        for k,v in pairs(args.patch) do assert(model.game_settings[k]~=nil);model.game_settings[k]=clone(v) end
    elseif name=="mods.enabled" then model.mods.enabled=args.value
    elseif name=="cheats.enabled" then model.cheats.enabled=args.value
    elseif name=="mod.enabled" then for _,m in ipairs(model.mods.mods) do if m.name==args.name then m.enabled=args.value end end
    elseif name=="cheat.enabled" then for _,c in ipairs(model.cheats.cheats) do if c.mod==args.mod and c.name==args.name then c.enabled=args.value end end
    end
    return {ok=true}
end,draw=function(kind,args)commands[#commands+1]={kind=kind,args=clone(args)};return true end}
local function read(path)local f=assert(io.open(path,"rb"));local value=f:read("*a");f:close();return value end
local app=arg[1] and assert(loadfile(arg[1]))() or assert(load(read("src/motion.lua").."\n"..read("src/ui.lua")))()
local function find(fn,name,seen)
    seen=seen or {};if seen[fn] then return end;seen[fn]=true
    for i=1,100 do local key,value=debug.getupvalue(fn,i);if not key then break end
        if key==name then return value end
        if type(value)=="function" then local found=find(value,name,seen);if found then return found end end
    end
end
local S=assert(find(app.update,"S"));local U=assert(find(app.update,"U"))
local settings=assert(find(app.input,"settings_rows"));local change=assert(find(app.input,"change_row"))
local value=assert(find(app.draw,"value_of"));local button=assert(find(app.input,"run_button"))
local modal=assert(find(app.input,"show_modal"));local rows=assert(find(app.input,"modal_rows"))
local checks,time=0,0
local function check(ok,label)assert(ok,label);checks=checks+1;print("PASS "..label)end
local function tick(n)for _=1,n do time=time+1/60;app.update({time=time,dt=1/60}) end end
local function draw()
    commands={};app.draw();local depth={opacity=0,clip=0,transform=0};local pops={unopacity="opacity",unclip="clip",untransform="transform"}
    for _,c in ipairs(commands) do
        if depth[c.kind] then depth[c.kind]=depth[c.kind]+1 elseif pops[c.kind] then local k=pops[c.kind];depth[k]=depth[k]-1;assert(depth[k]>=0) end
    end
    for _,n in pairs(depth) do assert(n==0,"Unbalanced drawing scope") end
end
local function has(text)for _,c in ipairs(commands) do if c.kind=="text" and c.args.text==text then return true end end;return false end
app.init({state={white=false,avatars={},recent={}},first_start=false});tick(90)
check(S.modal==nil and S.offer_seen=="v1.006.000","Update notices Off suppresses the startup dialog and records the offer")
S.screen="about";draw()
check(has("ProsperoEden v1.006.000 is available") and has("App update"),"About advertises the app update even when notices are Off")
app.input({key="triangle"});check(S.modal=="update","About can manually open the ProsperoEden updater")
S.modal=nil;U.view=true;app.updater_input({key="triangle"})
check(actions[#actions].name=="launcher_updates.close" and S.pending_app_update,"The themed launcher updater closes before opening the app updater")
tick(1);check(S.modal=="update" and not S.pending_app_update,"App updater opens after leaving the themed launcher update view")
S.modal=nil;S.game=game;S.game_settings=clone(model.game_settings)
local performance=settings("Performance",false);local speed=performance[#performance]
check(speed.field=="speed_limit" and #speed.values==5 and speed.values[5]=="Unlimited","Speed labels come from the host percentage list")
change(speed,1,false);check(model.preferences.speed_limit==1 and value(speed,false)=="150%","Global speed stores a zero-based host index")
for _=1,3 do change(speed,1,false) end
check(model.preferences.speed_limit==4 and value(speed,false)=="Unlimited","Unlimited stores index 4, not percentage 0")
local game_speed=settings("Performance",true)[9]
check(value(game_speed,true)=="System Settings (Unlimited)","Per-game speed inheritance displays the global value")
change(game_speed,1,true)
check(model.game_settings.speed_limit==0 and value(game_speed,true)=="100%","Per-game speed override stores the first host index")
change(game_speed,-1,true);check(model.game_settings.speed_limit==-1,"Per-game speed can return to Follows Settings")
check(model.game_settings.performance[1]==-1 and #model.game_settings.performance==8,"Speed changes do not overwrite the existing performance switches")
local game_video=settings("Video",true);local post
for _,row in ipairs(game_video) do if row.field=="post_processing" then post=row end end
check(post and post.values[3]=="Game-local preset","Game-local presets are snapshotted after reading game settings")
host.query("preferences")
check(post.values[3]=="Game-local preset" and #S.choices.post_processing==2,"Host preference polls cannot replace the game's preset list or contaminate the global list")
for _=1,3 do change(post,1,true) end
check(model.game_settings.post_processing==2,"Selecting a game-local preset stores its native list index")
local system=settings("System",false);check(system[3].field=="update_notices","System exposes the native update-notice preference")
change(system[3],1,false);model.status.update.version="v1.007.000";tick(30)
check(model.preferences.update_notices and S.modal=="update","Update notices On retains the normal startup offer")
S.modal=nil
local video=settings("Video",false);local method,frame
for _,row in ipairs(video) do if row.action=="frame_gen_setup" then method=row elseif row.field=="frame_gen" then frame=row end end
check(method and frame,"MihawkGen setup stays accessible when Lossless.dll is absent")
change(frame,1,false)
check(model.preferences.frame_gen,"Existing frame-generation toggle works with the method saved in native settings")
button(method,false);draw();check(S.modal=="frame_gen_setup" and has("Open built-in launcher"),"Method setup gives an explicit route to the built-in launcher")
button(rows()[1]);check(actions[#actions].name=="launcher.select" and actions[#actions].args.id=="builtin","Method setup uses the supported built-in launcher action")
for _,a in ipairs(actions) do if a.name=="preferences.set" or a.name=="game_settings.set" then check(not (a.args.frame_gen_method or (a.args.patch or {}).frame_gen_method),"Theme never writes an unexposed method field") end end
modal("game",nil,false);local categories=rows();local mods_row,cheats_row
for _,row in ipairs(categories) do if row.category=="Mods" then mods_row=row elseif row.category=="Cheats" then cheats_row=row end end
check(mods_row and cheats_row and mods_row.value=="2 of 2 on" and cheats_row.value=="2 of 2 on","Game options count mods and cheats independently")
modal("mods",nil,false);local mods=rows()
check(#mods==3 and mods[1].action=="all_mods" and mods[2].name=="Patch" and mods[3].name=="Combined","Mods hides cheat-only entries and individual cheat switches")
button(mods[1]);check(not model.mods.enabled and model.cheats.enabled,"All mods leaves All cheats unchanged")
modal("cheats",nil,false);local cheats=rows()
check(#cheats==3 and cheats[1].action=="all_cheats" and cheats[2].mod=="Combined","Cheats preserves each native mod/name identity")
button(cheats[2]);check(not model.cheats.cheats[1].enabled and model.cheats.cheats[2].enabled,"One cheat can change without changing another cheat")
button(rows()[1]);check(not model.cheats.enabled and not model.mods.enabled,"All cheats has its own native switch")
for _,white in ipairs({false,true}) do
    button({action=white and "theme_white" or "theme_black"})
    for _,kind in ipairs({"mods","cheats","game"}) do modal(kind,nil,false);tick(20);draw() end
    check(true,"Mod/cheat lists render with balanced draw scopes in "..(white and "light" or "dark"))
end
model.cheats.cheats={};tick(20);modal("cheats",nil,false);draw()
check(#S.rows==0,"Empty Cheats list has no misleading master switch")
check(not has("Create the folder"),"Empty Cheats list does not invoke the Mods folder action")
app.shutdown();print("RESULT "..checks.." host 1.005.000 checks passed")
