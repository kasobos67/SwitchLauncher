-- Golden samples generated from the user-supplied SwitchPS5 1.002.001 C++ Spring.
-- Run from the repository root with Lua 5.4: lua tests/scroll_motion.lua
local f=assert(io.open("src/motion.lua","rb"));local text=f:read("*a");f:close()
local motion=assert(load(text.."\nreturn motion","@motion"))()
local samples=assert(io.open("tests/scroll_reference.csv","r"));samples:read("*l")
local value,velocity,count,max_position,max_velocity=0,0,0,0,0
for line in samples:lines() do
    local row={};for field in line:gmatch("[^,]+") do row[#row+1]=assert(tonumber(field)) end
    if row[3]==1 then value,velocity=row[2],0 else value,velocity=motion.scroll(value,velocity,row[2],row[1]) end
    max_position=math.max(max_position,math.abs(value-row[4]));max_velocity=math.max(max_velocity,math.abs(velocity-row[5]));count=count+1
end
samples:close()
assert(count==300,"missing native reference samples")
assert(max_position<.005,"scroll position differs from SwitchPS5")
assert(max_velocity<.03,"scroll velocity differs from SwitchPS5")
-- Irregular frame steps preserve the same physical trajectory as regular frames.
local whole_v,whole_s=motion.scroll(0,0,405,.05)
local split_v,split_s=motion.scroll(0,0,405,.02);split_v,split_s=motion.scroll(split_v,split_s,405,.03)
assert(math.abs(whole_v-split_v)<1e-9 and math.abs(whole_s-split_s)<1e-9)
local settled,speed=motion.scroll(405,0,405,1/60);assert(settled==405 and speed==0)
print(string.format("PASS %d native scroll samples; max position error %.7f px, velocity error %.7f",count,max_position,max_velocity))
