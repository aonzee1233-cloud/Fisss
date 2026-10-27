--[[
    RemoteSpy.lua
    Engine  : Roblox (Luau), client side, run from an executor
    Target  : any Roblox game (built for Fisch scripting work)
    Needs   : getnamecallmethod + (hookmetamethod OR getrawmetatable + setreadonly)
    Optional: checkcaller, newcclosure, setclipboard/toclipboard, writefile, getnilinstances, gethui

    OUT = client -> server   RemoteEvent / UnreliableRemoteEvent :FireServer, RemoteFunction :InvokeServer
    IN  = server -> client   RemoteEvent / UnreliableRemoteEvent .OnClientEvent

    Not covered: InvokeServer return values, OnClientInvoke, and direct calls like
    remote.FireServer(remote, ...) which bypass __namecall (rare).

    Run   : execute in-game. A window opens (drag the title bar to move it).
            Tab "Remotes": EVERY remote found in the game, with call counters.
                           Row turns green once it has fired. Click a row = copy its path as code.
            Tab "Log"    : every call as a ready-to-paste line. Click a line = copy it.
            Filter box   : filters whichever tab is open (case-insensitive substring).
            Rescan       : look for remotes again (also catches ones created later / parented to nil).
            Clear        : wipes the log AND resets the counters (handy to see what an action fires).
            Pause        : stop/resume logging.
            Guard        : spam guard on/off. ON = max MaxPerSecond printed lines per remote and direction,
                           the rest are still COUNTED (shown in the Remotes tab and the status bar).
                           OFF = log every single call.
    Re-run: safe, the previous instance (and its window) is stopped first.

    A remote that the scan never saw is added automatically the first time it fires.

    Console commands (global RemoteSpy):
        RemoteSpy.List()           every remote found in the game
        RemoteSpy.Rescan()         scan again
        RemoteSpy.Copy(id)         copy log #id to the clipboard
        RemoteSpy.Dump([file])     save all logs to a file (clipboard if writefile is missing)
        RemoteSpy.Ignore(name)     hide a noisy remote  (RemoteSpy.Unignore(name) to undo)
        RemoteSpy.Only(name, ...)  show only these      (RemoteSpy.Only() to reset)
        RemoteSpy.Clear()          wipe the log buffer and counters
        RemoteSpy.Stop()           disconnect everything and close the window

    Live settings: IgnoreOwnCalls, MaxPerSecond, LogOut, LogIn, MaxDepth, MaxEntries, MaxLogs, PrintToConsole
    e.g. RemoteSpy.IgnoreOwnCalls = false  -> also log calls made by your own script
]]

local env = (getgenv and getgenv()) or _G
if env.RemoteSpy then
    pcall(env.RemoteSpy.Stop)
end

local checkcaller = checkcaller or function() return false end
local newcclosure = newcclosure or function(f) return f end

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

local Spy = {
    Enabled        = true,
    LogOut         = true,
    LogIn          = true,
    IgnoreOwnCalls = true,  -- skip calls made by executor scripts
    MaxPerSecond   = 8,     -- per remote and direction; extra calls are counted instead of logged
    MaxDepth       = 4,     -- table nesting limit when printing args
    MaxEntries     = 60,    -- entries per table
    MaxLogs        = 500,
    PrintToConsole = true,  -- also print every log line to the developer console
    Blacklist      = {},
    Whitelist      = {},
    Logs           = {},
    Remotes        = {},    -- [instance] = record { inst, class, display, out, inn, hidden, row }
    RemoteCount    = 0,
    Stats          = { out = 0, inn = 0, hidden = 0 },
}

local REMOTE_CLASSES = { RemoteEvent = true, UnreliableRemoteEvent = true, RemoteFunction = true }
local OUT_METHODS    = { FireServer = true, InvokeServer = true }
local connections, rate, nextId = {}, {}, 0

-- forward declarations (emit and track call each other)
local emit, track

-- ---------------------------------------------------------------- serialization

local IDENT = "^[%a_][%w_]*$"
local KEYWORDS = {}
for word in ("and break do else elseif end false for function if in local nil not or repeat return then true until while"):gmatch("%a+") do
    KEYWORDS[word] = true
end

local function isIdent(s)
    return s:match(IDENT) ~= nil and not KEYWORDS[s]
end

local ESC = { ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t", ['"'] = '\\"', ["\\"] = "\\\\" }
local function quote(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return ESC[c] or ("\\%03d"):format(c:byte())
    end) .. '"'
end

-- code that reaches the instance, e.g. game:GetService("ReplicatedStorage").events.cast
local function pathOf(inst)
    local chain, cur = {}, inst
    while cur and cur ~= game do
        table.insert(chain, 1, cur)
        cur = cur.Parent
    end
    if cur ~= game then
        return ("nil --[[ %s is parented to nil, get it with getnilinstances() ]]"):format(inst.Name)
    end
    if #chain == 0 then return "game" end

    local out, first = ("game:GetService(%s)"):format(quote(chain[1].Name)), 2
    for i, node in ipairs(chain) do
        if node == LocalPlayer then
            out, first = 'game:GetService("Players").LocalPlayer', i + 1
        end
    end
    for i = first, #chain do
        local n = chain[i].Name
        out ..= isIdent(n) and ("." .. n) or ("[" .. quote(n) .. "]")
    end
    return out
end

local function serialize(v, depth, seen)
    depth = depth or 0
    local t = typeof(v)

    if t == "string" then
        return quote(v)
    elseif t == "number" then
        if v ~= v then return "0/0" end
        if v == math.huge then return "math.huge" end
        if v == -math.huge then return "-math.huge" end
        return tostring(v)
    elseif t == "boolean" or t == "nil" then
        return tostring(v)
    elseif t == "Instance" then
        return pathOf(v)
    elseif t == "Vector3" then
        return ("Vector3.new(%s, %s, %s)"):format(v.X, v.Y, v.Z)
    elseif t == "Vector2" then
        return ("Vector2.new(%s, %s)"):format(v.X, v.Y)
    elseif t == "CFrame" then
        return ("CFrame.new(%s)"):format(table.concat({ v:GetComponents() }, ", "))
    elseif t == "Color3" then
        return ("Color3.new(%s, %s, %s)"):format(v.R, v.G, v.B)
    elseif t == "UDim2" then
        return ("UDim2.new(%s, %s, %s, %s)"):format(v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset)
    elseif t == "BrickColor" then
        return ("BrickColor.new(%s)"):format(quote(v.Name))
    elseif t == "EnumItem" then
        return tostring(v)
    elseif t == "table" then
        seen = seen or {}
        if seen[v] then return "{} --[[ cyclic ]]" end
        if depth >= Spy.MaxDepth then return "{} --[[ too deep ]]" end
        seen[v] = true

        local parts, n, truncated, len = {}, 0, false, #v
        for i = 1, len do
            n += 1
            if n > Spy.MaxEntries then truncated = true break end
            parts[#parts + 1] = serialize(v[i], depth + 1, seen)
        end
        if not truncated then
            for k, val in pairs(v) do
                if not (type(k) == "number" and k >= 1 and k <= len and k % 1 == 0) then
                    n += 1
                    if n > Spy.MaxEntries then truncated = true break end
                    local key = (type(k) == "string" and isIdent(k)) and k
                        or ("[" .. serialize(k, depth + 1, seen) .. "]")
                    parts[#parts + 1] = key .. " = " .. serialize(val, depth + 1, seen)
                end
            end
        end
        if truncated then parts[#parts + 1] = "--[[ truncated ]]" end
        seen[v] = nil
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return ("nil --[[ %s ]]"):format(t)
end

local function serializeArgs(packed)
    local out = {}
    for i = 1, packed.n do
        out[i] = serialize(packed[i], 0)
    end
    return table.concat(out, ", ")
end

local function clip(text)
    local fn = setclipboard or toclipboard
    if fn then fn(text) return true end
    return false
end

-- ---------------------------------------------------------------- UI

local ui = {
    alive = false,
    gui = nil,
    tab = "Remotes",
    filter = "",
    remoteQueue = {},   -- records waiting for a row
    logQueue = {},      -- log entries waiting for a row
    logRows = {},       -- [entry id] = row
    dirty = {},         -- records whose counters changed
    stick = false,      -- scroll the log to the bottom on next flush
    note = nil,
    noteUntil = 0,
}
local UI = {}

local WIN_W, WIN_H = 620, 400
local MAX_SHOWN = 700 -- characters of a log line shown in the window (click copies the full text)

local COLORS = {
    bg                    = Color3.fromRGB(22, 22, 26),
    bar                   = Color3.fromRGB(34, 34, 40),
    list                  = Color3.fromRGB(14, 14, 18),
    btn                   = Color3.fromRGB(52, 52, 62),
    btnOn                 = Color3.fromRGB(84, 84, 130),
    text                  = Color3.fromRGB(225, 225, 230),
    idle                  = Color3.fromRGB(28, 28, 34),
    fired                 = Color3.fromRGB(32, 52, 38),
    RemoteEvent           = Color3.fromRGB(130, 190, 255),
    UnreliableRemoteEvent = Color3.fromRGB(205, 165, 255),
    RemoteFunction        = Color3.fromRGB(255, 190, 110),
    OUT                   = Color3.fromRGB(140, 230, 140),
    IN                    = Color3.fromRGB(255, 225, 120),
}
local SHORT = { RemoteEvent = "Event", UnreliableRemoteEvent = "Unreliable", RemoteFunction = "Function" }

local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end

local function attach(gui)
    if gethui then
        local ok = pcall(function() gui.Parent = gethui() end)
        if ok and gui.Parent then return end
    end
    if syn and syn.protect_gui then pcall(syn.protect_gui, gui) end
    local ok = pcall(function() gui.Parent = game:GetService("CoreGui") end)
    if ok and gui.Parent then return end
    gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
end

local function note(msg)
    ui.note, ui.noteUntil = msg, os.clock() + 2.5
end

local function copy(text, what)
    if clip(text) then
        note("copied " .. what)
    else
        print(text)
        note("no clipboard function in this executor, printed to console instead")
    end
end

local function matches(text)
    if ui.filter == "" then return true end
    return text:lower():find(ui.filter, 1, true) ~= nil
end

local function remoteText(rec)
    local counts
    if rec.class == "RemoteFunction" then
        counts = ("calls %d"):format(rec.out)
    else
        counts = ("OUT %d  IN %d"):format(rec.out, rec.inn)
    end
    if rec.hidden > 0 then
        counts ..= ("  (%d not logged: spam guard)"):format(rec.hidden)
    end
    return ("[%s] %s    %s"):format(SHORT[rec.class] or rec.class, rec.display, counts)
end

local function makeRemoteRow(rec)
    local row = new("TextButton", {
        Name = rec.display, -- the list is sorted by Name
        Size = UDim2.new(1, -8, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = (rec.out + rec.inn > 0) and COLORS.fired or COLORS.idle,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.Code,
        TextSize = 13,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextColor3 = COLORS[rec.class] or COLORS.text,
        Text = remoteText(rec),
        Visible = matches(rec.display),
    }, ui.remoteList)
    row.MouseButton1Click:Connect(function()
        copy(pathOf(rec.inst), "path of " .. rec.inst.Name)
    end)
    rec.row = row
end

local function updateRemoteRow(rec)
    local row = rec.row
    if not row then return end
    row.Text = remoteText(rec)
    row.BackgroundColor3 = (rec.out + rec.inn > 0) and COLORS.fired or COLORS.idle
end

local function makeLogRow(entry)
    local text = entry.text
    local shown = text
    if #shown > MAX_SHOWN then
        shown = shown:sub(1, MAX_SHOWN) .. " ...[truncated, click to copy the full line]"
    end
    local row = new("TextButton", {
        Name = tostring(entry.id),
        LayoutOrder = entry.id,
        Size = UDim2.new(1, -8, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = COLORS.idle,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.Code,
        TextSize = 13,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextColor3 = COLORS[entry.dir] or COLORS.text,
        Text = ("[%s #%d] %s"):format(entry.dir, entry.id, shown),
        Visible = matches(text),
    }, ui.logList)
    row.MouseButton1Click:Connect(function()
        copy(text, "#" .. entry.id)
    end)
    ui.logRows[entry.id] = row
end

function UI.queueRemote(rec)
    if ui.alive then table.insert(ui.remoteQueue, rec) end
end

function UI.queueLog(entry)
    if ui.alive then table.insert(ui.logQueue, entry) end
end

function UI.markDirty(rec)
    if ui.alive then ui.dirty[rec] = true end
end

function UI.dropLog(entry)
    entry.dropped = true
    local row = ui.logRows[entry.id]
    if row then
        ui.logRows[entry.id] = nil
        row:Destroy()
    end
end

-- runs every 0.2s: creates the rows that are waiting and refreshes counters
function UI.flush()
    if not ui.alive then return end

    if ui.stick then
        ui.logList.CanvasPosition = Vector2.new(0, 1e6)
        ui.stick = false
    end

    local made = 0
    while #ui.remoteQueue > 0 and made < 150 do
        local rec = table.remove(ui.remoteQueue, 1)
        pcall(makeRemoteRow, rec)
        made += 1
    end

    for rec in pairs(ui.dirty) do
        ui.dirty[rec] = nil
        if rec.row then pcall(updateRemoteRow, rec) end
    end

    local list = ui.logList
    local atBottom = list.CanvasPosition.Y + list.AbsoluteSize.Y >= list.AbsoluteCanvasSize.Y - 30
    made = 0
    while #ui.logQueue > 0 and made < 150 do
        local entry = table.remove(ui.logQueue, 1)
        if not entry.dropped then
            pcall(makeLogRow, entry)
            made += 1
        end
    end
    if made > 0 and atBottom then ui.stick = true end

    local text
    if ui.note and os.clock() < ui.noteUntil then
        text = ui.note
    else
        text = ("remotes %d | OUT %d | IN %d | log lines %d | not logged (guard) %d%s"):format(
            Spy.RemoteCount, Spy.Stats.out, Spy.Stats.inn, #Spy.Logs, Spy.Stats.hidden,
            Spy.Enabled and "" or " | PAUSED")
    end
    ui.statusLabel.Text = text
end

function UI.applyFilter()
    for _, rec in pairs(Spy.Remotes) do
        if rec.row then rec.row.Visible = matches(rec.display) end
    end
    for _, entry in ipairs(Spy.Logs) do
        local row = ui.logRows[entry.id]
        if row then row.Visible = matches(entry.text) end
    end
end

function UI.build()
    local gui = new("ScreenGui", {
        Name = "RemoteSpyUI",
        ResetOnSpawn = false,
        DisplayOrder = 999999,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    })
    ui.gui = gui

    local main = new("Frame", {
        Name = "Main",
        Position = UDim2.fromOffset(40, 60),
        Size = UDim2.fromOffset(WIN_W, WIN_H),
        BackgroundColor3 = COLORS.bg,
        BorderSizePixel = 0,
        Active = true,
    }, gui)

    local bar = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 26),
        BackgroundColor3 = COLORS.bar,
        BorderSizePixel = 0,
        Text = "  RemoteSpy   (drag here)",
        TextColor3 = COLORS.text,
        Font = Enum.Font.Code,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, main)

    local function button(text, x, y, w, parent)
        return new("TextButton", {
            Text = text,
            Position = UDim2.fromOffset(x, y),
            Size = UDim2.fromOffset(w, 20),
            BackgroundColor3 = COLORS.btn,
            BorderSizePixel = 0,
            TextColor3 = COLORS.text,
            Font = Enum.Font.Code,
            TextSize = 13,
        }, parent)
    end

    local minBtn = button("_", WIN_W - 54, 3, 24, bar)
    local closeBtn = button("X", WIN_W - 28, 3, 24, bar)

    local body = new("Frame", {
        Position = UDim2.fromOffset(0, 26),
        Size = UDim2.new(1, 0, 1, -26),
        BackgroundTransparency = 1,
    }, main)

    local tabRemotes = button("Remotes", 6, 3, 84, body)
    local tabLog = button("Log", 94, 3, 50, body)

    local filterBox = new("TextBox", {
        Position = UDim2.fromOffset(150, 3),
        Size = UDim2.fromOffset(190, 20),
        BackgroundColor3 = COLORS.list,
        BorderSizePixel = 0,
        PlaceholderText = "filter...",
        Text = "",
        ClearTextOnFocus = false,
        TextColor3 = COLORS.text,
        PlaceholderColor3 = Color3.fromRGB(120, 120, 130),
        Font = Enum.Font.Code,
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, body)

    local rescanBtn = button("Rescan", 346, 3, 56, body)
    local clearBtn = button("Clear", 406, 3, 48, body)
    local pauseBtn = button("Pause", 458, 3, 56, body)
    local guardBtn = button(Spy.MaxPerSecond == math.huge and "Guard: OFF" or "Guard: ON", 518, 3, 96, body)

    local function makeList(name, sortOrder)
        local sf = new("ScrollingFrame", {
            Name = name,
            Position = UDim2.fromOffset(6, 28),
            Size = UDim2.new(1, -12, 1, -54),
            BackgroundColor3 = COLORS.list,
            BorderSizePixel = 0,
            ScrollBarThickness = 6,
            CanvasSize = UDim2.new(),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            ScrollingDirection = Enum.ScrollingDirection.Y,
        }, body)
        new("UIListLayout", { Padding = UDim.new(0, 1), SortOrder = sortOrder }, sf)
        return sf
    end
    ui.remoteList = makeList("Remotes", Enum.SortOrder.Name)
    ui.logList = makeList("Log", Enum.SortOrder.LayoutOrder)

    ui.statusLabel = new("TextLabel", {
        Position = UDim2.new(0, 6, 1, -22),
        Size = UDim2.new(1, -12, 0, 18),
        BackgroundTransparency = 1,
        Text = "",
        TextColor3 = Color3.fromRGB(170, 170, 185),
        Font = Enum.Font.Code,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, body)

    local function setTab(name)
        ui.tab = name
        ui.remoteList.Visible = name == "Remotes"
        ui.logList.Visible = name == "Log"
        tabRemotes.BackgroundColor3 = name == "Remotes" and COLORS.btnOn or COLORS.btn
        tabLog.BackgroundColor3 = name == "Log" and COLORS.btnOn or COLORS.btn
    end
    setTab("Remotes")

    tabRemotes.MouseButton1Click:Connect(function() setTab("Remotes") end)
    tabLog.MouseButton1Click:Connect(function() setTab("Log") end)

    filterBox:GetPropertyChangedSignal("Text"):Connect(function()
        ui.filter = filterBox.Text:lower()
        UI.applyFilter()
    end)

    rescanBtn.MouseButton1Click:Connect(function() Spy.Rescan() end)
    clearBtn.MouseButton1Click:Connect(function() Spy.Clear() end)

    pauseBtn.MouseButton1Click:Connect(function()
        Spy.Enabled = not Spy.Enabled
        pauseBtn.Text = Spy.Enabled and "Pause" or "Resume"
    end)

    local guardDefault = Spy.MaxPerSecond ~= math.huge and Spy.MaxPerSecond or 8
    guardBtn.MouseButton1Click:Connect(function()
        if Spy.MaxPerSecond == math.huge then
            Spy.MaxPerSecond = guardDefault
            guardBtn.Text = "Guard: ON"
        else
            guardDefault = Spy.MaxPerSecond
            Spy.MaxPerSecond = math.huge
            guardBtn.Text = "Guard: OFF"
        end
    end)

    local minimized = false
    minBtn.MouseButton1Click:Connect(function()
        minimized = not minimized
        body.Visible = not minimized
        main.Size = UDim2.fromOffset(WIN_W, minimized and 26 or WIN_H)
    end)
    closeBtn.MouseButton1Click:Connect(function() Spy.Stop() end)

    -- dragging by the title bar
    local dragging, dragStart, startPos = false, nil, nil
    bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, input.Position, main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    table.insert(connections, UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))

    attach(gui)
    ui.alive = true

    task.spawn(function()
        while ui.alive do
            pcall(UI.flush)
            task.wait(0.2)
        end
    end)
end

-- ---------------------------------------------------------------- logging

function emit(dir, remote, method, packed)
    if not Spy.Enabled then return end
    if (dir == "OUT" and not Spy.LogOut) or (dir == "IN" and not Spy.LogIn) then return end
    if not REMOTE_CLASSES[remote.ClassName] then return end

    -- registers remotes the scan missed, then counts the call (counters are never rate limited)
    local rec = track(remote)
    if dir == "OUT" then
        rec.out += 1
        Spy.Stats.out += 1
    else
        rec.inn += 1
        Spy.Stats.inn += 1
    end
    UI.markDirty(rec)

    local name = remote.Name
    if Spy.Blacklist[name] then return end
    if next(Spy.Whitelist) ~= nil and not Spy.Whitelist[name] then return end

    local path = pathOf(remote)

    -- spam guard: cap logged lines per remote per second, the rest is counted
    local key, now = dir .. path, os.clock()
    local r = rate[key]
    if not r or now - r.start >= 1 then
        if r and r.hidden > 0 and Spy.PrintToConsole then
            print(("[%s] %s  (+%d calls hidden by spam guard)"):format(dir, path, r.hidden))
        end
        rate[key] = { start = now, count = 1, hidden = 0 }
    else
        r.count += 1
        if r.count > Spy.MaxPerSecond then
            r.hidden += 1
            rec.hidden += 1
            Spy.Stats.hidden += 1
            UI.markDirty(rec)
            return
        end
    end

    local ok, args = pcall(serializeArgs, packed)
    if not ok then args = "--[[ serialize failed ]]" end

    local text
    if dir == "OUT" then
        text = ("%s:%s(%s)"):format(path, method, args)
    else
        text = ("%s.OnClientEvent  -->  (%s)"):format(path, args)
    end

    nextId += 1
    local entry = { id = nextId, dir = dir, text = text }
    table.insert(Spy.Logs, entry)
    UI.queueLog(entry)
    if #Spy.Logs > Spy.MaxLogs then
        UI.dropLog(table.remove(Spy.Logs, 1))
    end
    if Spy.PrintToConsole then
        print(("[%s #%d] %s"):format(dir, nextId, text))
    end
end

-- ---------------------------------------------------------------- OUT: hook __namecall

local oldNamecall
local function hook(self, ...)
    local method = getnamecallmethod() -- keep this first
    if OUT_METHODS[method] and Spy.Enabled and typeof(self) == "Instance"
        and not (Spy.IgnoreOwnCalls and checkcaller()) then
        -- separate thread so our own calls can't disturb this thread's namecall state
        task.spawn(emit, "OUT", self, method, table.pack(...))
    end
    return oldNamecall(self, ...)
end

local canHook = getnamecallmethod ~= nil
    and (hookmetamethod ~= nil or (getrawmetatable ~= nil and setreadonly ~= nil))

if canHook then
    local ok, err = pcall(function()
        if hookmetamethod then
            oldNamecall = hookmetamethod(game, "__namecall", newcclosure(hook))
        else
            local mt = getrawmetatable(game)
            oldNamecall = mt.__namecall
            setreadonly(mt, false)
            mt.__namecall = newcclosure(hook)
            setreadonly(mt, true)
        end
    end)
    if not ok then
        canHook = false
        warn("[RemoteSpy] hook failed: " .. tostring(err))
    end
else
    warn("[RemoteSpy] executor lacks getnamecallmethod/hookmetamethod: OUT logging is off, IN logging and the remote list still work")
end

-- ---------------------------------------------------------------- remote registry (IN hooks + scan)

function track(inst)
    local rec = Spy.Remotes[inst]
    if rec then return rec end

    local class = inst.ClassName
    if not REMOTE_CLASSES[class] then return nil end

    local display = inst:GetFullName()
    if not inst:IsDescendantOf(game) then
        display = "[nil parent] " .. display
    end

    rec = { inst = inst, class = class, display = display, out = 0, inn = 0, hidden = 0, row = nil }
    Spy.Remotes[inst] = rec
    Spy.RemoteCount += 1

    if class ~= "RemoteFunction" then
        table.insert(connections, inst.OnClientEvent:Connect(function(...)
            emit("IN", inst, "OnClientEvent", table.pack(...))
        end))
    end

    UI.queueRemote(rec)
    return rec
end

local function scan()
    for _, inst in ipairs(game:GetDescendants()) do
        pcall(track, inst)
    end
    if getnilinstances then
        local ok, list = pcall(getnilinstances)
        if ok then
            for _, inst in ipairs(list) do
                pcall(track, inst)
            end
        end
    end
end

-- ---------------------------------------------------------------- console API

function Spy.List()
    local rows = {}
    for _, rec in pairs(Spy.Remotes) do
        rows[#rows + 1] = ("%-22s %s"):format(rec.class, pathOf(rec.inst))
    end
    table.sort(rows)
    print(("[RemoteSpy] %d remotes in this game:"):format(#rows))
    for _, row in ipairs(rows) do print(row) end
    return rows
end

function Spy.Rescan()
    local before = Spy.RemoteCount
    scan()
    local added = Spy.RemoteCount - before
    note(("rescan done: %d new, %d total"):format(added, Spy.RemoteCount))
    return added
end

function Spy.Copy(id)
    for _, e in ipairs(Spy.Logs) do
        if e.id == id then
            if clip(e.text) then print("[RemoteSpy] copied #" .. id) else print(e.text) end
            return e.text
        end
    end
    warn("[RemoteSpy] no log with id " .. tostring(id))
end

function Spy.Dump(file)
    local lines = {}
    for _, e in ipairs(Spy.Logs) do
        lines[#lines + 1] = ("-- #%d [%s]\n%s"):format(e.id, e.dir, e.text)
    end
    local text = table.concat(lines, "\n\n")
    file = file or "RemoteSpy_log.txt"
    if writefile and pcall(writefile, file, text) then
        print("[RemoteSpy] saved " .. file)
    elseif clip(text) then
        print("[RemoteSpy] writefile unavailable, copied to clipboard instead")
    else
        warn("[RemoteSpy] neither writefile nor setclipboard is available")
    end
end

function Spy.Ignore(name)   Spy.Blacklist[name] = true end
function Spy.Unignore(name) Spy.Blacklist[name] = nil end

function Spy.Only(...)
    table.clear(Spy.Whitelist)
    for _, name in ipairs({ ... }) do Spy.Whitelist[name] = true end
end

function Spy.Clear()
    for _, e in ipairs(Spy.Logs) do UI.dropLog(e) end
    table.clear(Spy.Logs)
    for _, rec in pairs(Spy.Remotes) do
        rec.out, rec.inn, rec.hidden = 0, 0, 0
        UI.markDirty(rec)
    end
    Spy.Stats.out, Spy.Stats.inn, Spy.Stats.hidden = 0, 0, 0
end

function Spy.Stop()
    Spy.Enabled = false -- the __namecall hook stays installed but passes everything straight through
    ui.alive = false
    if ui.gui then pcall(function() ui.gui:Destroy() end) end
    for _, c in ipairs(connections) do c:Disconnect() end
    table.clear(connections)
    if env.RemoteSpy == Spy then env.RemoteSpy = nil end
    print("[RemoteSpy] stopped")
end

-- ---------------------------------------------------------------- start

local okUI, errUI = pcall(UI.build)
if not okUI then
    ui.alive = false
    if ui.gui then pcall(function() ui.gui:Destroy() end) end
    warn("[RemoteSpy] window failed to open (" .. tostring(errUI) .. "), falling back to console output only")
end

scan()
table.insert(connections, game.DescendantAdded:Connect(function(inst)
    pcall(track, inst)
end))

env.RemoteSpy = Spy

print(("[RemoteSpy] ready: %d remotes found, OUT logging %s, window %s"):format(
    Spy.RemoteCount, canHook and "on" or "off", ui.alive and "open" or "unavailable"))
print("[RemoteSpy] RemoteSpy.List() / .Rescan() / .Copy(id) / .Dump() / .Ignore(name) / .Only(name) / .Stop()")

return Spy
