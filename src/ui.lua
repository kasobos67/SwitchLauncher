-- SPDX-License-Identifier: GPL-3.0-or-later
-- External presentation. All emulation and persistent application operations use the host API.
local PACK_VERSION = "@PACK_VERSION@"
local LAUNCHER_UPDATES = true
local HOME_SLOTS = 12
local face_buttons={"cross","circle","square","triangle"}
local face_indices={cross=1,circle=2,square=3,triangle=4}
local face_labels={"Cross","Circle","Square","Triangle"}
local S = {screen="home",previous="home",transition=100,focus=1,zone="games",profile=1,
    library=1,scroll=0,scroll_target=0,strip=0,strip_target=0,elapsed=100,time=0,
    category=1,content=false,row=1,menu_scroll=0,modal=nil,modal_time=0,save="",
    games={},tiles={},profiles={},prefs={},choices={},status={},state={},message="",poll=0}
local U={row=1,status={},busy=false,can_update=true,view=false,credits=false,has_update=false,check_pending=true,next_poll=0}
local record_update_failure
local C = {base=0x2d2d2d,text=0xf5f5f5,title=0xffffff,copy=0xcfcfcf,meta=0xbdbdbd,
    line=0x555555,row=0x414141,accent=0x30d5c8,shortcut=0x505050,warn=0xffb36a}
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
local function cubic(x) x=clamp(x,0,1); return x*x*(3-2*x) end
local query_cache,rows_cache,layout_cache={},{},{}
local empty_args={}
local function D(kind,p)
    local result=host.draw(kind,p or empty_args)
    if type(result)=="table" and result.error then error(result.error) end
    return result
end
local function Q(name,p)
    local cached=name~="measure" and name~="library" and name~="status" and name~="state"
    local key=p and (p.game or p.path) or false
    key=key or false
    local bucket=cached and query_cache[name]
    local entry=bucket and bucket[key]
    if entry and S.time-entry.time<.25 then return entry.value end
    local result=host.query(name,p or empty_args)
    if type(result)=="table" and result.error and result.ok==false then error(result.error) end
    if cached then
        if not bucket then bucket={};query_cache[name]=bucket end
        bucket[key]={time=S.time,value=result}
    end
    return result
end
local function A(name,p)
    if name~="sound" and name~="state.save" then query_cache={};rows_cache={};layout_cache={} end
    if name=="library.refresh" or name=="game.delete" or name=="profile.choose" or name=="download.start" then S.library_dirty=true end
    local r=host.action(name,p or empty_args)
    if r and r.ok==false then
        local reason=r.error or r.message
        S.message=type(reason)=="string" and reason~="" and reason or "Could not complete this operation. Please try again."
        if name:sub(1,17)=="launcher_updates." and record_update_failure then
            U.action_error=S.message;record_update_failure({error=S.message,operation=name})
        end
    elseif name:sub(1,17)=="launcher_updates." then
        U.action_error=nil;U.failure=nil
        if name=="launcher_updates.check" or name=="launcher_updates.download" then U.last_failure_key=nil end
    end
    return r
end
local function save_state(quiet)
    local result=host.action("state.save",S.state)
    local ok=type(result)=="table" and result.ok==true
    if ok and type(S.state.updater_errors)=="table" and #S.state.updater_errors>0 then U.diagnostic_saved=true end
    if not quiet then
        local previous=S.state_save_error
        S.state_save_error=nil;S.state_save_detail=nil
        if not ok then
            local reason=type(result)=="table" and (result.error or result.message) or nil
            local detail=type(reason)=="string" and reason~="" and reason or "The host did not report a reason."
            local lower=detail:lower()
            S.state_save_error="Launcher settings could not be saved."
            if lower:find("no space left",1,true) or lower:find("quota exceeded",1,true) then
                S.state_save_error="Launcher settings could not be saved. Free some storage and try again."
            elseif lower:find("permission denied",1,true) or lower:find("operation not permitted",1,true) or lower:find("read-only",1,true) then
                S.state_save_error="Launcher settings could not be saved. Access to the data folder was denied."
            end
            S.state_save_detail=detail
            S.message=S.state_save_error
        elseif S.message==previous then S.message="" end
    end
    return ok
end
local function bounded_error(value,limit)
    local text=tostring(value or ""):gsub("[Aa]uthorization:[^\r\n]*","Authorization: [redacted]")
    text=text:gsub("[Bb]earer%s+[%w%._%-]+","Bearer [redacted]"):gsub("[Bb]asic%s+[%w%+/=]+","Basic [redacted]")
    text=text:gsub("(https?://[^%s?#]+)[?#][^%s]*","%1?[redacted]"):gsub("[%z\1-\31\127]"," ")
    local end_at=math.min(#text,limit or 1200)
    while end_at>0 and (text:byte(end_at+1) or 0)>=128 and (text:byte(end_at+1) or 0)<192 do end_at=end_at-1 end
    return text:sub(1,end_at)..(end_at<#text and "..." or "")
end
local function update_failure_description(raw,code)
    local value=string.lower(tostring(raw or ""))
    local function has(words) for _,word in ipairs(words) do if value:find(word,1,true) then return true end end;return false end
    if code=="storage_full" or has({"no space left","not enough space","not enough storage","disk full","enospc","disk quota","edquot"}) then
        return {code="storage_full",title="Not enough free storage.",detail="Free space on the device, then try the update again."}
    elseif code=="permission_denied" or has({"permission denied","access denied","read-only file system","erofs","eacces","operation not permitted"}) then
        return {code="permission_denied",title="Access to update files was denied.",detail="Check access to ProsperoEden's data folder, then try again."}
    elseif code=="timeout" or has({"timed out","timeout"}) then
        return {code="timeout",title="The update server did not respond.",detail="Check your connection or try again later."}
    elseif code=="server_unreachable" or has({"could not resolve","couldn't resolve","could not connect","couldn't connect","failed to connect","host unreachable","network is unreachable","connection refused","connection reset","network unavailable","dns"}) then
        return {code="server_unreachable",title="Cannot reach the update server.",detail="Check your connection, then try again. The server may also be temporarily unavailable."}
    elseif has({"certificate","ssl","tls","secure connection"}) then
        return {code="secure_connection",title="A secure connection could not be established.",detail="Check the console date and time and try again later."}
    elseif has({"404","not found"}) and has({"http","download","update","release","feed"}) then
        return {code="not_found",title="The update file could not be found.",detail="Check for updates again. The release or update source may have moved."}
    elseif has({"429","rate limit","http 403","http status 403"}) then
        return {code="server_limit",title="The update server refused the request.",detail="The server may be limiting requests. Wait a while, then try again."}
    elseif has({"http 500","http 502","http 503","http 504","http status 500","http status 502","http status 503","http status 504"}) then
        return {code="server_error",title="The update server is unavailable.",detail="Try again later."}
    elseif has({"checksum","sha256","sha-256","crc","archive hash","archive digest","zip","invalid lua","syntax error","script validation"}) then
        return {code="invalid_download",title="The downloaded files failed verification.",detail="Check for updates and download again. Invalid files will not be installed."}
    elseif has({"incompatible","unsupported api","capability","host contract","state schema"}) then
        return {code="incompatible",title="This update is not compatible.",detail="Use a compatible ProsperoEden version or wait for a compatible launcher release."}
    elseif has({"feed","release list","duplicate release","json.exception","invalid https","require https"}) then
        return {code="invalid_feed",title="The update information is invalid.",detail="The update source needs to be corrected. Try again later."}
    elseif has({"recovery","transaction","replacement destination"}) then
        return {code="recovery_required",title="The previous update needs recovery.",detail="Restart the app before trying again."}
    elseif has({"cannot write","cannot create","cannot synchronize","cannot replace","cannot remove","write failed","failed writing","failure writing","write error","writing output","could not save"}) then
        return {code="write_failed",title="The update files could not be saved.",detail="Check free space and access to the app's data folder, then try again."}
    elseif has({"finish","pending operation","not ready","unavailable during"}) then
        return {code="busy",title="Another operation is still running.",detail="Finish or cancel the current operation, then try again."}
    end
    return {code="unexpected",title="Something went wrong with the update.",detail="Try again. Keep the diagnostic details if the problem continues."}
end
record_update_failure=function(status)
    local raw=bounded_error(status.error or "The host did not provide an error reason.",1200)
    local failure=update_failure_description(raw,status.error_code)
    U.failure=failure
    local key=raw..":"..tostring(status.checked_at or "")..":"..(status.operation or U.operation or "update")
    if U.last_failure_key==key then return end
    U.last_failure_key=key
    local log=type(S.state.updater_errors)=="table" and S.state.updater_errors or {};S.state.updater_errors=log
    log[#log+1]={code=failure.code,error=raw,operation=status.operation or U.operation or "update",launcher=PACK_VERSION,
        host=bounded_error(S.status.version or "unknown",80),release=bounded_error((status.release or {}).version or U.target_version or "",80),
        checked_at=status.checked_at or U.checked_at,clock=S.status.clock or "",launcher_time=math.floor(S.time)}
    while #log>10 do table.remove(log,1) end
    U.diagnostic_pending=U.view
    U.diagnostic_saved=not U.view and save_state(true) or false
end
local function accept_update_status(status)
    U.status=status or {}
    local phase=U.status.phase
    if U.status.checked_at then U.checked_at=U.status.checked_at end
    if phase=="failed" then record_update_failure(U.status)
    elseif phase=="checking" or phase=="downloading" or phase=="validating" or phase=="installing" then
        U.operation=phase;U.failure=nil;U.last_failure_key=nil;U.action_error=nil
    elseif not U.action_error then U.failure=nil end
    if phase=="available" then
        local release=U.status.release or {}
        U.target_version=release.version;U.has_update=type(release.version)=="string" and release.version~=PACK_VERSION
    elseif phase=="current" or phase=="installed" or phase=="unconfigured" then U.has_update=false end
end
local function poll_launcher_updates()
    local status=Q("launcher_updates");accept_update_status(status)
    if not U.check_pending then return end
    local phase=status.phase or "idle"
    if status.automatic_checks==false or phase=="checking" or phase=="current" or phase=="available" or phase=="unconfigured" then U.check_pending=false;return end
    if S.intro<2 or S.time<(U.retry_at or 0) or S.launch_time or U.view then return end
    local launch=(S.status.launch or {}).stage or "idle"
    local app_phase=(S.status.update_status or {}).phase or 0
    if launch~="idle" or (app_phase~=0 and app_phase~=6 and app_phase~=7) then return end
    if phase~="idle" and phase~="failed" and phase~="cancelled" and phase~="installed" then return end
    -- Use the host's asynchronous check without opening a page or showing background errors.
    local result=host.action("launcher_updates.check",empty_args)
    query_cache.launcher_updates=nil;U.retry_at=S.time+5
    if result and result.ok then U.check_pending=false;U.next_poll=S.time+.25 end
end
local function sound(event)
    if event=="focus" then
        if S.screen=="profile" or S.screen=="avatar" or (S.screen=="home" and S.zone=="profiles") then event="focus_account"
        elseif S.screen=="home" then event=S.zone=="shortcuts" and "focus_applet" or S.focus>#S.tiles and "focus_library_button" or "focus"
        elseif S.screen=="library" and not S.modal then event="focus"
        elseif S.screen=="settings" and not S.content and not S.modal then event="focus_navigation"
        else event="focus_menu" end
    end
    A("sound",{event=event})
end
local text_args,box_args,line_args,image_args,circle_args,ring_args={},{},{},{},{},{}
local full_uv={0,0,1,1}
local home_blank_uv={{0,0,0.5,1},{0.5,0,0.5,1}}
local function text(value,x,y,size,ink,align,width)
    size=size or 30
    local drawn=S.prefs.large_text and size<30 and math.min(30,size*1.3) or size
    local p=text_args;p.text=tostring(value or "");p.x=x;p.y=y+(drawn-size)*.35;p.size=size;p.color=ink or C.text;p.align=align or "left";p.width=width or 1900
    D("text",p)
end
local function box(x,y,w,h,ink,alpha,radius) local p=box_args;p.x=x;p.y=y;p.w=w;p.h=h;p.color=ink;p.alpha=alpha or 1;p.radius=radius or 0;D("rect",p) end
local function line(x,y,x2,y2,ink,width,alpha) local p=line_args;p.x=x;p.y=y;p.x2=x2;p.y2=y2;p.color=ink or C.line;p.thickness=width or 1;p.alpha=alpha or 1;D("line",p) end
local function image(asset,x,y,w,h,uv,ink,alpha) local p=image_args;p.asset=asset;p.x=x;p.y=y;p.w=w;p.h=h;p.uv=uv or full_uv;p.color=ink or 0xffffff;p.alpha=alpha or 1;D("image",p) end
local function circle(x,y,r,ink,alpha) local p=circle_args;p.x=x;p.y=y;p.radius=r;p.color=ink;p.alpha=alpha or 1;D("circle",p) end
local function ring(x,y,r,thick,ink,alpha) local p=ring_args;p.x=x;p.y=y;p.radius=r;p.thickness=thick;p.color=ink;p.alpha=alpha or 1;D("ring",p) end
local measure_cache,measure_count={},0
local function measured(value,size)
    size=size or 30;if S.prefs.large_text and size<30 then size=math.min(30,size*1.3) end
    value=tostring(value or "")
    local bucket=measure_cache[size]
    if bucket and bucket[value] then return bucket[value] end
    local width=Q("measure",{text=value,size=size})
    if measure_count>=1024 then measure_cache={};measure_count=0;bucket=nil end
    if not bucket then bucket={};measure_cache[size]=bucket end
    bucket[value]=width;measure_count=measure_count+1
    return width
end
local wrap_cache={};local wrap_count=0
local function wrapped(value,size,width)
    value=tostring(value or "")
    local key=tostring(S.prefs.large_text)..":"..size..":"..width..":"..value
    if wrap_cache[key] then return wrap_cache[key] end
    local row="";local lines={}
    for paragraph in (value.."\n"):gmatch("(.-)\n") do
        row=""
        for word in paragraph:gmatch("%S+") do
            local next_row=row=="" and word or row.." "..word
            if row~="" and measured(next_row,size)>width then lines[#lines+1]=row;row=word else row=next_row end
        end
        lines[#lines+1]=row
    end
    if wrap_count>=128 then wrap_cache={};wrap_count=0 end
    wrap_cache[key]=lines;wrap_count=wrap_count+1
    return lines
end
local function text_block(value,x,y,size,ink,width,pitch,limit)
    local lines=wrapped(value,size,width)
    for i,line in ipairs(lines) do if i>(limit or 3) then break end;text(line,x,y+(i-1)*(pitch or 36),size,ink,"left",width) end
end
local function plate(x,y,w,h,selected)
    line(x+1,y+h-1,x+w-1,y+h-1,C.line,1,.45)
    if selected then D("border",{x=x,y=y,w=w,h=h,radius=2,color=C.row,border=S.prefs.high_contrast and 4 or 3,edge=S.prefs.high_contrast and C.title or C.accent}) end
end
local opacity_args,clip_args,transform_args,shadow_args={},{},{},{}
local function opacity(a) opacity_args.value=clamp(a,0,1);D("opacity",opacity_args) end
local function popopacity() D("unopacity") end
local function clip(x,y,w,h) local p=clip_args;p.x=x;p.y=y;p.w=w;p.h=h;D("clip",p) end
local function unclip() D("unclip") end
local function transform(scale,x,y,dx,dy) local p=transform_args;p.scale=scale or 1;p.ox=x or 0;p.oy=y or 0;p.dx=dx or 0;p.dy=dy or 0;D("transform",p) end
local function untransform() D("untransform") end
local function shadow_alpha(a) return (a or .4)*(S.state.white and .3 or 1) end
local function shadow(x,y,w,h,r,soft,a,ink) local p=shadow_args;p.x=x;p.y=y;p.w=w;p.h=h;p.radius=r or 0;p.softness=soft or 7.5;p.color=ink or 0;p.alpha=shadow_alpha(a);D("shadow",p) end
local function curve(name,frame) return motion[name] and motion[name](frame) or 1 end
local function focus(x,y,w,h,circular,amount)
    amount=amount or 1; local bx,by,bw,bh=x-7.5,y-7.5,w+15,h+15
    local radius=circular and bw*.5 or 3
    local glow_alpha=.31*amount*(.5+curve("cursor_glow_effect",S.time*60))
    -- Circular focus is drawn behind its icon, so its shadow stays circular.
    if circular then shadow(bx,by+4.5,bw,bh,radius,6,glow_alpha,0x15516e)
    else
        local clips={{bx-18,by-18,bw+36,y-by+18},{bx-18,y+h,bw+36,by+bh+18-y-h},
                     {bx-18,y,x-bx+18,h},{x+w,y,bx+bw+18-x-w,h}}
        for _,r in ipairs(clips) do clip(r[1],r[2],r[3],r[4]);shadow(bx,by+4.5,bw,bh,radius,6,glow_alpha,0x15516e);unclip() end
    end
    D("border",{x=bx,y=by,w=bw,h=bh,radius=radius,color=0,alpha=0,border=7.5,edge=S.prefs.high_contrast and C.title or C.accent,edge_alpha=amount})
    if not circular then
        local glow_frame=S.prefs.reduce_motion and 0 or S.time*60
        local alphas={curve("cursor_tl_alpha",glow_frame),curve("cursor_tr_alpha",glow_frame),curve("cursor_bl_alpha",glow_frame),curve("cursor_br_alpha",glow_frame)}
        local edgespec={{bx,by,bw,7.5,1,2,"horizontal"},{bx,by+bh-7.5,bw,7.5,3,4,"horizontal"},{bx,by,7.5,bh,1,3,"vertical"},{bx+bw-7.5,by,7.5,bh,2,4,"vertical"}}
        for _,e in ipairs(edgespec) do D("gradient",{x=e[1],y=e[2],w=e[3],h=e[4],radius=1.5,color=0xffffff,other=0xffffff,alpha=alphas[e[5]]/255*amount*.42,other_alpha=alphas[e[6]]/255*amount*.42,axis=e[7]}) end
        local frame=math.floor((S.prefs.reduce_motion and 0 or S.time)*6)%72
        local uv={(1060+frame%12*80)/2048,(364+math.floor(frame/12)*80)/1024,76/2048,76/1024}
        local edges={{bx,by,bw,7.5},{bx,by+bh-7.5,bw,7.5},{bx,by+7.5,7.5,bh-15},{bx+bw-7.5,by+7.5,7.5,bh-15}}
        local main_alpha=amount*.55*curve("cursor_main_effect",S.time*60)
        for _,r in ipairs(edges) do clip(r[1],r[2],r[3],r[4]); image("ui",bx,by,bw,bh,uv,0xffffff,main_alpha); unclip() end
    end
end
local icon_uv={}
for i=1,6 do icon_uv[i]={(2+(i-1)*132)/2048,2/1024,128/2048,128/1024} end
local function symbol(i,x,y,size,ink)
    if i==1 then
        local drawn=size*70/128
        image(U.has_update and "about_update" or "about",x-drawn*.5,y-drawn*.5,drawn,drawn,nil,ink or C.text)
    else image("ui",x-size*.5,y-size*.5,size,size,icon_uv[i],ink or C.text) end
end
local function grid_icon(x,y,size) image("icons",x-size*.5,y-size*.5,size,size,{0,0,64/384,63/128},C.title) end
local function pad(key,x,y,size)
    local action=face_indices[key]
    if action then key=face_buttons[((S.prefs.menu_bind or {})[action] or action-1)+1] end
    size=size or 36; local half=size*.5; local cx=x+half
    if key=="updown" or key=="leftright" or key=="dpad" then
        local u=key=="dpad" and 0 or key=="updown" and 32 or 64
        image("icons",x,y-half,size,size,{u/384,64/128,32/384,32/128},C.text); return size
    end
    if key=="l1" or key=="r1" then
        D("border",{x=x,y=y-half,w=size*1.45,h=size,radius=5,color=0,alpha=0,border=1.5,edge=C.text,edge_alpha=.4})
        text(string.upper(key),x+size*.725,y+size*.24,size*.52,C.text,"center"); return size*1.45
    end
    if key=="options" then ring(cx,y,half-.5,1.6,C.text);for j=-1,1 do line(cx-size*.2,y+j*size*.14,cx+size*.2,y+j*size*.14,C.text,size*.085) end;return size end
    image("icons",x,y-half,size,size,{192/384,64/128,32/384,32/128},C.text)
    local ink=C.base; local stroke=size*.085
    if key=="cross" then local d=size*.17; line(cx-d,y-d,cx+d,y+d,ink,stroke); line(cx-d,y+d,cx+d,y-d,ink,stroke)
    elseif key=="circle" then ring(cx,y,size*.21,stroke,ink)
    elseif key=="square" then D("border",{x=cx-size*.18,y=y-size*.18,w=size*.36,h=size*.36,radius=1.5,color=0,alpha=0,border=stroke,edge=ink})
    elseif key=="triangle" then D("triangle",{x=cx-size*.23,y=y-size*.24,w=size*.46,h=size*.4,color=ink,outline=stroke})
    else for j=-1,1 do line(cx-size*.2,y+j*size*.14,cx+size*.2,y+j*size*.14,ink,stroke) end end
    return size
end
local function hints(items,right,y,size)
    right=right or 1836; y=y or 1025; size=30
    local width=0
    local function pad_width(key) return (key=="l1" or key=="r1") and 36*1.45 or 36 end
    for i,item in ipairs(items) do width=width+pad_width(item[1])+10+measured(item[2],size)+(item[3] and 6+pad_width(item[3]) or 0)+(i<#items and 34 or 0) end
    local x=right-width
    for i,item in ipairs(items) do x=x+pad(item[1],x,y,36);if item[3] then x=x+6;x=x+pad(item[3],x,y,36) end;x=x+10;text(item[2],x,y+size*.35,size,C.text);x=x+measured(item[2],size)+34 end
end
local function footer(items)
    line(45,971,1875,971,C.line,1.5)
    local mask=S.status.controllers or 1
    for i=0,3 do image("controller",108+66*i,1007,50.4,35,nil,C.title,((mask & (1<<i))~=0) and 1 or .16) end
    hints(items or {{"circle","Back"},{"cross","Select"}})
end
local function frame(title,icon)
    if icon=="grid" then grid_icon(126,100,60)
    elseif icon=="controller" then symbol(4,126,100,66)
    elseif icon=="files" then symbol(2,126,100,66)
    elseif icon=="info" then image("icons",96,70,60,60,{160/384,64/128,32/384,32/128},C.text)
    else image("icons",96,70,60,60,{128/384,0,40/384,40/128},C.text) end
    text(title,178,114,40,C.title,"left",1430); line(96,157,1824,157)
end
local default_avatar={icon=0,color=0}
local function valid_avatar(value)
    return type(value)=="table" and type(value.icon)=="number" and value.icon>=0 and value.icon<147 and value.icon%1==0
        and type(value.color)=="number" and value.color>=0 and value.color<72 and value.color%1==0
end
local function unique_profile_name(profile)
    local count=0;for _,p in ipairs(S.profiles) do if p.name==profile.name then count=count+1 end end
    return count==1
end
local function avatar_settings(profile)
    local saved=profile.handle and S.state.avatars[profile.handle]
    if valid_avatar(saved) then return saved end
    if unique_profile_name(profile) then
        local alias=S.state.avatar_aliases[profile.name] or S.state.avatars[profile.name]
        if valid_avatar(alias) then return alias end
    end
    return default_avatar
end
local function store_avatar(profile,icon,color)
    local value={icon=icon,color=color};local key=profile.handle or profile.name
    S.state.avatars[key]=value
    if unique_profile_name(profile) then S.state.avatar_aliases[profile.name]={handle=profile.handle,icon=icon,color=color} end
end
local function recover_avatar_aliases()
    local changed=false
    for _,profile in ipairs(S.profiles) do
        local value=avatar_settings(profile)
        if value~=default_avatar then
            local key=profile.handle or profile.name;local alias=S.state.avatar_aliases[profile.name]
            if not valid_avatar(S.state.avatars[key]) or (unique_profile_name(profile) and
                (not valid_avatar(alias) or alias.handle~=profile.handle or alias.icon~=value.icon or alias.color~=value.color)) then
                store_avatar(profile,value.icon,value.color);changed=true
            end
        end
    end
    return changed
end
local function avatar(profile,x,y,size,circular)
    local saved=avatar_settings(profile);local icon=saved.icon
    local rgb=profile_colors[(saved.color or 0)+1] or 0xffcccc
    if circular then circle(x+size*.5,y+size*.5,size*.5,rgb) else box(x,y,size,size,rgb) end
    D("image",{asset="profiles",x=x,y=y,w=size,h=size,uv={(icon%8)/8,math.floor(icon/8)/19,1/8,1/19},color=0xffffff,radius=circular and size*.5 or 0})
end
local function refresh_models()
    S.prefs=Q("preferences"); S.profiles=Q("profiles"); S.status=Q("status"); S.home=Q("home"); S.choices=Q("choices")
    rows_cache={};layout_cache={}
    -- Catalog changes and explicit refreshes invalidate the library snapshot.
    if S.time>=(S.next_catalog or 0) then
        local source_generation=Q("sources").generation;S.next_catalog=S.time+2
        if source_generation==nil then S.library_dirty=true
        elseif source_generation~=S.source_generation then
            S.source_generation=source_generation;S.library_watch=S.time+3
        end
    end
    if not S.generation or S.library_dirty or S.scanning or S.download or S.time<(S.library_watch or 0) or S.time>=(S.library_safety or 0) then
        local library=Q("library");S.scanning=library.scanning;S.library_dirty=false;S.library_safety=S.time+60
        if library.generation~=S.generation then
            S.games=library.games; S.generation=library.generation;S.game_lookup={}
            if S.sort then table.sort(S.games,function(a,b)return (S.sort=="file" and a.file or a.name)<(S.sort=="file" and b.file or b.name) end) end
            for _,g in ipairs(S.games) do if not g.remote and not S.game_lookup[g.file] then S.game_lookup[g.file]=g end end
        end
    end
    if S.state.white then C.base=0xebebeb; C.text=0x252525; C.title=0x252525; C.copy=0x646464; C.meta=0x646464; C.row=0xffffff; C.line=0xc7c7c7; C.shortcut=0xffffff
    else C.base=0x2d2d2d; C.text=0xf5f5f5; C.title=0xffffff; C.copy=0xcfcfcf; C.meta=0xbdbdbd; C.row=0x414141; C.line=0x555555; C.shortcut=0x505050 end
    local order={tostring(S.generation),S.scanning and "scanning" or "ready",S.sort or "",S.home.last_file or ""}
    for _,file in ipairs(S.state.recent or {}) do order[#order+1]=file end
    order[#order+1]="|"
    for _,recent in ipairs(S.home.recents or {}) do order[#order+1]=recent.file end
    local signature=table.concat(order,"\0")
    if signature==S.tiles_signature then return end
    S.tiles_signature=signature;S.tiles={}; local seen={}
    local function add(file)
        local g=(S.game_lookup or empty_args)[file]
        if g and not seen[file] and not g.remote and #S.tiles<HOME_SLOTS then S.tiles[#S.tiles+1]=g;seen[file]=true end
    end
    add(S.home.last_file)
    for _,file in ipairs(S.state.recent or {}) do add(file) end
    for _,recent in ipairs(S.home.recents or {}) do add(recent.file) end
    for _,g in ipairs(S.games) do if #S.tiles>=HOME_SLOTS then break end;add(g.file) end
    -- Empty firmware positions are decorative. Only real entries receive focus.
    S.home_library=#S.games>#S.tiles
    S.home_count=#S.tiles+(S.home_library and 1 or 0)
    if S.zone=="games" then
        if S.home_count==0 then
            if not S.scanning then S.zone="shortcuts";S.focus=1 end
        else S.focus=clamp(S.focus,1,S.home_count) end
    end
    S.strip_target=math.min(S.strip_target,math.max(0,(S.home_count-4)*405))
end
local function open(screen,quiet)
    if S.screen==screen then return end
    S.previous=S.screen; S.screen=screen; S.transition=0; S.modal=nil; S.message=""; S.row=1; S.save=""; S.elapsed=0
    if quiet then return end
    if screen=="library" then S.scroll=0;S.scroll_target=0;S.library=1; A("library.refresh"); sound("library_open")
    elseif screen=="controllers" then sound("controllers_open")
    elseif screen=="profile" then sound("profile_open")
    elseif screen=="files" then sound("open")
    elseif screen=="about" then sound("news_open")
    elseif screen=="sources" or screen=="sync_setup" then sound("modal_open")
    elseif screen=="home" then sound("back")
    elseif screen=="off" then sound("select")
    else sound("open") end
end
local function current_game() if S.screen=="library" then return S.games[S.library] end return S.tiles[S.focus] end
local function cover(g,x,y,w,h)
    shadow(x,y+1.5,w,h,0,7.5,.4)
    if g then D("cover",{game=g.handle,x=x,y=y,w=w,h=h,color=0xffffff,fallback=C.row}) else box(x,y,w,h,C.row) end
end
local function marquee(value,x,y,w,size)
    local width=measured(value,size)
    if width<=w or S.prefs.reduce_motion then text(value,x+w*.5,y,size,C.accent,"center",w);return end
    local distance=width-w;local phase=S.elapsed%(3.4+distance/72);local offset=clamp((phase-2.4)*72,0,distance)
    clip(x,y-size,w,size*1.7);text(value,x-offset,y,size,C.accent);unclip()
end
local function render_home()
    for i,p in ipairs(S.profiles) do local x=100.5+(i-1)*90
        local selected=S.zone=="profiles" and S.profile==i
        if selected then focus(x,62,72,72,true) end
        avatar(p,x,62,72,true);ring(x+36,98,37,2,C.title,.7)
        if p.playing and not selected then box(x+16,144,40,4,C.accent,1,2) end
        if selected then text(p.name,x+36,178,28,C.accent,"center",240) end
    end
    text(S.status.clock,1814,115.5,30,C.text,"right")
    local phase=(S.status.room or {}).phase or 0;local ux=phase==2 and 1354 or (phase==1 or phase==3) and 1318 or 1282
    image("ui",1832,81,48,48,{ux/2048,136/1024,32/2048,32/1024},C.text)
    local intro=S.intro or 100
    local ga=S.prefs.reduce_motion and 1 or curve(S.first_start and "home_starter_alpha" or "home_entry_alpha",intro*60)/255
    local gs=S.prefs.reduce_motion and 1 or curve(S.first_start and "home_starter_scale" or "home_entry_scale",intro*60)
    opacity(ga);transform(gs,960,483)
    local g=S.tiles[S.focus]; local title=g and g.name or (S.home_library and "All Software" or ""); local selected_x=160.5+(S.focus-1)*405-S.strip
    if S.zone=="games" then local w=math.min(900,math.max(450,measured(title,32)));marquee(title,clamp(selected_x+192-w*.5,112,1808-w),258,w,32) end
    clip(0,278,1920,426)
    for i=1,math.max(HOME_SLOTS,S.home_count or 0) do
        local x=160.5+(i-1)*405-S.strip;local all=S.home_library and i==#S.tiles+1;local blank=not all and not S.tiles[i]
        if x+384>0 and x<1920 then
            local scale=(S.launch_time and S.focus==i) and curve("decide_scale",S.launch_time*60) or 1
            transform(S.prefs.reduce_motion and 1 or scale,x+192,483)
            if blank then
                -- Baked P_Blank material: no cover lookup or live blur for empty slots.
                image("home_blank",x-12,279,408,408,home_blank_uv[S.state.white and 2 or 1])
            elseif all then
                shadow(x+72,364.5,240,240,120,7.5,.4)
                if S.zone=="games" and S.focus==i then focus(x+72,363,240,240,true) end
                circle(x+192,483,120,C.shortcut);grid_icon(x+192,483,108)
            else
                cover(S.tiles[i],x,291,384,384)
                if S.zone=="games" and S.focus==i then focus(x,291,384,384,false) end
            end
            if S.launch_time and S.focus==i and not all then
                box(x,291,384,384,0xffffff,curve("decide_flash",S.launch_time*60)/255)
                local size=450*curve("launch_effect_scale",S.launch_time*60);clip(x,291,384,384)
                image("ui",x+192-size*.5,483-size*.5,size,size,{514/2048,136/1024,220/2048,220/1024},0xffffff,curve("launch_effect_alpha",S.launch_time*60)/255);unclip()
            end
            untransform()
        end
    end
    unclip();untransform();popopacity()
    opacity(ga);transform(gs,960,816)
    local names={"About","Game files","Multiplayer","Controllers","System Settings","Screen off"}
    local inks={0xff4d4d,0xffae2e,0x4a9bdb,C.title,C.title,C.title}
    for i=1,6 do local x=555+(i-1)*162;shadow(x-66,751.5,132,132,66,7.5,.35)
        if S.zone=="shortcuts" and S.focus==i then focus(x-66,750,132,132,true);text(names[i],x,918,24,C.accent,"center",330) end
        circle(x,816,66,C.shortcut)
        symbol(i,x,816,i<=4 and 132 or 96,inks[i])
    end
    untransform();popopacity()
    local notice=S.message~="" and S.message or S.state_save_error
    if notice then text(notice,960,720,22,C.warn,"center",1608)
    elseif (S.home.status or "")~="" then text(S.home.status,960,720,22,C.copy,"center",1608) end
    footer({{"triangle","Game settings"},{"cross","Select"}})
end
local function bubble(title,x,y,w)
    local center=x+w*.5
    w=math.max(180,math.min(980,measured(title,30)+42));local bx=clamp(center-w*.5,130.5,1786.5-w)
    shadow(bx,y-82.5,w,65,4.5,6,.36)
    -- Two mirrored halves preserve the original tip and its single joined shadow.
    image("ui",x+115.5,y-25.75,15,27,{258/2048,136/1024,12/2048,40/1024},0xffffff,shadow_alpha(.36))
    image("ui",x+130.5,y-25.75,15,27,{270/2048,136/1024,-12/2048,40/1024},0xffffff,shadow_alpha(.36))
    image("ui",x+114,y-22,16.5,19.5,{2/2048,136/1024,11/2048,13/1024},C.shortcut)
    image("ui",x+130.5,y-22,16.5,19.5,{13/2048,136/1024,-11/2048,13/1024},C.shortcut)
    box(bx,y-84,w,65,C.shortcut,1,4.5)
    marquee(title,bx+21,y-41,w-42,30)
end
local function render_library()
    local entering=S.screen=="library";local animation_frame=S.transition*60
    local header=entering and curve("library_header_in",math.max(0,animation_frame-27))/255 or curve("library_header_out",animation_frame)/255
    local content=entering and curve("library_content_in",math.max(0,animation_frame-33))/255 or curve("library_content_out",animation_frame)/255
    if S.prefs.reduce_motion or S.transition>1 then header=1;content=1 end
    opacity(header)
    frame("All Software","grid");pad("options",1574,98,32);text(S.sort=="file" and "By File Name" or "By Title",1758,110,28,C.text,"right");line(1784,87,1793,96,C.text,2.5);line(1793,96,1802,87,C.text,2.5)
    popopacity();opacity(content)
    clip(120,185,1668,767)
    local first=math.max(0,math.ceil((S.scroll-370)/276))*6+1
    local last=math.min(#S.games,(math.floor((S.scroll+690)/276)+1)*6)
    for i=first,last do local g=S.games[i];local x=138+((i-1)%6)*276;local y=278+math.floor((i-1)/6)*276-S.scroll
        if y+261>=169 and y<=968 then cover(g,x,y,261,261)
            if i==S.library then focus(x,y,261,261,false)
                if S.launch_time then box(x,y,261,261,0xffffff,curve("library_decide_flash",S.launch_time*60)/255) end
            end
            if g.remote then text("Download",x+130.5,y+235,22,C.title,"center",240) end
        end
    end
    local selected=S.games[S.library]
    if selected then bubble(selected.name,138+((S.library-1)%6)*276,278+math.floor((S.library-1)/6)*276-S.scroll,261) end
    unclip()
    local total=math.ceil(#S.games/6)*276;local handle=math.max(48,767*767/math.max(1,total))
    local maximum=math.max(1,278+(math.ceil(#S.games/6)-1)*276+261-940)
    if total>767 then box(1814,190,6,750,C.line,.22,3);box(1814,190+(750-handle)*clamp(S.scroll/maximum,0,1),6,handle,C.text,.58,3) end
    if #S.games==0 then text("No ROM files found.",960,500,32,C.copy,"center") end
    popopacity();footer(selected and selected.remote and {{"square","Download"},{"circle","Back"},{"cross","Download and play"}} or {{"triangle","Options"},{"circle","Back"},{"cross","Start"}})
end

local categories={"Profiles","Video","Performance","Audio","Accessibility","System","Themes","Downloads","Save sync"}
local game_categories={"Console mode","Video","Performance","Audio","Controls","System","Mods","Save data","Delete from console"}
local function choice(field,label,values,help) return {field=field,label=label,kind="choice",values=values,help=help} end
local function toggle(field,label,help) return {field=field,label=label,kind="toggle",help=help} end
local function button(label,action) return {label=label,kind="button",action=action} end
local function settings_rows(category,per_game)
    local cacheable=category~="Profiles" and category~="Downloads" and category~="Save sync" and not (per_game and category=="System")
    local cache_key=category..(per_game and ":game" or ":global")
    if cacheable and rows_cache[cache_key] then return rows_cache[cache_key] end
    local rows={}
    if category=="Video" then
        rows={choice("renderer","Renderer",{"OpenGL","Vulkan"}),choice("output","Output resolution",{"1080p","1440p","2160p"}),
            choice("resolution","Resolution",S.choices.resolution),choice("filter","Upscaling filter",S.choices.filter),
            choice("astc","ASTC textures",S.choices.astc),choice("refresh","Refresh rate",{"60 Hz","120 Hz"}),
            toggle("hud","FPS overlay"),button("Overlay options","overlay"),toggle("frame_gen","Frame generation"),
            choice("frame_gen_target","Frame gen target",{"Auto","60 Hz","90 Hz","120 Hz","144 Hz","240 Hz"}),
            choice("frame_gen_multiplier","Frame gen multiplier",{"2x","3x","4x"})}
        if per_game then
            table.remove(rows,2);table.remove(rows,7)
            table.insert(rows,7,choice("hud_size","Overlay size",{"Regular","Medium","Large"}))
            table.insert(rows,8,choice("hud_corner","Overlay corner",{"Top left","Top right","Bottom left","Bottom right"}))
        end
        if type(S.choices.post_processing)=="table" and #S.choices.post_processing>0 then
            local post=choice("post_processing","Post-processing",S.choices.post_processing)
            post.help="Applies a visual preset to the game picture. Requires the Vulkan renderer."
            table.insert(rows,per_game and 5 or 6,post)
        end
        if S.choices.frame_gen_state==0 then
            for i=#rows,1,-1 do if rows[i].field=="frame_gen" or rows[i].field=="frame_gen_target" or rows[i].field=="frame_gen_multiplier" then table.remove(rows,i) end end
        end
    elseif category=="Performance" then
        local fields={"block_list","async_shaders","fast_gpu","unsafe_cpu","unsafe_dma","reactive_flushing","skip_invalidation","compact_memory"}
        local labels={"Compile ahead","Asynchronous shaders","Faster GPU emulation","Faster CPU emulation","Faster DMA","Reactive flushing","Skip CPU invalidation","Compact memory"}
        local helps={"Compiles code used in earlier sessions as a game starts.","Draws effects once their shaders are ready, reducing compilation pauses.","Lower GPU accuracy can be faster, but graphics may be incorrect.","Less exact floating-point math may affect some games.","Less exact GPU transfers may affect graphics.","Keeps GPU readback accurate. Disabling it may affect effects.","Fewer invalidation checks may leave stale textures.","Gives back memory left mostly empty. Can cause stutters in games that keep rewriting it; leave off unless memory runs short."}
        for i,key in ipairs(fields) do rows[#rows+1]=toggle(key,labels[i],helps[i]);rows[#rows].performance=i end
    elseif category=="Audio" then rows={{field="volume",label="Game volume",kind="slider"},toggle("mute","Mute")};if not per_game then rows[#rows+1]={field="menu_volume",label="Menu sounds",kind="slider"} end
    elseif category=="Controls" then
        rows={toggle("vibration","Vibration"),choice("vibration_strength","Vibration strength",{"25%","50%","75%","100%"}),button("Change Button Mapping","mapping")}
        if per_game then rows={toggle("vibration","Vibration"),button("Button mapping","mapping"),choice("controller","Controller type",{"Pro Controller","Handheld","Two Joy-Cons","Left Joy-Con","Right Joy-Con"})} end
    elseif category=="Accessibility" then rows={toggle("large_text","Larger text","Draws the menu's small text larger."),toggle("high_contrast","High contrast","Solid surfaces and brighter text make the selection easier to see."),toggle("reduce_motion","Reduce motion","Limits menu transitions and loading-screen motion.")}
    elseif category=="System" then
        rows={toggle("detailed_logging","Detailed logging"),toggle("immediate_logs","Write logs at once","Keeps the last line before a crash, but games stutter. From the next start.")}
        if per_game then rows={button("RNG seed","rng_seed")};rows[1].value=(S.game_settings.rng_seed or -1)<0 and "Random" or tostring(S.game_settings.rng_seed) end
    elseif category=="Themes" then rows={button("Basic White","theme_white"),button("Basic Black","theme_black"),button("Launcher","launcher")}
    elseif category=="Profiles" then
        for i,p in ipairs(S.profiles) do rows[#rows+1]=button(p.name,p.playing and "profile" or "choose_profile");rows[#rows].profile=i;rows[#rows].value=p.playing and "Current user" or "" end
        if #S.profiles<8 then rows[#rows+1]=button("Add user","add_profile") end
    elseif category=="Downloads" then
        local sources=Q("sources"); for _,source in ipairs(sources.list or {}) do rows[#rows+1]=button(source.name, "download_source");rows[#rows].value=source.online and (source.games.." games") or source.error end
        rows[#rows+1]=button("Refresh sources","refresh_sources");rows[#rows+1]=button("Download queue","queue")
    elseif category=="Save sync" then
        local setup=Q("save_sync_setup"); for i,p in ipairs(setup.profiles or {}) do rows[#rows+1]=button(p.name,"sync_profile");rows[#rows].profile=i;rows[#rows].value=p.linked and p.server or "Not linked";rows[#rows].linked=p.linked end
        rows[#rows+1]=button("Pairing status","pairing")
    end
    if cacheable then rows_cache[cache_key]=rows end
    return rows
end
local function value_of(row,per_game)
    if row.value then return row.value end
    if row.kind=="button" then
        if row.action=="mapping" then
            if per_game then return S.game_settings.own_mapping and "This game" or "System Settings (As usual)" end
            local mapping=per_game and S.game_settings.mapping or S.prefs.mapping
            local defaults={1,0,3,2,4,5,6,7,10,12,8,9};for i,v in ipairs(defaults) do if mapping[i]~=v then return "Changed" end end
            return "Default"
        end
        return ""
    end
    local data=per_game and S.game_settings or S.prefs; local value=data[row.field]
    if per_game and row.performance then value=data.performance[row.performance] end
    if per_game and value==-1 then
        local usual=S.prefs[row.field];local shown=""
        if row.kind=="toggle" then shown=(usual==true or usual==1) and "On" or "Off"
        elseif row.kind=="slider" then shown=tostring(usual or 100).."%"
        else shown=(row.values or {})[(usual or 0)+1] or "Default" end
        return "System Settings ("..shown..")"
    end
    if row.kind=="toggle" then return (value==true or value==1) and "On" or "Off" end
    if row.field=="vibration_strength" then return tostring(value).."%" end
    if row.kind=="slider" then return tostring(value).."%" end
    if row.kind=="choice" then return (row.values or {})[(value or 0)+1] or "-" end
    return ""
end
local function rows_draw(rows,x,y,w,selected,visible,per_game,pitch)
    pitch=pitch or 96
    visible=visible or 5; local top=math.max(0,selected-visible);if selected<=visible then top=0 end
    local bottom=math.min(#rows,top+visible); local height=visible*pitch
    clip(x-6,y-6,w+12,height+12)
    for i=top+1,bottom do local yy=y+(i-top-1)*pitch;local row=rows[i]
        plate(x,yy,w,pitch-2,i==selected)
        local unavailable=(row.field=="frame_gen" or row.field=="frame_gen_target" or row.field=="frame_gen_multiplier") and S.choices.frame_gen_state~=2
        if unavailable then opacity(.38) end
        local value_size=(per_game or S.screen=="mapping") and 24 or 30
        local right=x+w-((per_game or S.screen=="mapping") and 32 or 36);local value=value_of(row,per_game);local used=math.min(w*.56,measured(value,value_size))
        if unavailable then value="Unavailable";used=measured(value,value_size) end
        local own=per_game and ((row.action=="mapping" and S.game_settings.own_mapping) or (type(S.game_settings[row.field])=="number" and S.game_settings[row.field]>=0) or (row.performance and S.game_settings.performance[row.performance]>=0))
        text(value,right,yy+pitch*.5+9.5,value_size,(value=="On" or own) and C.accent or C.copy,"right",w*.56)
        text(row.label,x+36,yy+pitch*.5+9.5,30,C.text,"left",w-used-102)
        if unavailable then popopacity() end
    end
    unclip()
    if #rows>visible then local track=visible*pitch;local handle=track*visible/#rows;box(x+w+14,y,9,track,C.line,.35,4.5);box(x+w+14,y+(top/math.max(1,#rows-visible))*(track-handle),9,handle,C.meta,.8,4.5) end
end
local function settings_layout(rows,top,note)
    local key=top..":"..tostring(S.prefs.large_text)..":"..(note or "")
    local cached=layout_cache[rows]
    if cached and cached.key==key then return cached.value end
    local help_lines=note and #wrapped(note,24,1008) or 0
    for _,row in ipairs(rows) do
        if row.help then help_lines=math.max(help_lines,#wrapped(row.help,24,1008)) end
    end
    local font=S.prefs.large_text and 30 or 24
    local help_pitch=S.prefs.large_text and 39 or 36
    local help_height=help_lines*help_pitch
    local budget=950-top-28-64-(help_lines>0 and help_height+28 or 0)
    local visible=math.max(1,math.min(#rows,math.floor(budget/80)))
    local pitch=math.min(96,math.floor(budget/visible))
    local finish=top+visible*pitch
    local help_top=finish+28
    local save_top=help_lines>0 and help_top+help_height+28 or finish+28
    local result={visible=visible,pitch=pitch,help_y=help_top+font*.8,help_pitch=help_pitch,
        help_lines=help_lines,save_y=save_top+font*.8}
    layout_cache[rows]={key=key,value=result}
    return result
end
local function settings_content(rows,top,selected,per_game,note,x,w)
    x=x or 714;w=w or 1086
    local layout=settings_layout(rows,top,note)
    rows_draw(rows,x,top,w,selected,layout.visible,per_game,layout.pitch)
    local help=(rows[S.row] or {}).help
    if per_game then help=(rows[S.modal_row] or {}).help end
    if help or note then text_block(help or note,x+36,layout.help_y,24,C.copy,w-78,layout.help_pitch,layout.help_lines) end
    if S.message~="" or S.save~="" then
        text_block(S.message~="" and S.message or S.save,x+36,layout.save_y,24,S.message~="" and C.warn or C.copy,w-78,32,2)
    end
end
local function set_preference(row,value,per_game)
    local r
    if per_game then
        local patch={};if row.performance then local list={table.unpack(S.game_settings.performance)};list[row.performance]=value;patch.performance=list else patch[row.field]=value end
        r=A("game_settings.set",{game=S.game.handle,patch=patch});if r.ok then S.game_settings=Q("game_settings",{game=S.game.handle}) end
    else r=A("preferences.set",{[row.field]=value});if r.ok then S.prefs=Q("preferences") end end
    if r.ok then
        S.message="";S.save=per_game and "Saved for this game. Applies on next launch." or "Saved. Applies when a game starts."
        if not per_game and row.field=="menu_volume" then S.save="Saved." end
        if not per_game and (row.field=="large_text" or row.field=="high_contrast" or row.field=="reduce_motion") then S.save="" end
    end
    return r.ok
end
local function change_row(row,step,per_game)
    if per_game and row.action=="mapping" then
        local own=not S.game_settings.own_mapping
        local patch={own_mapping=own};if own then patch.mapping=S.prefs.mapping end
        local r=A("game_settings.set",{game=S.game.handle,patch=patch})
        if r.ok then S.game_settings=Q("game_settings",{game=S.game.handle});S.save="Saved for this game. Applies on next launch.";sound("toggle") end
        return true
    end
    if row.kind=="button" then return false end
    if row.field=="frame_gen" or row.field=="frame_gen_target" or row.field=="frame_gen_multiplier" then if S.choices.frame_gen_state~=2 then S.message="Frame generation is unavailable.";sound("error");return true end end
    local data=per_game and S.game_settings or S.prefs;local value=data[row.field]
    if per_game and row.performance then value=data.performance[row.performance] end
    if row.kind=="toggle" then value=per_game and ((value+1+(step<0 and -1 or 1))%3-1) or not value
    elseif row.kind=="slider" then
        if per_game then
            if value<0 then value=step>0 and 0 or 100
            elseif (value==0 and step<0) or (value==100 and step>0) then value=-1
            else value=clamp((step>0 and math.floor(value/10)+1 or math.ceil(value/10)-1)*10,0,100) end
        else value=clamp(value+step*10,0,100) end
    elseif row.field=="vibration_strength" then value=clamp(value+step*25,25,100)
    elseif row.kind=="choice" then local count=#row.values;value=per_game and ((value+1+step)%(count+1)-1) or ((value+step)%count) end
    if set_preference(row,value,per_game) then
        local event="toggle"
        if not per_game then
            if row.kind=="slider" or row.field=="vibration_strength" or row.field=="hud_size" or row.field=="hud_corner" then event="slider"
            elseif row.kind=="toggle" then
                local enabled=S.prefs[row.field];if row.field=="immediate_logs" then enabled=S.prefs.detailed_logging end
                event=enabled and "toggle" or "toggle_off"
            end
        end
        sound(event)
    else sound("error") end
    return true
end
local function show_modal(kind,data,event)
    S.modal=kind;S.modal_data=data or {};S.modal_row=1;S.modal_time=0;S.message=""
    if event~=false then sound(event or ((kind=="game_options" or kind=="mods") and "open" or "modal_open")) end
end
local function close_modal(event) S.modal=nil;S.modal_time=0;if event~=false then sound(event or "modal_close") end end
local function row_choice(row,per_game)
    if row.field=="frame_gen" or row.field=="frame_gen_target" or row.field=="frame_gen_multiplier" then
        if S.choices.frame_gen_state~=2 then S.message="Frame generation is unavailable.";sound("error");return end
    end
    local values={};if per_game then values[1]="Follows Settings" end
    if row.kind=="slider" then for n=0,100,10 do values[#values+1]=n.."%" end
    elseif row.kind=="toggle" then values[#values+1]="Off";values[#values+1]="On"
    else for _,value in ipairs(row.values or {}) do values[#values+1]=value end end
    local category=S.modal=="game_options" and S.modal_data.category or nil;local return_row=S.modal_row
    local model=per_game and S.game_settings or S.prefs;local value=row.performance and per_game and model.performance[row.performance] or model[row.field]
    local selected=per_game and type(value)=="number" and value<0 and -1 or row.kind=="slider" and math.floor(math.max(0,value)/10) or row.kind=="toggle" and (value==true and 1 or value==false and 0 or value) or value
    show_modal("choice",{values=values,setting=row,per_game=per_game,return_category=category,return_row=return_row})
    S.modal_row=clamp((selected or 0)+(per_game and 2 or 1),1,#values)
    S.choice_original=S.modal_row
end
local function render_settings()
    frame("System Settings")
    for i,name in ipairs(categories) do local y=209+(i-1)*68
        if S.category==i then
            if not S.content then D("border",{x=156,y=y,w=438,h=66,radius=2,color=C.row,border=S.prefs.high_contrast and 4 or 3,edge=S.prefs.high_contrast and C.title or C.accent}) end
            box(171,y+12,4,42,C.accent)
        end
        text(name,188,y+43,30,S.category==i and C.accent or C.text)
    end
    local category=categories[S.category]
    local rows=settings_rows(category);S.rows=rows
    if category=="Profiles" or category=="Downloads" or category=="Save sync" then
        local titles={Profiles="User Settings",Downloads="Downloads",["Save sync"]="Save sync"}
        plate(714,228,1086,112,S.content);text(titles[category],750,294.5,30,C.text)
        local copy=""
        if category=="Profiles" then
            for i,p in ipairs(S.profiles) do local x=750+(i-1)*124;circle(x+44,439,44,0x438cc8)
                image("icons",x+14,409,60,60,{256/384,0,128/384,1},C.text)
                if p.playing then ring(x+44,439,50,3,C.accent) end
            end
            copy="Each user keeps their own save data, settings and recent software."
        elseif category=="Downloads" then
            local sources=Q("sources");copy="Games on your network, downloaded when you play them.\n"..(sources.configured and (#sources.list.." sources") or "Not set up")
        elseif category=="Save sync" then copy="Each profile's save data on a server of its own, synced before and after a game." end
        text_block(copy,750,category=="Profiles" and 550 or 392,24,C.copy,1008,36,3)
    elseif category=="Themes" then
        for i=1,2 do local y=228+(i-1)*114;plate(714,y,1086,112,S.content and S.row==i)
            D("border",{x=750,y=y+24,w=64,h=64,radius=0,color=i==1 and 0xf4f4f4 or 0x303030,border=1,edge=C.line})
            text(i==1 and "Basic White" or "Basic Black",846,y+66.5,30,C.text)
            if (not not S.state.white)==(i==1) then line(1730,y+53,1742,y+65,C.accent,4);line(1742,y+65,1766,y+39,C.accent,4) end
        end
        plate(714,456,1086,112,S.content and S.row==3);text("Launcher",750,522.5,30,C.text)
    elseif category=="System" then
        text("System Information",750,258,30,C.text)
        local details=Q("setup").details or "";local count=math.min(6,#wrapped(details,26,1008))
        text_block(details,750,322,26,C.copy,1008,39,6)
        local folder_y=322+count*39+20
        text(Q("game_files").current,750,folder_y,24,C.copy,"left",1008)
        settings_content(rows,folder_y+40,S.content and S.row or 0,false)
    else
        local note=category=="Audio" and "Game audio settings apply when software starts. Menu sound volume changes immediately." or nil
        settings_content(rows,228,S.content and S.row or 0,false,note)
    end
    footer({{"circle","Back"},{"cross","OK"}})
end
local function render_controllers()
    frame("Controllers","controller")
    local mask=S.status.controllers or 1
    for i=0,3 do local x=484+252*i
        if (mask&(1<<i))~=0 then image("controller",x,309,160,111,nil,C.text)
            for light=0,3 do box(x+41+light*21,449,12,12,light<=i and C.accent or C.line) end
        else text("-",x+80,392,32,C.meta,"center") end
    end
    text("Connected controllers",456,511,24,C.copy)
    S.rows=settings_rows("Controls");rows_draw(S.rows,420,528,1086,S.row,3)
    text("Left touchpad + L1  End the game and return to this menu",456,867,24,C.copy,"left",1008)
    text("Left touchpad + R1  Show or hide the FPS overlay",456,907,24,C.copy,"left",1008)
    if S.save~="" then text(S.save,456,947,24,C.copy,"left",1008) end
    footer({{"options","Menu buttons"},{"updown","Select"},{"circle","Back"},{"cross","OK"}})
end
local function render_files()
    frame("Data Management")
    local model=S.files or Q("game_files");S.files=model;text(model.path,112,229.1,26,C.text,"left",1670)
    line(784,269,784,916,C.line,1,.6)
    local rows={};if model.path~="/" then rows[1]=button("..","files_parent") end
    for _,name in ipairs(model.folders or {}) do rows[#rows+1]=button(name,"files_child");rows[#rows].folder=name end
    S.rows=rows;local top=math.max(0,S.row-6);clip(108,280,644,536)
    for i=top+1,math.min(#rows,top+6) do local y=282+(i-top-1)*88;plate(112,y,628,78,i==S.row)
        box(134,y+26,18,8,C.meta,1,3);box(134,y+30,40,24,C.meta,1,4)
        if rows[i].action=="files_parent" then line(154,y+48,154,y+36,C.base,2.4);line(148,y+41,154,y+35,C.base,2.4);line(160,y+41,154,y+35,C.base,2.4) end
        text(rows[i].label,202,y+47.4,24,C.text,"left",510)
    end
    unclip()
    if #rows>6 then local h=518*6/#rows;box(758,282,9,518,C.line,.35,4.5);box(758,282+top/math.max(1,#rows-6)*(518-h),9,h,C.meta,.8,4.5) end
    if #rows==0 then text("No folders here.",132,500,24,C.copy) end
    text("Game Files",844,326.5,30,C.title,"left",950)
    local info=model.info or {};local labels={"Keys","Firmware","Software","Current Folder"}
    local values={info.keys and "Ready" or "Missing",(info.firmware or -1)>=0 and tostring(info.firmware) or "Missing",(info.games or -1)>=0 and tostring(info.games) or "Missing",model.current or ""}
    for i=1,4 do local y=384+(i-1)*80;text(labels[i],860,y+43.4,24,C.text,"left",320);text(values[i],1778,y+43.4,24,C.accent,"right",570);line(844,y+76,1796,y+76,C.line,1,.5) end
    text_block("Use extracted firmware NCA files. Choose the folder here; restart the app after changing it.",844,774.7,22,C.copy,952,34,3)
    if S.message~="" then text_block(S.message,844,872,20,C.accent,950,26,2) end
    footer({{"l1","Page","r1"},{"square","Default"},{"triangle","Use this folder"},{"circle","Back"},{"cross","Open"}})
end
local update_labels={idle="Ready to check for updates",unconfigured="No update source configured",checking="Checking for updates...",
    current="Your launcher is up to date.",available="An update is available.",downloading="Downloading update...",
    validating="Checking downloaded files...",ready="Installing update...",installing="Installing update...",
    installed="Update complete.",failed="Could not update.",cancelled="Update cancelled."}
local update_buttons={"Check for updates","Update"}
local function update_progress(x,y,width,status,indeterminate,complete)
    box(x,y,width,8,C.line,1,4)
    local total=status.total or 0
    local fraction=complete and 1 or total>0 and clamp((status.done or 0)/total,0,1) or 0
    if indeterminate then
        if S.prefs.reduce_motion then fraction=1
        else
            local length=math.min(200,width)
            box(x+(S.time*.6%1)*(width-length),y,length,8,C.accent,1,4)
            return
        end
    end
    if fraction>0 then box(x,y,width*fraction,8,C.accent,1,4) end
end
local render_credits
local function render_about()
    frame("About Switch","info")
    local status=U.status;local phase=status.phase or "idle";local release=status.release or {}
    local installed=status.installed_version or PACK_VERSION
    local x,w,inset=384,1152,36
    local left,right=x+inset,x+w-inset
    text("Switch UI",left,264,40,C.title,"left",720)
    text("v"..installed,right,264,30,C.text,"right",300)
    text("ProsperoEden",left,328,26,C.copy,"left",720)
    text(S.status.version or "v1.004.000",right,328,26,C.copy,"right",300)
    line(x,376,x+w,376,C.line)

    local failure=U.failure
    text(failure and failure.title or status.rollback and phase=="installed" and "Previous version restored." or update_labels[phase] or "Ready",left,448,30,failure and C.warn or C.accent,"left",w-inset*2)
    local detail=failure and failure.detail or S.message~="" and S.message or status.error or ""
    if detail=="" then
        if phase=="available" then detail="Version "..(release.version or "").." is ready to install."
        elseif phase=="downloading" then detail=(status.total or 0)>0 and (math.floor((status.done or 0)/status.total*100).."% downloaded") or "Downloading..."
        elseif phase=="installing" or phase=="ready" or phase=="validating" then detail="Keep the app open until the update finishes."
        elseif phase=="unconfigured" then detail="This launcher does not provide an update source." end
    end
    text_block(detail,left,496,24,failure and C.warn or C.copy,w-inset*2,32,3)
    if failure then text("Error: "..failure.code..". "..(U.diagnostic_saved and "Details saved in launcher state." or U.diagnostic_pending and "Return to HOME to save diagnostic details." or "Diagnostic details could not be saved."),left,590,20,C.meta,"left",w-inset*2) end
    if U.busy then
        update_progress(left,600,w-inset*2,status,phase=="checking")
    end
    for i,label in ipairs(update_buttons) do
        local y=648+(i-1)*104;plate(x,y,w,80,U.row==i)
        local enabled=not U.busy and U.can_update and (i==1 or phase=="available")
        if not enabled then opacity(.38) end
        text(label,left,y+48,30,C.text,"left",w-inset*2)
        if not enabled then popopacity() end
    end
    footer({{"square","Credits"},{"circle",U.busy and "Cancel" or "Back"},{"cross","OK"}})
    if U.credits then render_credits() end
end
render_credits=function()
    box(0,0,1920,1080,0,.68)
    local elapsed=math.max(0,S.time-(U.credits_started or S.time))
    local alpha=S.prefs.reduce_motion and 1 or curve("screen_in",elapsed*60)/255
    local scale=S.prefs.reduce_motion and 1 or curve("modal_scale",elapsed*60)
    opacity(alpha);transform(scale,960,540)
    local x,y,w,h=480,160,960,760
    local left,right=x+48,x+w-48
    shadow(x,y+1.5,w,h,0,6,.6);box(x,y,w,h,C.base)
    text("Credits",left,248,40,C.title,"left",w-96)
    line(left,282,right,282,C.line)
    local credits={
        {"Emulation","Eden developers and contributors"},
        {"PS5 port","BlackBearReloaded"},
        {"Switch UI","kasobos67"},
        {"Artwork & menu sounds","Nintendo"}
    }
    for i,credit in ipairs(credits) do
        local top=342+(i-1)*108
        text(credit[1],left,top,22,C.meta,"left",w-96)
        text(credit[2],left,top+40,28,C.text,"left",w-96)
    end
    line(left,798,right,798,C.line)
    hints({{"circle","Back"}},right,856,26)
    untransform();popopacity()
end

local function render_profile()
    local p=S.profiles[S.profile]
    if p then avatar(p,141,62,76,true) end
    text(p and (p.name.."'s Page") or "Add User",238,116,40,C.title,"left",1500);line(96,157,1824,157,C.line)
    local count=math.min(8,#S.profiles+1)
    for i=1,count do local y=228+(i-1)*78;if i==S.profile then plate(156,y,438,76,true) end
        text(S.profiles[i] and S.profiles[i].name or "Add User",198,y+47.8,28,i==S.profile and C.accent or C.text,"left",372)
    end
    if p then
        avatar(p,714,220,312,false);plate(1062,220,738,112,true);text(p.name,1098,290,40,C.text,"left",652)
        text(p.playing and "Current User" or "Select this User",1098,403,30,p.playing and C.accent or C.copy)
        line(1062,452,1800,452,C.line);text_block("Save data and settings are kept separately for each user.",1098,495,24,C.copy,666,36,2)
        text("Software",714,602,30,C.text);line(714,627,1800,627,C.line)
        if p.playing then for i=1,math.min(3,#S.tiles) do local y=645+(i-1)*94;cover(S.tiles[i],714,y,78,78);text(S.tiles[i].name,816,y+48.45,27,C.text,"left",984);line(714,y+88,1800,y+88,C.line) end
        else text_block("Select this user to view their software.",714,687,26,C.copy,1086,39,2) end
    else text("Add a user to this console.",714,350,30,C.text);text_block("Each user keeps their own save data, settings and recent games.",714,435,26,C.copy,1086,39,3) end
    if S.message~="" then text(S.message,750,929,24,C.copy,"left",1008) end
    footer(p and {{"options","Edit Icon"},{"triangle","Rename"},{"square","Remove"},{"circle","Back"},{"cross","Select"}} or {{"circle","Back"},{"cross","OK"}})
end
local function render_avatar()
    local p=S.profiles[S.profile] or {name="Player"};local color=S.avatar_mode=="color"
    text(color and "Choose a Background" or "Choose an Icon",96,112,40,C.title);line(96,157,1824,157,C.line);line(520,195,520,914,C.line)
    local count=color and 72 or 147;local size=114;local scroll=math.max(0,math.floor((S.avatar_selected-1)/8)-4)*120
    clip(560,195,1168,714)
    for i=1,count do local row=math.floor((i-1)/8);local x=570+((i-1)%8)*144;local y=206+row*120-scroll
        if y+size>=195 and y<=909 then
            local icon=color and S.avatar_icon or i-1;local rgb=profile_colors[(color and i or S.avatar_color+1)]
            box(x,y,size,size,rgb);image("profiles",x,y,size,size,{(icon%8)/8,math.floor(icon/8)/19,1/8,1/19})
            if i==S.avatar_selected then focus(x,y,size,size,false) end
        end
    end
    unclip();local icon=color and S.avatar_icon or S.avatar_selected-1;local rgb=profile_colors[(color and S.avatar_selected or S.avatar_color+1)]
    box(174,309,300,300,rgb);image("profiles",174,309,300,300,{(icon%8)/8,math.floor(icon/8)/19,1/8,1/19});text(p.name,324,669,30,C.text,"center",348)
    if S.state_save_error then text_block(S.state_save_error,174,744,22,C.warn,324,32,5) end
    footer({{"circle","Back"},{"cross","OK"}})
end
local game_buttons={"A","B","X","Y","L","R","ZL","ZR","+","−","Left stick","Right stick"}
local pad_buttons={"Cross","Circle","Square","Triangle","L1","R1","L2","R2","L3","R3","Options","Create","Touchpad"}
local function render_mapping()
    frame("Change Button Mapping");local mapping=S.mapping_game and S.game_settings.mapping or S.prefs.mapping
    image("controller",156,324,360,250,nil,C.title);text_block(S.mapping_game and S.game.name or "Controller Settings",156,677,30,C.text,438,42,3)
    local rows={};for i,label in ipairs(game_buttons) do rows[i]={label=label,value=pad_buttons[mapping[i]+1] or "-",kind="button"} end
    S.rows=rows;rows_draw(rows,714,228,1086,S.row,6)
    if S.save~="" then text_block(S.save,750,857,24,C.copy,1008,33,2) end
    footer({{"square","Reset"},{"leftright","Change"},{"circle","Back"},{"cross","OK"}})
end

local function modal_rows()
    local kind=S.modal;local data=S.modal_data or {}
    if kind=="game" then
        local rows={};for i,label in ipairs(game_categories) do rows[i]=button(label,"game_category");rows[i].category=label end
        rows[1]={label="Console mode",kind="button",action="docked",value=S.game_settings.docked and "Docked" or "Handheld"}
        local fields={Video={"renderer","resolution","filter","astc","post_processing","refresh","hud","hud_size","hud_corner","frame_gen","frame_gen_target","frame_gen_multiplier"},
            Audio={"volume","mute"},Controls={"controller","vibration"},System={"rng_seed"}}
        for _,row in ipairs(rows) do local count=0;local category=row.category
            if category=="Performance" then
                for _,value in ipairs(S.game_settings.performance or {}) do if value>=0 then count=count+1 end end
            elseif fields[category] then
                for _,name in ipairs(fields[category]) do local value=S.game_settings[name];if type(value)=="number" and value>=0 then count=count+1 end end
                if category=="Controls" and S.game_settings.own_mapping then count=count+1 end
            end
            if fields[category] or category=="Performance" then row.value=count==0 and "Follows Settings" or (count.." changed") end
        end
        local mods=Q("mods",{game=S.game.handle});local enabled=0;for _,mod in ipairs(mods.mods) do if mod.enabled then enabled=enabled+1 end end
        for i=#rows,1,-1 do
            if rows[i].category=="Mods" then rows[i].value=#mods.mods==0 and "No mods" or not mods.enabled and "Off" or (enabled.." of "..#mods.mods.." on")
            elseif rows[i].category=="Save data" and not Q("setup").save_transfer then table.remove(rows,i)
            elseif rows[i].category=="Delete from console" and #(S.game.sources or {})==0 then table.remove(rows,i) end
        end
        return rows
    elseif kind=="game_options" then return settings_rows(data.category,true)
    elseif kind=="menu_bindings" then
        local rows={};local labels={"Select / confirm","Back","Secondary action","Game options"}
        for i,label in ipairs(labels) do rows[i]={label=label,kind="button",action="menu_binding",menu_action=i,value=face_labels[((S.prefs.menu_bind or {})[i] or i-1)+1]} end
        rows[#rows+1]=button("Reset menu buttons","menu_reset");return rows
    elseif kind=="overlay" then
        local rows={toggle("hud_colors","Enable colors"),choice("hud_size","Size",{"Regular","Medium","Large"}),choice("hud_corner","Corner",{"Top left","Top right","Bottom left","Bottom right"})}
        local labels={"Backend","FPS","Frame time","Speed","CPU","GPU","Memory","Ping","CPU by core","Render resolution"}
        for i,label in ipairs(labels) do local on=(S.prefs.hud_fields&(1<<(i-1)))~=0;if i==9 then on=not on end;rows[#rows+1]={label=label,kind="button",action="hud_bit",bit=i-1,value=on and "On" or "Off"} end
        return rows
    elseif kind=="choice" then local rows={};for i,label in ipairs(data.values or {}) do rows[i]=button(label,"choose_value");rows[i].value_index=i end;return rows
    elseif kind=="sort" then return {button("By Title","sort_title"),button("By File Name","sort_file")}
    elseif kind=="theme" then return {button("Basic Black","theme_black"),button("Basic White","theme_white")}
    elseif kind=="launchers" then local rows={};for _,p in ipairs(Q("launchers").installed) do rows[#rows+1]=button(p.name,"select_launcher");rows[#rows].id=p.id end;return rows
    elseif kind=="mods" then local model=Q("mods",{game=S.game.handle});local rows={}
        for _,m in ipairs(model.mods) do rows[#rows+1]={label=m.name,detail=m.kind,kind="button",action="mod_toggle",name=m.name,value=m.enabled and "On" or "Off",enabled=m.enabled,live=model.enabled}
            for _,c in ipairs(m.cheats or {}) do rows[#rows+1]={label=c.name,kind="button",action="cheat_toggle",name=c.name,mod=m.name,value=c.enabled and "On" or "Off",enabled=c.enabled,live=model.enabled and m.enabled} end
        end
        return rows
    elseif kind=="saves" then return {button("Import save data","save_import"),button("Export save data","save_export")}
    elseif kind=="confirm" then return {button("Cancel","cancel"),button("Continue","confirm")}
    elseif kind=="queue" then local rows={};for _,d in ipairs(Q("downloads")) do rows[#rows+1]={label=d.name,kind="button",action="cancel_download",key=d.key,value=d.total>0 and (math.floor(d.done/d.total*100).."%") or "Queued"} end;return rows
    elseif kind=="download_source" then local rows={};for i,name in ipairs(data.game.sources or {}) do rows[#rows+1]=button(name,"download_choose");rows[#rows].index=i end;return rows
    elseif kind=="download" then return {button("Keep downloading in the background","download_background"),button("Cancel download","download_stop")}
    elseif kind=="pair_servers" then local rows={};for i,p in ipairs(Q("pair_servers")) do rows[#rows+1]=button(p.name,"pair_server");rows[#rows].index=i end;return rows
    elseif kind=="sync_profile" then return {button("Pair with server","pair_servers"),button("Unlink server","unlink")}
    elseif kind=="sync_launch" then local status=(S.status.launch or {}).sync or {};if status.stage==2 then return {button("Keep console save","sync_console"),button("Use server save","sync_server"),button("Change nothing","launch_cancel")} end
        if status.stage==4 then return {button("Try again","sync_retry"),button("Play without sync","sync_anyway"),button("Back","launch_cancel")} end;return {button("Cancel","launch_cancel")}
    elseif kind=="sync_after" then return {button("Keep console save","sync_console"),button("Use server save","sync_server"),button("Change nothing","sync_neither")}
    elseif kind=="update" then local status=S.status.update_status or {};if status.phase==4 then return {button("Update now","update_apply"),button("Cancel","update_cancel")} end
        if status.phase==0 or status.phase==6 or status.phase==7 then
            local offer=S.status.update or {};local rows={}
            if offer.version and offer.installable then rows[#rows+1]=button("Download update","update_start") end
            if offer.version then rows[#rows+1]=button("What's new","release_notes") end
            rows[#rows+1]=button("Back","update_back");return rows
        end;return {button("Cancel download","update_cancel")}
    elseif kind=="room" then
        local room=S.status.room or {};if room.phase==2 then return {button("Disconnect","room_leave")} end
        if data.page=="private" then return {button("Address","room_host"),button("Port","room_port"),button("Nickname","room_nickname"),button("Password","room_password"),button("Connect","room_join")}
        elseif data.page=="public" then local rows={{label="Nickname",value=S.room_form.nickname or "Player",kind="button",action="room_nickname"}};local public=Q("public_rooms");for i,r in ipairs(public.rooms) do rows[#rows+1]={label=r.name,kind="button",action="room_public",index=i,value=r.players.." / "..r.capacity,room=r} end;return rows end
        return {button("Public rooms","room_public_page"),button("Private room","room_private_page")}
    end
    return {}
end
local app_update_labels={
    [0]="A ProsperoEden update is available.",[1]="Starting download...",
    [2]="Downloading update...",[3]="Preparing update files...",
    [4]="Ready to install.",[5]="Installing ProsperoEden...",
    [6]="Update cancelled.",[7]="Could not update ProsperoEden."
}
local function render_app_update()
    local status=S.status.update_status or {};local offer=S.status.update or {}
    local phase=status.phase or 0
    local rows=modal_rows();S.rows=rows
    S.modal_row=clamp(S.modal_row,1,math.max(1,#rows))
    text("Current version: "..(S.status.version or "v1.004.000"),382,332,24,C.copy,"left",1156)
    if offer.version then text("Available version: "..offer.version,382,380,24,C.copy,"left",1156) end
    local label=app_update_labels[phase] or "Updating ProsperoEden..."
    if phase==0 and not offer.version then label="No ProsperoEden update is currently offered." end
    text(label,382,450,30,phase==7 and C.warn or C.accent,"left",1156)
    local detail=S.message~="" and S.message or status.error or ""
    if detail=="" then
        if phase==2 then
            detail=(status.total or 0)>0 and (math.floor(clamp((status.done or 0)/status.total,0,1)*100).."% downloaded") or "Downloading..."
        elseif phase==3 or phase==5 then detail="Keep the app open until the update finishes."
        elseif phase==4 then detail="Choose Update now to install the downloaded application."
        elseif phase==0 and offer.version then detail="This updates the ProsperoEden application. Switch UI is updated separately in About." end
    end
    text_block(detail,382,494,24,phase==7 and C.warn or C.copy,1156,32,3)
    if phase>=1 and phase<=5 then
        update_progress(382,600,1156,status,phase<4 and (status.total or 0)<=0,phase>=4)
    end
    local top=828-#rows*80
    for i,row in ipairs(rows) do
        local y=top+(i-1)*80
        plate(382,y,1156,78,i==S.modal_row)
        text(row.label,418,y+48,30,C.text,"left",1084)
    end
end
local modal_titles={menu_bindings="Menu buttons",game="Game settings",game_options="Game settings",overlay="Overlay options",choice="Choose an option",sort="Sort Software",theme="Basic Theme",launchers="Choose a Launcher",mods="Mods",saves="Save Data",confirm="Are you sure?",queue="Downloads",download_source="Download from",download="Download and play",pair_servers="Choose a Server",sync_profile="Save Sync",sync_launch="Save Sync",sync_after="Save Sync",update="ProsperoEden Update",release_notes="What's New",system_info="System Information",pairing="Pairing"}
local function modal_panel(x,y,w,h,title)
    shadow(x,y+1.5,w,h,0,6,.6);box(x,y,w,h,C.base);text(title,x+42,y+86,48,C.title,"left",w-84)
end
local function render_sources()
    box(0,0,1920,1080,0,.68);modal_panel(550,180,820,720,"Downloads")
    local model=Q("sources");local downloads=Q("downloads");local rows={}
    for _,source in ipairs(model.list or {}) do rows[#rows+1]={label=source.name,detail=source.error~="" and source.error or source.address,value=source.online and (source.games.." games") or "Not connected yet",action="refresh_sources"} end
    for _,d in ipairs(downloads) do rows[#rows+1]={label=d.name,detail=d.error or d.source,value=d.total>0 and (math.floor(d.done/d.total*100).."%") or "Queued",action="cancel_download",key=d.key} end
    S.source_rows=rows;local top=math.max(0,S.row-5)
    clip(586,328,748,492)
    for i=top+1,math.min(#rows,top+5) do local y=334+(i-top-1)*96;local row=rows[i];plate(592,y,736,94,i==S.row)
        text(row.label,628,y+41.4,24,C.text,"left",400);text(row.value,1292,y+40,20,C.accent,"right",250)
        text(row.detail or "",628,y+73,20,C.meta,"left",664)
    end
    unclip()
    if #rows==0 then text_block("No download sources are configured. Add your server to sources.json in the data folder, then read the lists again.",592,360,24,C.copy,736,36,5)
    elseif #downloads==0 then text_block("No downloads. In the Library, Square puts a game from a source in the queue.",592,350+#rows*96,20,C.meta,736,30,2) end
    hints({{"cross","Read the lists again"},{"circle","Back"}},1328,848,24)
end
local function render_sync_setup()
    box(0,0,1920,1080,0,.68);modal_panel(430,180,1060,720,"Save Sync")
    text_block("Each profile's save data on a server of its own, synced before and after a game.",472,310,24,C.copy,976,36,2)
    local rows=settings_rows("Save sync");S.sync_rows=rows;rows_draw(rows,472,382,976,S.row,4)
    if S.message~="" then text_block(S.message,508,820,22,C.warn,904,30,2) end
    hints({{"cross","Select"},{"circle","Back"}},1448,854,24)
end
local function render_room()
    local data=S.modal_data;local room=S.status.room or {phase=0};local page=data.page or "choice"
    local left,right,width=548,1372,824
    local notice=S.message~="" and S.message or (room.error or "")
    local public=page=="public" and Q("public_rooms") or nil
    if notice=="" and public then notice=public.error or "" end
    local connected=room.phase==2
    shadow(500,151.5,920,780,0,6,.6);box(500,150,920,780,C.base)
    text(connected and "Multiplayer" or page=="choice" and "Multiplayer" or page=="public" and "Public rooms" or "Private room",left,238,40,C.title,"left",width)
    text(({"Offline","Connecting...","Connected","Leaving...","Connection failed"})[(room.phase or 0)+1],left,284,24,connected and C.accent or C.copy,"left",width)
    if public and not connected then text(public.refreshing and "Refreshing..." or (#public.rooms.." public rooms"),right,284,24,C.copy,"right",width*.5) end
    line(left,316,right,316,C.line)
    local rows=modal_rows();S.rows=rows;S.modal_row=clamp(S.modal_row,1,math.max(1,#rows))
    if connected then
        text(room.name,left,378,30,C.title,"left",width)
        text("Players",left,422,22,C.meta,"left",width)
        for i,name in ipairs(room.members or {}) do
            if i<=(notice~="" and 6 or 8) then text(name,left+36,462+(i-1)*32,26,C.copy,"left",width-72) end
        end
        local top=notice~="" and 686 or 734
        plate(left,top,width,72,S.modal_row==1);text("Disconnect",left+36,top+45.5,28,C.text,"left",width-72)
        hints({{"cross","Disconnect"},{"circle","Back"}},right,878,24)
    elseif page=="choice" then
        for i,row in ipairs(rows) do
            local y=344+(i-1)*128;plate(left,y,width,112,S.modal_row==i)
            text(row.label,left+36,y+41,28,C.text,"left",width-72)
            text(i==1 and "Browse the public directory and choose a room." or "Connect using an address, port and password.",left+36,y+81,24,C.copy,"left",width-72)
        end
        text_block("Join a room before launching a game, then choose Local Wireless in the game.",left+36,664,24,C.copy,width-72,36,2)
        hints({{"cross","Select"},{"square","Go offline"},{"circle","Back"}},right,878,24)
    elseif page=="private" then
        local form=S.room_form;local values={form.host,tostring(form.port or 24872),form.nickname,(form.password or "")~="" and "••••••" or "",""}
        for i,row in ipairs(rows) do row.value=values[i] end
        rows_draw(rows,left,338,width,S.modal_row,5,false,84)
        hints({{"cross","Select"},{"square","Go offline"},{"circle","Back"}},right,878,24)
    else
        -- Keep the nickname separate from the scrolling, two-line room entries.
        plate(left,338,width,72,S.modal_row==1)
        text(rows[1].label,left+36,383.5,28,C.text,"left",250)
        text(rows[1].value,right-36,383.5,28,C.copy,"right",width-358)
        local visible=notice~="" and 4 or 5;local count=#rows-1
        local top=clamp(S.modal_row-1-visible,0,math.max(0,count-visible))
        for i=top+2,math.min(#rows,top+visible+1) do
            local row=rows[i];local y=426+(i-top-2)*76
            plate(left,y,width,74,i==S.modal_row)
            text(row.label,left+36,y+31,26,C.text,"left",width-252)
            text(row.value,right-36,y+31,24,C.copy,"right",156)
            local detail=row.room.game..(row.room.password and " | Password" or "")..(row.room.compatible and "" or " | Incompatible")
            text(detail,left+36,y+62,22,C.copy,"left",width-72)
        end
        if count==0 then text(public.refreshing and "Loading public rooms..." or "No public rooms found.",left+36,476,24,C.copy,"left",width-72) end
        if count>visible then
            local height=visible*76;local handle=math.max(28,height*visible/count)
            box(right+14,426,6,height,C.line,.35,3)
            box(right+14,426+top/(count-visible)*(height-handle),6,handle,C.meta,.8,3)
        end
        hints({{"cross","Select"},{"triangle","Refresh"},{"circle","Back"}},right,878,24)
    end
    if notice~="" then text_block(notice,left+36,786,22,C.warn,width-72,28,2) end
    line(left,826,right,826,C.line)
end

local function render_modal()
    if S.modal=="game" then
        box(0,0,1920,1080,C.base);frame("Options");cover(S.game,156,228,312,312)
        text_block(S.game.name,156,596.5,30,C.text,360,42,3);text((S.game.format or "").." · "..(S.game.size or ""),156,750,24,C.meta)
        text_block(S.game.addons or "",156,798,22,C.meta,360,32,3)
        local rows=modal_rows();S.rows=rows;local layout=settings_layout(rows,228)
        local top=math.max(0,S.modal_row-layout.visible);local height=layout.visible*layout.pitch
        clip(586,222,1228,height+12)
        for i=top+1,math.min(#rows,top+layout.visible) do local y=228+(i-top-1)*layout.pitch;plate(600,y,1182,layout.pitch-2,i==S.modal_row)
            text(value_of(rows[i]),1746,y+layout.pitch*.5+7.4,24,i==1 and C.accent or C.meta,"right",400)
            text(rows[i].label,636,y+layout.pitch*.5+8.8,28,C.text,"left",690)
        end
        unclip();if #rows>layout.visible then local h=height*layout.visible/#rows;box(1810,228,9,height,C.line,.35,4.5);box(1810,228+top/math.max(1,#rows-layout.visible)*(height-h),9,h,C.meta,.8,4.5) end
        if S.message~="" or S.save~="" then text_block(S.message~="" and S.message or S.save,636,layout.save_y,24,S.message~="" and C.warn or C.copy,1110,32,2) end
        footer({{"circle","Back"},{"cross","Select"}});return
    end
    if S.modal=="game_options" then
        box(0,0,1920,1080,C.base);text(S.game.name,156,112,40,C.title,"left",1644);line(96,157,1824,157,C.line)
        cover(S.game,156,228,312,312);text(S.game.name,312,596,27,C.copy,"center",438)
        text(S.modal_data.category,750,256,30,C.text)
        local rows=modal_rows();S.rows=rows
        local note=S.modal_data.category=="System" and "A fixed RNG seed loads this software at the same address on each launch. Choose Random to use a new address." or "Settings for this software apply on the next launch."
        settings_content(rows,300,S.modal_row,true,note)
        footer({{"leftright","Change"},{"circle","Back"},{"cross","OK"}});return
    end
    if S.modal=="overlay" or S.modal=="menu_bindings" then
        box(0,0,1920,1080,C.base);frame(S.modal=="menu_bindings" and "Menu buttons" or "Overlay options")
        local rows=modal_rows();S.rows=rows
        settings_content(rows,228,S.modal_row,false,nil,156,1608)
        footer({{"circle","Back"},{"cross","OK"}});return
    end
    if S.modal=="choice" then
        box(0,0,1920,1080,0,.68);shadow(390,136.5,1140,810,0,6,.6);box(390,135,1140,810,C.base)
        local data=S.modal_data;local title=data.menu_action and "Choose a menu button" or data.setting and data.setting.label or data.mapping and game_buttons[data.mapping] or data.vibration and "Vibration strength" or "Choose an option"
        text(title,450,212,36,C.title);local rows=modal_rows();S.rows=rows;local top=math.max(0,S.modal_row-6)
        clip(420,255,1080,550)
        for i=top+1,math.min(#rows,top+6) do local y=264+(i-top-1)*90;plate(450,y,1020,88,i==S.modal_row);text(rows[i].label,486,y+54.5,30,C.text,"left",900)
            if i==S.choice_original then line(1386,y+42,1398,y+54,C.accent,4);line(1398,y+54,1422,y+28,C.accent,4) end
        end
        unclip()
        if #rows>6 then local h=538*6/#rows;box(1484,264,9,538,C.line,.35,4.5);box(1484,264+top/math.max(1,#rows-6)*(538-h),9,h,C.meta,.8,4.5) end
        hints({{"circle","Back"},{"cross","OK"}},1470,897,30);return
    end
    if S.modal=="mods" then
        box(0,0,1920,1080,0,.68);modal_panel(340,180,1240,720,"Mods");text(S.game.name,382,314,20,C.meta,"left",1156)
        local rows=modal_rows();S.rows=rows;local top=math.max(0,S.modal_row-5);clip(358,328,1204,492)
        for i=top+1,math.min(#rows,top+5) do local row=rows[i];local y=334+(i-top-1)*96;plate(382,y,1156,94,i==S.modal_row)
            if row.action=="cheat_toggle" then text(row.label,458,y+55.4,24,row.live and C.text or C.meta,"left",520)
            else text(row.label,418,y+41.4,24,row.live and C.text or C.meta,"left",560);text(row.detail or "",418,y+73,20,C.meta,"left",560) end
            opacity(row.live and 1 or .4);text(row.value,1502,y+56.8,28,row.enabled and C.accent or C.meta,"right");popopacity()
        end
        unclip()
        if #rows==0 then text_block("No mods for this game yet. Copy each mod's folder next to roms/ in the game's mods directory.",382,392.4,24,C.copy,1156,40,5) end
        if S.message~="" then text_block(S.message,418,842,20,C.copy,1084,26,2) end
        hints(#rows==0 and {{"square","Create the folder"},{"circle","Back"}} or {{"updown","Select"},{"cross","Turn on or off"},{"circle","Back"}},1538,848,30);return
    end
    box(0,0,1920,1080,0,.68)
    local alpha=S.prefs.reduce_motion and 1 or curve("screen_in",S.modal_time*60)/255
    opacity(alpha);local scale=S.prefs.reduce_motion and 1 or curve("modal_scale",S.modal_time*60);transform(scale,960,540)
    if S.modal=="room" then render_room()
    else
        local title=modal_titles[S.modal] or "Settings";if S.modal=="game_options" then title=S.modal_data.category end
        modal_panel(340,180,1240,720,title)
        if S.game and (S.modal=="game" or S.modal=="game_options" or S.modal=="mods" or S.modal=="saves") then text(S.game.name,382,314,24,C.meta,"left",1156) end
        if S.modal=="update" then render_app_update()
        elseif S.modal=="release_notes" or S.modal=="system_info" or S.modal=="pairing" then
            local value=S.modal=="release_notes" and ((S.status.update or {}).notes or "No release notes are available.") or S.modal=="system_info" and Q("setup").details or ""
            if S.modal=="pairing" then local p=Q("pairing");if (p.address or "")~="" then D("qr",{text=p.address,x=1080,y=354,w=380,h=380,color=0,background=0xffffff}) end;value=(p.code or "").."\n"..(p.address or "").."\n"..(p.error or "");if p.stage==3 then value="Paired as "..p.user end end
            local i=0;for part in tostring(value):gmatch("[^\n]+") do if i<12 then text(part,382,350+i*38,26,C.copy,"left",1156);i=i+1 end end
        else
            local rows=modal_rows();S.rows=rows;rows_draw(rows,382,334,1156,S.modal_row,5,S.modal=="game_options")
            if #rows==0 then text("Nothing to show yet.",960,510,30,C.meta,"center") end
            if S.modal=="sync_launch" then local u=(S.status.launch or {}).sync or {};text(u.error or "Synchronizing save data...",382,802,24,C.copy,"left",1156) end
            if S.modal=="download" then local d=S.download_status or {};text(d.error or (d.total and d.total>0 and (math.floor(d.done/d.total*100).."% downloaded") or "Waiting for the download..."),382,802,24,C.copy,"left",1156) end
        end
        hints({{"updown","Select"},{"circle","Back"},{"cross","OK"}},1538,848,24)
        if S.message~="" and S.modal~="update" then text(S.message,382,806,24,C.warn,"left",1156) end
    end
    untransform();popopacity()
end
local function request_game_settings()
    local g=current_game();if not g then return end
    if g.remote then S.message="Download the game to change its settings.";return end
    if g.title_id=="0000000000000000" then S.message="This game has no title ID; its settings cannot be saved.";return end
    S.game=g;S.game_settings=Q("game_settings",{game=g.handle});show_modal("game")
end
local function download_game(g,source,play)
    local result=A("download.start",{game=g.handle,source=source or 0,first=play})
    if result.ok then
        if play then S.download={key=g.key,file=g.file,name=g.name};S.download_seen=true;S.download_rescan=false;S.download_wait=0;show_modal("download")
        else S.message="Download queued.";sound("select") end
    end
end
local function request_launch(selected)
    local g=selected or current_game();if not g then return end
    if not S.home.setup_ready then S.message=S.home.status;sound("error");return end
    if g.remote then
        if #g.sources>1 then show_modal("download_source",{game=g,play=true}) else download_game(g,0,true) end;return
    end
    local result=A("launch.request",{game=g.handle})
    if result.ok then S.game=g;S.status=Q("status");S.launch_time=nil;S.launch_committed=false
        if S.status.launch.stage=="syncing" then show_modal("sync_launch") else S.launch_time=0;sound(S.screen=="library" and "library_launch" or "launch");if S.screen=="home" then sound("launch_effect") end end
    else sound("error") end
end
local function run_button(row,per_game)
    local action=row.action
    if action=="mapping" then S.mapping_game=per_game;S.mapping_return=S.screen;S.mapping_modal=S.modal;S.modal=nil;S.screen="mapping";S.row=1;sound(not per_game and S.mapping_return=="controllers" and "controllers_open" or "open")
    elseif action=="overlay" then show_modal("overlay")
    elseif action=="hud_bit" then local r=A("preferences.set",{hud_fields=S.prefs.hud_fields~(1<<row.bit)});S.prefs=Q("preferences");local on=(S.prefs.hud_fields&(1<<row.bit))~=0;if row.bit==8 then on=not on end;sound(r.ok and (on and "toggle" or "toggle_off") or "error")
    elseif action=="docked" then local r=A("game.docked",{game=S.game.handle,value=not S.game_settings.docked});S.game_settings=Q("game_settings",{game=S.game.handle});if r.ok then S.save="Saved for this game. Applies on next launch." end;sound("toggle")
    elseif action=="game_category" then local name=row.category;if name=="Mods" then show_modal("mods") elseif name=="Save data" then show_modal("saves") elseif name=="Delete from console" then show_modal("confirm",{action="delete_game",title=S.game.name}) else show_modal("game_options",{category=name}) end
    elseif action=="rng_seed" then local r=A("keyboard.seed",{game=S.game.handle,current=S.game_settings.rng_seed});if r.ok then S.keyboard_target={kind="seed"} end
    elseif action=="theme" then show_modal("theme")
    elseif action=="launcher" then show_modal("launchers")
    elseif action=="select_launcher" then A("launcher.select",{id=row.id})
    elseif action=="theme_black" or action=="theme_white" then S.state.white=action=="theme_white";save_state();refresh_models();if S.modal then close_modal(false) end;sound("toggle")
    elseif action=="sort_title" or action=="sort_file" then S.sort=action=="sort_file" and "file" or "title";table.sort(S.games,function(a,b)return (S.sort=="file" and a.file or a.name)<(S.sort=="file" and b.file or b.name) end);S.library=1;S.scroll=0;S.scroll_target=0;close_modal("select")
    elseif action=="profile" then S.profile=row.profile;S.profile_return=S.screen=="settings" and "settings" or "home";open("profile");S.row=1
    elseif action=="choose_profile" then local r=A("profile.choose",{handle=S.profiles[row.profile].handle});if r.ok then refresh_models() end
    elseif action=="add_profile" then local r=A("profile.add");refresh_models();sound(r.ok and "toggle" or "error")
    elseif action=="rename_profile" then
        local p=S.profiles[S.profile];local saved=avatar_settings(p);local old_name=p.name
        local r=A("profile.rename",{index=S.profile-1,step=1});refresh_models()
        if r.ok and S.profiles[S.profile] then local next_profile=S.profiles[S.profile];store_avatar(next_profile,saved.icon,saved.color);if old_name~=next_profile.name then S.state.avatar_aliases[old_name]=nil;S.state.avatars[old_name]=nil end;save_state() end
        sound(r.ok and "account_select" or "error")
    elseif action=="remove_profile" then show_modal("confirm",{action="remove_profile"})
    elseif action=="avatar_icon" or action=="avatar_color" then
        local p=S.profiles[S.profile];local current=avatar_settings(p)
        S.avatar_icon=current.icon;S.avatar_color=current.color;S.avatar_mode=action=="avatar_icon" and "icon" or "color";S.avatar_selected=(S.avatar_mode=="icon" and current.icon or current.color)+1;S.screen="avatar"
    elseif action=="files_select" then local r=A("game_files.set",{path=S.files.path});S.message=r.ok and "Saved. Reopen Switch to use this folder." or S.message;sound(r.ok and "saved" or "error")
    elseif action=="files_parent" then
        local from=S.files.path;local parent=from:match("^(.*)/[^/]+$") or "/";S.files=Q("game_files",{path=parent=="" and "/" or parent});S.row=1
        local left=from:match("([^/]+)$");for i,name in ipairs(S.files.folders or {}) do if name==left then S.row=i+(S.files.path~="/" and 1 or 0) end end
        sound("select")
    elseif action=="files_child" then
        local next_folder=Q("game_files",{path=(S.files.path=="/" and "" or S.files.path).."/"..row.folder})
        if next_folder.ok then S.files=next_folder;S.row=1;S.message="";sound("select") else S.message="This folder cannot be opened.";sound("error") end
    elseif action=="launcher_update" then
        if not LAUNCHER_UPDATES then return end
        accept_update_status(Q("launcher_updates"));U.row=1;U.credits=false
        local custom=false
        for _,capability in ipairs(Q("runtime").capabilities or {}) do
            if capability=="updates.launcher-packs.view.v1" then custom=true;break end
        end
        if row.enter and not custom then return end
        S.state.update_return=custom and "home" or "about";save_state()
        local result=A("launcher_updates.open",{view=custom and "launcher" or ""})
        if result.ok then S.modal=nil;S.clear_update_return=true;U.view=custom;U.exit_home=custom
        else S.state.update_return=nil;save_state() end
    elseif action=="menu_binding" then
        show_modal("choice",{values=face_labels,menu_action=row.menu_action})
        S.modal_row=((S.prefs.menu_bind or {})[row.menu_action] or row.menu_action-1)+1;S.choice_original=S.modal_row
    elseif action=="menu_reset" then A("preferences.set",{menu_bind={0,1,2,3}});S.prefs=Q("preferences");sound("saved")
    elseif action=="update_back" then close_modal("back")
    elseif action=="system_info" then show_modal("system_info")
    elseif action=="update" then show_modal("update")
    elseif action=="all_mods" then local m=Q("mods",{game=S.game.handle});local r=A("mods.enabled",{game=S.game.handle,value=not m.enabled});sound(r.ok and "toggle" or "error")
    elseif action=="mod_toggle" then local r=A("mod.enabled",{game=S.game.handle,name=row.name,value=not row.enabled});sound(r.ok and "toggle" or "error")
    elseif action=="cheat_toggle" then local r=A("cheat.enabled",{game=S.game.handle,mod=row.mod,name=row.name,value=not row.enabled});sound(r.ok and "toggle" or "error")
    elseif action=="mods_folder" then A("mods.folder",{game=S.game.handle})
    elseif action=="save_import" then show_modal("confirm",{action="save_import"})
    elseif action=="save_export" then local r=A("save.export",{game=S.game.handle});S.message=r.message or S.message
    elseif action=="refresh_sources" then A("sources.refresh")
    elseif action=="download_source" then close_modal();open("library");A("library.refresh")
    elseif action=="queue" then show_modal("queue")
    elseif action=="cancel_download" then show_modal("confirm",{action="cancel_download",key=row.key})
    elseif action=="download_choose" then local data=S.modal_data;close_modal();download_game(data.game,row.index-1,data.play)
    elseif action=="download_background" then S.download=nil;close_modal()
    elseif action=="download_stop" then if S.download then A("download.cancel",{key=S.download.key}) end;S.download=nil;close_modal()
    elseif action=="sync_profile" then show_modal("sync_profile",{profile=row.profile,linked=row.linked})
    elseif action=="pair_servers" then local profile=S.modal_data.profile;show_modal("pair_servers",{profile=profile})
    elseif action=="pair_server" then A("pair.start",{profile=S.modal_data.profile-1,server=row.index-1});show_modal("pairing")
    elseif action=="pairing" then show_modal("pairing")
    elseif action=="unlink" then A("pair.unlink",{index=S.modal_data.profile-1});close_modal()
    elseif action=="launch_cancel" then A("launch.cancel");S.launch_time=nil;close_modal()
    elseif action=="sync_console" or action=="sync_server" or action=="sync_retry" or action=="sync_anyway" or action=="sync_neither" then
        local choices={sync_console="console",sync_server="server",sync_retry="retry",sync_anyway="play_anyway",sync_neither="neither"};A("sync.answer",{choice=choices[action]})
    elseif action=="update_start" then A("update.start")
    elseif action=="update_cancel" then A("update.cancel");close_modal()
    elseif action=="update_apply" then A("update.apply")
    elseif action=="release_notes" then show_modal("release_notes")
    elseif action=="room_public_page" then S.modal_data.page="public";S.modal_row=1;A("room.refresh");sound("open")
    elseif action=="room_private_page" then S.modal_data.page="private";S.modal_row=1;sound("open")
    elseif action=="room_leave" then A("room.leave")
    elseif action=="room_host" or action=="room_port" or action=="room_nickname" or action=="room_password" then
        local fields={room_host={0,"host"},room_port={1,"port"},room_nickname={2,"nickname"},room_password={3,"password"}};local f=fields[action];A("keyboard.open",{field=f[1],text=tostring(S.room_form[f[2]] or "")});S.keyboard_target={kind="room",field=f[2]}
    elseif action=="room_join" then A("room.join",S.room_form)
    elseif action=="room_public" then
        if not row.room.compatible then S.message="This room uses a different protocol version.";return end
        if row.room.password then A("keyboard.open",{field=3,text=""});S.keyboard_target={kind="public_room",index=row.index}
        else A("room.join_public",{index=row.index-1,nickname=S.room_form.nickname}) end
    elseif action=="choose_value" then
        local data=S.modal_data
        if data.mapping then local mapping={table.unpack(S.mapping_game and S.game_settings.mapping or S.prefs.mapping)};local old=mapping[data.mapping];local value=row.value_index-1
            for i,v in ipairs(mapping) do if i~=data.mapping and v==value then mapping[i]=old end end;mapping[data.mapping]=value
            if S.mapping_game then A("game_settings.set",{game=S.game.handle,patch={mapping=mapping,own_mapping=true}});S.game_settings=Q("game_settings",{game=S.game.handle}) else A("preferences.set",{mapping=mapping});S.prefs=Q("preferences") end
        elseif data.menu_action then
            local binding={table.unpack(S.prefs.menu_bind or {0,1,2,3})};local previous=binding[data.menu_action];local value=row.value_index-1
            for i,pad in ipairs(binding) do if i~=data.menu_action and pad==value then binding[i]=previous end end
            binding[data.menu_action]=value;local result=A("preferences.set",{menu_bind=binding})
            if not result.ok then sound("error");return end
            S.prefs=Q("preferences");show_modal("menu_bindings",nil,false);S.modal_row=data.menu_action;sound("saved");return
        elseif data.vibration then A("preferences.set",{vibration_strength=row.value_index*25});S.prefs=Q("preferences");S.save="Saved. Applies when a game starts."
        elseif data.setting then
            local value=data.per_game and row.value_index-2 or row.value_index-1
            if data.setting.kind=="slider" then value=value<0 and -1 or value*10
            elseif data.setting.kind=="toggle" and not data.per_game then value=value==1 end
            if not set_preference(data.setting,value,data.per_game) then sound("error");return end
        end
        if data.return_category then show_modal("game_options",{category=data.return_category},false);S.modal_row=data.return_row;sound("modal_close") else close_modal() end
        sound("saved")
    elseif action=="confirm" then local data=S.modal_data
        if data.action=="delete_game" then A("game.delete",{game=S.game.handle,confirmed=true})
        elseif data.action=="save_import" then local r=A("save.import",{game=S.game.handle});S.message=r.message or S.message
        elseif data.action=="remove_profile" then A("profile.remove",{index=S.profile-1});refresh_models();S.profile=clamp(S.profile,1,#S.profiles)
        elseif data.action=="cancel_download" then A("download.cancel",{key=data.key}) end;close_modal()
    elseif action=="cancel" then close_modal()
    end
end

local function active_rows()
    if S.modal then return modal_rows() end
    if S.screen=="settings" then return settings_rows(categories[S.category])
    elseif S.screen=="controllers" then return settings_rows("Controls")
    elseif S.screen=="files" then local rows={};if S.files.path~="/" then rows[1]=button("..","files_parent") end;for _,name in ipairs((S.files or {}).folders or {}) do rows[#rows+1]=button(name,"files_child");rows[#rows].folder=name end;return rows
    elseif S.screen=="about" then return {}
    elseif S.screen=="profile" then return {button("Edit icon","avatar_icon"),button("Background color","avatar_color"),button("Change nickname","rename_profile"),button("Delete user","remove_profile")}
    elseif S.screen=="mapping" then local rows={};for _,label in ipairs(game_buttons) do rows[#rows+1]=button(label,"mapping_button") end;return rows end
    return {}
end
local function input(event)
    local key=event.key;S.elapsed=0
    for action,physical in ipairs(S.prefs.menu_bind or {0,1,2,3}) do
        if face_buttons[physical+1]==key then key=face_buttons[action];break end
    end
    if S.screen=="off" then S.screen="home";S.transition=0;sound("resume");return end
    if S.launch_time then return end
    if S.modal then
        local rows=active_rows()
        if key=="circle" then
            if S.modal=="room" and S.modal_data.page and S.modal_data.page~="choice" then A("keyboard.cancel");S.keyboard_target=nil;S.modal_data.page="choice";S.modal_row=1;sound("back")
            elseif S.modal=="choice" and S.modal_data.menu_action then local action=S.modal_data.menu_action;show_modal("menu_bindings",nil,"back");S.modal_row=action
            elseif S.screen=="about" and (S.modal=="update" or S.modal=="system_info" or S.modal=="release_notes") then if S.modal=="release_notes" then show_modal("update",nil,"back") else close_modal("back") end
            elseif S.modal=="choice" and S.modal_data.return_category then local data=S.modal_data;show_modal("game_options",{category=data.return_category},false);S.modal_row=data.return_row;sound("modal_close")
            elseif S.modal=="game_options" or S.modal=="mods" or S.modal=="saves" then show_modal("game",nil,"back")
            elseif S.modal=="sort" or S.modal=="overlay" then close_modal("back")
            elseif S.modal=="sync_launch" then A("launch.cancel");close_modal()
            elseif S.modal=="sync_after" then A("sync.answer",{choice="neither"});close_modal()
            elseif S.modal=="download" then if S.download then A("download.cancel",{key=S.download.key}) end;S.download=nil;close_modal()
            elseif S.modal=="pairing" then A("pair.cancel");close_modal()
            else close_modal() end;return
        elseif key=="square" and S.modal=="room" then A("room.leave");return
        elseif key=="square" and S.modal=="mods" and #rows==0 then A("mods.folder",{game=S.game.handle});return
        elseif key=="triangle" and S.modal=="room" then A("room.refresh");return
        elseif key=="up" or key=="down" then local before=S.modal_row;S.modal_row=clamp(S.modal_row+(key=="down" and 1 or -1),1,math.max(1,#rows));if S.modal_row~=before then sound((S.modal=="game" or S.modal=="game_options" or S.modal=="mods") and S.screen=="home" and "focus" or "focus_menu") end;return
        elseif key=="l1" or key=="r1" then S.modal_row=clamp(S.modal_row+(key=="r1" and 5 or -5),1,math.max(1,#rows));sound("page");return
        end
        local row=rows[S.modal_row];if not row then return end
        if key=="left" or key=="right" then
            if S.modal=="game_options" then change_row(row,key=="right" and 1 or -1,true)
            elseif S.modal=="overlay" then change_row(row,key=="right" and 1 or -1,false)
            elseif S.modal=="game" and S.modal_row==1 then run_button(row,false) end
        elseif key=="cross" then
            if S.modal=="game_options" and row.action=="mapping" then
                if S.game_settings.own_mapping then run_button(row,true) else change_row(row,1,true) end
            elseif S.modal=="game_options" and row.kind~="button" then row_choice(row,true)
            elseif S.modal=="overlay" and row.kind=="choice" then row_choice(row,false)
            elseif S.modal=="game_options" or S.modal=="overlay" then if not change_row(row,1,S.modal=="game_options") then run_button(row,S.modal=="game_options") end
            else run_button(row,false) end
        end
        return
    end
    if S.screen=="home" then
        if key=="triangle" then if S.zone=="games" then request_game_settings() else sound("error") end;return end
        if S.zone=="profiles" then
            if key=="left" or key=="right" then S.profile=clamp(S.profile+(key=="right" and 1 or -1),1,math.max(1,#S.profiles));sound("focus_account")
            elseif key=="down" or key=="circle" then S.zone="games";S.focus=1;sound("focus_navigation")
            elseif key=="cross" then local p=S.profiles[S.profile];if p then
                if p.playing then S.profile_return="home";open("profile");S.row=1
                else local r=A("profile.choose",{handle=p.handle});if r.ok then refresh_models();sound("account_select") end end
            end end;return
        end
        if key=="up" then if S.zone=="shortcuts" then S.zone="games";S.focus=1;sound("focus") elseif #S.profiles>0 then S.zone="profiles";S.profile=1;sound("focus") end
        elseif key=="down" then if S.zone~="shortcuts" then S.zone="shortcuts";S.focus=1;sound("focus") end
        elseif key=="left" or key=="right" then
            local before=S.focus;S.focus=clamp(S.focus+(key=="right" and 1 or -1),1,S.zone=="shortcuts" and 6 or math.max(1,S.home_count or 0))
            if S.focus~=before then sound("focus");if S.zone=="games" then sound("home_scroll") end else sound("scroll_limit") end
        elseif key=="cross" then
            if S.zone=="games" then
                if S.home_library and S.focus==#S.tiles+1 then open("library")
                elseif S.tiles[S.focus] then request_launch() else sound("error") end
            else local screens={"about","files","room","controllers","settings","off"};local target=screens[S.focus]
                if target=="room" then S.room_form=Q("room_form");show_modal("room",{page="choice"});sound("album_open")
                else open(target);if target=="files" then S.files=Q("game_files")
                    elseif target=="about" then run_button({action="launcher_update",enter=true}) end end
            end
        end
        S.strip_target=S.zone=="games" and math.max(0,(S.focus-4)*405) or S.strip_target
        return
    elseif S.screen=="library" then
        if key=="circle" then open("home");return
        elseif key=="options" then show_modal("sort");return
        elseif key=="triangle" then request_game_settings();return
        elseif key=="cross" then request_launch();return
        elseif key=="square" then local g=current_game();if g then if g.remote then A("download.start",{game=g.handle,source=0,first=false})
            elseif g.title_id=="0000000000000000" or g.mods==0 then sound("error")
            else local m=Q("mods",{game=g.handle});local r=A("mods.enabled",{game=g.handle,value=not m.enabled});sound(r.ok and "toggle" or "error") end end;return end
        local delta=key=="left" and -1 or key=="right" and 1 or key=="up" and -6 or key=="down" and 6 or key=="l1" and -18 or key=="r1" and 18 or 0
        local before=S.library;S.library=clamp(S.library+delta,1,math.max(1,#S.games));local row=math.floor((S.library-1)/6)
        if row==0 then S.scroll_target=0
        else local top=278+row*276;local bottom=top+261
            if top-S.scroll_target<278 then S.scroll_target=math.max(0,top-278)
            elseif bottom-S.scroll_target>945 then S.scroll_target=bottom-945 end
        end
        if S.library~=before then sound((key=="l1" or key=="r1") and "page" or "focus") end;return
    elseif S.screen=="avatar" then
        if key=="circle" then
            if S.avatar_mode=="color" then S.avatar_mode="icon";S.avatar_selected=S.avatar_icon+1 else S.screen="profile" end
            sound("back");return
        end
        local columns=8;local count=S.avatar_mode=="color" and 72 or 147
        local delta=key=="left" and -1 or key=="right" and 1 or key=="up" and -columns or key=="down" and columns or key=="l1" and -columns*6 or key=="r1" and columns*6 or 0
        S.avatar_selected=clamp(S.avatar_selected+delta,1,count)
        if key=="cross" then
            local p=S.profiles[S.profile]
            if p then
                local icon=S.avatar_mode=="icon" and S.avatar_selected-1 or S.avatar_icon
                local color=S.avatar_mode=="color" and S.avatar_selected-1 or S.avatar_color
                store_avatar(p,icon,color)
                if save_state() then
                    S.message="";S.avatar_icon=icon;S.avatar_color=color
                    if S.avatar_mode=="icon" then S.avatar_mode="color";S.avatar_selected=color+1;sound("select")
                    else S.screen="profile";sound("saved") end
                else sound("error") end
            end
        else sound("focus") end;return
    elseif S.screen=="profile" then
        local p=S.profiles[S.profile]
        if key=="circle" then sound("modal_close");local target=S.profile_return or "home";S.profile_return=nil;S.screen=target;S.transition=0;sound("back")
        elseif key=="up" or key=="down" or key=="left" or key=="right" then S.profile=clamp(S.profile+((key=="down" or key=="right") and 1 or -1),1,math.min(8,#S.profiles+1));S.message="";sound("focus")
        elseif key=="options" and p then
            local current=avatar_settings(p);S.avatar_icon=current.icon;S.avatar_color=current.color;S.avatar_selected=current.icon+1;S.avatar_mode="icon";S.screen="avatar";sound("open")
        elseif key=="triangle" and p then run_button({action="rename_profile"})
        elseif key=="square" and p then
            if p.playing or #S.profiles<2 then S.message="The profile that is playing stays. Choose another one first.";sound("error") else run_button({action="remove_profile"}) end
        elseif key=="cross" then
            if not p then run_button({action="add_profile"});S.profile=#S.profiles
            elseif not p.playing then local r=A("profile.choose",{handle=p.handle});if r.ok then refresh_models();sound("toggle") else sound("error") end
            else sound("focus") end
        end;return
    elseif S.screen=="sources" or S.screen=="sync_setup" then
        if key=="circle" then S.screen="settings";S.transition=0;sound("modal_close")
        elseif key=="up" or key=="down" then local rows=S.screen=="sources" and S.source_rows or S.sync_rows;S.row=clamp(S.row+(key=="down" and 1 or -1),1,math.max(1,#(rows or {})));sound("focus")
        elseif key=="cross" then local rows=S.screen=="sources" and S.source_rows or S.sync_rows;local row=(rows or {})[S.row];if row then run_button(row) elseif S.screen=="sources" then A("sources.refresh") end end;return
    elseif S.screen=="about" then
        if U.credits then
            if key=="circle" or key=="square" then U.credits=false;sound("back") end
            return
        end
        if key=="circle" then open("home")
        elseif key=="up" or key=="down" then
            local row=key=="down" and 2 or 1;if row~=U.row then U.row=row;sound("focus_menu") end
        elseif key=="cross" or key=="triangle" then run_button({action="launcher_update"})
        elseif key=="square" then U.credits=true;U.credits_started=S.time;sound("modal_open") end;return
    elseif S.screen=="controllers" and key=="options" then show_modal("menu_bindings");return
    elseif S.screen=="files" then
        if key=="circle" then open("home")
        elseif key=="triangle" then run_button({action="files_select"})
        elseif key=="square" then local path=(S.files or {}).default or "/data/prosperoeden";local r=A("game_files.set",{path=path});S.files=Q("game_files",{path=path});S.row=1;S.message=r.ok and "Default folder saved. Reopen Switch to use it." or S.message;sound(r.ok and "saved" or "error")
        elseif key=="l1" or key=="r1" then S.row=clamp(S.row+(key=="r1" and 6 or -6),1,math.max(1,#active_rows()));sound("page")
        elseif key=="up" or key=="down" then S.row=clamp(S.row+(key=="down" and 1 or -1),1,math.max(1,#active_rows()));sound("focus")
        elseif key=="cross" then local row=active_rows()[S.row];if row then run_button(row) end end
        return
    elseif S.screen=="mapping" and (key=="square" or key=="triangle") then
        local mapping={1,0,3,2,4,5,6,7,10,12,8,9}
        if S.mapping_game then A("game_settings.set",{game=S.game.handle,patch={mapping=mapping,own_mapping=false}});S.game_settings=Q("game_settings",{game=S.game.handle})
        else A("preferences.set",{mapping=mapping});S.prefs=Q("preferences") end
        S.save="Saved. Applies when a game starts.";sound("toggle");return
    elseif S.screen=="mapping" and key=="circle" then
        S.screen=S.mapping_return or "controllers";S.row=3
        if S.mapping_game then show_modal("game_options",{category="Controls"},false);S.modal_row=2 else sound("modal_close") end;sound("back");return
    elseif S.screen=="mapping" and (key=="left" or key=="right") then
        local mapping={table.unpack(S.mapping_game and S.game_settings.mapping or S.prefs.mapping)}
        local old=mapping[S.row];local value=(old+(key=="right" and 1 or -1)+#pad_buttons)%#pad_buttons
        for i,v in ipairs(mapping) do if i~=S.row and v==value then mapping[i]=old end end;mapping[S.row]=value
        if S.mapping_game then A("game_settings.set",{game=S.game.handle,patch={mapping=mapping,own_mapping=true}});S.game_settings=Q("game_settings",{game=S.game.handle}) else A("preferences.set",{mapping=mapping});S.prefs=Q("preferences") end
        S.save="Saved. Applies when a game starts.";sound("toggle");return
    elseif S.screen=="settings" then
        if key=="circle" then if S.content then S.content=false;sound("back") else open("home") end;return end
        if not S.content then
            if key=="up" or key=="down" then local before=S.category;S.category=clamp(S.category+(key=="down" and 1 or -1),1,#categories);S.row=1;S.save="";S.message="";if S.category~=before then sound("focus") end
            elseif key=="right" or key=="cross" then S.content=true;S.row=1;sound("focus") end;return
        elseif key=="left" then S.content=false;S.message="";S.save="";sound("back");return end
        local category=categories[S.category]
        if category=="Profiles" or category=="Downloads" or category=="Save sync" then
            if key=="cross" or key=="right" then
                S.settings_return=S.category
                if category=="Profiles" then S.profile_return="settings";for i,p in ipairs(S.profiles) do if p.playing then S.profile=i end end;open("profile")
                else open(category=="Downloads" and "sources" or "sync_setup") end
            end;return
        end
        if key=="up" or key=="down" then S.row=clamp(S.row+(key=="down" and 1 or -1),1,math.max(1,#active_rows()));S.message="";S.save="";sound("focus");return end
        local row=active_rows()[S.row]
        if row and key=="right" and row.kind~="toggle" then if row.kind=="button" then run_button(row) else row_choice(row,false) end;return end
    elseif key=="circle" then open("home");return end
    local rows=active_rows()
    if key=="up" or key=="down" then S.row=clamp(S.row+(key=="down" and 1 or -1),1,math.max(1,#rows));sound("focus_menu");return end
    local row=rows[S.row];if not row then return end
    if key=="left" or key=="right" then change_row(row,key=="right" and 1 or -1,false)
    elseif key=="cross" then
        if S.screen=="mapping" then local value=(S.mapping_game and S.game_settings.mapping or S.prefs.mapping)[S.row];show_modal("choice",{values=pad_buttons,mapping=S.row});S.modal_row=value+1;S.choice_original=S.modal_row
        elseif row.field=="vibration_strength" then show_modal("choice",{values={"25%","50%","75%","100%"},vibration=true});S.modal_row=math.floor(S.prefs.vibration_strength/25);S.choice_original=S.modal_row
        elseif row.kind=="choice" or row.kind=="slider" then row_choice(row,false)
        elseif not change_row(row,1,false) then run_button(row,false) end
    end
end
local function update(event)
    if U.exit_home then U.exit_home=nil;U.view=false;U.credits=false;U.busy=false;open("home",true) end
    if S.pending_about then S.pending_about=nil;run_button({action="launcher_update",enter=true});return end
    if S.clear_update_return then S.clear_update_return=nil;S.state.update_return=nil;save_state() end
    if S.save_recovered_avatars then S.save_recovered_avatars=nil;save_state() end
    if U.diagnostic_pending and not U.view then U.diagnostic_pending=false;U.diagnostic_saved=save_state(true) end
    S.intro=(S.intro or 0)+event.dt
    S.time=event.time;S.elapsed=S.elapsed+event.dt;S.transition=S.transition+event.dt;S.modal_time=S.modal_time+event.dt;S.poll=S.poll+event.dt
    if S.poll>=.25 then S.poll=0;refresh_models()
        if LAUNCHER_UPDATES and not U.view and (S.screen=="about" or S.time>=U.next_poll) then
            U.next_poll=S.time+1;poll_launcher_updates()
            local phase=U.status.phase;U.busy=phase=="checking" or phase=="downloading" or phase=="validating" or phase=="ready" or phase=="installing"
        end
    end
    if S.download then
        local found=nil;for _,d in ipairs(Q("downloads")) do if d.key==S.download.key then found=d;break end end
        S.download_status=found
        if found then S.download_seen=true;S.download_wait=0;if (found.file or "")~="" then S.download.file=found.file end
        elseif S.download_seen then
            S.download_wait=(S.download_wait or 0)+event.dt
            local local_game=nil;for _,g in ipairs(S.games) do if not g.remote and (g.key==S.download.key or g.file==S.download.file) then local_game=g;break end end
            if local_game then S.download=nil;close_modal();request_launch(local_game)
            elseif not S.download_rescan then S.download_rescan=true;A("library.refresh") end
            if S.download and S.download_wait>5 and not S.scanning then S.download=nil;close_modal();S.message="Download ended before the game was available." end
        end
    end
    if S.welcome then S.welcome=false;sound(S.home.launch_failed and "notify" or S.first_start and "welcome" or "resume") end
    if S.prefs.reduce_motion then S.scroll=S.scroll_target;S.strip=S.strip_target;S.transition=100
    else local follow=1-math.exp(-18*event.dt);S.scroll=S.scroll+(S.scroll_target-S.scroll)*follow;S.strip=S.strip+(S.strip_target-S.strip)*follow
        if math.abs(S.scroll-S.scroll_target)<.1 then S.scroll=S.scroll_target end
    end
    local after=S.status.save_sync or {}
    if after.before==false and after.stage==2 and not S.modal and not S.launch_time then show_modal("sync_after") end
    if after.before==false and (after.stage==3 or after.stage==4) and (not S.modal or S.modal=="sync_after") then
        if S.modal=="sync_after" then close_modal() end
        S.message=after.stage==3 and "Save data synchronized." or (after.error or "Save sync failed.");A("sync.finish")
    end
    local offer=S.status.update or {}
    if offer.version and offer.version~=S.offer_seen and not S.modal and not S.launch_time then
        S.offer_seen=offer.version;show_modal("update");sound("notify")
    end
    local status=S.status.launch or {}
    if status.stage=="ready" and not S.launch_time and not S.launch_committed and S.game then S.launch_time=0;S.modal=nil;sound(S.screen=="library" and "library_launch" or "launch");if S.screen=="home" then sound("launch_effect") end end
    if S.launch_time then
        S.launch_time=S.launch_time+event.dt
        if not S.launch_committed and (S.launch_time>=.95 or S.prefs.reduce_motion) then
            S.state.recent=S.state.recent or {};for i=#S.state.recent,1,-1 do if S.state.recent[i]==S.game.file then table.remove(S.state.recent,i) end end
            table.insert(S.state.recent,1,S.game.file);while #S.state.recent>HOME_SLOTS do table.remove(S.state.recent) end;save_state()
            local result=A("launch.commit");if result.ok then S.launch_committed=true else S.launch_time=nil;A("launch.cancel");S.status=Q("status");sound("error") end
        end
    end
    if S.keyboard_target and (S.status.keyboard or {}).ready then
        local answer=S.status.keyboard;local target=S.keyboard_target;S.keyboard_target=nil
        if not answer.cancelled and not answer.error then
            if target.kind=="room" then S.room_form[target.field]=target.field=="port" and tonumber(answer.text) or answer.text
            elseif target.kind=="public_room" then A("room.join_public",{index=target.index-1,password=answer.text,nickname=S.room_form.nickname})
            elseif target.kind=="seed" then A("game_settings.set",{game=S.game.handle,patch={rng_seed=tonumber(answer.text) or -1}});S.game_settings=Q("game_settings",{game=S.game.handle}) end
        elseif answer.error then S.message=answer.error end
    end
end
local renderers={home=render_home,library=render_library,settings=render_settings,controllers=render_controllers,
    files=render_files,about=render_about,profile=render_profile,avatar=render_avatar,mapping=render_mapping,
    sources=render_sources,sync_setup=render_sync_setup}
local function draw()
    box(0,0,1920,1080,C.base)
    if S.screen=="off" then box(0,0,1920,1080,0);return end
    if S.previous=="home" and S.screen=="library" and S.transition<.55 and not S.prefs.reduce_motion then
        -- Finish fading HOME before revealing library content: the two sets of tiles never overlap.
        opacity(1-cubic(S.transition/.45));render_home();popopacity()
    elseif S.previous=="library" and S.screen=="home" and S.transition<.2 and not S.prefs.reduce_motion then
        opacity(1-cubic(S.transition/.2));render_library();popopacity()
    else
        local alpha=S.screen=="library" and 1 or curve("screen_in",S.transition*60)/255
        if S.prefs.reduce_motion or S.transition>1 then alpha=1 end
        opacity(alpha);local renderer=renderers[S.screen];if renderer then renderer() end;popopacity()
    end
    if S.modal then render_modal() end
    if S.launch_time then box(0,0,1920,1080,0,cubic((S.launch_time/.95-.12)/.5)) end
end
local function updater_status(event)
    if event.first then U.row=1;U.credits=false;U.view=true;S.message="" end
    accept_update_status(event.status);U.busy=event.busy;U.can_update=event.can_update
    S.prefs=event.preferences or S.prefs
    S.status.controllers=event.controllers or S.status.controllers
end
local function updater_input(event)
    local key=event.key
    for action,physical in ipairs(S.prefs.menu_bind or {0,1,2,3}) do
        if face_buttons[physical+1]==key then key=face_buttons[action];break end
    end
    if U.credits then
        if key=="circle" or key=="square" then U.credits=false;sound("back") end
        return
    end
    if key=="circle" then local result=A("launcher_updates.close");if result.ok then sound("back") else sound("error") end;return end
    if key=="square" then U.credits=true;U.credits_started=S.time;sound("modal_open");return end
    if key=="up" or key=="down" or key=="left" or key=="right" then
        local row=(key=="down" or key=="right") and 2 or 1
        if row~=U.row then U.row=row;sound("focus_menu") end
    elseif (key=="cross" or key=="triangle") and not U.busy then
        if not U.can_update then sound("error");return end
        local result
        if U.row==1 or key=="triangle" then result=A("launcher_updates.check")
        elseif U.status.phase=="available" then result=A("launcher_updates.download",{confirmed=true,version=(U.status.release or {}).version})
        else sound("error");return end
        if result.ok then U.busy=true;S.message="";sound("select") else sound("error") end
    end
end
local function updater_draw(event)
    S.time=event.time;U.view=true
    -- Fast repeated checks can complete before the host emits a changed status callback.
    if S.time>=(U.next_view_poll or 0) then
        U.next_view_poll=S.time+.25;accept_update_status(Q("launcher_updates"))
        local phase=U.status.phase;U.busy=phase=="checking" or phase=="downloading" or phase=="validating" or phase=="ready" or phase=="installing"
    end
    box(0,0,1920,1080,C.base)
    render_about()
end


return {
    init=function(event)
        S.state=type(event.state)=="table" and event.state or {};S.state.avatars=type(S.state.avatars)=="table" and S.state.avatars or {};S.state.avatar_aliases=type(S.state.avatar_aliases)=="table" and S.state.avatar_aliases or {};S.state.recent=S.state.recent or {};S.state.schema=1
        S.welcome=true;S.first_start=event.first_start;S.intro=0;U.check_pending=true;U.next_poll=0;refresh_models();S.save_recovered_avatars=recover_avatar_aliases()
        if S.state.update_return=="about" then S.screen="about";S.previous="about";S.pending_about=true end
        if S.state.update_return then S.state.update_return=nil;S.clear_update_return=true;S.welcome=false end
    end,
    input=input,update=update,draw=draw,
    updater_status=updater_status,updater_input=updater_input,updater_draw=updater_draw,
    shutdown=function() save_state() end
}
