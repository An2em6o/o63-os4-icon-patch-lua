-- Project: s441-os4-patch
-- By: @IKUN_CXKPRO
-- Time: 2026-09-30
-- github: https://github.com/An2em6o/o63-os4-icon-patch-lua
local lvgl=require("lvgl")
local LOG="/data/s441_icon.log"
local uiRoot=SCRIPT_PATH or ""
local BLOB=uiRoot.."working.bin"

local BS_PREF=32768
local BS_LADDER={32768,4096,2048,512}
local PART_SIZE={["/dev/app"]=317252608,["/dev/misc"]=81577984}
local PART_IMG={["/dev/app"]="vela_app.bin",["/dev/misc"]="vela_misc.bin"}
local PART_MNT={["/dev/app"]="/resource/app",["/dev/misc"]="/resource/misc"}
local TMPOUT="/tmp/s441_win.bin"
local TMPIN="/tmp/s441_w.bin"

local function sh(c)
 local a,b,c2=os.execute(c)
 local ok
 if type(a)=="number" then ok=(a==0) else ok=(a==true) end
 return ok,tonumber(c2) or 0
end
local function log(m)local f=io.open(LOG,"ab")if f then f:write(m,"\n")f:close()end end
local function rl()local f=io.open(LOG,"rb")if not f then return""end local d=f:read("*a")f:close()return d or""end
local function clearlog()local f=io.open(LOG,"wb")if f then f:close()end end

local ERRNOS={[1]="EPERM(权限)",[2]="ENOENT(不存在)",[5]="EIO(设备I/O)",[6]="ENXIO(节点未注册)",
 [9]="EBADF(句柄不可写)",[12]="ENOMEM(内存)",[13]="EACCES(拒绝访问)",[16]="EBUSY(被占用)",
 [17]="EEXIST",[19]="ENODEV(无此设备)",[20]="ENOTDIR",[21]="EISDIR",[22]="EINVAL(参数/对齐非法)",
 [25]="ENOTTY(不支持该操作)",[28]="ENOSPC",[29]="ESPIPE(不支持随机寻址)",[30]="EROFS(只读)",
 [38]="ENOSYS(未实现)"}
-- NuttX system/dd: 成功返回 0；失败返回【负 errno】(main 的返回值) -> 退出码被截成 1 字节
local function dexit(ok,code)
 if ok then return "ok" end
 local raw=tonumber(code) or -1
 local e=raw
 if e<0 then e=-e end
 if e>128 and e<=255 then e=256-e end
 return string.format("fail raw=%d -> %s",raw,ERRNOS[e] or ("errno"..tostring(e)))
end

local function hex(b,n)
 if not b then return"(nil)" end
 local t={}
 for i=1,math.min(#b,n or 8)do t[#t+1]=string.format("%02x",b:byte(i))end
 return table.concat(t," ")
end

local function magic_ok(h)
 if not h or #h<2 then return false end
 if h:byte(1)~=0x19 then return false end
 local b2=h:byte(2)
 return b2==0x0a or b2==0x10
end

-- 按需读 blob 区间, 单次只分配 n 字节
local function readblob(off,n)
 local f=io.open(BLOB,"rb")
 if not f then return nil end
 local ok=f:seek("set",off)
 local d=nil
 if ok then d=f:read(n) end
 f:close()
 return d
end

local function win(off,len,bs)
 local start=math.floor(off/bs)*bs
 local inblk=off-start
 local nblk=math.floor((inblk+len-1)/bs)+1
 return start,nblk,inblk
end

local function io_readwin(f,start,want)
 local ok=f:seek("set",start)
 if not ok then return nil,"seek 失败" end
 local d=f:read(want)
 if not d then return nil,"read 返回 nil" end
 if #d~=want then return nil,"短读 "..#d.."/"..want end
 return d
end

local function io_writewin(f,start,buf)
 local ok=f:seek("set",start)
 if not ok then return false,"seek 失败" end
 local w=f:write(buf)
 if not w then
  return false,"write 返回 nil (句柄可能被降级为只读: NuttX CONFIG_BCH_DEVICE_READONLY 会把 O_RDWR 改成 O_RDONLY)"
 end
 local ok2,err2=f:flush()
 if not ok2 then return false,"flush 失败: "..tostring(err2) end
 return true
end


local function dd_read(dev,bs,startblk,nblk,tmp)
 local ok,code=sh(string.format("dd if=%s of=%s bs=%d skip=%d count=%d",dev,tmp,bs,startblk,nblk))
 if not ok then return nil,"dd 读取 "..dexit(ok,code) end
 local f=io.open(tmp,"rb")
 if not f then return nil,"dd 未产出输出文件" end
 local d=f:read("*a")
 f:close()
 return d
end

local function dd_write(dev,bs,start,nblk,tmp)
 local ok,code=sh(string.format("dd if=%s of=%s bs=%d seek=%d count=%d conv=notrunc",
   tmp,dev,bs,math.floor(start/bs),nblk))
 if not ok then return false,"dd 写入 "..dexit(ok,code) end
 return true
end

local function dev_readctx(ctx,dev,off,len,forcefresh)
 local bs=ctx.bs[dev] or BS_PREF
 local start,nblk,inblk=win(off,len,bs)
 local want=nblk*bs
 local why="?"
 if not forcefresh then
  local h=ctx.h[dev]
  if h then
   local d
   d,why=io_readwin(h,start,want)
   if d then return d:sub(inblk+1,inblk+len) end
   log("  [io 读失败] "..dev.." @"..string.format("0x%x",start).." : "..tostring(why))
   pcall(function() h:close() end)
   ctx.h[dev]=nil
  end
 end
 local f=io.open(dev,"rb")
 if f then
  local d
  d,why=io_readwin(f,start,want)
  if d then
   if not forcefresh then ctx.h[dev]=f else f:close() end
   return d:sub(inblk+1,inblk+len)
  end
  f:close()
  log("  [io 读失败·新句柄] "..dev.." : "..tostring(why))
 else
  log("  [io open 失败] "..dev)
 end
 local d,why2=dd_read(dev,bs,math.floor(start/bs),nblk,TMPOUT)
 if not d then return nil,"io 与 dd 均失败: "..tostring(why).." / "..tostring(why2) end
 if #d~=want then return nil,"dd 短读 "..#d.."/"..want end
 ctx.chan[dev]="dd"
 return d:sub(inblk+1,inblk+len)
end

local function dev_write(ctx,dev,off,data)
 local bs=ctx.bs[dev] or BS_PREF
 local start,nblk,inblk=win(off,#data,bs)
 local want=nblk*bs
 local buf,why=dev_readctx(ctx,dev,start,want,true)
 if not buf or #buf~=want then return false,"RMW 读窗失败 "..tostring(buf and #buf or why) end
 local new=buf:sub(1,inblk)..data..buf:sub(inblk+#data+1)
 if #new~=want then return false,"RMW 拼接尺寸异常" end
 local used="io"
 local h,e=io.open(dev,"r+b")
 if not h then
  log("  [r+b 打开失败] "..dev.." : "..tostring(e))
  used="dd"
 else
  local ok,why2=io_writewin(h,start,new)
  h:close()
  if not ok then
   log("  [io 写失败] "..dev.." : "..tostring(why2))
   used="dd"
  end
 end
 if used=="dd" then
  local wf=io.open(TMPIN,"wb")
  if not wf then return false,"tmp 写出失败" end
  wf:write(new) wf:close()
  local ok,why3=dd_write(dev,bs,start,nblk,TMPIN)
  if not ok then return false,why3 end
  ctx.chan[dev]="dd"
 end

 local v,why4=dev_readctx(ctx,dev,off,#data,true)
 if not v then
  v,why4=dev_readctx(ctx,dev,off,#data,true)
 end
 if not v then return false,"回读失败: "..tostring(why4) end
 if v~=data then
  local k=0
  for i=1,math.min(#v,#data)do if v:byte(i)~=data:byte(i)then k=i break end end
  return false,"回读不一致(通道 "..used..") 首个差异 offset="..k
 end
 return true
end

-- 自检
local function probe_dev(dev)
 log(string.format("节点 %s | 固件容量=%s | 镜像=%s | 挂载点=%s",
   dev,tostring(PART_SIZE[dev] or "?"),tostring(PART_IMG[dev] or "?"),tostring(PART_MNT[dev] or "?")))
 local f,e=io.open(dev,"rb")
 if not f then
  log("  只读 open 失败: "..tostring(e))
  return false
 end
 local ok=f:seek("set",0)
 local d=nil
 if ok then d=f:read(16) end
 log("  只读 open OK, 首16字节: "..hex(d,16))
 local se=f:seek("end")
 if se then log("  seek(end) => "..tostring(se)) else log("  seek(end) 不支持(驱动无 seek 方法时会 ENOSYS)") end
 f:close()
 return true
end

local function probe_bs(dev,off)
 for _,bs in ipairs(BS_LADDER)do
  local start,nblk,inblk=win(off,24,bs)
  local want=nblk*bs
  local f=io.open(dev,"rb")
  if not f then
   log(string.format("  bs=%-6d NO  open 失败",bs))
  else
   local d,why=io_readwin(f,start,want)
   f:close()
   if d then
    local h=d:sub(inblk+1,inblk+24)
    if magic_ok(h) then
     log(string.format("  bs=%-6d OK  窗口 %d B 全读回, 目标头 %s (start=0x%x nblk=%d inblk=%d)",
       bs,want,hex(h,4),start,nblk,inblk))
     return bs
    end
    log(string.format("  bs=%-6d NO  窗口读回但目标头非 LVGL 头(%s)",bs,hex(h,8)))
    why="目标头非 LVGL"
   end
   log(string.format("  bs=%-6d NO  %s",bs,tostring(why)))
  end
 end
 return nil
end

local function probe_bs_dd(dev,off)
 for _,bs in ipairs(BS_LADDER)do
  local start,nblk,inblk=win(off,24,bs)
  local want=nblk*bs
  local d,why=dd_read(dev,bs,math.floor(start/bs),nblk,TMPOUT)
  if d and #d==want then
   local h=d:sub(inblk+1,inblk+24)
   if magic_ok(h) then
    log(string.format("  [dd] bs=%-6d OK  窗口 %d B 全读回, 目标头 %s (start=0x%x)",bs,want,hex(h,4),start))
    return bs
   end
   log(string.format("  [dd] bs=%-6d NO  窗口读回但目标头非 LVGL 头(%s)",bs,hex(h,8)))
  else
   log(string.format("  [dd] bs=%-6d NO  %s",bs,tostring(d and ("短读 "..#d.."/"..want) or why)))
  end
 end
 return nil
end

-- 写入的位置、偏移等
local ENTRIES={
 {name="activities",DEV="/dev/app",OFFSET=0x12e7b000,SIZE=21772,OSRC=12180,PSRC=2714448},
 {name="aivs",DEV="/dev/app",OFFSET=0x4ea1e00,SIZE=82956,OSRC=33952,PSRC=2736220},
 {name="alarm",DEV="/dev/app",OFFSET=0x12467400,SIZE=82956,OSRC=116908,PSRC=2819176},
 {name="alipay",DEV="/dev/app",OFFSET=0x1241b600,SIZE=21772,OSRC=199864,PSRC=2902132},
 {name="barometer",DEV="/dev/app",OFFSET=0x118e9a00,SIZE=82956,OSRC=221636,PSRC=2923904},
 {name="breath",DEV="/dev/misc",OFFSET=0x2339a00,SIZE=82956,OSRC=304592,PSRC=3006860},
 {name="calendar",DEV="/dev/app",OFFSET=0x11820e00,SIZE=82956,OSRC=387548,PSRC=3089816},
 {name="chronograph",DEV="/dev/app",OFFSET=0x1161cc00,SIZE=82956,OSRC=470504,PSRC=3172772},
 {name="compass",DEV="/dev/app",OFFSET=0x11474200,SIZE=21772,OSRC=553460,PSRC=3255728},
 {name="course",DEV="/dev/app",OFFSET=0x793fe00,SIZE=82956,OSRC=575232,PSRC=3277500},
 {name="find_phone",DEV="/dev/app",OFFSET=0x112fa000,SIZE=82956,OSRC=658188,PSRC=3360456},
 {name="flashlight",DEV="/dev/app",OFFSET=0x112e5a00,SIZE=82956,OSRC=741144,PSRC=3443412},
 {name="health_today",DEV="/dev/app",OFFSET=0xfdad200,SIZE=82956,OSRC=824100,PSRC=3526368},
 {name="heartrate",DEV="/dev/app",OFFSET=0xfbb7800,SIZE=82956,OSRC=907056,PSRC=3609324},
 {name="innovation_research",DEV="/dev/app",OFFSET=0xf2b8a00,SIZE=82956,OSRC=990012,PSRC=3692280},
 {name="interconnect",DEV="/dev/app",OFFSET=0xf2a1000,SIZE=82956,OSRC=1072968,PSRC=3775236},
 {name="media",DEV="/dev/app",OFFSET=0xf257200,SIZE=82956,OSRC=1155924,PSRC=3858192},
 {name="mijia",DEV="/dev/app",OFFSET=0xf162200,SIZE=82956,OSRC=1238880,PSRC=3941148},
 {name="nfccard",DEV="/dev/app",OFFSET=0xef92800,SIZE=82956,OSRC=1321836,PSRC=4024104},
 {name="oxygen",DEV="/dev/app",OFFSET=0xea9e600,SIZE=82956,OSRC=1404792,PSRC=4107060},
 {name="phone",DEV="/dev/app",OFFSET=0xd303c00,SIZE=82956,OSRC=1487748,PSRC=4190016},
 {name="pressure",DEV="/dev/app",OFFSET=0xd1bf000,SIZE=82956,OSRC=1570704,PSRC=4272972},
 {name="record",DEV="/dev/app",OFFSET=0x7447e00,SIZE=82956,OSRC=1653660,PSRC=4355928},
 {name="recorder",DEV="/dev/app",OFFSET=0xc05b200,SIZE=82956,OSRC=1736616,PSRC=4438884},
 {name="remote_camera",DEV="/dev/app",OFFSET=0xbe4a600,SIZE=21772,OSRC=1819572,PSRC=4521840},
 {name="settings",DEV="/dev/app",OFFSET=0x7afaa00,SIZE=82956,OSRC=1841344,PSRC=4543612},
 {name="sleep",DEV="/dev/app",OFFSET=0x7968e00,SIZE=82956,OSRC=1924300,PSRC=4626568},
 {name="sports",DEV="/dev/app",OFFSET=0x75d8800,SIZE=82956,OSRC=2007256,PSRC=4709524},
 {name="temperature",DEV="/dev/app",OFFSET=0x6069600,SIZE=21772,OSRC=2090212,PSRC=4792480},
 {name="timer",DEV="/dev/app",OFFSET=0x55daa00,SIZE=82956,OSRC=2111984,PSRC=4814252},
 {name="todolist",DEV="/dev/app",OFFSET=0x55afe00,SIZE=82956,OSRC=2194940,PSRC=4897208},
 {name="training",DEV="/dev/app",OFFSET=0x716c600,SIZE=82956,OSRC=2277896,PSRC=4980164},
 {name="vitality",DEV="/dev/app",OFFSET=0x5579600,SIZE=82956,OSRC=2360852,PSRC=5063120},
 {name="weather",DEV="/dev/app",OFFSET=0x21bc800,SIZE=82956,OSRC=2443808,PSRC=5146076},
 {name="womenhealth",DEV="/dev/app",OFFSET=0x47a00,SIZE=82956,OSRC=2526764,PSRC=5229032},
 {name="worldclock",DEV="/dev/app",OFFSET=0x12600,SIZE=82956,OSRC=2609720,PSRC=5311988},
 {name="wxpay",DEV="/dev/app",OFFSET=0xbc00,SIZE=21772,OSRC=2692676,PSRC=5394944},
}

local UI_W,UI_H=464,464
local function uiFileExists(path)
 local f=io.open(path,"rb")
 if f then f:close()return true end
 return false
end

-- 引入字体
local function makeFont(size)
 for _,nm in ipairs({"MiSans-Medium","MiSans-Regular","MiSans-Demibold"})do
  local f=nil
  if pcall(function() f=lvgl.Font(nm,size) end) and f then return f end
 end
 return lvgl.BUILTIN_FONT.MONTSERRAT_14
end
local UI_FONT=makeFont(32)
local uiSuffix={}
local function uiImgPath(name)
 local path=uiRoot..name
 if uiSuffix[name] then return path..uiSuffix[name] end
 if uiFileExists(path..".bin") then uiSuffix[name]=".bin"return path..".bin" end
 if uiFileExists(path..".rle") then uiSuffix[name]=".rle"return path..".rle" end
 return path
end

local rootbase1=lvgl.Object(nil,{
 outline_width=0,border_width=0,pad_all=0,bg_opa=lvgl.OPA(100),
 bg_color=0,align=lvgl.ALIGN.CENTER,w=lvgl.HOR_RES(),h=lvgl.VER_RES()
})
rootbase1:clear_flag(lvgl.FLAG.SCROLLABLE)
rootbase1:add_flag(lvgl.FLAG.EVENT_BUBBLE)
local rootbase=lvgl.Object(rootbase1,{
 outline_width=0,border_width=0,pad_all=0,bg_opa=lvgl.OPA(100),
 bg_color=0,align=lvgl.ALIGN.CENTER,w=UI_W,h=UI_H
})
rootbase:clear_flag(lvgl.FLAG.SCROLLABLE)
rootbase:add_flag(lvgl.FLAG.EVENT_BUBBLE)

local uiPages={}
local function uiPage(name,asset,contentHeight,imgH)
 contentHeight=contentHeight or UI_H
 imgH=imgH or contentHeight
 local page=lvgl.Object(rootbase,{
  outline_width=0,border_width=0,pad_all=0,bg_opa=lvgl.OPA(100),
  bg_color=0,align=lvgl.ALIGN.CENTER,w=UI_W,h=UI_H
 })
 page:clear_flag(lvgl.FLAG.SCROLLABLE)
 page:add_flag(lvgl.FLAG.EVENT_BUBBLE)
 local content=lvgl.Object(page,{x=0,y=0,w=UI_W,h=UI_H,bg_opa=lvgl.OPA(0),border_width=0,pad_all=0})
 content:add_flag(lvgl.FLAG.EVENT_BUBBLE)
 if contentHeight<=UI_H then
  content:clear_flag(lvgl.FLAG.SCROLLABLE)
 else
  content:add_flag(lvgl.FLAG.SCROLLABLE)
  content:set {scroll_dir=lvgl.DIR.VER,scrollbar_mode=lvgl.SCROLLBAR_MODE.OFF}
 end
 local image=content:Image{src=uiImgPath(asset),x=0,y=0,w=UI_W,h=imgH}
 image:clear_flag(lvgl.FLAG.SCROLLABLE)
 image:clear_flag(lvgl.FLAG.CLICKABLE)
 uiPages[name]={page=page,content=content}
 return page,content
end
local function uiShow(target)
 for name,entry in pairs(uiPages)do
  if name==target then entry.page:clear_flag(lvgl.FLAG.HIDDEN)else entry.page:add_flag(lvgl.FLAG.HIDDEN)end
 end
end
local function uiHit(parent,x,y,w,h,callback)
 local obj=lvgl.Object(parent,{
  outline_width=0,border_width=0,pad_all=0,bg_opa=lvgl.OPA(0),
  x=x,y=y,w=w,h=h
 })
 obj:clear_flag(lvgl.FLAG.SCROLLABLE)
 obj:add_flag(lvgl.FLAG.CLICKABLE)
 obj:add_flag(lvgl.FLAG.EVENT_BUBBLE)
 obj:onevent(lvgl.EVENT.SHORT_CLICKED,function()callback()end)
 return obj
end

-- 页面
local mainPage=uiPage("index","index")                          -- 表盘主页 464
local helpPage,helpContent=uiPage("help","help",643)            -- 阅读帮助 643(可滚)
local aboutPage,aboutContent=uiPage("about","about",597)        -- 关于    597(可滚)
local installPage=uiPage("install","install_confirm")           -- 刷入资源包 464
local restorePage=uiPage("restore","restore_confirm")           -- 恢复资源包 464
local successPage,successContent=uiPage("success","install_success",584) -- 安装完成 584(可滚)
local logPage,logContent=uiPage("log","log",776)                -- 日志显示 776(可滚)
local LOG_FONT=makeFont(20)
local logText=logContent:Textarea{x=35,y=217,w=398,h=410,text="",text_color="#eeeeee",text_font=LOG_FONT,bg_color=0,bg_opa=lvgl.OPA(0),border_width=0,pad_all=8}
logText:add_flag(lvgl.FLAG.SCROLLABLE)
logText:add_flag(lvgl.FLAG.CLICKABLE)
logText:set {scroll_dir=lvgl.DIR.VER, scrollbar_mode=lvgl.SCROLLBAR_MODE.OFF}
local function refreshLog()
 logText:set{text=rl()}
end

local failurePage=lvgl.Object(rootbase,{
 outline_width=0,border_width=0,pad_all=0,bg_opa=lvgl.OPA(100),
 bg_color=0,align=lvgl.ALIGN.CENTER,w=UI_W,h=UI_H
})
failurePage:clear_flag(lvgl.FLAG.SCROLLABLE)
failurePage:add_flag(lvgl.FLAG.EVENT_BUBBLE)
local failureBg=failurePage:Image{src=uiImgPath("write_confirm"),x=0,y=0,w=UI_W,h=UI_H}
failureBg:clear_flag(lvgl.FLAG.SCROLLABLE)
failureBg:clear_flag(lvgl.FLAG.CLICKABLE)
local failureTitle=failurePage:Label{
 x=0,y=44,w=UI_W,h=54,text="操作失败",text_color="#ffffff",
 text_font=UI_FONT,text_align=lvgl.ALIGN.TOP_MID
}
local failureText=failurePage:Label{
 x=0,y=112,w=UI_W,h=250,text="请返回首页",text_color="#a8a8a8",
 text_font=UI_FONT,text_align=lvgl.ALIGN.TOP_MID
}
uiPages.failure={page=failurePage,content=failurePage}

local jobTimer=nil jobPhase=0 jobIndex=0 jobMode="install" jobRunning=false
local ctx={h={},bs={},chan={},devs={},firstoff={}}
local start_job

local function ctxClose()
 for k,f in pairs(ctx.h)do f:close() end
 ctx.h={}
end

local function jobFinish(ok,why)
 ctxClose()
 if jobTimer then jobTimer:delete() jobTimer=nil end
 jobRunning=false jobPhase=0 jobIndex=0
 log(ok and "任务完成" or ("任务中止: "..tostring(why)))
 if ok then
  uiShow("success")
 else
  failureText:set{text="操作已中止\n"..tostring(why)}
  uiShow("failure")
 end
end

local function jobStep(timer)
 if jobPhase==0 then
  local dev=ctx.devs[jobIndex]
  if not dev then
   log(string.format("自检完成, 进入只读全量校验(通道=%s)",ctx.chan.sel or "io"))
   jobPhase=1 jobIndex=1
   return timer:ready()
  end
  log(string.format("===== 自检 %d/%d =====",jobIndex,#ctx.devs))
  local opened=probe_dev(dev)
  if opened then
   local bs=probe_bs(dev,ctx.firstoff[dev])
   if bs then
    ctx.bs[dev]=bs
    ctx.h[dev]=io.open(dev,"rb")
    log(string.format("  选定块大小 %d  (io 通道; 固件 ota.sh 用 bs=%d)",bs,BS_PREF))
    jobIndex=jobIndex+1
    return timer:ready()
   end
   log("  io 通道全部失败, 改试 dd 回退通道…")
  end
  local dbs=probe_bs_dd(dev,ctx.firstoff[dev])
  if dbs then
   ctx.bs[dev]=dbs
   ctx.chan[dev]="dd"
   log(string.format("  选定块大小 %d  (dd 回退通道)",dbs))
   jobIndex=jobIndex+1
   return timer:ready()
  end
  return jobFinish(false,dev.." io 与 dd 通道均不可用(见日志)")
 end
 if jobPhase==1 then
  local e=ENTRIES[jobIndex]
  local h=dev_readctx(ctx,e.DEV,e.OFFSET,24)
  if not h or #h<24 then
   return jobFinish(false,e.name.." 读取失败 @"..string.format("0x%x",e.OFFSET).." ("..tostring(h)..")")
  end
  if not magic_ok(h) then
   return jobFinish(false,e.name.." 目标头非法(偏移或节点不匹配) "..hex(h,4))
  end
  local d=readblob(jobMode=="restore" and e.OSRC or e.PSRC,e.SIZE)
  if not d then return jobFinish(false,e.name.." blob 读取失败(BLOB="..BLOB..")") end
  if #d~=e.SIZE then return jobFinish(false,e.name.." 数据长度不符 "..#d.."/"..e.SIZE) end
  if not magic_ok(d) then return jobFinish(false,e.name.." 待写数据头非法") end
  local lim=PART_SIZE[e.DEV]
  if lim and (e.OFFSET+e.SIZE)>lim then
   return jobFinish(false,e.name.." 超出固件分区容量 "..tostring(e.OFFSET+e.SIZE)..">"..tostring(lim))
  end
  log(string.format("校验 %02d/%02d %s",jobIndex,#ENTRIES,e.name))
  jobIndex=jobIndex+1
  if jobIndex>#ENTRIES then
   if jobMode=="probe" then
    ctxClose()
    if jobTimer then jobTimer:delete() jobTimer=nil end
    jobRunning=false jobPhase=0 jobIndex=0
    log("=== 自检通过(未写设备) ===")
    refreshLog()
    uiShow("log")
    return
   end
   jobPhase=2 jobIndex=1
  end
  return timer:ready()
 end
 if jobPhase==2 then
  local e=ENTRIES[jobIndex]
  local d=readblob(jobMode=="restore" and e.OSRC or e.PSRC,e.SIZE)
  if not d then return jobFinish(false,e.name.." blob 读取失败(BLOB="..BLOB..")") end
  if #d~=e.SIZE then return jobFinish(false,e.name.." 数据长度不符 "..#d.."/"..e.SIZE) end
  local ok,why=dev_write(ctx,e.DEV,e.OFFSET,d)
  if not ok then return jobFinish(false,e.name.." 写入失败: "..tostring(why)) end
  d=nil
  log(string.format("写入 %02d/%02d %s @0x%x %s OK",jobIndex,#ENTRIES,e.name,e.OFFSET,e.DEV))
  jobIndex=jobIndex+1
  if jobIndex>#ENTRIES then
   sh("sync")
   log(jobMode=="restore" and "=== RESTORE COMPLETE ===" or "=== INSTALL COMPLETE ===")
   return jobFinish(true)
  end
  return timer:ready()
 end
 return jobFinish(true)
end

function start_job(mode)
 if jobRunning then return end
 if mode==true then mode="restore" elseif mode==false or mode==nil then mode="install" end
 jobRunning=true
 jobMode=mode
 jobPhase=0 jobIndex=1
 ctx={h={},bs={},chan={},devs={},firstoff={}}
 local seen={}
 for _,e in ipairs(ENTRIES)do
  if not seen[e.DEV] then
   seen[e.DEV]=true
   ctx.devs[#ctx.devs+1]=e.DEV
   ctx.firstoff[e.DEV]=e.OFFSET
  end
 end
 table.sort(ctx.devs)
 clearlog()
 log(jobMode=="restore" and "=== RESTORE s441 ICONS ==="
   or (jobMode=="probe" and "=== s441 只读自检 ===" or "=== INSTALL s541 ICONS -> s441 ==="))
 log(string.format("共 %d 个图标, 节点 %d 个, BLOB=%s",#ENTRIES,#ctx.devs,BLOB))
 log(string.format("固件依据: ota.sh bs=%d ; partitions.json app=%d misc=%d",
   BS_PREF,PART_SIZE["/dev/app"],PART_SIZE["/dev/misc"]))
 local t=lvgl.Timer{period=1,repeat_count=-1,paused=true,cb=function(timer)
  local ok,err=pcall(jobStep,timer)
  if not ok then jobFinish(false,"内部错误: "..tostring(err)) end
 end}
 if not t then jobRunning=false return end
 jobTimer=t
 t:resume()
 t:ready()
end

uiHit(mainPage,80,108,312,95,function()uiShow("help")end)
uiHit(mainPage,80,207,312,96,function()uiShow("install")end)
uiHit(mainPage,80,307,312,96,function()uiShow("about")end)
uiHit(helpContent,128,35,212,67,function()uiShow("index")end)
uiHit(helpContent,128,533,212,67,function()uiShow("restore")end)
uiHit(aboutContent,128,35,212,67,function()uiShow("index")end)
uiHit(aboutContent,128,497,212,67,function()refreshLog();uiShow("log")end)
uiHit(logContent,126,95,215,67,function()uiShow("index")end)
uiHit(logContent,75,642,317,80,function()clearlog();refreshLog()end)
uiHit(installPage,68,326,164,84,function()uiShow("index")end)
uiHit(installPage,232,326,164,84,function()start_job("install")end)
uiHit(restorePage,68,326,164,84,function()uiShow("index")end)
uiHit(restorePage,232,326,164,84,function()start_job("restore")end)
uiHit(successContent,82,114,312,95,function()sh("sync");sh("reboot")end)
uiHit(successContent,82,214,312,95,function()uiShow("index")end)
uiHit(successContent,81,315,312,94,function()refreshLog();uiShow("log")end)
uiShow("index")
