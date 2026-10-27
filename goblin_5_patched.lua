-- Fisch | Goblin ESP v4 (tag FischfrightGoblin) | Delta mobile
-- v4: บันทึกตำแหน่ง goblin เป็นบรรทัด table + ปุ่ม POS + เฝ้านับ tag
local CS = game:GetService("CollectionService")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local lp = game:GetService("Players").LocalPlayer
local TAG = "FischfrightGoblin"

local gui = Instance.new("ScreenGui")
gui.ResetOnSpawn = false
gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")

local function label(pos, size, ts)
    local l = Instance.new("TextLabel")
    l.Position = pos
    l.Size = size
    l.BackgroundColor3 = Color3.new(0, 0, 0)
    l.BackgroundTransparency = 0.3
    l.TextColor3 = Color3.new(1, 1, 1)
    l.TextSize = ts
    l.TextWrapped = true
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextYAlignment = Enum.TextYAlignment.Top
    l.Text = ""
    l.Parent = gui
    return l
end

local status = label(UDim2.new(0.02, 0, 0.07, 0), UDim2.new(0.6, 0, 0.04, 0), 14)
local box = label(UDim2.new(0.02, 0, 0.12, 0), UDim2.new(0.6, 0, 0.3, 0), 12)

local btn = Instance.new("TextButton")
btn.Size = UDim2.new(0.2, 0, 0.06, 0)
btn.Position = UDim2.new(0.02, 0, 0.43, 0)
btn.Text = "COPY"
btn.Parent = gui

-- ปุ่มใหม่: copy เฉพาะบรรทัดตำแหน่ง (วางใน table ได้เลย)
local pbtn = Instance.new("TextButton")
pbtn.Size = UDim2.new(0.2, 0, 0.06, 0)
pbtn.Position = UDim2.new(0.24, 0, 0.43, 0)
pbtn.Text = "POS"
pbtn.Parent = gui

local out = {}
local function log(...)
    local a = table.pack(...)
    local t = {}
    for i = 1, a.n do t[i] = tostring(a[i]) end
    local line = ("[%.0f] %s"):format(os.clock(), table.concat(t, " ")):sub(1, 300)
    table.insert(out, line)
    box.Text = table.concat(out, "\n", math.max(1, #out - 16), #out)
end

btn.Activated:Connect(function()
    if setclipboard then
        setclipboard(table.concat(out, "\n"))
        btn.Text = "COPIED"
        task.wait(1)
        btn.Text = "COPY"
    end
end)

-- เก็บตำแหน่งตาม UID (ไม่ซ้ำ) เรียงตามลำดับที่เจอ
local positions = {}
local posOrder = {}

pbtn.Activated:Connect(function()
    if not setclipboard then return end
    local t = {}
    for _, uid in ipairs(posOrder) do t[#t + 1] = positions[uid] end
    setclipboard(table.concat(t, "\n"))
    pbtn.Text = "COPIED " .. #t
    task.wait(1)
    pbtn.Text = "POS"
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

    -- v4: บันทึกตำแหน่งเป็นบรรทัดพร้อมวางใน table
    local uid = tostring(o:GetAttribute("UID"))
    local p = pos(o) or Vector3.zero
    local line = ('["%s"]=Vector3.new(%.1f,%.1f,%.1f),'):format(uid, p.X, p.Y, p.Z)
    if not positions[uid] then posOrder[#posOrder + 1] = uid end
    positions[uid] = line
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

-- v4: เฝ้านับ tag ดูว่า goblin stream เข้ามาตอนไหน
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
        end
    end
    status.Text = ("goblins: %d | nearest: %s | saved: %d"):format(
        n, nearest < math.huge and (math.floor(nearest) .. "m") or "-", #posOrder)
end)

-- ตรวจจับแจ้งเตือน Goblin และวาร์ปไปยังเกาะที่ระบุ
local ISLANDS = {
    ["Moosewood"]       = Vector3.new(380, 135, 234),
    ["Roslit Bay"]      = Vector3.new(-1473, 133, 708),
    ["Forsaken Shores"] = Vector3.new(-2491, 133, 1561),
    ["Sunstone Island"] = Vector3.new(-913, 138, -1133),
    ["Terrapin Island"] = Vector3.new(-193, 135, 1951),
    ["Mushgrove Swamp"] = Vector3.new(2434, 132, -692),
    ["Ancient Isle"]    = Vector3.new(6056, 195, 307),
    ["Lost Jungle"]     = Vector3.new(-2589, 158, -2194),
    ["Scoria Reach"]    = Vector3.new(-4976, 145, -1577),
    ["Snowcap Island"]  = Vector3.new(2607, 135, 2436),
}

local autoWarp = false
local wbtn = Instance.new("TextButton")
wbtn.Size = UDim2.new(0.2, 0, 0.06, 0)
wbtn.Position = UDim2.new(0.46, 0, 0.43, 0)
wbtn.Text = "WARP: OFF"
wbtn.Parent = gui
wbtn.Activated:Connect(function()
    autoWarp = not autoWarp
    wbtn.Text = autoWarp and "WARP: ON" or "WARP: OFF"
end)

local function warp(name)
    local p = ISLANDS[name]
    if not p then log("WARP no coords:", name) return end
    local root = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not root then return end
    pcall(function() lp:RequestStreamAroundAsync(p, 5) end)
    root.CFrame = CFrame.new(p + Vector3.new(0, 5, 0))
    log("WARP ->", name)
end

local lastName, lastT = nil, 0
local function onNotif(text)
    text = text:gsub("<[^>]+>", "")
    local name = text:match("[Gg]oblins have spawned at (.-)!")
    if not name then return end
    name = name:match("^%s*(.-)%s*$")
    if name == lastName and os.clock() - lastT < 10 then return end
    lastName, lastT = name, os.clock()
    log("SPAWN", name)
    if autoWarp then warp(name) end
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
