-- Fisch | Goblin Quest Bot v1 | Luau, Delta mobile
-- flow: คุยก้อบลิน(รับ) -> อ่านเควส+เป้าหมายจาก UI -> handler ตามประเภท -> คุย(ส่ง/รับรางวัล) -> วน
-- handler 1 ตัวต่อประเภท รับ target เป็นพารามิเตอร์ ไม่ hardcode ตามระดับ
-- หา goblin จาก tag เดียวกับสคริปต์ ESP (ไม่ต้องแชร์ตัวแปร) / ตอนบอททำงานให้ปิด AUTO WARP + TOUR
-- ไม่เห็น UI/ปุ่ม dialog จริง -> ใช้ keyword + log ปุ่มที่เจอ ถ้าไม่ตรงให้กด DUMP แล้วส่งผลมาปรับ

local Players = game:GetService("Players")
local CS = game:GetService("CollectionService")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local TextChatService = game:GetService("TextChatService")
local GuiService = game:GetService("GuiService")
local lp = Players.LocalPlayer
local pg = lp:WaitForChild("PlayerGui")
local Net = RS:WaitForChild("packages"):WaitForChild("Net")
local env = (getgenv and getgenv()) or _G

-- ================= CONFIG =================
local CFG = {
    TAG = "FischfrightGoblin",
    DELAY = {0.8, 2.2},            -- delay สุ่มระหว่างแต่ละ action
    BETWEEN = {2.5, 5},            -- delay สุ่มระหว่างเควส
    STALL = 30,                    -- progress ไม่ขยับกี่วิ -> ยกเลิกเควสนี้
    STALL_FISH = 300,              -- เควสตกปลารอนานกว่า
    QUEST_PATH = nil,              -- ถ้ารู้ path label เควสแล้ว เช่น "hud.safezone.quest.Desc" (เริ่มจาก PlayerGui)
    QUEST_IDS = {"PlaguedReaper-3"}, -- ใช้ตอน DUMP: ดึง RF/GetActiveQuestData มาดูโครงข้อมูล
    NPC_POS = {},                  -- ["beatrix"] = Vector3.new(x,y,z) ถ้า NPC ไม่ stream (ปุ่ม MYPOS ตอนยืนข้างเธอ)
    FISH_HOOK = nil,               -- function(on, q) เปิด/ปิด autofarm ตกปลาของนาย (หรือ getgenv().FISH_HOOK)
    USE_REMOTE_FALLBACK = true,    -- ไม่เจอปุ่ม dialog -> ยิง RF/DialogInteract(1,1) ตามที่เห็นใน log
    KW = {
        accept = {"accept", "take", "start"},
        submit = {"complete", "claim", "turn in", "turn-in", "submit", "reward", "collect", "finish"},
        cancel = {"cancel", "abandon", "reroll", "new quest", "decline"},
        insult = {"insult", "mock", "tease", "roast"},
    },
}
local KW = CFG.KW
-- =========================================

local running, alive, stuck = false, false, 0
local ui = {}
local logLines = {}
local curLbl -- label ของเควสที่กำลังทำ

local function log(...)
    local a = table.pack(...)
    local t = {}
    for i = 1, a.n do t[i] = tostring(a[i]) end
    local line = table.concat(t, " ")
    print("[GQ] " .. line)
    logLines[#logLines + 1] = line
    if #logLines > 200 then table.remove(logLines, 1) end
    if ui.status then ui.status.Text = line:sub(1, 70) end
end

local function rnd(a, b) return a + math.random() * (b - a) end
local function pause(r) task.wait(rnd(r[1], r[2])) end

local function getRoot() local c = lp.Character return c and c:FindFirstChild("HumanoidRootPart") end
local function getHum() local c = lp.Character return c and c:FindFirstChildOfClass("Humanoid") end

local function clean(s)
    return (s:gsub("<[^>]+>", ""):gsub("%s+", " "):match("^%s*(.-)%s*$"))
end

local function hasAny(low, list)
    for _, k in ipairs(list) do
        if low:find(k, 1, true) then return true end
    end
    return false
end

local function ser(v, d)
    d = d or 0
    if typeof(v) ~= "table" then return tostring(v) end
    if d >= 3 then return "{...}" end
    local t = {}
    for k, x in pairs(v) do t[#t + 1] = tostring(k) .. "=" .. ser(x, d + 1) end
    return "{" .. table.concat(t, ", ") .. "}"
end

-- ================= GUI helpers =================
local function shown(o)
    while o and o ~= pg do
        if o:IsA("GuiObject") and not o.Visible then return false end
        if o:IsA("ScreenGui") and not o.Enabled then return false end
        o = o.Parent
    end
    return true
end

local function ancestorHas(o, word)
    while o and o ~= pg do
        if o.Name:lower():find(word, 1, true) then return true end
        o = o.Parent
    end
    return false
end

local function btnText(b)
    if b:IsA("TextButton") then return clean(b.Text) end
    local l = b:FindFirstChildWhichIsA("TextLabel", true)
    return l and clean(l.Text) or ""
end

local function choices(dialogOnly)
    local t = {}
    for _, b in ipairs(pg:GetDescendants()) do
        if b:IsA("GuiButton") and b.AbsoluteSize.X > 0 and shown(b) and btnText(b) ~= "" then
            if not dialogOnly or ancestorHas(b, "dialog") then t[#t + 1] = b end
        end
    end
    return t
end

local function click(b)
    if getconnections then
        for _, sig in ipairs({b.Activated, b.MouseButton1Click}) do
            local ok, cons = pcall(getconnections, sig)
            if ok and cons and #cons > 0 then
                for _, c in ipairs(cons) do pcall(function() c:Fire() end) end
                return true
            end
        end
    end
    -- fallback: แตะจริงด้วย VirtualInputManager
    return pcall(function()
        local VIM = game:GetService("VirtualInputManager")
        local c = b.AbsolutePosition + b.AbsoluteSize / 2 + GuiService:GetGuiInset()
        VIM:SendMouseButtonEvent(c.X, c.Y, 0, true, game, 1)
        task.wait(0.05)
        VIM:SendMouseButtonEvent(c.X, c.Y, 0, false, game, 1)
    end)
end

-- ================= world helpers =================
local function pivot(o)
    local ok, cf = pcall(o.GetPivot, o)
    return ok and cf.Position or nil
end

local function promptPos(pp)
    local par = pp.Parent
    if not par then return nil end
    if par:IsA("Attachment") then return par.WorldPosition end
    return pivot(par)
end

local function teleport(p)
    local root = getRoot()
    if not root then return false end
    pcall(function() lp:RequestStreamAroundAsync(p, 2) end)
    root = getRoot()
    if not root then return false end
    root.AssemblyLinearVelocity = Vector3.zero
    root.CFrame = CFrame.new(p + Vector3.new(2.5, 2, 2.5))
    return true
end

local function press(pp)
    pcall(function() pp.RequiresLineOfSight = false pp.HoldDuration = 0 end)
    if fireproximityprompt and pcall(fireproximityprompt, pp) then return end
    pcall(function() pp:InputHoldBegin() task.wait(0.1) pp:InputHoldEnd() end)
end

local function say(msg)
    local ok = pcall(function()
        TextChatService.TextChannels.RBXGeneral:SendAsync(msg)
    end)
    if not ok then
        pcall(function() RS.DefaultChatSystemChatEvents.SayMessageRequest:FireServer(msg, "All") end)
    end
end

local function equipTool(name)
    local hum, char = getHum(), lp.Character
    if not hum or not char then return false end
    if char:FindFirstChild(name) then return true end
    local t = lp.Backpack:FindFirstChild(name)
    if t then hum:EquipTool(t) return true end
    log("tool not found:", name)
    return false
end

local npcCache = {}
local function findNpc(name)
    local c = npcCache[name]
    if c and c[1].Parent then return c[1], c[2] end
    local pos = CFG.NPC_POS[name]
    if pos then teleport(pos) task.wait(1.5) end
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("Model") and d.Name:lower():find(name, 1, true) then
            local pp = d:FindFirstChildWhichIsA("ProximityPrompt", true)
            if pp then npcCache[name] = {d, pp} return d, pp end
        end
    end
end

local function nearestGoblin()
    local root = getRoot()
    local best, bd
    for _, o in ipairs(CS:GetTagged(CFG.TAG)) do
        local pp = o:FindFirstChildWhichIsA("ProximityPrompt", true)
        local p = pivot(o)
        if pp and p then
            local d = root and (p - root.Position).Magnitude or 0
            if not best or d < bd then best, bd = {inst = o, pp = pp}, d end
        end
    end
    return best
end

-- เดินไปหา -> กด prompt -> รอปุ่ม dialog ที่ตรง keyword (ไล่ตามลำดับ list) -> คลิก
local function interact(inst, pp, lists, useRemote)
    local p = pivot(inst)
    if p then teleport(p) end
    task.wait(rnd(0.4, 0.8))
    press(pp)
    local t0 = os.clock()
    while running and os.clock() - t0 < 4 do
        local opts = choices()
        for _, kws in ipairs(lists) do
            for _, b in ipairs(opts) do
                if hasAny(btnText(b):lower(), kws) then
                    log("click:", btnText(b))
                    click(b)
                    task.wait(rnd(0.5, 1))
                    return true
                end
            end
        end
        task.wait(0.3)
    end
    local names = {}
    for _, b in ipairs(choices()) do names[#names + 1] = btnText(b) end
    log("no match; buttons:", table.concat(names, " | "):sub(1, 220))
    if useRemote and CFG.USE_REMOTE_FALLBACK then
        local rf = Net:FindFirstChild("RF/DialogInteract")
        if rf then
            local ok, r = pcall(rf.InvokeServer, rf, 1, 1)
            log("DialogInteract(1,1) ->", ok, ser(r))
            return ok
        end
    end
    return false
end

local function talkGoblin(lists)
    local g = nearestGoblin()
    if not g then log("no goblin loaded - วาร์ปไปหา/รอ spawn") return false end
    return interact(g.inst, g.pp, lists, true)
end

-- ================= quest parsing =================
local KEYS = {"jump", "walk", "stud", "dance", "insult", "perfect", "flimsy", "fright", "trick",
    "goblins rule", "favorite", "favourite", "guess", "drown", "burn", "freez", "haunted", "unique"}

-- ลำดับสำคัญ: อันเจาะจงกว่าอยู่บน
local RULES = {
    {"skip", {"drown", "burn", "freez", "haunted"}},
    {"skip", {"unique", "different species", "different fish", "distinct"}},
    {"insult", {"insult"}},
    {"flimsy", {"flimsy"}},
    {"perfect", {"perfect"}},
    {"fright", {"fright"}},
    {"trick", {"trick"}},
    {"guess", {"favorite", "favourite", "guess"}},
    {"dance", {"dance"}},
    {"jump", {"jump"}},
    {"walk", {"walk", "stud"}},
}

local function parseQuest(raw)
    local text = clean(raw)
    local low = text:lower()
    local q = {text = text}

    local a, b, c, d = low:match("(%d+):(%d+)%s*/%s*(%d+):(%d+)") -- mm:ss / mm:ss
    if a then
        q.progress = tonumber(a) * 60 + tonumber(b)
        q.target = tonumber(c) * 60 + tonumber(d)
    else
        local cur, tot = low:match("(%d+)%s*/%s*(%d+)")
        if cur then q.progress, q.target = tonumber(cur), tonumber(tot) end
    end
    q.target = q.target or tonumber(low:match("(%d+)")) or 1
    if low:find("in a row", 1, true) or low:find("consecutive", 1, true) or low:find("streak", 1, true) then
        q.streak = true
    end

    local phrase = text:match('"(.-)"') or text:match("“(.-)”")
    local chatish = low:find("chat", 1, true) or low:find("say", 1, true) or low:find("type", 1, true)
    if phrase and chatish then
        q.kind, q.phrase = "chat", phrase
    else
        for _, r in ipairs(RULES) do
            if hasAny(low, r[2]) then q.kind = r[1] break end
        end
    end

    if q.kind == "dance" and not a and low:find("min", 1, true) and not low:find("sec", 1, true) then
        q.target = q.target * 60
        if q.progress then q.progress = q.progress * 60 end
    end
    q.complete = (q.progress ~= nil and q.progress >= q.target)
    return q
end

local function scanQuests()
    local res = {}
    local function add(o, score)
        res[#res + 1] = {lbl = o, q = parseQuest(o.Text), score = score, y = o.AbsolutePosition.Y}
    end
    if CFG.QUEST_PATH then
        local o = pg
        for part in CFG.QUEST_PATH:gmatch("[^%.]+") do o = o and o:FindFirstChild(part) end
        if o and o:IsA("TextLabel") and o.Text ~= "" and shown(o) then add(o, 9) end
        return res
    end
    for _, o in ipairs(pg:GetDescendants()) do
        if o:IsA("TextLabel") and o.Text ~= "" and #o.Text < 220 and o.AbsoluteSize.X > 0 then
            local low = clean(o.Text):lower()
            if low:find("%d") and hasAny(low, KEYS) and shown(o) then
                local score, p = 0, o
                while p and p ~= pg do
                    local n = p.Name:lower()
                    if n:find("quest", 1, true) then score = score + 2 end
                    if n:find("chat", 1, true) or n:find("notif", 1, true)
                        or n:find("inventory", 1, true) or n:find("shop", 1, true) then
                        score = score - 5
                    end
                    p = p.Parent
                end
                if score >= 0 then add(o, score) end
            end
        end
    end
    table.sort(res, function(x, y)
        if x.score ~= y.score then return x.score > y.score end
        return x.y < y.y
    end)
    return res
end

local function readProgress()
    if curLbl and curLbl.Parent then return parseQuest(curLbl.Text).progress end
end

-- ตัวนับความคืบหน้า: ใช้ progress จาก UI ถ้าอ่านได้ ไม่งั้นนับเอง; label หาย = เควสจบ
local function tracker(target, stall)
    local t = {done = 0, last = os.clock(), target = target, stall = stall or CFG.STALL,
        hadLbl = curLbl ~= nil, finished = false}
    function t:bump(n)
        if self.hadLbl and not (curLbl and curLbl.Parent) then self.finished = true return true end
        local p = readProgress()
        local new = p or (self.done + n)
        if new > self.done then self.last = os.clock() end
        self.done = new
        if self.done >= self.target then self.finished = true end
        return self.finished
    end
    function t:idle() return os.clock() - self.last end
    function t:stalled() return self:idle() > self.stall end
    return t
end

-- ================= handlers (target = จำนวนเป้าหมายจาก UI) =================
local H = {}

H.jump = function(target)
    local tr = tracker(target)
    while running and not tr:stalled() do
        local hum = getHum()
        if hum and hum.FloorMaterial ~= Enum.Material.Air then
            -- ไม่รู้เกมฟังสัญญาณไหน: ใช้ครบทั้ง Jump / state / JumpRequest
            hum.Jump = true
            pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
            if firesignal then pcall(firesignal, UIS.JumpRequest) end
            task.wait(rnd(0.55, 0.95))
            if tr:bump(1) then break end
        else
            task.wait(0.15)
        end
    end
    return tr.finished
end

H.walk = function(target)
    local tr = tracker(target)
    local root = getRoot()
    if not root then return false end
    local origin = root.Position
    local dir = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
    dir = dir.Magnitude > 0 and dir.Unit or Vector3.new(0, 0, 1)
    local out = true
    while running and not tr:stalled() do
        local hum = getHum()
        root = getRoot()
        if not (hum and root) then
            task.wait(1)
        else
            local goal = out and (origin + dir * 35) or origin
            hum:MoveTo(goal)
            local last, moved, t0 = root.Position, 0, os.clock()
            while running and os.clock() - t0 < 8 do
                task.wait(0.15)
                root = getRoot()
                if not root then break end
                local dx, dz = root.Position.X - last.X, root.Position.Z - last.Z
                local d = math.sqrt(dx * dx + dz * dz)
                if d < 12 then moved = moved + d end -- ข้ามการวาร์ป/กระชาก
                last = root.Position
                local gx, gz = root.Position.X - goal.X, root.Position.Z - goal.Z
                if math.sqrt(gx * gx + gz * gz) < 2.5 then break end
            end
            out = not out
            if tr:bump(moved) then break end
            if moved < 4 and root then -- ติดของ: หมุนทิศ 90°
                dir = Vector3.new(-dir.Z, 0, dir.X)
                origin = root.Position
                out = true
            end
        end
    end
    return tr.finished
end

H.dance = function(target)
    local tr = tracker(target)
    local last, lastEmote = os.clock(), 0
    while running and not tr:stalled() do
        local hum = getHum()
        if hum and (lastEmote == 0 or (tr:idle() > 8 and os.clock() - lastEmote > 12)) then
            lastEmote = os.clock()
            local ok, played = pcall(function() return hum:PlayEmote("dance") end)
            if not (ok and played) then say("/e dance") end
        end
        task.wait(1)
        local now = os.clock()
        local fin = tr:bump(now - last)
        last = now
        if fin then break end
    end
    local hum = getHum() -- ขยับนิดนึงให้เลิกท่า
    if hum then pcall(function() hum:Move(Vector3.new(0, 0, -1), true) task.wait(0.2) hum:Move(Vector3.zero) end) end
    return tr.finished
end

H.chat = function(target, q)
    local tr = tracker(target)
    local phrase = q.phrase or "Goblins Rule!"
    while running and not tr:stalled() do
        say(phrase)
        task.wait(rnd(3.2, 4.6)) -- กัน chat rate limit
        if tr:bump(1) then break end
    end
    return tr.finished
end

H.insult = function(target)
    local tr, miss = tracker(target), 0
    while running and not tr:stalled() do
        local npc, pp = findNpc("beatrix")
        if not npc then
            log("Beatrix ไม่ถูกโหลด -> ตั้ง CFG.NPC_POS.beatrix (ปุ่ม MYPOS ตอนยืนข้างเธอ)")
            return false
        end
        if not interact(npc, pp, {KW.insult}, false) then
            miss = miss + 1
            if miss >= 3 then return false end
        end
        pause(CFG.DELAY)
        if tr:bump(1) then break end
    end
    return tr.finished
end

local function trickPrompts()
    local root, list = getRoot(), {}
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") then
            local s = ((d.ActionText or "") .. " " .. (d.ObjectText or "")):lower()
            if s:find("trick", 1, true) or s:find("treat", 1, true) or s:find("candy", 1, true) then
                local p = promptPos(d)
                if p then list[#list + 1] = {pp = d, p = p, d = root and (p - root.Position).Magnitude or 0} end
            end
        end
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    return list
end

H.trick = function(target)
    local tr = tracker(target)
    local list, i = trickPrompts(), 1
    while running and not tr:stalled() do
        local e = list[i]
        if not e then
            list, i = trickPrompts(), 1
            if #list == 0 then log("ไม่เจอ prompt trick-or-treat (ยังไม่ stream?)") task.wait(3) end
        else
            i = i + 1
            if e.pp.Parent then
                teleport(e.p)
                task.wait(rnd(0.4, 0.8))
                press(e.pp)
                pause(CFG.DELAY)
                if tr:bump(1) then break end
            end
        end
    end
    return tr.finished
end

-- best-effort: ลองตัวเลือก dialog ทีละอัน (ยังไม่เคยเห็น flow จริง)
H.guess = function(target)
    local tr, tried = tracker(target), {}
    while running and not tr:stalled() do
        local g = nearestGoblin()
        if not g then return false end
        local p = pivot(g.inst)
        if p then teleport(p) end
        task.wait(rnd(0.4, 0.8))
        press(g.pp)
        task.wait(1.2)
        local pick
        for _, b in ipairs(choices(true)) do
            local t = btnText(b):lower()
            if not tried[t] and not hasAny(t, KW.cancel) and not hasAny(t, {"leave", "bye", "close", "back"}) then
                pick = b
                break
            end
        end
        if not pick then log("guess: ไม่มีตัวเลือกใหม่ / ไม่เจอ dialog UI") return false end
        tried[btnText(pick):lower()] = true
        log("guess try:", btnText(pick))
        click(pick)
        pause({1, 2})
        if tr:bump(0) then break end
    end
    return tr.finished
end

-- ตกปลา: ผมไม่รู้ remote ตกปลาเวอร์ชันนี้ -> เปลี่ยนคันให้ แล้วส่งต่อ FISH_HOOK (autofarm ของนาย) แล้วรอ progress
local function fishHandler(rod)
    return function(target, q)
        local tr = tracker(target, CFG.STALL_FISH)
        if rod then equipTool(rod) end
        local hook = env.FISH_HOOK or CFG.FISH_HOOK
        if hook then
            pcall(hook, true, q)
        else
            log("ไม่มี FISH_HOOK - รอให้ตกเอง/autofarm อื่น" .. (q.streak and " (ต้อง perfect ติดกัน)" or ""))
        end
        while running and not tr:stalled() do
            task.wait(2)
            if tr:bump(0) then break end
        end
        if hook then pcall(hook, false, q) end
        return tr.finished
    end
end
H.fright = fishHandler(nil)
H.perfect = fishHandler(nil)
H.flimsy = fishHandler("Flimsy Rod")

-- ================= quest loop =================
local function cancelQuest()
    for _, b in ipairs(choices()) do
        if ancestorHas(b, "quest") and hasAny(btnText(b):lower(), KW.cancel) then
            log("cancel:", btnText(b))
            click(b)
            stuck = 0
            return true
        end
    end
    if talkGoblin({KW.cancel}) then stuck = 0 return true end
    stuck = stuck + 1
    log("cancel ไม่สำเร็จ", stuck, "/3")
    if stuck >= 3 then log("หาปุ่มยกเลิกไม่เจอ หยุดบอท - กด DUMP แล้วส่งผลมา") running = false end
    return false
end

local noGoblin = 0
local function cycle()
    local active, complete
    for _, e in ipairs(scanQuests()) do
        if e.q.complete then complete = complete or e else active = active or e end
    end

    if active then
        curLbl = active.lbl
        local q = active.q
        log("QUEST", q.kind or "?", q.target, "|", q.text:sub(1, 45))
        if q.kind == "skip" or not q.kind or not H[q.kind] then
            log("ข้ามเควสนี้ -> ยกเลิก/รับใหม่")
            cancelQuest()
            return
        end
        pause(CFG.DELAY)
        if H[q.kind](q.target, q) then
            log("done:", q.kind)
            stuck = 0
            pause(CFG.DELAY)
            talkGoblin({KW.submit})
        else
            log("fail/stall:", q.kind, "-> ยกเลิก")
            cancelQuest()
        end
        return
    end

    curLbl = nil -- ไม่มีเควสค้าง: ส่งของ (ถ้ามี) แล้วรับใหม่
    if talkGoblin({KW.submit, KW.accept}) then
        noGoblin = 0
    else
        noGoblin = noGoblin + 1
        if noGoblin >= 6 then
            log("คุยกับก้อบลินไม่สำเร็จ 6 ครั้ง หยุดบอท")
            running = false
        end
        task.wait(5)
    end
end

local function loop()
    while running do
        local ok, err = pcall(cycle)
        if not ok then log("ERR", tostring(err):sub(1, 80)) task.wait(2) end
        if running then pause(CFG.BETWEEN) end
    end
    log("stopped")
end

-- ================= DUMP / UI =================
local function dump()
    log("--- DUMP ---")
    local n = 0
    for _, o in ipairs(pg:GetDescendants()) do
        if o:IsA("TextLabel") and o.Text ~= "" and o.AbsoluteSize.X > 0 and shown(o) and hasAny(o.Text:lower(), KEYS) then
            n = n + 1
            if n <= 15 then log("LBL", (o:GetFullName():gsub("^.-PlayerGui%.", "")), "=", clean(o.Text):sub(1, 90)) end
        end
    end
    local names = {}
    for _, b in ipairs(choices(true)) do names[#names + 1] = btnText(b) end
    log("DIALOG BTNS:", table.concat(names, " | "))
    local rf = Net:FindFirstChild("RF/GetActiveQuestData")
    if rf then
        for _, id in ipairs(CFG.QUEST_IDS) do
            local ok, r = pcall(rf.InvokeServer, rf, id)
            log("QDATA", id, ok, ser(r):sub(1, 300))
        end
    end
    if setclipboard then setclipboard(table.concat(logLines, "\n", math.max(1, #logLines - 60), #logLines)) end
end

if env.__GQ_STOP then pcall(env.__GQ_STOP) end
local gui = Instance.new("ScreenGui")
gui.Name = "GoblinQuestBot"
gui.ResetOnSpawn = false
gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")
env.__GQ_STOP = function() running = false gui:Destroy() end

local function mk(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    o.Parent = parent
    return o
end

local frame = mk("Frame", {
    Size = UDim2.fromOffset(200, 0), AutomaticSize = Enum.AutomaticSize.Y,
    Position = UDim2.fromOffset(262, 60), BackgroundColor3 = Color3.fromRGB(20, 22, 28),
    BackgroundTransparency = 0.05, BorderSizePixel = 0,
}, gui)
mk("UICorner", {CornerRadius = UDim.new(0, 10)}, frame)
mk("UIPadding", {PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
    PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8)}, frame)
mk("UIListLayout", {Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder}, frame)

ui.status = mk("TextLabel", {
    Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, Text = "quest bot idle",
    TextColor3 = Color3.fromRGB(140, 146, 160), Font = Enum.Font.Gotham, TextSize = 11,
    TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 1,
}, frame)

local function button(text, order)
    local b = mk("TextButton", {
        Size = UDim2.new(1, 0, 0, 32), BackgroundColor3 = Color3.fromRGB(44, 48, 60), Text = text,
        TextColor3 = Color3.fromRGB(235, 237, 242), Font = Enum.Font.GothamMedium, TextSize = 13,
        LayoutOrder = order,
    }, frame)
    mk("UICorner", {CornerRadius = UDim.new(0, 8)}, b)
    return b
end

local startBtn = button("START QUESTS", 2)
local dumpBtn = button("DUMP (calibrate)", 3)
local posBtn = button("MYPOS", 4)

startBtn.Activated:Connect(function()
    running = not running
    startBtn.Text = running and "STOP QUESTS" or "START QUESTS"
    startBtn.BackgroundColor3 = running and Color3.fromRGB(80, 230, 110) or Color3.fromRGB(44, 48, 60)
    startBtn.TextColor3 = running and Color3.fromRGB(15, 18, 22) or Color3.fromRGB(235, 237, 242)
    if running then
        stuck, noGoblin = 0, 0
        if not alive then
            alive = true
            task.spawn(function() loop() alive = false end)
        end
    end
end)

dumpBtn.Activated:Connect(function()
    task.spawn(function()
        local ok, err = pcall(dump)
        if not ok then log("dump err", tostring(err):sub(1, 80)) end
        dumpBtn.Text = "COPIED"
        task.wait(1)
        dumpBtn.Text = "DUMP (calibrate)"
    end)
end)

posBtn.Activated:Connect(function()
    local r = getRoot()
    if r and setclipboard then
        local p = r.Position
        setclipboard(("Vector3.new(%.1f, %.1f, %.1f)"):format(p.X, p.Y, p.Z))
        posBtn.Text = "COPIED"
        task.wait(1)
        posBtn.Text = "MYPOS"
    end
end)

log("ready")
