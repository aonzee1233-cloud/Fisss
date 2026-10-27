-- Fisch | Goblin ESP v5 (tag FischfrightGoblin) | Delta mobile
-- v5: วาร์ปขึ้นเกาะ -> รอ ARRIVE_WAIT วิให้ goblin stream เข้า -> วาร์ปไปทีละพิกัด
--     เรียงจากใกล้ไปไกล ยืนพิกัดละ STAND_TIME วิ + ปุ่ม TOUR (กดซ้ำ = หยุด)
-- v7-ui: เมนูใหม่ เล็ก ลากได้ พับได้ log ซ่อนไว้ (กด LOG ค่อยเปิด)
local CS = game:GetService("CollectionService")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local lp = game:GetService("Players").LocalPlayer
local TAG = "FischfrightGoblin"

local ARRIVE_WAIT = 3 -- รอหลังถึงเกาะ ก่อนเก็บพิกัด
local STAND_TIME = 3  -- ยืนแต่ละพิกัดกี่วิ

local gui = Instance.new("ScreenGui")
gui.ResetOnSpawn = false
gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")

-- ================= UI =================
local COL = {
    bg     = Color3.fromRGB(20, 22, 28),
    bar    = Color3.fromRGB(30, 33, 42),
    btn    = Color3.fromRGB(44, 48, 60),
    on     = Color3.fromRGB(80, 230, 110),
    text   = Color3.fromRGB(235, 237, 242),
    dim    = Color3.fromRGB(140, 146, 160),
    dark   = Color3.fromRGB(15, 18, 22),
}

local function round(o, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 8)
    c.Parent = o
end

local function mk(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    o.Parent = parent
    return o
end

local main = mk("Frame", {
    Size = UDim2.fromOffset(240, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    Position = UDim2.fromOffset(12, 60),
    BackgroundColor3 = COL.bg,
    BackgroundTransparency = 0.05,
    BorderSizePixel = 0,
    Active = true,
}, gui)
round(main, 10)
mk("UIStroke", {Color = COL.bar, Thickness = 1}, main)
mk("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder}, main)

-- title bar (ลากเมนูได้จากตรงนี้)
local bar = mk("Frame", {
    Size = UDim2.new(1, 0, 0, 32),
    BackgroundColor3 = COL.bar,
    BorderSizePixel = 0,
    LayoutOrder = 1,
}, main)
round(bar, 10)

mk("TextLabel", {
    Size = UDim2.new(1, -80, 1, 0),
    Position = UDim2.fromOffset(10, 0),
    BackgroundTransparency = 1,
    Text = "Goblin",
    TextColor3 = COL.text,
    Font = Enum.Font.GothamBold,
    TextSize = 14,
    TextXAlignment = Enum.TextXAlignment.Left,
}, bar)

local function tiny(text, xOff)
    local b = mk("TextButton", {
        Size = UDim2.fromOffset(34, 22),
        Position = UDim2.new(1, xOff, 0.5, -11),
        BackgroundColor3 = COL.btn,
        Text = text,
        TextColor3 = COL.text,
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        AutoButtonColor = true,
    }, bar)
    round(b, 6)
    return b
end
local logToggle = tiny("LOG", -76)
local foldBtn = tiny("–", -38)

-- ลากเมนู
do
    local dragging, dragStart, startPos
    bar.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, i.Position, main.Position
            i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = i.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
end

-- body
local body = mk("Frame", {
    Size = UDim2.new(1, 0, 0, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1,
    LayoutOrder = 2,
}, main)
mk("UIPadding", {
    PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8),
    PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
}, body)
mk("UIListLayout", {Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder}, body)

-- สถานะบรรทัดเดียว
local status = mk("TextLabel", {
    Size = UDim2.new(1, 0, 0, 16),
    BackgroundTransparency = 1,
    Text = "goblins 0  ·  nearest -  ·  saved 0",
    TextColor3 = COL.dim,
    Font = Enum.Font.Gotham,
    TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left,
    LayoutOrder = 1,
}, body)

-- ปุ่ม 2x2
local grid = mk("Frame", {
    Size = UDim2.new(1, 0, 0, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1,
    LayoutOrder = 2,
}, body)
mk("UIGridLayout", {
    CellSize = UDim2.new(0.5, -3, 0, 34),
    CellPadding = UDim2.fromOffset(6, 6),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, grid)

local function button(text, order)
    local b = mk("TextButton", {
        BackgroundColor3 = COL.btn,
        Text = text,
        TextColor3 = COL.text,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        AutoButtonColor = true,
        LayoutOrder = order,
    }, grid)
    round(b, 8)
    return b
end

-- สลับสีปุ่มตามสถานะ ON/OFF
local function paint(b, on)
    b.BackgroundColor3 = on and COL.on or COL.btn
    b.TextColor3 = on and COL.dark or COL.text
end

local wbtn = button("AUTO WARP", 1)
local tbtn = button("TOUR", 2)
local btn  = button("COPY LOG", 3)
local pbtn = button("COPY POS", 4)

-- log (ซ่อนเป็นค่าเริ่มต้น)
local logFrame = mk("Frame", {
    Size = UDim2.new(1, 0, 0, 130),
    BackgroundColor3 = COL.dark,
    BackgroundTransparency = 0.2,
    Visible = false,
    LayoutOrder = 3,
}, body)
round(logFrame, 8)
mk("UIPadding", {
    PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6),
    PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
}, logFrame)

local box = mk("TextLabel", {
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    Text = "",
    TextColor3 = COL.dim,
    Font = Enum.Font.Code,
    TextSize = 11,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Bottom,
    ClipsDescendants = true,
}, logFrame)

logToggle.Activated:Connect(function()
    logFrame.Visible = not logFrame.Visible
    paint(logToggle, logFrame.Visible)
end)

foldBtn.Activated:Connect(function()
    body.Visible = not body.Visible
    foldBtn.Text = body.Visible and "–" or "+"
end)
-- ================= /UI =================

local out = {}
local function log(...)
    local a = table.pack(...)
    local t = {}
    for i = 1, a.n do t[i] = tostring(a[i]) end
    local line = ("[%.0f] %s"):format(os.clock(), table.concat(t, " ")):sub(1, 300)
    table.insert(out, line)
    box.Text = table.concat(out, "\n", math.max(1, #out - 9), #out)
end

btn.Activated:Connect(function()
    if setclipboard then
        setclipboard(table.concat(out, "\n"))
        btn.Text = "COPIED"
        task.wait(1)
        btn.Text = "COPY LOG"
    end
end)

-- เก็บตำแหน่งตาม UID (ไม่ซ้ำ) เรียงตามลำดับที่เจอ
local positions = {}
local posOrder = {}
-- พิกัดของ event รอบปัจจุบัน (uid -> Vector3) ใช้เป็น list ให้ tour
-- ถูกล้างทุกครั้งที่มี spawn ใหม่ และเก็บเป็นพิกัดไว้เพราะ goblin อาจถูก stream ออกตอนเราไปไกล
local found = {}

pbtn.Activated:Connect(function()
    if not setclipboard then return end
    local t = {}
    for _, uid in ipairs(posOrder) do t[#t + 1] = positions[uid] end
    setclipboard(table.concat(t, "\n"))
    pbtn.Text = "COPIED " .. #t
    task.wait(1)
    pbtn.Text = "COPY POS"
end)

local tracked = {}

local function pos(o)
    local ok, cf = pcall(o.GetPivot, o)
    return ok and cf.Position or nil
end

local function attrs(o)
    local t = {}
    for k, v in pairs(o:GetAttributes()) do t[#t + 1] = k .. "=" .. tostring(v) end
    return table.concat(t, ", ")
end

local function track(o)
    if tracked[o] or not o:IsA("PVInstance") then return end

    local hl = Instance.new("Highlight")
    hl.Adornee = o
    hl.FillColor = Color3.fromRGB(80, 255, 80)
    hl.FillTransparency = 0.4
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Parent = gui

    local bb = Instance.new("BillboardGui")
    bb.AlwaysOnTop = true
    bb.Size = UDim2.fromOffset(140, 24)
    bb.StudsOffset = Vector3.new(0, 6, 0)
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.fromScale(1, 1)
    lbl.BackgroundTransparency = 1
    lbl.TextColor3 = Color3.new(1, 1, 1)
    lbl.TextStrokeTransparency = 0
    lbl.Font = Enum.Font.GothamBold
    lbl.TextSize = 14
    lbl.Parent = bb
    bb.Parent = gui

    task.spawn(function()
        for _ = 1, 50 do
            local part = o:IsA("BasePart") and o or o:FindFirstChildWhichIsA("BasePart", true)
            if part then
                bb.Adornee = part
                return
            end
            task.wait(0.1)
        end
    end)

    tracked[o] = {hl = hl, bb = bb, lbl = lbl}

    local uid = tostring(o:GetAttribute("UID") or o:GetDebugId())
    tracked[o].uid = uid
    local p = pos(o) or Vector3.zero
    local line = ('["%s"]=Vector3.new(%.1f,%.1f,%.1f),'):format(uid, p.X, p.Y, p.Z)
    if not positions[uid] then posOrder[#posOrder + 1] = uid end
    positions[uid] = line
    if p ~= Vector3.zero then found[uid] = p end
    log("FOUND", o.Name, line)

    log("attrs:", attrs(o))
    local pp = o:FindFirstChildWhichIsA("ProximityPrompt", true)
    if pp then log("prompt:", pp.ActionText, pp.ObjectText, "range", pp.MaxActivationDistance) end

    o.AncestryChanged:Connect(function(_, parent)
        if not parent then
            hl:Destroy()
            bb:Destroy()
            tracked[o] = nil
            log("GONE", o.Name)
        end
    end)
end

for _, o in ipairs(CS:GetTagged(TAG)) do track(o) end
CS:GetInstanceAddedSignal(TAG):Connect(track)

local hide = RS.packages.Net:FindFirstChild("RE/Goblins/Hide")
if hide then
    hide.OnClientEvent:Connect(function(a, b)
        if typeof(a) == "table" then
            log("HIDE batch", #a)
        else
            log("HIDE", tostring(a), b and "instant" or "poof")
        end
    end)
end

for _, tag in ipairs(CS:GetAllTags()) do
    local l = tag:lower()
    if l:find("goblin") or l:find("fischfright") then
        log("TAG", tag, #CS:GetTagged(tag))
    end
end
log("streaming:", workspace.StreamingEnabled)

-- เฝ้านับ tag ดูว่า goblin stream เข้ามาตอนไหน
task.spawn(function()
    local last = -1
    while true do
        local c = #CS:GetTagged(TAG)
        if c ~= last then
            log("TAGGED now", c)
            last = c
        end
        task.wait(2)
    end
end)

RunService.Heartbeat:Connect(function()
    local root = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    local n, nearest = 0, math.huge
    for o, v in pairs(tracked) do
        n = n + 1
        local p = pos(o)
        if p and root then
            local d = (p - root.Position).Magnitude
            v.lbl.Text = ("goblin %dm"):format(math.floor(d))
            nearest = math.min(nearest, d)
            -- ถ้า goblin ขยับ ให้พิกัดใน found ตามไปด้วย (อัปเดตเฉพาะ uid ที่อยู่ใน event รอบนี้)
            if found[v.uid] then found[v.uid] = p end
        end
    end
    status.Text = ("goblins %d  ·  nearest %s  ·  saved %d"):format(
        n, nearest < math.huge and (math.floor(nearest) .. "m") or "-", #posOrder)
end)

-- ตรวจจับแจ้งเตือน Goblin และวาร์ปไปยังเกาะที่ระบุ
local ISLANDS = {
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
}

local autoWarp = false
wbtn.Activated:Connect(function()
    autoWarp = not autoWarp
    paint(wbtn, autoWarp)
end)

local function findCoords(name)
    if ISLANDS[name] then return ISLANDS[name] end
    local ln = name:lower()
    for k, v in pairs(ISLANDS) do
        local lk = k:lower()
        if lk:find(ln, 1, true) or ln:find(lk, 1, true) then return v end
    end
    local ok, res = pcall(function()
        local root = (workspace:FindFirstChild("world") and workspace.world:FindFirstChild("map")) or workspace
        for _, d in ipairs(root:GetDescendants()) do
            if (d:IsA("Model") or d:IsA("BasePart")) and d.Name:lower() == ln then
                return d:GetPivot().Position
            end
        end
    end)
    if ok and res then ISLANDS[name] = res return res end
end

local function getRoot()
    return lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
end

-- วาร์ปไปพิกัดตรงๆ; สั่ง stream รอบจุดนั้นก่อน เผื่อ goblin ที่ไกลยังไม่โหลด
local function goTo(p)
    local root = getRoot()
    if not root then return false end
    pcall(function() lp:RequestStreamAroundAsync(p, 2) end)
    root = getRoot()
    if not root then return false end
    root.AssemblyLinearVelocity = Vector3.zero
    root.CFrame = CFrame.new(p + Vector3.new(0, 3, 0))
    return true
end

local function warp(name)
    local p = findCoords(name)
    if not p then log("WARP no coords:", name) return false end
    local root = getRoot()
    if not root then return false end
    pcall(function() lp:RequestStreamAroundAsync(p, 5) end)
    root = getRoot()
    if not root then return false end
    root.CFrame = CFrame.new(p + Vector3.new(0, 5, 0))
    log("WARP ->", name)
    return true
end

-- tour: รอ ARRIVE_WAIT วิ -> ล็อกรายการพิกัด -> ไล่ไปทีละจุดจากใกล้ไปไกล ยืนจุดละ STAND_TIME วิ
-- tourId ใช้ยกเลิกรอบเก่า (spawn ใหม่ หรือกดปุ่ม TOUR ซ้ำ)
local tourId = 0
local touring = false

local function tour()
    tourId = tourId + 1
    local myId = tourId
    touring = true
    tbtn.Text = "STOP"
    paint(tbtn, true)
    task.spawn(function()
        log("TOUR wait", ARRIVE_WAIT)
        task.wait(ARRIVE_WAIT)

        local visited = {}
        while myId == tourId do
            local root = getRoot()
            if not root then break end

            local list = {}
            for uid, p in pairs(found) do
                if not visited[uid] then
                    list[#list + 1] = {uid = uid, p = p, d = (p - root.Position).Magnitude}
                end
            end
            if #list == 0 then break end
            table.sort(list, function(a, b) return a.d < b.d end)
            log("TOUR targets", #list)

            for i, g in ipairs(list) do
                if myId ~= tourId then return end
                visited[g.uid] = true
                -- ใช้พิกัดล่าสุดของ goblin ตัวนั้นถ้ามี (found อัปเดตตามตอนมันขยับ)
                local p = found[g.uid] or g.p
                if goTo(p) then
                    log(("TOUR %d/%d %s %dm"):format(i, #list, g.uid, math.floor(g.d)))
                end
                task.wait(STAND_TIME)
            end
            -- วนเช็กอีกรอบ: goblin ตัวไกลที่เพิ่ง stream เข้ามาระหว่างทัวร์จะถูกเพิ่มใน found
        end

        if myId == tourId then
            touring = false
            tbtn.Text = "TOUR"
            paint(tbtn, false)
            log("TOUR done", #posOrder)
        end
    end)
end

tbtn.Activated:Connect(function()
    if touring then
        tourId = tourId + 1
        touring = false
        tbtn.Text = "TOUR"
        paint(tbtn, false)
        log("TOUR stopped")
    else
        tour()
    end
end)

local lastName, lastT = nil, 0
local function onNotif(text)
    text = text:gsub("<[^>]+>", "")
    local name = text:match("[Gg]oblins have spawned at (.-)!")
    if not name then return end
    name = name:match("^%s*(.-)%s*$")
    if name == lastName and os.clock() - lastT < 10 then return end
    lastName, lastT = name, os.clock()
    log("SPAWN", name)
    if autoWarp then
        found = {} -- เริ่ม event ใหม่ ล้างพิกัดรอบก่อน
        if warp(name) then tour() end
    end
end

local PHRASE = "goblins have spawned at"
local function scan(v, d)
    d = d or 0
    if typeof(v) == "string" then
        return v:lower():find(PHRASE, 1, true) and v or nil
    end
    if typeof(v) == "table" and d < 3 then
        for _, x in pairs(v) do
            local r = scan(x, d + 1)
            if r then return r end
        end
    end
end

for _, r in ipairs(RS.packages.Net:GetChildren()) do
    if r:IsA("RemoteEvent") or r:IsA("UnreliableRemoteEvent") then
        r.OnClientEvent:Connect(function(...)
            local a = table.pack(...)
            for i = 1, a.n do
                local s = scan(a[i])
                if s then log("NOTIF-RE", r.Name) onNotif(s) break end
            end
        end)
    end
end

local pg = lp:WaitForChild("PlayerGui")
local function watchText(t, isNew)
    if not (t:IsA("TextLabel") or t:IsA("TextButton")) then return end
    local function chk()
        if t.Text:lower():find(PHRASE, 1, true) then
            log("NOTIF-UI", t:GetFullName():sub(-40))
            onNotif(t.Text)
        end
    end
    if isNew then chk() end
    t:GetPropertyChangedSignal("Text"):Connect(chk)
end
for _, d in ipairs(pg:GetDescendants()) do watchText(d, false) end
pg.DescendantAdded:Connect(function(d) watchText(d, true) end)
-- ================= v9 PHASE 1: อ่านเควส + จำนวนเป้าหมายจาก UI =================
local Quest = {}
Quest.cur = nil

local QPATTERNS = {
    {"skip_drown",   {"drown"}},
    {"skip_burn",    {"burn"}},
    {"skip_freeze",  {"freez"}},
    {"skip_haunted", {"haunted"}},
    {"skip_unique",  {"different"}},
    {"skip_unique",  {"unique"}},
    {"flimsy_streak", {"flimsy", "perfect"}},
    {"flimsy",       {"flimsy"}},
    {"perfect",      {"perfect"}},
    {"insult",       {"insult"}},
    {"insult",       {"beatrix"}},
    {"dance",        {"dance"}},
    {"jump",         {"jump"}},
    {"walk",         {"walk"}},
    {"walk",         {"stud"}},
    {"trick",        {"trick"}},
    {"trick",        {"treat"}},
    {"chat",         {"goblins rule"}},
    {"chat",         {"say"}},
    {"guess",        {"favorite"}},
    {"guess",        {"favourite"}},
    {"guess",        {"guess"}},
    {"catch_ff",     {"fischfright"}},
    {"catch_ff",     {"catch", "fish"}},
}
local LEVELS = {"easy", "normal", "hard", "extreme", "ultimate"}

local function clean(s) return (s:gsub("<[^>]+>", "")) end
local function num(s) return tonumber((s:gsub(",", ""))) end
local function isText(o) return o:IsA("TextLabel") or o:IsA("TextButton") end
local function has(txt, w) return txt:find("%f[%a]" .. w) ~= nil end

local function classify(low)
    for _, p in ipairs(QPATTERNS) do
        local ok = true
        for _, w in ipairs(p[2]) do
            if not has(low, w) then ok = false break end
        end
        if ok then return p[1] end
    end
end

local function visible(g)
    local o = g
    while o and o ~= pg do
        if o:IsA("GuiObject") and not o.Visible then return false end
        if o:IsA("ScreenGui") and not o.Enabled then return false end
        o = o.Parent
    end
    return true
end

local function parseProgress(s)
    local a, b = s:match("(%d[%d,]*)%s*/%s*(%d[%d,]*)")
    if a then return num(a), num(b) end
end

local function nearProgress(t)
    local o = t
    for _ = 1, 2 do
        o = o.Parent
        if not o or o == pg then break end
        for _, d in ipairs(o:GetDescendants()) do
            if d ~= t and isText(d) and visible(d) then
                local a, b = parseProgress(clean(d.Text))
                if a then return a, b, d end
            end
        end
    end
end

local function findLevel(t)
    local o = t
    for _ = 0, 2 do
        if not o or o == pg then break end
        local pool = {o}
        for _, d in ipairs(o:GetDescendants()) do pool[#pool + 1] = d end
        for _, d in ipairs(pool) do
            if isText(d) and visible(d) then
                local low = clean(d.Text):lower()
                for _, lv in ipairs(LEVELS) do
                    if has(low, lv) and #low < 40 then return lv end
                end
            end
        end
        o = o.Parent
    end
end

function Quest.read(verbose)
    local best
    for _, d in ipairs(pg:GetDescendants()) do
        if isText(d) and d.Text ~= "" and visible(d) then
            local txt = clean(d.Text)
            local key = classify(txt:lower())
            if key then
                local score = 2 + (txt:find("%d") and 1 or 0)
                if verbose then
                    log("CAND", key, txt:sub(1, 60), "@", d:GetFullName():sub(-60))
                end
                if not best or score > best.score then
                    best = {obj = d, text = txt, key = key, score = score}
                end
            end
        end
    end

    if not best then
        if verbose then
            local n = 0
            for _, d in ipairs(pg:GetDescendants()) do
                if n >= 30 then break end
                if isText(d) and visible(d) then
                    local txt = clean(d.Text)
                    if #txt >= 4 and txt:find("%a") then
                        n = n + 1
                        log("TXT", txt:sub(1, 50), "@", d:GetFullName():sub(-50))
                    end
                end
            end
        end
        Quest.cur = nil
        return nil
    end

    local a, b = parseProgress(best.text)
    local pobj
    if not a then a, b, pobj = nearProgress(best.obj) end
    local target = b or (best.text:match("(%d[%d,]*)") and num(best.text:match("(%d[%d,]*)")))

    Quest.cur = {
        key = best.key,
        skip = best.key:sub(1, 5) == "skip_",
        target = target,
        prog = a,
        level = findLevel(best.obj),
        text = best.text,
        obj = best.obj,
        pobj = pobj,
    }
    local q = Quest.cur
    log("QUEST", q.key, "target", q.target, "prog", q.prog, "lv", q.level, "skip", q.skip)
    return q
end

function Quest.dump(v, d)
    d = d or 0
    if typeof(v) ~= "table" or d > 3 then return tostring(v) end
    local t = {}
    for k, x in pairs(v) do t[#t + 1] = tostring(k) .. "=" .. Quest.dump(x, d + 1) end
    return "{" .. table.concat(t, ", ") .. "}"
end

local qbtn = button("QUEST?", 5)
qbtn.Activated:Connect(function()
    table.clear(out)
    log("=== QUEST SCAN ===")
    local q = Quest.read(true)
    local rf = RS.packages.Net:FindFirstChild("RF/GetActiveQuestData")
    if rf then
        local ok, res = pcall(function() return rf:InvokeServer("PlaguedReaper-3") end)
        local s = Quest.dump(res)
        log("QDATA ok", ok, "len", #s)
        for i = 1, #s, 270 do log("QDATA", s:sub(i, i + 269)) end
    end
    qbtn.Text = q and (q.key .. " " .. tostring(q.target or "?")) or "NOT FOUND"
    task.wait(2)
    qbtn.Text = "QUEST?"
end)
-- ================= /PHASE 1 =================

-- ===== PHASE 1b: อ่านเฉพาะกล่อง hud.deviceinset.quests =====
local function questRoot()
    local h = pg:FindFirstChild("hud")
    local di = h and h:FindFirstChild("deviceinset")
    return di and di:FindFirstChild("quests")
end

local function rel(d, root)
    return d:GetFullName():sub(#root:GetFullName() + 2)
end

function Quest.read(verbose)
    local root = questRoot()
    if not root then
        if verbose then log("NO hud.deviceinset.quests") end
        Quest.cur = nil
        return nil
    end

    local pick, pickTexts
    for _, c in ipairs(root:GetChildren()) do
        local texts = {}
        for _, d in ipairs(c:GetDescendants()) do
            if isText(d) and d.Text ~= "" then
                texts[#texts + 1] = {o = d, s = clean(d.Text), vis = visible(d)}
            end
        end
        if verbose then
            log("CHILD", c.Name, "texts", #texts)
            for i = 1, math.min(#texts, 12) do
                local x = texts[i]
                log(" ", x.vis and "" or "HIDDEN", rel(x.o, root), "=", x.s:sub(1, 70))
            end
        end
        local isGoblin = c.Name:lower():find("goblin") ~= nil
        for _, x in ipairs(texts) do
            if x.s:lower():find("fischfright", 1, true) then isGoblin = true end
        end
        if isGoblin and not pick then pick, pickTexts = c, texts end
    end
    if not pick then
        Quest.cur = nil
        return nil
    end

    local body, prog, target, level = {}, nil, nil, nil
    for _, x in ipairs(pickTexts) do
        if x.vis then
            local low = x.s:lower()
            local a, b = parseProgress(x.s)
            if a and not prog then prog, target = a, b end
            if x.o.Name:lower() ~= "title" then body[#body + 1] = x.s end
            if not level and #low < 40 then
                for _, lv in ipairs(LEVELS) do
                    if has(low, lv) then level = lv break end
                end
            end
        end
    end

    local text = table.concat(body, " | ")
    local key = classify(text:lower()) or "unknown"
    if not target then
        local n = text:match("(%d[%d,]*)")
        target = n and num(n)
    end

    Quest.cur = {
        key = key,
        skip = key:sub(1, 5) == "skip_",
        target = target,
        prog = prog,
        level = level,
        text = text,
        obj = pick,
        name = pick.Name,
    }
    log("QUEST", key, "target", target, "prog", prog, "lv", level, "|", text:sub(1, 80))
    return Quest.cur
end
-- ===== /PHASE 1b =====

