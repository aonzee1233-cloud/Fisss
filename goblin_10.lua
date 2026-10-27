--[[
Goblin Auto v10 | Fisch - FischFright 3 | Delta
Run it once while the event is on. Re-running replaces the previous instance.

Flow per goblin (nearest first):
TP -> Talk -> pick difficulty -> read objective -> do it -> TP back -> Talk -> claim

Auto objectives : type in chat, dance, jump, walk
Skipped + logged: catch / perfect catch / drown / burn / freeze / trick-or-treat / guess / insult

What changed vs v9 (self-heal)
 * No more standing still after a quest ends or is skipped: the old code waited up to 120s
   before looking for the next goblin. Now every goblin outcome (done / skipped / failed /
   error) triggers a sweep within CFG.sweepGap seconds, and idle sweeps run every CFG.sweepEvery.
 * A goblin that keeps failing is put on a cooldown (40s, 80s, 160s ... max 300s) and the bot
   goes to other goblins instead of retrying the same one forever.
 * Supervisor thread: restarts a dead / hung loop, unfreezes anchored / sitting / ragdolled
   characters, closes a dialog left open, forces a sweep when nothing happened for
   CFG.idleLimit seconds, teleports to Moosewood if stuck or out of the world, and as a last
   resort respawns the character (CFG.hardResetAfter).
 * Dying during any objective (not only walking) is detected and the try is refunded.
 * New button: Fix now (runs the same repair by hand).

Buttons: Auto ON/OFF | Copy report | Clear | Dump UI | Sweep now
If something still fails: open the dialog by hand, press Dump UI, then Copy report.
]]

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local PPS = game:GetService("ProximityPromptService")
local TCS = game:GetService("TextChatService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local lp = Players.LocalPlayer

local genv = (getgenv and getgenv()) or _G
if genv.GoblinAutoStop then pcall(genv.GoblinAutoStop) end

local okVim, VIM = pcall(function() return game:GetService("VirtualInputManager") end)
if not okVim then VIM = nil end

local CFG = {
	difficulty = "Easy",     -- Easy | Normal | Hard | Extreme | Ultimate
	scanDelay = 0.25,        -- seconds between goblin scans
	dialogWait = 1.1,        -- seconds between dialog clicks
	tpOffset = CFrame.new(0, 3, 6),
	fastJump = false,        -- true = fire the Jump quest remote directly (faster, riskier)
	clickMode = "conn",      -- "conn" = fire button connections | "vim" = real click
	useDisplayName = false,  -- fills <player> if it ever shows up literally in a sentence
	resumeActive = true,     -- if a goblin quest is already active, do it instead of failing
	warpOnSpawn = true,      -- ดักแจ้งเตือน "goblins have spawned at X!" แล้ววาร์ปไปเกาะนั้น (ต้อง Auto ON)
	arriveWait = 3,          -- รอกี่วิหลังถึงเกาะ ให้ goblin stream เข้ามา
	acceptFirst = false,     -- true = รับเควสให้ครบก่อน แล้วค่อยทำเรียงจากรับมานานสุด | false = ทำทีละตัวแบบเดิม
	acceptBatch = 3,         -- รับค้างไว้ได้สูงสุดกี่เควสก่อนเริ่มทำ
	acceptFailMax = 4,       -- รับเควสไม่สำเร็จครบกี่ครั้ง -> พัก goblin ตัวนั้น ไปรับตัวอื่นก่อน
	acceptCool = 60,         -- พักกี่วินาที (x2 ทุกรอบ สูงสุด 300)
	deathCoolAfter = 3,      -- ตายซ้ำที่ goblin ตัวเดียวกันกี่ครั้ง -> พักตัวนั้นเหมือนกัน
	esp = true,              -- ไฮไลต์ goblin + บอกระยะ (false = ซ่อน)
	retryAfter = 300,        -- a finished goblin that stays in place is retried after this long
	talk = true,             -- false = ไม่คุยกับ goblin เลย
	levels = { easy = true, normal = false, hard = false, extreme = false, ultimate = false },
	watchdog = true,
	failCool = 40,           -- goblin ที่ทำไม่สำเร็จครบ 4 ครั้ง พักกี่วินาที (x2 ทุกรอบ สูงสุด 300) แล้วไปหาตัวอื่นก่อน
	hardResetAfter = 4,      -- ซ่อมแบบเบากี่รอบติดแล้วยังไม่หาย -> รีเซ็ตตัวละคร (0 = ปิด)
	islandPos = {
		["Moosewood"]       = Vector3.new(380, 135, 234),
		["Roslit Bay"]      = Vector3.new(-1473, 133, 708),
		["Forsaken Shores"] = Vector3.new(-2491, 133, 1561),
		["Sunstone Island"] = Vector3.new(-913, 138, -1133),
		["Sunstone"]        = Vector3.new(-913, 138, -1133),
		["Castaway Cliffs"] = Vector3.new(657, 134, -1623),
		["Statue of Sovereignty"] = Vector3.new(35, 135, -1010),
		["Harvesters Spike"] = Vector3.new(-1260, 135, 1550),
		["The Arch"]        = Vector3.new(1100, 130, -1250),
		["Birch Cay"]       = Vector3.new(1650, 130, -2350),
		["Haddock Rock"]    = Vector3.new(-500, 125, -505),
		["Earmark Island"]  = Vector3.new(1200, 130, 530),
		["Terrapin Island"] = Vector3.new(-193, 135, 1951),
		["Mushgrove Swamp"] = Vector3.new(2434, 132, -692),
		["Ancient Isle"]    = Vector3.new(6056, 195, 307),
		["Lost Jungle"]     = Vector3.new(-2589, 158, -2194),
		["Scoria Reach"]    = Vector3.new(-4976, 145, -1577),
		["Snowcap Island"]  = Vector3.new(2607, 135, 2436),
	},
}

local running, enabled = true, true
local lines, seen, conns = {}, {}, {}

---------------------------------------------------------------- state
local state = setmetatable({}, { __mode = "k" })      -- goblin model -> status table
local dialogAt = setmetatable({}, { __mode = "k" })   -- npc -> time of last dialogstart
local dialogCfg = setmetatable({}, { __mode = "k" })
local lastClick = setmetatable({}, { __mode = "k" })  -- button -> { t = text, at = time }
local pendingWarp = nil -- { name, cf, at } ใส่โดยตัวดักแจ้งเตือน spawn / tickOnce เป็นคนเอาไปใช้
local dialogRoot = nil
local statusLbl = nil
local working = false         -- true while a goblin / sweep is being processed
local lastWork = os.clock()   -- last time the loop did something real
local recoverNow = nil        -- set by the supervisor (used by the Fix now button)

-- watchdog: ทุก step ใหญ่เรียก touch() ถ้าเงียบเกิน limit วินาที = ค้าง
local wd = { beat = os.clock(), limit = 60 }
local lastDied = false -- doWalk2 ตั้งเป็น true ตอนตัวละครตายระหว่างทำเควส
local function touch(limit)
	wd.beat = os.clock()
	wd.limit = limit or 60
end

local function setStatus(s)
	touch(60)
	if statusLbl then statusLbl.Text = s end
end

local function log(s)
	if #lines < 1500 then lines[#lines + 1] = s end
	print("[GA] " .. s)
end

local function fmt(a, d, maxd)
	d = d or 0
	maxd = maxd or 2
	if typeof(a) == "Instance" then return a:GetFullName() end
	if type(a) == "table" then
		if d >= maxd then return "{...}" end
		local p = {}
		for k, v in pairs(a) do p[#p + 1] = tostring(k) .. "=" .. fmt(v, d + 1, maxd) end
		return "{" .. table.concat(p, ", ") .. "}"
	end
	return tostring(a)
end

---------------------------------------------------------------- helpers
local function hrpOf()
	local c = lp.Character
	return c and c:FindFirstChild("HumanoidRootPart"), c and c:FindFirstChildOfClass("Humanoid")
end

local function clean(s)
	s = tostring(s or "")
	local nm = CFG.useDisplayName and lp.DisplayName or lp.Name
	s = s:gsub("<[Pp]layer>", function() return nm end)
	s = s:gsub("<[^>]+>", "")
	s = s:gsub("\226\128\156", '"'):gsub("\226\128\157", '"'):gsub("\226\128\153", "'")
	return s
end

local function goblins()
	local out = {}
	local w = workspace:FindFirstChild("world")
	local npcs = w and w:FindFirstChild("npcs")
	local folder = npcs and npcs:FindFirstChild("FischfrightGoblins")
	if folder then
		for _, m in ipairs(folder:GetChildren()) do
			if m:IsA("Model") then
				local loaded = m:FindFirstChildWhichIsA("BasePart", true) ~= nil
				local p = m:GetPivot().Position
				local ok = loaded or (p.Y > 100 and Vector3.new(p.X, 0, p.Z).Magnitude > 150)
				if not loaded then
					local d = ("FAR %s | %.0f, %.0f, %.0f | %s"):format(m.Name, p.X, p.Y, p.Z, ok and "use" or "ignored")
					if not seen[d] then seen[d] = true; log(d) end
				end
				if ok then out[#out + 1] = m end
			end
		end
	end
	return out
end

local function promptPos(m)
	local pp = m:FindFirstChildWhichIsA("ProximityPrompt", true)
	local par = pp and pp.Parent
	if par and par:IsA("Attachment") then return par.WorldPosition end
	if par and par:IsA("BasePart") then return par.Position end
	return m:GetPivot().Position
end

local function standCF(m)
	local gp = promptPos(m)
	local root = m:FindFirstChild("RootPart") or m.PrimaryPart
	local look = root and root.CFrame.LookVector or Vector3.new(0, 0, -1)
	look = Vector3.new(look.X, 0, look.Z)
	look = look.Magnitude > 0.1 and look.Unit or Vector3.new(0, 0, -1)
	local side = Vector3.new(-look.Z, 0, look.X)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { lp.Character, m }
	rp.IgnoreWater = true
	for _, d in ipairs({ look, side, -side, -look }) do
		local p = gp + d * 5
		local hit = workspace:Raycast(p + Vector3.new(0, 4, 0), Vector3.new(0, -25, 0), rp)
		if hit and math.abs(hit.Position.Y - gp.Y) < 8 then
			local pos = hit.Position + Vector3.new(0, 3.2, 0)
			return CFrame.lookAt(pos, Vector3.new(gp.X, pos.Y, gp.Z))
		end
	end
	local pos = gp + look * 5 + Vector3.new(0, 2, 0)
	return CFrame.lookAt(pos, Vector3.new(gp.X, pos.Y, gp.Z))
end

local function tpTo(model)
	local hrp = hrpOf()
	if not hrp or not model.Parent then return false end
	local cf = model:GetPivot()
	if not model:FindFirstChildWhichIsA("BasePart", true) then
		pcall(function() lp:RequestStreamAroundAsync(cf.Position, 2) end)
		hrp.Anchored = true -- ลอยรอให้ goblin โหลด
		hrp.CFrame = cf + Vector3.new(0, 40, 0)
		hrp.AssemblyLinearVelocity = Vector3.zero
		local t0 = os.clock()
		while model.Parent and os.clock() - t0 < 8
			and not model:FindFirstChildWhichIsA("BasePart", true) do
			task.wait(0.1)
		end
		hrp.Anchored = false
		if not model.Parent or not model:FindFirstChildWhichIsA("BasePart", true) then
			log("NOTE: " .. model.Name .. " did not load at its saved spot")
			return false
		end
		cf = model:GetPivot()
	end
	hrp.CFrame = standCF(model)
	hrp.AssemblyLinearVelocity = Vector3.zero
	task.wait(0.5)
	return model.Parent ~= nil
end

local function tap(key, t)
	if not VIM then return end
	pcall(function() VIM:SendKeyEvent(true, key, false, game) end)
	task.wait(t or 0.15)
	pcall(function() VIM:SendKeyEvent(false, key, false, game) end)
end

local function cancelEmote()
	local e = RS:FindFirstChild("events")
	local r = e and e:FindFirstChild("CancelEmote")
	if r then pcall(function() r:FireServer() end) end
end

local function exitEmote()
	cancelEmote()
	local hrp, hum = hrpOf()
	if not hrp or not hum then return end
	local n = 0
	for _, tr in ipairs(hum:GetPlayingAnimationTracks()) do
		n = n + 1
		pcall(function() tr:Stop(0.1) end)
	end
	-- restart the Animate script: clears an emote that is stuck in a loop
	local an = lp.Character and lp.Character:FindFirstChild("Animate")
	if an then
		pcall(function() an.Disabled = true end)
		pcall(function() an.Enabled = false end)
		task.wait(0.15)
		pcall(function() an.Disabled = false end)
		pcall(function() an.Enabled = true end)
	end
	hum:MoveTo(hrp.Position + hrp.CFrame.LookVector * 4)
	tap(Enum.KeyCode.W, 0.35) -- a real key press: most games cancel an emote on input
	tap(Enum.KeyCode.Space, 0.1)
	hum.Jump = true
	task.wait(0.5)
	log("EMOTE stop (" .. n .. " tracks)")
end

local ISLANDS = {
	{ "Ancient Isle", "ancient" }, { "Drylands", "dryland", "dry land" },
	{ "Everturn Forest", "everturn" }, { "Forsaken Shores", "forsaken" },
	{ "Lost Jungle", "lost jungle", "lostjungle" }, { "Moosewood", "moosewood" },
	{ "Mushgrove Swamp", "mushgrove" }, { "Roslit Bay", "roslit" },
	{ "Scoria Reach", "scoria" }, { "Skycrest", "skycrest", "sky crest" },
	{ "Snowcap Island", "snowcap" }, { "Sunstone Island", "sunstone" },
	{ "Terrapin Island", "terrapin" },
	{ "Castaway Cliffs", "castaway" }, { "Statue of Sovereignty", "sovereignty" },
	{ "Harvesters Spike", "harvester" }, { "The Arch", "the arch" },
	{ "Birch Cay", "birch" }, { "Haddock Rock", "haddock" }, { "Earmark Island", "earmark" },
}

local function posOf(o)
	if o:IsA("BasePart") then return o.Position end
	if o:IsA("Model") then
		local ok, cf = pcall(function() return o:GetPivot() end)
		if ok then return cf.Position end
	end
	return nil
end

local function islandRoots()
	local out = {}
	local function add(r) if r then out[#out + 1] = r end end
	local w = workspace:FindFirstChild("world")
	local sp = w and w:FindFirstChild("spawns")
	local z = workspace:FindFirstChild("zones")
	add(sp and sp:FindFirstChild("TpSpots"))
	add(w and w:FindFirstChild("map"))
	add(z and z:FindFirstChild("fishing"))
	return out
end

local islandCache, islandMiss = {}, {}
-- พิกัดสำรอง "ค่าประมาณจากความจำ ไม่ได้เช็คกับเกมนี้" ใช้เมื่อหาด้วยชื่อไม่เจอ; ถ้าตกน้ำให้ใช้ปุ่ม Mark spot
local islandGuess = { ["Snowcap Island"] = Vector3.new(2607, 135, 2436) }

-- ค้นทุกอย่างใต้ workspace.world / workspace.zones หา Model/Part ที่ชื่อมีคีย์เวิร์ดเกาะ (เช่น "Snowcap Shipwright")
local function deepFind(isl)
	local best, bd
	for _, rn in ipairs({ "world", "zones" }) do
		local r = workspace:FindFirstChild(rn)
		if r then
			for _, o in ipairs(r:GetDescendants()) do
				if (o:IsA("Model") or o:IsA("BasePart")) and #o.Name <= 40 then
					local n = o.Name:lower()
					for i = 2, #isl do
						if n:find(isl[i], 1, true) then
							local p = posOf(o)
							local d = #o:GetFullName()
							if p and (not bd or d < bd) then best, bd = p, d end
						end
					end
				end
			end
		end
	end
	return best
end

local function findIsland(isl)
	local name = isl[1]
	if CFG.islandPos[name] then return CFrame.new(CFG.islandPos[name]) end
	if islandCache[name] then return CFrame.new(islandCache[name]) end
	for _, r in ipairs(islandRoots()) do
		local best, bl
		for _, o in ipairs(r:GetChildren()) do
			local n = o.Name:lower()
			for i = 2, #isl do
				if n:find(isl[i], 1, true) and (not bl or #n < bl) and posOf(o) then
					best, bl = o, #n
				end
			end
		end
		if best then return CFrame.new(posOf(best)) end
	end
	if not islandMiss[name] or os.clock() - islandMiss[name] > 90 then
		local p = deepFind(isl)
		if p then
			islandCache[name] = p
			return CFrame.new(p)
		end
		islandMiss[name] = os.clock()
	end
	if islandGuess[name] then return CFrame.new(islandGuess[name]) end
	return nil
end

local MAXTRY = 4
local function stOf(m)
	local pos = m:GetPivot().Position
	local s = state[m]
	local strikes = 0
	if s then
		local age = os.clock() - s.at
		local moved = (s.pos - pos).Magnitude > 25
		local expired = (s.done and age > CFG.retryAfter)
			or (not s.done and s.tries >= MAXTRY and age > (s.cool or 40))
		if expired and not moved then strikes = s.strikes or 0 end
		if moved or expired then s = nil end -- respawned somewhere else / cooldown over
	end
	if not s then
		s = { pos = pos, tries = 0, done = false, claim = false, at = os.clock(), strikes = strikes }
		state[m] = s
	end
	return s
end

local diffByName = { ["goblin"] = "easy", ["ghoulish goblin"] = "normal" }

local function wantsModel(m)
	if not CFG.talk then return false end
	local lv = diffByName[m.Name:lower()]
	return lv == nil or CFG.levels[lv] == true
end

local function fresh()
	local out = {}
	for _, m in ipairs(goblins()) do
		local ok, s = pcall(stOf, m)
		if ok and not s.done and s.tries < MAXTRY and wantsModel(m)
			and (s.coolUntil or 0) <= os.clock() then out[#out + 1] = m end
	end
	return out
end

-- goblin ยังอยู่แต่ลองครบแล้ว: อย่าวิ่งหนีไป sweep เกาะอื่น
local function pending()
	for _, m in ipairs(goblins()) do
		local ok, s = pcall(stOf, m)
		if ok and not s.done and wantsModel(m) then return true end
	end
	return false
end

---------------------------------------------------------------- events + remote logging
local function onEvent(name, t)
	if name == "dialogstart" then
		local d = t[1]
		if type(d) == "table" and typeof(d.npc) == "Instance" then
			dialogAt[d.npc] = os.clock()
			dialogCfg[d.npc] = t[3]
		end
	elseif name:find("Goblins/", 1, true) then
		if name:find("Hide", 1, true) then
			for i = 1, t.n do
				local v = t[i]
				if type(v) == "string" then
					for _, m in ipairs(goblins()) do
						if m:GetAttribute("UID") == v then
							state[m] = { pos = m:GetPivot().Position, tries = 0, done = true,
								claim = true, at = os.clock() }
						end
					end
				end
			end
		end
	end
end

local skipKeys = { "ClientKit", "Settings/Edit", "ResourceStream", "SetHotbar", "Analytics", "SetZone" }
local function noisy(path)
	for _, k in ipairs(skipKeys) do
		if path:find(k, 1, true) then return true end
	end
	return false
end

genv.GA_CALL = function(line)
	if not seen[line] then
		seen[line] = true
		log(line)
	end
end

if hookmetamethod and getnamecallmethod then
	if not genv.GA_HOOKED then
		genv.GA_HOOKED = true
		local nc = newcclosure or function(f) return f end
		local old
		old = hookmetamethod(game, "__namecall", nc(function(self, ...)
			local m = getnamecallmethod()
			if m == "FireServer" or m == "InvokeServer" then
				local t = table.pack(...)
				local remote = self
				task.defer(function()
					local path = fmt(remote)
					if noisy(path) then return end
					local parts = {}
					for i = 1, t.n do parts[i] = fmt(t[i]) end
					local f = genv.GA_CALL
					if f then f("CALL " .. path .. ":" .. m .. "(" .. table.concat(parts, ", ") .. ")") end
				end)
			end
			return old(self, ...)
		end))
	end
else
	log("NOTE: executor has no hookmetamethod (remote calls will not be logged)")
end

-- one short line per dialogstart instead of the whole dialog tree (keeps the report small)
local function briefDialog(t)
	local d, c = t[1], t[3]
	local npc = type(d) == "table" and typeof(d.npc) == "Instance" and d.npc.Name or "?"
	c = type(c) == "table" and c or {}
	local n1 = type(c.dialog) == "table" and c.dialog[1]
	return ("DIALOG %s | cs_start=%s | init=%s | node1=%s"):format(
		npc, tostring(c.cs_start), fmt(c.initial_data, 0, 2),
		type(n1) == "table" and clean(tostring(n1.text)) or "?")
end

local function listen(r)
	if r and r:IsA("BaseRemoteEvent") then
		conns[#conns + 1] = r.OnClientEvent:Connect(function(...)
			local t = table.pack(...)
			local parts = {}
			for i = 1, t.n do parts[i] = fmt(t[i], 0, 2) end
			local s = "EVENT " .. r.Name .. "(" .. table.concat(parts, ", ") .. ")"
			if r.Name == "dialogstart" then s = briefDialog(t) end
			if #s > 1500 then s = s:sub(1, 1500) .. "...<cut>" end
			if not seen[s] then
				seen[s] = true
				log(s)
			end
			local ok, err = pcall(onEvent, r.Name, t)
			if not ok then log("ERR onEvent " .. tostring(err)) end
		end)
	end
end

local ev = RS:FindFirstChild("events")
local dsEvent = ev and ev:FindFirstChild("dialogstart")
if dsEvent then listen(dsEvent) end
local pk = RS:FindFirstChild("packages")
local net = pk and pk:FindFirstChild("Net")
local DI = net and net:FindFirstChild("RF/DialogInteract")
if net then
	for _, r in ipairs(net:GetChildren()) do
		local n = r.Name
		if n:find("Goblins/", 1, true) or n:find("TrickOrTreat/", 1, true) or n:find("QuestTrigger", 1, true) or n:find("Dialog", 1, true) then
			listen(r)
		end
	end
end

conns[#conns + 1] = PPS.PromptTriggered:Connect(function(p)
	log("PROMPT " .. p:GetFullName() .. " | " .. p.ActionText .. " / " .. p.ObjectText)
end)

---------------------------------------------------------------- GUI reading / clicking
local function visibleChain(g)
	local pg = lp.PlayerGui
	local o = g
	while o and o ~= pg do
		if o:IsA("GuiObject") and not o.Visible then return false end
		if o:IsA("ScreenGui") and not o.Enabled then return false end
		o = o.Parent
	end
	return o == pg
end

local function alive(o)
	return o ~= nil and o.Parent ~= nil and visibleChain(o)
end

local function isText(g) return g:IsA("TextButton") or g:IsA("TextLabel") end

local function hasAny(txt, list)
	for _, w in ipairs(list) do
		if txt:find(w, 1, true) then return true end
	end
	return false
end

-- HUD stuff that must never be clicked: timers, counters, icon names
local function noise(t)
	if t:find("^time left") then return true end
	if t:find("^[%d%.,%s]+[kmb]?$") then return true end
	if t:find("^[%l%d]+%-[%l%d%-]+$") then return true end
	return false
end

-- remember which text objects are visible right now; only objects that are NOT in this
-- set count as "new" later (keyed by instance, so a ticking timer text is never new)
local base = setmetatable({}, { __mode = "k" })
local function snapshot()
	base = setmetatable({}, { __mode = "k" })
	for _, g in ipairs(lp.PlayerGui:GetDescendants()) do
		if isText(g) and visibleChain(g) then base[g] = true end
	end
end

local function texts(onlyNew)
	local out = {}
	for _, g in ipairs(lp.PlayerGui:GetDescendants()) do
		if isText(g) and #g.Text > 1 and visibleChain(g) then
			if not onlyNew or not base[g] then out[#out + 1] = g end
		end
	end
	return out
end

local function clickTarget(g)
	if g:IsA("GuiButton") then return g end
	return g:FindFirstAncestorWhichIsA("GuiButton")
end

local function fireConns(sig)
	if not getconnections then return 0 end
	local n = 0
	local ok, list = pcall(getconnections, sig)
	if ok and type(list) == "table" then
		for _, c in ipairs(list) do
			if pcall(function() c:Fire() end) then n = n + 1 end
		end
	end
	return n
end

local function realClick(g)
	if not VIM then return false end
	local p, s = g.AbsolutePosition, g.AbsoluteSize
	local sg = g:FindFirstAncestorWhichIsA("ScreenGui")
	local inset = (sg and sg.IgnoreGuiInset) and Vector2.zero or GuiService:GetGuiInset()
	local x, y = p.X + s.X / 2 + inset.X, p.Y + s.Y / 2 + inset.Y
	VIM:SendMouseButtonEvent(x, y, 0, true, game, 0)
	task.wait(0.06)
	VIM:SendMouseButtonEvent(x, y, 0, false, game, 0)
	return true
end

local function press(btn)
	if CFG.clickMode == "conn" then
		if fireConns(btn.Activated) > 0 then return "Activated" end
		if fireConns(btn.MouseButton1Click) > 0 then return "MouseButton1Click" end
	end
	if realClick(btn) then return "vim" end
	return "none"
end

local function emoteBtn()
	for _, g in ipairs(texts(false)) do
		if clean(g.Text):lower():find("cancel emote", 1, true) then
			return clickTarget(g) or g
		end
	end
	return nil
end

local function stopEmote()
	for i = 1, 6 do
		local b = emoteBtn()
		if not b then
			if i > 1 then log("EMOTE stopped") end
			return true
		end
		if i % 2 == 1 then
			local ok, how = pcall(press, b)
			log("EMOTE cancel click via " .. tostring(ok and how or "error"))
		else
			pcall(realClick, b) -- รอบคู่ กดจริงบนจอ
		end
		cancelEmote()
		task.wait(0.4)
	end
	log("NOTE: emote cancel button still showing after 6 tries")
	return false
end

local function closeDialog()
	for _, g in ipairs(texts(false)) do
		if clean(g.Text):lower():find("nevermind", 1, true) then
			local b = clickTarget(g)
			if b then
				press(b)
				return
			end
		end
	end
end

-- a dialog window that stays open blocks the prompt. Close it ("Nevermind..."), then walk
-- out of its range (maxdistance = 12) so it closes by itself
local function leaveDialog(m)
	closeDialog()
	task.wait(0.3)
	local hrp = hrpOf()
	if not hrp then return end
	local origin = (m and m.Parent) and m:GetPivot().Position or hrp.Position
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { lp.Character }
	rp.IgnoreWater = true
	for i = 0, 7 do
		local a = math.rad(i * 45)
		local p = origin + Vector3.new(math.cos(a), 0, math.sin(a)) * 28
		local hit = workspace:Raycast(p + Vector3.new(0, 60, 0), Vector3.new(0, -120, 0), rp)
		if hit and math.abs(hit.Position.Y - origin.Y) < 10 then
			hrp.CFrame = CFrame.new(hit.Position + Vector3.new(0, 4, 0))
			hrp.AssemblyLinearVelocity = Vector3.zero
			task.wait(1.2)
			return
		end
	end
	-- no ground found around it: hang in the air for a moment instead
	hrp.Anchored = true
	hrp.CFrame = CFrame.new(origin + Vector3.new(0, 45, 0))
	task.wait(1.2)
	hrp.Anchored = false
end

-- ปิด dialog แบบไม่วาปหนี: กด Nevermind แล้วรอ ถ้ายังไม่ปิดจริงๆ ค่อยถอยออกไป
local function softLeave(m)
	closeDialog()
	task.wait(0.5)
	for _, g in ipairs(texts(false)) do
		if clean(g.Text):lower():find("nevermind", 1, true) then
			leaveDialog(m)
			return
		end
	end
end

---------------------------------------------------------------- dialog
local DIFF = { "easy", "normal", "hard", "extreme", "ultimate" }
local function levelOrder()
	local o = {}
	for _, d in ipairs(DIFF) do
		if CFG.levels[d] then o[#o + 1] = d end
	end
	return o
end

local EXCLUDE = { "never", "leave", "bye", "cancel", "close", "decline", "nope", "not now", "no thanks", "[no]", "navigate" }
local QUESTY = { "goblin quest", "friend quest", "quest:", "track" }
local PREFER = { "accept", "okay", "ok", "sure", "deal", "yes", "fine", "continue", "next",
	"claim", "complete", "done", "turn in", "reward", "thank", "alright", "bring it" }

local BADUI = { "statuses", "popupNotif", "topbar", "changelogs", "PlayerList", "backpack", "TopbarStandard" }
local function badUI(o)
	local p = o:GetFullName()
	for _, k in ipairs(BADUI) do
		if p:find(k, 1, true) then return true end
	end
	return false
end

-- find the container (direct child of a ScreenGui) that holds the most NEW text:
-- that is the dialog window
local function pickRoot()
	local score, best, bestRoot = {}, 0, nil
	for _, g in ipairs(texts(true)) do
		local t = clean(g.Text):lower()
		if not noise(t) and not badUI(g) then
			local sg = g:FindFirstAncestorWhichIsA("ScreenGui")
			if sg then
				local top = g
				while top.Parent and top.Parent ~= sg do top = top.Parent end
				score[top] = (score[top] or 0) + 1
				if score[top] > best then
					best = score[top]
					bestRoot = top
				end
			end
		end
	end
	return bestRoot
end

local function inRoot(o)
	return dialogRoot ~= nil and (o == dialogRoot or o:IsDescendantOf(dialogRoot))
end

-- clickable options inside the dialog window only
local function dialogButtons()
	if not alive(dialogRoot) then dialogRoot = pickRoot() end
	local out = {}
	if not dialogRoot then return out end
	for _, g in ipairs(texts(true)) do
		local b = clickTarget(g)
		if b and inRoot(b) and not badUI(b) then
			local t = clean(g.Text):lower()
			local lc = lastClick[b]
			local recent = lc and lc.t == t and os.clock() - lc.at < 1.8
			if not recent and not noise(t) and not hasAny(t, EXCLUDE)
				and not hasAny(t, DIFF) and not hasAny(t, QUESTY) then
				out[#out + 1] = { b = b, t = t }
			end
		end
	end
	return out
end

local function stepDialog()
	local cands = dialogButtons()
	if #cands == 0 then return false end
	local pick = cands[1]
	for _, c in ipairs(cands) do
		if hasAny(c.t, PREFER) then
			pick = c
			break
		end
	end
	lastClick[pick.b] = { t = pick.t, at = os.clock() }
	log(('CLICK "%s" via %s'):format(pick.t:sub(1, 60), press(pick.b)))
	return true
end

-- the 5 difficulty options ("Can I just get an Easy one?" ...), never the quest HUD
local function diffButtons()
	local out = {}
	for _, g in ipairs(texts(true)) do
		local b = clickTarget(g)
		if b then
			local t = clean(g.Text):lower()
			if #t <= 60 and not noise(t) and not hasAny(t, QUESTY) and hasAny(t, DIFF) then
				out[#out + 1] = { b = b, t = t }
			end
		end
	end
	return out
end

local function pickDifficulty()
	local order = levelOrder()
	local t0, settled = os.clock(), false
	while os.clock() - t0 < 12 do
		if not alive(dialogRoot) then dialogRoot = pickRoot() end
		local cands = diffButtons()
		if #cands > 0 then
			if not settled then
				settled = true -- let the rest of the options finish appearing
				task.wait(0.7)
			else
				for _, w in ipairs(order) do
					for _, c in ipairs(cands) do
						if c.t:find(w, 1, true) then return c.b, c.t end
					end
				end
				task.wait(0.3)
			end
		else
			-- intro lines first: click "continue"-like buttons inside the dialog
			stepDialog()
			task.wait(CFG.dialogWait)
		end
	end
	return nil
end

local function firePrompt(pp, useFire)
	if fireproximityprompt and useFire then
		pcall(fireproximityprompt, pp)
	else
		pcall(function()
			pp:InputHoldBegin()
			task.wait(0.2)
			pp:InputHoldEnd()
		end)
	end
end

local function openDialog(model)
	local pp
	local t0 = os.clock()
	while model.Parent do
		pp = model:FindFirstChildWhichIsA("ProximityPrompt", true)
		if pp or os.clock() - t0 > 6 then break end
		task.wait(0.4)
	end
	if not pp then
		log("NOTE: no prompt on " .. model.Name)
		return false
	end
	pcall(function()
		pp.HoldDuration = 0
		pp.RequiresLineOfSight = false
		pp.MaxActivationDistance = 40
	end)
	dialogRoot = nil
	snapshot()
	for attempt = 1, 5 do
		touch(60)
		if not model.Parent then return false end
		-- prompt ถูกปิดอยู่ (goblin กำลังคุย / คูลดาวน์): รอให้เปิดก่อน ไม่ต้องยิงรัวแล้ววาปหนี
		local w1 = os.clock()
		while model.Parent and not pp.Enabled and os.clock() - w1 < 6 do
			task.wait(0.3)
		end
		local hrp = hrpOf()
		if hrp and (hrp.Position - promptPos(model)).Magnitude > 10 then
			tpTo(model)
		end
		dialogAt[model] = nil
		cancelEmote()
		if attempt >= 2 then stopEmote(); exitEmote() end
		task.wait(0.1)
		firePrompt(pp, attempt % 2 == 1)
		local w0, again = os.clock(), false
		while os.clock() - w0 < 4.5 do -- dialogstart มาช้าแล้วโดนวาปหนีกลางทาง
			if dialogAt[model] then break end
			if not dsEvent and pickRoot() then break end
			if not again and os.clock() - w0 > 2.2 then
				again = true
				firePrompt(pp, attempt % 2 == 0)
			end
			task.wait(0.1)
		end
		if dialogAt[model] or (not dsEvent and pickRoot()) then
			log("TALK " .. model.Name)
			return true
		end
		log("NOTE: no dialog yet on " .. model.Name .. " (try " .. attempt .. ")")
		closeDialog()
		task.wait(0.6)
		if attempt == 3 then leaveDialog(model) end -- วาปถอยแค่ครั้งเดียว หลังลองครบ 3 รอบ
	end
	return false
end

---------------------------------------------------------------- objective parsing
local function numAfter(l, kw)
	local rest = l:match(kw .. "(.*)")
	if not rest then return nil end
	local n = rest:match("(%d[%d,]*)")
	return n and tonumber((n:gsub(",", ""))) or nil
end

-- "(12/50)" style progress -> how many are still left
local function remaining(l, total)
	local a, b = l:match("(%d[%d,]*)%s*/%s*(%d[%d,]*)")
	a = a and tonumber((a:gsub(",", "")))
	b = b and tonumber((b:gsub(",", "")))
	if a and b and b >= a then return b - a end
	return total
end

local function parse(raw)
	local t = clean(raw)
	local l = t:lower()

	local q = t:match('[Tt]ype%s*"(.-)"')
	if q and l:find("in chat", 1, true) then
		local n = tonumber(l:match("in chat%s+(%d+)%s+times"))
			or (l:find("in chat twice", 1, true) and 2) or 1
		return { kind = "chat", text = q, count = n }
	end
	if l:find("%f[%a]danc") or l:find("%f[%a]jig%f[%A]") then
		local n = numAfter(l, "danc") or numAfter(l, "jig")
		return { kind = "dance", secs = n and remaining(l, n) or 15 }
	end
	if l:find("jump%D*%d") then
		local n = numAfter(l, "jump")
		return { kind = "jump", n = n and remaining(l, n) }
	end
	if l:find("walk%D*%d") then
		local n = numAfter(l, "walk")
		return { kind = "walk", n = n and remaining(l, n) }
	end

	for _, k in ipairs({ "catch", "perfect", "beatrix", "insult", "trick", "guess", "drown", "burn", "freeze" }) do
		if l:find(k, 1, true) then return { kind = "skip", why = k } end
	end
	return nil
end

-- prefers something we can actually do over something we have to skip
local function readObjective()
	local skip
	for _, g in ipairs(texts(true)) do
		local o = parse(g.Text)
		if o then
			if o.kind ~= "skip" then return o, clean(g.Text) end
			skip = skip or { o = o, raw = clean(g.Text) }
		end
	end
	if skip then return skip.o, skip.raw end
	return nil
end

local function hasGoblinQuest()
	for _, g in ipairs(texts(false)) do
		if clean(g.Text):lower():find("goblin quest", 1, true) then return true end
	end
	return false
end

local function activeObjective(hudOnly)
	for pass = 1, 2 do
		if pass == 1 or not hudOnly then
			for _, g in ipairs(texts(false)) do
				if pass == 2 or g:GetFullName():find("deviceinset", 1, true) then
					local o = parse(g.Text)
					if o and o.kind ~= "skip" then return o, clean(g.Text) end
				end
			end
		end
	end
	return nil
end

local function advance(rounds, wantObj)
	local obj, raw
	for _ = 1, rounds do
		task.wait(CFG.dialogWait)
		if wantObj and not obj then obj, raw = readObjective() end
		if not stepDialog() then break end
	end
	if wantObj then
		local t0 = os.clock()
		while not obj and os.clock() - t0 < 6 do
			obj, raw = readObjective()
			if not obj then task.wait(0.5) end
		end
	end
	return obj, raw
end

---------------------------------------------------------------- objective actions
local function sendChat(msg)
	local ok = false
	if TCS.ChatVersion == Enum.ChatVersion.TextChatService then
		local chans = TCS:FindFirstChild("TextChannels")
		local ch = chans and (chans:FindFirstChild("RBXGeneral") or chans:FindFirstChildWhichIsA("TextChannel"))
		if ch then ok = pcall(function() ch:SendAsync(msg) end) end
	end
	if not ok then
		local dce = RS:FindFirstChild("DefaultChatSystemChatEvents")
		local req = dce and dce:FindFirstChild("SayMessageRequest")
		if req then
			req:FireServer(msg, "All")
			ok = true
		end
	end
	return ok
end

local function doChat(o)
	for _ = 1, o.count do
		if not running then return false end
		if not sendChat(o.text) then
			log("NOTE: could not send chat")
			return false
		end
		log("CHAT " .. o.text)
		task.wait(1.7)
	end
	return true
end

local function doDance(o)
	local _, hum = hrpOf()
	if not hum then return false end
	local ok, res = pcall(function() return hum:PlayEmote("dance") end)
	if not (ok and res) then sendChat("/e dance") end
	log("DANCE " .. o.secs .. "s")
	task.wait(o.secs + 2)
	exitEmote()
	return true
end

local function doJump(o)
	local _, hum = hrpOf()
	if not hum then return false end
	local n = o.n or 15
	local r = net and net:FindFirstChild("URE/QuestTrigger/Jump")
	log("JUMP x" .. n)
	if CFG.fastJump and r then
		for _ = 1, n do
			touch(30)
			if not running then return false end
			r:FireServer()
			task.wait(0.12)
		end
	else
		for _ = 1, n do
			touch(30)
			if not running then return false end
			hum.Jump = true
			hum:ChangeState(Enum.HumanoidStateType.Jumping)
			task.wait(0.55)
		end
	end
	return true
end

-- "(a/b)" of the first quest-HUD line that mentions `word` (PlayerGui.hud.deviceinset.quests)
local function hudProgress(word)
	for _, g in ipairs(texts(false)) do
		if g:GetFullName():find("deviceinset", 1, true) then
			local l = clean(g.Text):lower()
			if l:find(word, 1, true) then
				local a, b = l:match("(%d[%d,]*)%s*/%s*(%d[%d,]*)")
				if a and b then
					return tonumber((a:gsub(",", ""))), tonumber((b:gsub(",", "")))
				end
			end
		end
	end
	return nil
end

-- direction with the longest stretch of flat ground (no water, wall or cliff) from here
local function openLane(hrp)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { lp.Character }
	rp.IgnoreWater = false -- นับน้ำเป็น "ไม่มีพื้น"
	local base = hrp.Position
	local best, bestLen = Vector3.new(0, 0, 1), -1
	for i = 0, 7 do
		local a = math.rad(i * 45)
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local len = 0
		for step = 1, 8 do
			local p = base + dir * (step * 5)
			local hit = workspace:Raycast(p + Vector3.new(0, 20, 0), Vector3.new(0, -60, 0), rp)
			if not (hit and hit.Material ~= Enum.Material.Water
				and math.abs(hit.Position.Y - (base.Y - 3)) < 6) then break end
			len = step * 5
		end
		if len > bestLen then best, bestLen = dir, len end
	end
	return best, bestLen
end

-- walks back and forth until the HUD says (b/b). Studs and the quest's own unit may differ,
-- so the HUD is the judge; the stud goal is only the fallback when the HUD line is unreadable
local function doWalk(o)
	local hrp, hum = hrpOf()
	if not hrp or not hum then return false end
	local goal = (o.n or 50) * 1.1 + 5
	local dir, len = openLane(hrp)
	len = math.clamp(len, 12, 35)
	local a = hrp.Position
	local b = a + dir * len
	log(("WALK n=%s lane=%d studs"):format(tostring(o.n), len))
	local walked, last = 0, hrp.Position
	local hbc = RunService.Heartbeat:Connect(function()
		local h = hrpOf()
		if not h then return end
		local d = (h.Position - last).Magnitude
		if d < 8 then walked = walked + d end -- ignore teleports
		last = h.Position
	end)

	local toB, done, sawHud, missing = true, false, false, 0
	local t0, lastLog = os.clock(), 0
	local lastHud, lastMove = nil, os.clock()
	while running and not done and os.clock() - t0 < 300 do
		local target = toB and b or a
		hum:MoveTo(target)
		local s0 = os.clock()
		repeat
			task.wait(0.1)
			local h = hrpOf()
			if not h then break end
		until (h.Position - target).Magnitude < 4 or os.clock() - s0 > 3.5
		toB = not toB

		local pa, pb = hudProgress("walk")
		if pa then
			sawHud, missing = true, 0
			if pa ~= lastHud then lastHud, lastMove = pa, os.clock() end
			if pa >= pb then done = true end
			if os.clock() - lastLog > 5 then
				lastLog = os.clock()
				log(("WALK hud %d/%d | moved %.0f studs"):format(pa, pb, walked))
			end
			if not done and os.clock() - lastMove > 25 and walked > 60 then
				log("NOTE: walk progress is stuck on the HUD - send this report")
				break
			end
		elseif sawHud then
			missing = missing + 1
			if missing >= 2 then done = true end -- the line is gone: objective finished
		elseif walked >= goal then
			done = true
		end
	end
	hbc:Disconnect()
	return done
end

local function logHud(tag)
	local n = 0
	for _, g in ipairs(texts(false)) do
		if g:GetFullName():find("deviceinset", 1, true) then
			n = n + 1
			if n <= 8 then log(("HUD[%s] %s"):format(tag, clean(g.Text):sub(1, 80))) end
		end
	end
end

local function doDance2(o)
	local _, hum = hrpOf()
	if not hum then return false end
	cancelEmote()
	task.wait(0.4)
	logHud("dance start")
	log("DANCE " .. o.secs .. "s")
	local methods = {
		function() return hum:PlayEmote("dance") end,
		function() return sendChat("/e dance") end,
		function() return sendChat("/e dance2") end,
		function() return sendChat("/e dance3") end,
	}
	local counted = false
	for i, f in ipairs(methods) do
		pcall(f)
		local a
		for _ = 1, 6 do
			task.wait(1)
			touch(30)
			a = hudProgress("dance")
			if a == nil or a > 0 then break end
		end
		log(("DANCE method %d | hud=%s"):format(i, tostring(a)))
		if a == nil or a > 0 then
			counted = true
			break
		end
		cancelEmote()
		task.wait(0.4)
	end
	local t0 = os.clock()
	while running and os.clock() - t0 < o.secs + 6 do
		touch(30)
		local a, b = hudProgress("dance")
		if a and b and a >= b then break end
		task.wait(1)
	end
	logHud("dance end")
	stopEmote()
	exitEmote()
	stopEmote()
	return counted
end

-- มีพื้นอยู่ข้างหน้าไหม (กันเดินตกหน้าผา / ลงน้ำลึก)
local function groundAhead(h, dir)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { lp.Character }
	rp.IgnoreWater = false -- นับน้ำเป็น "ไม่มีพื้น"
	local p = h.Position + dir * 7
	local hit = workspace:Raycast(p + Vector3.new(0, 4, 0), Vector3.new(0, -20, 0), rp)
	return hit ~= nil and hit.Material ~= Enum.Material.Water
		and math.abs(hit.Position.Y - (h.Position.Y - 3)) < 6
end

local function doWalk2(o)
	local hrp, hum = hrpOf()
	if not hrp or not hum then return false end
	local char = lp.Character
	cancelEmote()
	logHud("walk start")
	local dir, len = openLane(hrp)
	local leg = math.clamp(len / 16, 1.2, 3)
	local goal = (o.n or 50) * 1.1 + 5
	local flip, done, sawHud, missing = 1, false, false, 0
	local walked, last = 0, hrp.Position
	local t0 = os.clock()
	local flipAt, chkAt, hudAt, logAt = t0 + leg, t0 + 1.2, t0 + 1, t0 + 8
	local ledgeAt = t0 + 0.4
	local lastDry = hrp.CFrame
	local chkPos, lastHud, lastMove = hrp.Position, nil, t0
	pcall(function() RunService:UnbindFromRenderStep("GA_walk") end)
	RunService:BindToRenderStep("GA_walk", Enum.RenderPriority.Last.Value, function()
		pcall(function() hum:Move(dir * flip, false) end)
	end)
	local ok, err = pcall(function()
		while running and not done and os.clock() - t0 < 300 do
			task.wait(0.1)
			touch(30)
			-- ตายระหว่างเดิน: เลิกทันที ห้ามนับว่าเควสเสร็จ
			if lp.Character ~= char or hum.Health <= 0 then
				lastDied = true
				log("NOTE: died while walking - will redo the quest after respawn")
				break
			end
			local h = hrpOf()
			if not h then break end
			local now = os.clock()
			local d = (h.Position - last).Magnitude
			if d < 8 then walked = walked + d end
			last = h.Position
			-- ลงน้ำ/ว่ายอยู่: วาปกลับจุดบกล่าสุด แล้วเดินกลับทิศ
			if hum:GetState() == Enum.HumanoidStateType.Swimming or hum.FloorMaterial == Enum.Material.Water then
				h.CFrame = lastDry + Vector3.new(0, 3, 0)
				h.AssemblyLinearVelocity = Vector3.zero
				flip = -flip
				flipAt, ledgeAt = now + leg, now + 1
				log("NOTE: walked into water - back to land")
			elseif hum.FloorMaterial ~= Enum.Material.Air then
				lastDry = h.CFrame
			end
			if now > ledgeAt and not groundAhead(h, dir * flip) then
				flip = -flip
				flipAt = now + leg
				ledgeAt = now + 0.6
			end
			if now > chkAt then
				if (h.Position - chkPos).Magnitude < 1 then
					dir = CFrame.Angles(0, math.rad(90), 0):VectorToWorldSpace(dir)
				end
				chkPos, chkAt = h.Position, now + 1.2
			end
			if now > flipAt then
				flip, flipAt = -flip, now + leg
			end
			if now > logAt then
				logAt = now + 8
				logHud(("walk %.0f studs"):format(walked))
			end
			if now > hudAt then
				hudAt = now + 1
				local pa, pb = hudProgress("walk")
				if pa then
					sawHud, missing = true, 0
					if pa ~= lastHud then lastHud, lastMove = pa, now end
					if pa >= pb then done = true end
					if not done and now - lastMove > 25 and walked > 60 then
						log(("NOTE: walk hud stuck at %d/%d after %.0f studs - send this report"):format(pa, pb, walked))
						break
					end
				elseif sawHud then
					missing = missing + 1
					if missing >= 2 and walked > 20 then done = true end
				elseif walked >= goal then
					done = true
				end
			end
		end
	end)
	RunService:UnbindFromRenderStep("GA_walk")
	pcall(function() hum:Move(Vector3.zero, false) end)
	if not ok then log("ERR walk " .. tostring(err)) end
	return done
end

local function perform(o)
	local char = lp.Character
	local _, hum = hrpOf()
	local res = false
	if o.kind == "chat" then res = doChat(o)
	elseif o.kind == "dance" then res = doDance2(o)
	elseif o.kind == "jump" then res = doJump(o)
	elseif o.kind == "walk" then res = doWalk2(o)
	end
	-- ตายระหว่างทำ (ไม่ว่าเควสชนิดไหน) = ไม่นับว่าเสร็จ ห้ามเซ็ต claim
	if lp.Character ~= char or (hum and hum.Health <= 0) then
		lastDied = true
		log("NOTE: died during " .. o.kind .. " - not counted, will redo after respawn")
		return false
	end
	return res
end

---------------------------------------------------------------- per-goblin flow
local function pickByRemote(m)
	local cfg = dialogCfg[m]
	local node = cfg and cfg.dialog and cfg.dialog[1]
	local ch = node and node.choices
	if not (DI and ch) then return false end
	local order = levelOrder()
	for _, w in ipairs(order) do
		for i, c in ipairs(ch) do
			if c.callback and clean(tostring(c.arg or c.text)):lower():find(w, 1, true) then
				log(("PICK %s -> DialogInteract(1, %d)"):format(w, i))
				local ok, res = pcall(function() return DI:InvokeServer(1, i) end)
				log("DialogInteract returned " .. tostring(ok) .. " " .. fmt(res))
				return ok
			end
		end
	end
	return false
end

local function objFromCfg(m)
	local cfg = dialogCfg[m]
	local msg = cfg and cfg.initial_data and cfg.initial_data.msg
	if not msg then return nil end
	local o = parse(msg)
	if o then return o, clean(msg) end
end

local function turnIn(m)
	if not m.Parent then
		log("NOTE: goblin left before turn-in")
		return false
	end
	setStatus("claim: " .. m.Name)
	if not tpTo(m) then return false end
	if not openDialog(m) then return false end
	local st = state[m]
	if st then st.pos = m:GetPivot().Position end
	advance(5, false)
	softLeave(m)
	log("DONE " .. m.Name)
	return true
end

-- multiple-choice question (guess ...): reopening the dialog gives cs_start = "choicesN" and
-- initial_data = { msg, choice1..N }. The answer is DialogInteract(8 + N, picked index).
-- true = answered | false = could not open the dialog | nil = not a multiple-choice dialog
local function doChoice(m, alreadyOpen)
	local tried = {}
	for round = 1, 4 do
		if not (round == 1 and alreadyOpen) and not openDialog(m) then return false end
		local cfg = dialogCfg[m]
		local cs = cfg and tostring(cfg.cs_start) or ""
		local n = tonumber(cs:match("^choices(%d+)$"))
		local d = cfg and cfg.initial_data or {}
		if not DI then return false end
		if cs == "started2" then -- มีปุ่มเดียวให้กด (insult / say-this)
			log("ANSWER " .. clean(tostring(d.msg)) .. " -> " .. clean(tostring(d.choice)))
			local ok, res = pcall(function() return DI:InvokeServer(3, 1) end)
			log("DialogInteract returned " .. tostring(ok) .. " " .. fmt(res))
			softLeave(m)
			return ok
		end
		if not n then
			if round == 1 then
				log("NOTE: no multiple-choice dialog (cs_start=" .. cs .. ")")
				return nil
			end
			return true
		end
		local pool = {}
		for i = 1, n do
			if not tried[i] then pool[#pool + 1] = i end
		end
		if #pool == 0 then return true end
		local pick = pool[math.random(#pool)] -- สุ่มตอบ
		tried[pick] = true
		log(("ANSWER %s -> #%d %s"):format(clean(tostring(d.msg)), pick, clean(tostring(d["choice" .. pick]))))
		local ok, res = pcall(function() return DI:InvokeServer(8 + n, pick) end)
		log("DialogInteract returned " .. tostring(ok) .. " " .. fmt(res))
		softLeave(m)
		if not ok then return false end
		if not tostring(res):lower():find("wrong", 1, true) then return true end
	end
	return true
end

local function handleGoblin(m, s, phase)
	if s.claim then return turnIn(m) end
	if phase == "do" and s.obj then -- เควสรับไว้แล้ว: ทำให้เสร็จ แล้วค่อยกลับไปส่ง
		setStatus(s.obj.kind .. ": " .. m.Name)
		if not perform(s.obj) then
			log("NOTE: objective did not finish")
			return false
		end
		s.claim = true
		return turnIn(m)
	end
	-- มีเควสตัวอื่นที่รับค้างไว้ไหม: ถ้ามี ห้ามอ่านเควสจาก HUD (จะไปหยิบของตัวอื่นมา)
	local others = false
	for _, g in ipairs(goblins()) do
		local o = state[g]
		if g ~= m and o and o.accepted and not o.done then others = true break end
	end

	setStatus("quest: " .. m.Name)
	if not tpTo(m) then return false end
	if not openDialog(m) then return false end

	local obj, raw
	local cfg0 = dialogCfg[m]
	if not (cfg0 and cfg0.cs_start) then
		local ch = cfg0 and cfg0.dialog and cfg0.dialog[1] and cfg0.dialog[1].choices
		if ch then
			local lvs, ok = {}, false
			for _, c in ipairs(ch) do
				if c.callback and c.arg then
					local lv = clean(tostring(c.arg)):lower()
					lvs[#lvs + 1] = lv
					if CFG.levels[lv] then ok = true end
				end
			end
			local key = m.Name:lower()
			if #lvs == 1 and diffByName[key] ~= lvs[1] then
				diffByName[key] = lvs[1]
				log("LEARN " .. m.Name .. " = " .. lvs[1])
			end
			if #lvs > 0 and not ok then
				log("SKIP level " .. table.concat(lvs, "/") .. " (not selected) on " .. m.Name)
				closeDialog()
				return true
			end
		end
	end
	if cfg0 and cfg0.cs_start and cfg0.initial_data then
		obj, raw = objFromCfg(m) -- quest already running
		if not obj and tostring(cfg0.cs_start):find("^choices%d") then
			obj, raw = { kind = "skip", why = "guess" }, clean(tostring(cfg0.initial_data.msg))
		end
		if not obj and not others then obj, raw = activeObjective(true) end
		if obj then log("RESUME " .. raw) end
	elseif pickByRemote(m) then
		obj, raw = advance(5, true)
		if not obj and openDialog(m) then obj, raw = objFromCfg(m) end
	else
		local btn, label = pickDifficulty()
		if btn then
			lastClick[btn] = { t = label, at = os.clock() }
			log(('PICK "%s" via %s'):format(label:sub(1, 60), press(btn)))
			obj, raw = advance(5, true)
		elseif CFG.resumeActive and not others and hasGoblinQuest() then
			obj, raw = activeObjective()
			if obj then log("RESUME " .. raw) end
		end
	end

	if not obj then
		local c = dialogCfg[m]
		local cs = c and tostring(c.cs_start) or ""
		if cs:find("^choices%d") or cs == "started2" then
			obj = { kind = "skip", why = "guess" }
			raw = clean(tostring(c.initial_data and c.initial_data.msg))
		end
	end
	if not obj and not others then
		obj, raw = activeObjective(true) -- บรรทัดเควสบน HUD เช่น "Dance for 15 seconds (0/15)"
		if obj then log("HUD " .. raw) end
	end

	if not obj and s.obj then -- เควสที่เคยอ่านไว้ (ตายแล้ววนกลับมา / ข้อความ resume อ่านไม่ออก)
		obj, raw = s.obj, "(remembered) " .. tostring(s.obj.kind)
		log("RESUME " .. raw)
	end
	if not obj then
		log("NOTE: no quest/objective found on " .. m.Name
			.. " - open the dialog, press Dump UI, then send the report")
		return false
	end
	log("OBJECTIVE " .. raw .. " -> " .. obj.kind)
	if obj.kind ~= "skip" then s.obj = obj end
	if obj.kind == "skip" and (obj.why == "guess" or obj.why == "insult") then
		local c = dialogCfg[m]
		local cs = c and tostring(c.cs_start) or ""
		local r = doChoice(m, cs:find("^choices%d") ~= nil or cs == "started2")
		if r == true then
			s.claim = true
			pcall(turnIn, m) -- dialog "finish" ให้ของรางวัล
			return true
		end
		if r ~= nil then return r end
	end
	softLeave(m)
	if obj.kind == "skip" then
		log("SKIP (do it manually): " .. obj.why)
		return true
	end
	if phase == "accept" then -- รับอย่างเดียว ยังไม่ทำ
		s.accepted = true
		s.acceptAt = s.acceptAt or os.clock()
		log(("ACCEPTED %s -> %s"):format(m.Name, obj.kind))
		return "accepted"
	end

	setStatus(obj.kind .. ": " .. m.Name)
	if not perform(obj) then
		log("NOTE: objective did not finish")
		return false
	end
	s.claim = true
	return turnIn(m)
end

---------------------------------------------------------------- UI
local function dumpUI()
	log("---- UI DUMP (visible text) ----")
	local n = 0
	for _, g in ipairs(texts(false)) do
		if not badUI(g) and not g:GetFullName():find("announcements", 1, true) then
			n = n + 1
			if n > 120 then break end
			log(('UI %s | "%s" | button=%s'):format(g:GetFullName(), clean(g.Text):sub(1, 50),
				tostring(clickTarget(g) ~= nil)))
		end
	end
end

local gui = Instance.new("ScreenGui")
gui.Name = "GoblinAuto"
gui.ResetOnSpawn = false
gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")

local function addButton(text, y, fn, x)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0, 140, 0, 38)
	b.AnchorPoint = Vector2.new(1, 0)
	b.Position = UDim2.new(1, -(x or 10), 0, y)
	b.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Text = text
	b.Parent = gui
	b.Activated:Connect(function() fn(b) end)
	return b
end

addButton("Auto: ON", 110, function(b)
	enabled = not enabled
	b.Text = enabled and "Auto: ON" or "Auto: OFF"
end)
addButton("Copy report", 156, function()
	local txt = table.concat(lines, "\n")
	if setclipboard then setclipboard(txt) else warn("executor has no setclipboard") end
end)
addButton("Clear", 202, function()
	table.clear(lines)
	table.clear(seen)
end)
addButton("Dump UI", 248, function() dumpUI() end)
addButton("Fix now", 386, function()
	if recoverNow then task.spawn(recoverNow, "manual (Fix now button)") end
end)

-- คอลัมน์ 2: เลือกระดับเควส
local function paint(b, on)
	b.BackgroundColor3 = on and Color3.fromRGB(30, 120, 60) or Color3.fromRGB(25, 25, 30)
end
for i, l in ipairs(DIFF) do
	local function label() return (CFG.levels[l] and "[x] " or "[ ] ") .. l end
	local btn = addButton(label(), 110 + (i - 1) * 46, function(b)
		CFG.levels[l] = not CFG.levels[l]
		b.Text = label()
		paint(b, CFG.levels[l])
	end, 156)
	paint(btn, CFG.levels[l])
end
local talkBtn = addButton(CFG.talk and "Talk: ON" or "Talk: OFF", 340, function(b)
	CFG.talk = not CFG.talk
	b.Text = CFG.talk and "Talk: ON" or "Talk: OFF"
	paint(b, CFG.talk)
end, 156)
paint(talkBtn, CFG.talk)
local warpBtn = addButton(CFG.warpOnSpawn and "Warp on spawn: ON" or "Warp on spawn: OFF", 386, function(b)
	CFG.warpOnSpawn = not CFG.warpOnSpawn
	b.Text = CFG.warpOnSpawn and "Warp on spawn: ON" or "Warp on spawn: OFF"
	paint(b, CFG.warpOnSpawn)
end, 156)
paint(warpBtn, CFG.warpOnSpawn)
local espBtn = addButton(CFG.esp and "ESP: ON" or "ESP: OFF", 432, function(b)
	CFG.esp = not CFG.esp
	b.Text = CFG.esp and "ESP: ON" or "ESP: OFF"
	paint(b, CFG.esp)
end, 156)
paint(espBtn, CFG.esp)

-- คอลัมน์ 3: วาปไปเกาะ (goblin โหลดแล้ว Auto จะหยิบเอง)
local function goTo(cf)
	local hrp = hrpOf()
	if not hrp then return false end
	local p = cf.Position
	pcall(function() lp:RequestStreamAroundAsync(p) end)
	hrp.Anchored = true
	hrp.CFrame = CFrame.new(p + Vector3.new(0, 60, 0))
	hrp.AssemblyLinearVelocity = Vector3.zero
	task.wait(1.5)
	-- หาพื้นใกล้ความสูงที่เซฟไว้ (p.Y) เท่านั้น ข้ามพาร์ทมองไม่เห็น/ไม่ชน (โซน, ฮิตบ็อกซ์, ท้องฟ้า)
	-- เอาจุดที่ใกล้ p.Y ที่สุด ไม่งั้นจะไปยืนบนพาร์ทลอยฟ้า
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.RespectCanCollide = true
	local ground
	for _ = 1, 8 do
		local skip, best = { lp.Character }, nil
		for _ = 1, 12 do
			rp.FilterDescendantsInstances = skip
			local hit = workspace:Raycast(p + Vector3.new(0, 80, 0), Vector3.new(0, -300, 0), rp)
			if not hit then break end
			local inst = hit.Instance
			if inst:IsA("Terrain") then -- ดินหรือผิวน้ำ: ใต้นี้ไม่ต้องหาต่อ
				if not best or math.abs(hit.Position.Y - p.Y) < math.abs(best.Y - p.Y) then best = hit.Position end
				break
			end
			if inst.Transparency < 0.95
				and (not best or math.abs(hit.Position.Y - p.Y) < math.abs(best.Y - p.Y)) then
				best = hit.Position
			end
			skip[#skip + 1] = inst
		end
		if best then ground = best break end
		task.wait(0.5)
	end
	hrp.CFrame = CFrame.new(ground and (ground + Vector3.new(0, 5, 0)) or (p + Vector3.new(0, 8, 0)))
	hrp.Anchored = false
	return true
end

local lastIsl
-- กดปุ่มเกาะที่วาปไม่ได้ -> ไปยืนบนเกาะนั้นเอง -> กด Mark spot : เซฟพิกัด + log บรรทัดให้ก๊อปไปใส่ CFG.islandPos
local function markSpot()
	local hrp = hrpOf()
	if not (hrp and lastIsl) then
		setStatus("press an island first")
		return
	end
	local p = hrp.Position
	CFG.islandPos[lastIsl[1]] = p
	log(('SPOT SAVED ["%s"] = Vector3.new(%.0f, %.0f, %.0f),'):format(lastIsl[1], p.X, p.Y, p.Z))
	setStatus("saved " .. lastIsl[1])
end

local function goIsland(isl)
	lastIsl = isl
	local cf = findIsland(isl)
	if not cf then
		log("NOTE: island not found: " .. isl[1] .. " - press Dump islands, or fill CFG.islandPos")
		setStatus("no spot: " .. isl[1])
		return
	end
	log("TP island " .. isl[1])
	setStatus("tp: " .. isl[1])
	goTo(cf)
	setStatus("idle")
end

local function dumpIslands()
	log("---- ISLAND DUMP ----")
	for _, r in ipairs(islandRoots()) do
		log("ROOT " .. r:GetFullName())
		for i, o in ipairs(r:GetChildren()) do
			if i > 80 then break end
			local p = posOf(o)
			log(("  %s | %s"):format(o.Name, p and ("%.0f, %.0f, %.0f"):format(p.X, p.Y, p.Z) or "no pos"))
		end
	end
end

local islandFrame = Instance.new("ScrollingFrame")
islandFrame.Size = UDim2.new(0, 150, 0, 280)
islandFrame.AnchorPoint = Vector2.new(1, 0)
islandFrame.Position = UDim2.new(1, -302, 0, 110)
islandFrame.BackgroundColor3 = Color3.new(0, 0, 0)
islandFrame.BackgroundTransparency = 0.5
islandFrame.ScrollBarThickness = 4
islandFrame.CanvasSize = UDim2.new(0, 0, 0, (#ISLANDS + 2) * 40 + 4)
islandFrame.Parent = gui
for i = 1, #ISLANDS + 2 do
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, -10, 0, 36)
	b.Position = UDim2.new(0, 4, 0, 4 + (i - 1) * 40)
	b.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
	b.TextColor3 = Color3.new(1, 1, 1)
	b.TextSize = 14
	b.Parent = islandFrame
	if ISLANDS[i] then
		b.Text = ISLANDS[i][1]
		b.Activated:Connect(function() goIsland(ISLANDS[i]) end)
	elseif i == #ISLANDS + 1 then
		b.Text = "Dump islands"
		b.Activated:Connect(dumpIslands)
	else
		b.Text = "Mark spot"
		b.Activated:Connect(markSpot)
	end
end

statusLbl = Instance.new("TextLabel")
statusLbl.Size = UDim2.new(0, 140, 0, 36)
statusLbl.AnchorPoint = Vector2.new(1, 0)
statusLbl.Position = UDim2.new(1, -10, 0, 340)
statusLbl.BackgroundColor3 = Color3.new(0, 0, 0)
statusLbl.BackgroundTransparency = 0.4
statusLbl.TextColor3 = Color3.new(1, 1, 1)
statusLbl.TextSize = 12
statusLbl.TextWrapped = true
statusLbl.Text = "idle"
statusLbl.Parent = gui

---------------------------------------------------------------- ESP
do
	local esp = {} -- goblin model -> { hl, bb, lbl }

	local function drop(m)
		local e = esp[m]
		if not e then return end
		esp[m] = nil
		pcall(function() e.hl:Destroy() end)
		pcall(function() e.bb:Destroy() end)
	end

	local function add(m)
		local hl = Instance.new("Highlight")
		hl.Adornee = m
		hl.FillColor = Color3.fromRGB(80, 255, 80)
		hl.FillTransparency = 0.4
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.Parent = gui
		local bb = Instance.new("BillboardGui")
		bb.AlwaysOnTop = true
		bb.Size = UDim2.fromOffset(180, 24)
		bb.StudsOffset = Vector3.new(0, 6, 0)
		bb.Parent = gui
		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.BackgroundTransparency = 1
		lbl.TextColor3 = Color3.new(1, 1, 1)
		lbl.TextStrokeTransparency = 0
		lbl.Font = Enum.Font.GothamBold
		lbl.TextSize = 14
		lbl.Parent = bb
		esp[m] = { hl = hl, bb = bb, lbl = lbl }
	end

	task.spawn(function()
		while running do
			pcall(function()
				local live = {}
				if CFG.esp then
					local hrp = hrpOf()
					for _, m in ipairs(goblins()) do
						live[m] = true
						if not esp[m] then add(m) end
						local e = esp[m]
						if not (e.bb.Adornee and e.bb.Adornee:IsDescendantOf(workspace)) then
							e.bb.Adornee = m:FindFirstChildWhichIsA("BasePart", true)
						end
						if hrp then
							local d = (m:GetPivot().Position - hrp.Position).Magnitude
							e.lbl.Text = ("%s %dm"):format(m.Name, math.floor(d))
						end
					end
				end
				for m in pairs(esp) do
					if not live[m] then drop(m) end
				end
			end)
			task.wait(0.3)
		end
		for m in pairs(esp) do drop(m) end
	end)
end

genv.GoblinAutoStop = function()
	running = false
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	local h = hrpOf()
	if h then pcall(function() h.Anchored = false end) end
	gui:Destroy()
end

---------------------------------------------------------------- main loop + self-heal
local loopThread
local heal = { fails = 0, lastFix = 0 } -- consecutive repairs that did not lead to progress

local function activity() lastWork = os.clock() end

-- ปลดทุกอย่างที่อาจค้าง: anchor, bind เดิน, emote, dialog, สถานะตัวละคร
local function unstick(why)
	log("HEAL unstick: " .. why)
	pcall(function() RunService:UnbindFromRenderStep("GA_walk") end)
	local h, hum = hrpOf()
	if h then pcall(function() h.Anchored = false end) end
	if hum then
		pcall(function() hum:Move(Vector3.zero, false) end)
		pcall(function() hum.PlatformStand = false end)
		pcall(function() hum.Sit = false end)
	end
	dialogRoot = nil
	pcall(closeDialog)
	pcall(cancelEmote)
end

local function waitAlive(maxT)
	local t0 = os.clock()
	while os.clock() - t0 < (maxT or 20) do
		task.wait(0.5)
		touch(60)
		local h, hum = hrpOf()
		if h and hum and hum.Health > 0 then
			task.wait(2.5) -- ให้ตัวละครโหลดนิ่งก่อน
			return true
		end
	end
	return false
end

local function refundTries()
	for _, st in pairs(state) do
		if not st.done then
			st.tries = 0
			st.cool = nil
		end
	end
end

-- stand on ground that is known to exist (Moosewood) when stuck in geometry / out of the world
local function safeTeleport()
	local p = CFG.islandPos["Moosewood"]
	if not p then return end
	pcall(goTo, CFrame.new(p))
	local h = hrpOf()
	if h then pcall(function() h.Anchored = false end) end
end

-- goblin failed this try; after MAXTRY tries it rests for a while (longer each time)
local function noteFail(s)
	s.at = os.clock()
	if s.tries >= MAXTRY then
		s.strikes = (s.strikes or 0) + 1
		s.cool = math.min(CFG.failCool * 2 ^ (s.strikes - 1), 300)
		log(("GIVE UP on this goblin for %ds (strike %d) - going to look for others"):format(
			math.floor(s.cool), s.strikes))
	end
end

-- วาร์ปไปเกาะที่แจ้งเตือนบอก แล้วรอให้ goblin stream เข้า (ใช้ goTo ของส่วน UI)
local function warpToSpawn(pw)
	setStatus("warp: " .. pw.name)
	log("WARP -> " .. pw.name)
	if not goTo(pw.cf) then return false end
	local t0 = os.clock()
	while running and os.clock() - t0 < CFG.arriveWait do
		task.wait(0.15)
		touch(60)
		if #fresh() > 0 then return true end
	end
	log("WARP: no goblins loaded near " .. pw.name)
	return false
end

-- ตายแล้ว: เควสที่รับค้างไว้ (ยังไม่ได้ส่ง) ให้กลับไปคุยกับ goblin ใหม่ทุกตัว เพราะเควสอาจถูกรีเซ็ต
-- (acceptAt เดิมยังอยู่ ลำดับ "รับมานานสุดก่อน" ไม่เปลี่ยน)
local function reaccept()
	for _, st in pairs(state) do
		if st.accepted and not st.claim and not st.done then st.accepted = false end
	end
end

local function startCool(s, name, why)
	s.coolStrikes = (s.coolStrikes or 0) + 1
	local secs = math.min(CFG.acceptCool * 2 ^ (s.coolStrikes - 1), 300)
	s.coolUntil = os.clock() + secs
	log(("COOLDOWN %s %ds (%s) - going to other goblins"):format(name, math.floor(secs), why))
	pcall(closeDialog)
end

-- รับเควสไม่สำเร็จ 1 ครั้ง: ครบ CFG.acceptFailMax -> พักตัวนี้
local function acceptFailed(s, name, why)
	s.accFails = (s.accFails or 0) + 1
	log(("ACCEPT FAIL %s %d/%d (%s)"):format(name, s.accFails, CFG.acceptFailMax, why))
	if s.accFails >= CFG.acceptFailMax then
		s.accFails = 0
		startCool(s, name, "accept failed " .. CFG.acceptFailMax .. "x")
	end
end

-- รัน handleGoblin 1 ตัว + จัดการผล phase = "accept" | "do" | nil
local function runOne(m, s, phase)
	local h0, hum0 = hrpOf()
	if not h0 or not hum0 or hum0.Health <= 0 then waitAlive(25) return false end -- ยังตายอยู่: รอเกิดก่อน
	s.tries = s.tries + 1
	s.at = os.clock()
	working = true
	activity()
	lastDied = false
	touch(90)
	local char0 = lp.Character
	local ok, res = pcall(handleGoblin, m, s, phase)
	working = false
	activity()
	local acceptStage = phase == "accept" or (phase == nil and not s.obj) -- พลาดก่อนอ่านเควสได้ = พลาดตอนรับ
	local died = lastDied or lp.Character ~= char0 or (hum0 ~= nil and hum0.Health <= 0)
	if died then
		lastDied = false
		s.tries = math.max(0, s.tries - 1) -- ตายไม่นับเป็นความพยายามที่เสีย
		reaccept()
		s.deaths = (s.deaths or 0) + 1
		log(("DIED (%d) on %s - will re-talk to the goblins after respawn"):format(s.deaths, m.Name))
		if s.deaths >= CFG.deathCoolAfter then
			s.deaths = 0
			startCool(s, m.Name, "died " .. CFG.deathCoolAfter .. "x here")
		end
		waitAlive(25)
	elseif not ok then
		log("ERR " .. tostring(res))
		unstick("error in handleGoblin")
		if acceptStage then
			s.tries = math.max(0, s.tries - 1)
			acceptFailed(s, m.Name, "error")
		else
			noteFail(s)
		end
	elseif res == "accepted" then
		s.tries = 0 -- รับสำเร็จ = ไม่นับเป็นพยายามที่เสีย
		s.accFails, s.coolUntil = 0, nil
		s.at = os.clock()
		heal.fails = 0
	elseif res then
		s.done = true -- done OR skipped (a quest we cannot do): either way, move on
		s.at = os.clock()
		s.deaths, s.coolStrikes = 0, 0
		heal.fails = 0
	elseif acceptStage then
		s.tries = math.max(0, s.tries - 1) -- นับด้วย accFails แทน
		acceptFailed(s, m.Name, "talk/accept failed")
	else
		noteFail(s)
	end
	return ok and res
end

local function tickOnce()
	local list = fresh()
	-- เพิ่งมีแจ้งเตือน spawn และไม่มี goblin ค้างให้ทำแล้ว -> ไปเกาะนั้น
	if #list == 0 and pendingWarp then
		local pw = pendingWarp
		pendingWarp = nil
		if os.clock() - pw.at < 120 and CFG.talk and #levelOrder() > 0 then
			working = true
			activity()
			touch(90)
			local ok, err = pcall(warpToSpawn, pw)
			working = false
			activity()
			if not ok then log("ERR warp " .. tostring(err)) end
			local h = hrpOf()
			if h then h.Anchored = false end
			list = fresh()
		end
	end

	local hrp = hrpOf()
	if hrp then
		pcall(table.sort, list, function(x, y)
			return (x:GetPivot().Position - hrp.Position).Magnitude
				< (y:GetPivot().Position - hrp.Position).Magnitude
		end)
	end

	if CFG.acceptFirst then
		-- รอบ 1: รับเควสให้ครบก่อน (ตัวใกล้สุดก่อน) ยังไม่ทำ
		local acc = 0
		for _, m in ipairs(goblins()) do
			local s = state[m]
			if s and s.accepted and not s.done and s.tries < MAXTRY then acc = acc + 1 end
		end
		for _, m in ipairs(list) do
			if not running or not enabled or acc >= CFG.acceptBatch then break end
			if m.Parent then
				local okS, s = pcall(stOf, m)
				if okS and not s.done and not s.accepted and s.tries < MAXTRY then
					if runOne(m, s, "accept") == "accepted" then acc = acc + 1 end
				end
			end
		end
		-- รอบ 2: ทำเควสที่รับไว้ เรียงจากรับมานานสุด -> ใหม่สุด (ทำเสร็จ -> กลับไปส่ง -> ตัวถัดไป)
		local queue = {}
		for _, m in ipairs(goblins()) do
			local okS, s = pcall(stOf, m)
			if okS and s.accepted and s.obj and not s.done and s.tries < MAXTRY then
				queue[#queue + 1] = m
			end
		end
		table.sort(queue, function(x, y) return state[x].acceptAt < state[y].acceptAt end)
		for _, m in ipairs(queue) do
			if not running or not enabled then break end
			local s = state[m]
			if m.Parent and s and s.accepted and not s.done and s.tries < MAXTRY then
				runOne(m, s, "do")
			end
		end
	else
		for _, m in ipairs(list) do -- แบบเดิม: ทีละตัวจนจบ
			if not running or not enabled then break end
			if m.Parent then
				local okS, s = pcall(stOf, m)
				if okS and not s.done and s.tries < MAXTRY then runOne(m, s, nil) end
			end
		end
	end
	setStatus("idle")
end

local function startLoop()
	if loopThread then pcall(task.cancel, loopThread) end
	touch(60)
	working = false
	activity()
	loopThread = task.spawn(function()
		while running do
			local h, hum = hrpOf()
			if enabled and h and hum and hum.Health > 0 then
				local ok, err = pcall(tickOnce)
				if not ok then
					log("ERR loop " .. tostring(err))
					working = false
					unstick("loop error")
				end
			end
			task.wait(CFG.scanDelay)
		end
	end)
end

-- full repair, escalating: restart loop -> + teleport to safe ground -> + respawn character
local function recover(why)
	local now = os.clock()
	if now - heal.lastFix > 300 then heal.fails = 0 end
	heal.lastFix = now
	heal.fails = heal.fails + 1
	log(("HEAL #%d: %s"):format(heal.fails, why))
	if loopThread then pcall(task.cancel, loopThread) end
	working = false
	unstick(why)
	refundTries()
	if heal.fails >= 2 then pcall(safeTeleport) end
	if CFG.hardResetAfter > 0 and heal.fails >= CFG.hardResetAfter then
		heal.fails = 0
		log("HEAL hard reset: respawning the character")
		local _, hum = hrpOf()
		if hum then pcall(function() hum.Health = 0 end) end
		waitAlive(30)
	end
	startLoop()
end
recoverNow = recover

conns[#conns + 1] = lp.CharacterAdded:Connect(function()
	dialogRoot = nil
	task.delay(3, function()
		if running and not working then pcall(unstick, "respawned") end
	end)
end)

startLoop()

-- supervisor: runs on its own thread, so it still works when the main loop is hung or dead
task.spawn(function()
	local anchoredSince, seatedSince
	while running do
		task.wait(2)
		if CFG.watchdog and enabled then
			local ok, err = pcall(function()
				local now = os.clock()

				-- 1) loop thread is dead
				if loopThread ~= nil and coroutine.status(loopThread) == "dead" then
					recover("loop thread died")
					return
				end

				-- no character / dead: the game is respawning us, that is not a hang
				local h, hum = hrpOf()
				if not h or not hum or hum.Health <= 0 then
					touch(60)
					anchoredSince, seatedSince = nil, nil
					return
				end

				-- 2) loop is alive but has not reported in for too long
				if now - wd.beat > wd.limit then
					recover(("loop hung %ds at: %s"):format(math.floor(now - wd.beat),
						statusLbl and statusLbl.Text or "?"))
					return
				end

				-- 3) fell out of the world
				if h.Position.Y < -50 then
					recover("fell out of the world")
					return
				end

				-- 4) frozen / sitting / ragdolled for too long
				if h.Anchored then
					anchoredSince = anchoredSince or now
					if now - anchoredSince > 15 then
						h.Anchored = false
						anchoredSince = nil
						log("HEAL: character was frozen (anchored) for 15s -> released")
					end
				else
					anchoredSince = nil
				end
				if hum.PlatformStand or hum.Sit then
					seatedSince = seatedSince or now
					if now - seatedSince > 6 then
						hum.PlatformStand = false
						hum.Sit = false
						hum.Jump = true
						seatedSince = nil
						log("HEAL: character was sitting / ragdolled -> stood up")
					end
				else
					seatedSince = nil
				end

			end)
			if not ok then log("ERR supervisor " .. tostring(err)) end
		end
	end
end)


do
	local qn = {}
	for _, r in ipairs(net and net:GetChildren() or {}) do
		if r.Name:find("QuestTrigger", 1, true) then qn[#qn + 1] = r.Name end
	end
	log("QUEST REMOTES: " .. table.concat(qn, ", "))
end
do
	local names = {}
	for _, root in ipairs({ RS:FindFirstChild("events"), net }) do
		if root then
			for _, r in ipairs(root:GetChildren()) do
				if r.Name:lower():find("emote", 1, true) then names[#names + 1] = r:GetFullName() end
			end
		end
	end
	log("EMOTE REMOTES: " .. table.concat(names, ", "))
end
---------------------------------------------------------------- spawn notification -> pendingWarp (พิกัดเกาะ + ค้นหา = ของ goblin_8)
do
	-- findCoords ของ goblin_8: ชื่อตรง -> ชื่อใกล้เคียง -> ค้นชื่อใน world.map (จำผลไว้) ใช้ตาราง CFG.islandPos
	local function findCoords(name)
		if CFG.islandPos[name] then return CFG.islandPos[name] end
		local ln = name:lower()
		for k, v in pairs(CFG.islandPos) do
			local lk = k:lower()
			if lk:find(ln, 1, true) or ln:find(lk, 1, true) then return v end
		end
		-- เกาะที่ไม่มีใน CFG.islandPos แต่มีในปุ่มวาป (ISLANDS): ใช้ findIsland ตัวเดียวกับปุ่ม
		for _, isl in ipairs(ISLANDS) do
			local hit = #ln >= 4 and (ln:find(isl[1]:lower(), 1, true) ~= nil
				or isl[1]:lower():find(ln, 1, true) ~= nil)
			for i = 2, #isl do
				if ln:find(isl[i], 1, true) then hit = true end
			end
			if hit then
				local okI, cf = pcall(findIsland, isl)
				if okI and cf then
					CFG.islandPos[name] = cf.Position
					return cf.Position
				end
			end
		end
		local ok, res = pcall(function()
			local root = (workspace:FindFirstChild("world") and workspace.world:FindFirstChild("map")) or workspace
			for _, d in ipairs(root:GetDescendants()) do
				if (d:IsA("Model") or d:IsA("BasePart")) and d.Name:lower() == ln then
					return d:GetPivot().Position
				end
			end
		end)
		if ok and res then CFG.islandPos[name] = res return res end
	end

	local PHRASE = "goblins have spawned at"
	local lastName, lastAt = nil, 0

	local function onSpawnText(text)
		if not running then return end
		text = tostring(text):gsub("<[^>]+>", "")
		local name = text:match("[Gg]oblins have spawned at (.-)!")
			or text:match("[Gg]oblins have spawned at (.+)$")
		if not name then return end
		name = name:match("^%s*(.-)%s*$")
		if name == "" or (name == lastName and os.clock() - lastAt < 10) then return end
		lastName, lastAt = name, os.clock()
		log("SPAWN " .. name)
		if not CFG.warpOnSpawn then return end
		local p = findCoords(name)
		if not p then
			log("NOTE: no coords for '" .. name .. "' - add it to CFG.islandPos")
			return
		end
		pendingWarp = { name = name, cf = CFrame.new(p), at = os.clock() }
	end

	local function scanText(v, d)
		d = d or 0
		if typeof(v) == "string" then
			return v:lower():find(PHRASE, 1, true) and v or nil
		end
		if typeof(v) == "table" and d < 3 then
			for _, x in pairs(v) do
				local r = scanText(x, d + 1)
				if r then return r end
			end
		end
		return nil
	end

	-- ทางที่ 1: remote ใน packages.Net ที่ส่งข้อความแจ้งเตือนมา
	if net then
		for _, r in ipairs(net:GetChildren()) do
			if r:IsA("BaseRemoteEvent") then
				conns[#conns + 1] = r.OnClientEvent:Connect(function(...)
					local a = table.pack(...)
					for i = 1, a.n do
						local s = scanText(a[i])
						if s then onSpawnText(s) break end
					end
				end)
			end
		end
	end

	-- ทางที่ 2: ข้อความแจ้งเตือนที่โผล่บนจอ (สำรอง)
	local pg = lp:WaitForChild("PlayerGui")
	local function watchText(t, isNew)
		if not (t:IsA("TextLabel") or t:IsA("TextButton")) then return end
		local function chk()
			if t.Text:lower():find(PHRASE, 1, true) then onSpawnText(t.Text) end
		end
		if isNew then chk() end
		-- ไม่เก็บใน conns: label ถูกทำลายเองได้ และเก็บแล้ว table จะโตไม่หยุด
		t:GetPropertyChangedSignal("Text"):Connect(chk)
	end
	for _, d in ipairs(pg:GetDescendants()) do watchText(d, false) end
	conns[#conns + 1] = pg.DescendantAdded:Connect(function(d) watchText(d, true) end)
end

log("READY v12 | difficulty=" .. CFG.difficulty .. " | waiting for goblins")
do
	local names = {}
	for _, root in ipairs({ RS:FindFirstChild("events"), net }) do
		if root then
			for _, r in ipairs(root:GetChildren()) do
				local n = r.Name:lower()
				if n:find("goblin", 1, true) or n:find("spawn", 1, true) or n:find("haunt", 1, true) then
					names[#names + 1] = r:GetFullName()
					listen(r)
				end
			end
		end
	end
	log("SPAWN REMOTES: " .. table.concat(names, ", "))
end
