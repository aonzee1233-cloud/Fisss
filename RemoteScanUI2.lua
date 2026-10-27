--[[
    RemoteScanUI2.lua
    Engine : Roblox (Luau), client side, Delta
    Needs  : decompile  (checked at start, it tells you if missing)
    Optional: getscripts, getloadedmodules, getnilinstances, gethui, writefile, setclipboard,
              getgc + debug.getupvalues + debug.getconstants  (only for the "Deep scan" button)

    What it does
      Scans every LocalScript / ModuleScript the client can see and shows the result in a window.
      No remote is fired.

      For every remote call it works out
        - which remote it is (name, class, full path in the game, resolved through local variables)
        - the direction and the method: FireServer / InvokeServer / OnClientEvent / OnClientInvoke
        - the arguments that are sent (count, literal type, and what a variable was assigned from)
        - the parameters of an OnClientEvent / OnClientInvoke handler
        - the function the call sits in
      It also indexes every RemoteEvent / RemoteFunction / UnreliableRemoteEvent in the game and
      shows which ones no client script calls (usually server fired).

      Deep scan (button) looks at the closures that are running in memory. It reads their upvalues
      and constants, so it still finds the remote when the decompiled text only shows v12 style names,
      and it finds scripts that failed to decompile.

    Window
      Tabs    : Scripts (scripts with remote calls) | Remotes (every remote, most client refs first)
      Filter  : type a remote name, an argument, a script name, any text, the list narrows down
      Viewer  : details of the selected item
      Buttons : Stop | Deep scan | Copy all | Copy sel. | Save
      Title   : drag to move, "-" folds, "X" closes and stops

    Output : RemoteScan.txt in the executor workspace folder when the scan ends (needs writefile).
]]

local OUTFILE = "RemoteScan.txt"
local TIMEOUT = 8          -- seconds to wait per script before skipping it
local CONTEXT = 1          -- lines of code context around each hit
local MAX_SHOWN = 12000    -- max characters shown in the viewer (Copy sel. gives everything)
local MAX_CALLS_SHOWN = 80 -- calls listed per script in the viewer (the saved report has all)
local GC_SECONDS = 45      -- max time of the deep scan

local METHODS = {
    { key = "FireServer",     kind = "event",  dir = "client -> server" },
    { key = "fireServer",     kind = "event",  dir = "client -> server" },
    { key = "InvokeServer",   kind = "func",   dir = "client -> server, waits for the reply" },
    { key = "invokeServer",   kind = "func",   dir = "client -> server, waits for the reply" },
    { key = "OnClientEvent",  kind = "listen", dir = "server -> client" },
    { key = "OnClientInvoke", kind = "cb",     dir = "server -> client, handler must return a value" },
}
local METHOD_SET, PATTERNS = {}, {}
for _, m in ipairs(METHODS) do
    METHOD_SET[m.key] = m
    PATTERNS[#PATTERNS + 1] = m.key
end

if not decompile then
    warn("[RemoteScan] this executor has no decompile(), the scan cannot run")
    return
end

local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local UIS = game:GetService("UserInputService")
local RobloxRS
pcall(function() RobloxRS = game:GetService("RobloxReplicatedStorage") end)

local REMOTE_CLASS = { RemoteEvent = true, RemoteFunction = true, UnreliableRemoteEvent = true }

local function engineOwned(inst)
    local ok, r = pcall(function()
        return inst:IsDescendantOf(CoreGui) or (RobloxRS ~= nil and inst:IsDescendantOf(RobloxRS))
    end)
    return ok and r == true
end

-- ================================================================ text analysis (no Roblox API)

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- text between the bracket at openPos and its partner; second value false if it is not closed on this line
local function balancedAfter(line, openPos)
    local depth, i, n = 0, openPos, #line
    local quote = nil
    while i <= n do
        local c = line:sub(i, i)
        if quote then
            if c == "\\" then
                i += 1
            elseif c == quote then
                quote = nil
            end
        elseif c == '"' or c == "'" then
            quote = c
        elseif c == "(" or c == "[" or c == "{" then
            depth += 1
        elseif c == ")" or c == "]" or c == "}" then
            depth -= 1
            if depth == 0 then
                return line:sub(openPos + 1, i - 1), true
            end
        end
        i += 1
    end
    return line:sub(openPos + 1), false
end

-- split "a, f(b, c), {d, e}" on the commas that are not nested
local function splitTop(s)
    local out, depth, cur, quote = {}, 0, 1, nil
    local i, n = 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if quote then
            if c == "\\" then
                i += 1
            elseif c == quote then
                quote = nil
            end
        elseif c == '"' or c == "'" then
            quote = c
        elseif c == "(" or c == "[" or c == "{" then
            depth += 1
        elseif c == ")" or c == "]" or c == "}" then
            depth -= 1
        elseif c == "," and depth == 0 then
            out[#out + 1] = trim(s:sub(cur, i - 1))
            cur = i + 1
        end
        i += 1
    end
    local last = trim(s:sub(cur))
    if last ~= "" or #out > 0 then out[#out + 1] = last end
    return out
end

local function guessType(a)
    if a:match('^".*"$') or a:match("^'.*'$") then return "string" end
    if tonumber(a) then return "number" end
    if a == "true" or a == "false" then return "boolean" end
    if a == "nil" then return "nil" end
    if a:sub(1, 1) == "{" then return "table" end
    if a:match("^function") then return "function" end
    return "var"
end

-- the expression right before ":" or "." at sepPos, e.g.  game:GetService("RS").Remotes.Buy
local function receiverBefore(line, sepPos)
    local i = sepPos - 1
    while i >= 1 do
        local c = line:sub(i, i)
        if c == ")" or c == "]" then
            local open = (c == ")") and "(" or "["
            local depth = 0
            while i >= 1 do
                local d = line:sub(i, i)
                if d == c then
                    depth += 1
                elseif d == open then
                    depth -= 1
                    if depth == 0 then break end
                end
                i -= 1
            end
            i -= 1
        elseif c:match("[%w_%.:]") then
            i -= 1
        else
            break
        end
    end
    return line:sub(i + 1, sepPos - 1)
end

local SKIP_NAMES = { script = true, self = true, game = true, workspace = true }

-- last name of an expression. second value: "string" (WaitForChild("X") / ["X"]), "field" (.X) or "ident" (bare variable)
local function nameFromExpr(expr)
    expr = trim(expr)
    local s = expr:match('[%(%[]%s*"([^"]+)"%s*[%)%]]%s*$') or expr:match("[%(%[]%s*'([^']+)'%s*[%)%]]%s*$")
    if s then return s, "string" end
    local id = expr:match("[%.:]([%a_][%w_]*)$")
    if id then return id, "field" end
    id = expr:match("^([%a_][%w_]*)$")
    if id and not SKIP_NAMES[id] then return id, "ident" end
    return nil, nil
end

-- nearest earlier line that assigns the variable:  local x = ...  /  x = ...
local function findAssign(lines, name, fromLine)
    if not name:match("^[%a_][%w_]*$") then return nil end
    local pat = "%f[%w_]" .. name .. "%s*=%s*(.+)$"
    for n = math.min(fromLine, #lines), 1, -1 do
        local line = lines[n]
        local s, _, rhs = line:find(pat)
        if s and rhs and rhs:sub(1, 1) ~= "=" then
            local before = (s > 1) and line:sub(s - 1, s - 1) or ""
            if before ~= "." and before ~= ":" then
                rhs = trim((rhs:gsub("%s*%-%-.*$", ""):gsub(";%s*$", "")))
                return rhs, n
            end
        end
    end
    return nil
end

-- name of the remote behind a receiver expression, following local variables up to 4 steps
local function resolveRemote(lines, recv, lineNo)
    local name, kind = nameFromExpr(recv)
    if not name then return nil, nil, nil end
    local via, depth, from = nil, 0, lineNo
    while kind == "ident" and depth < 4 do
        local rhs, at = findAssign(lines, name, from)
        if not rhs then break end
        local step = ("%s = %s  (L%d)"):format(name, rhs:sub(1, 90), at)
        via = via and (via .. "  <-  " .. step) or step
        local n2, k2 = nameFromExpr(rhs)
        if not n2 then break end
        name, kind = n2, k2
        from = at - 1
        depth += 1
    end
    return name, via, kind
end

local function indentOf(line)
    return #(line:match("^[ \t]*"))
end

-- the function the line sits in, found through the indentation of the decompiled text
local function enclosing(lines, n)
    local ind = indentOf(lines[n])
    for k = n - 1, 1, -1 do
        local l = lines[k]
        if l:match("%S") then
            local i2 = indentOf(l)
            if i2 < ind then
                if l:find("function", 1, true) then
                    return trim(l):sub(1, 90), k
                end
                ind = i2
            end
        end
    end
    return nil, nil
end

local function hasPattern(line)
    for _, p in ipairs(PATTERNS) do
        if line:find(p, 1, true) then return true end
    end
    return false
end

-- every remote call on one line, with everything that can be read from the text
local function analyzeHit(lines, n)
    local line = lines[n]
    local calls = {}
    local inside, insideLine = enclosing(lines, n)
    for _, m in ipairs(METHODS) do
        local from = 1
        while true do
            local s, e = line:find(m.key, from, true)
            if not s then break end
            from = e + 1
            local sep = (s > 1) and line:sub(s - 1, s - 1) or ""
            if sep == ":" or sep == "." then
                local c = {
                    line = n, method = m.key, kind = m.kind, dir = m.dir,
                    inside = inside, insideLine = insideLine,
                }
                c.recv = trim(receiverBefore(line, s - 1))
                c.name, c.via, c.nameKind = resolveRemote(lines, c.recv, n)
                local rest = line:sub(e + 1)

                if m.kind == "event" or m.kind == "func" then
                    local op = line:find("(", e + 1, true)
                    if op and trim(line:sub(e + 1, op - 1)) == "" then
                        local inner, closed = balancedAfter(line, op)
                        local args = splitTop(inner)
                        if sep == "." and #args > 0 then table.remove(args, 1) end -- Remote.FireServer(Remote, ...)
                        c.args, c.argsOpen = args, not closed
                        c.argInfo = {}
                        for i, a in ipairs(args) do
                            if i > 8 then
                                c.argInfo[#c.argInfo + 1] = ("... +%d more"):format(#args - 8)
                                break
                            end
                            local t = guessType(a)
                            local hint = ""
                            if t == "var" and a:match("^[%a_][%w_]*$") then
                                local rhs = findAssign(lines, a, n - 1)
                                if rhs then hint = "  = " .. rhs:sub(1, 60) end
                            end
                            c.argInfo[#c.argInfo + 1] = ("%d) %s  [%s]%s"):format(i, a:sub(1, 70), t, hint)
                        end
                        c.argShort = table.concat(args, ", "):sub(1, 70)
                    end
                elseif m.kind == "listen" then
                    c.how = rest:match("^:(%a+)")
                    local p = rest:match("function%s*%(([^%)]*)%)")
                    if p then c.params = splitTop(p) end
                else
                    if rest:match("^%s*=") then
                        c.how = "handler assigned here"
                        local p = rest:match("function%s*%(([^%)]*)%)")
                        if p then c.params = splitTop(p) end
                    else
                        c.how = "read / called"
                    end
                end
                calls[#calls + 1] = c
            end
        end
    end
    return calls
end

-- ================================================================ data

local groups = {}       -- remote name -> { name, class, instances = {{path, class}}, uses = {}, ev = {} }
local entries = {}      -- scripts: { full, label, cls, hits, calls, code, live = {} }
local entryByFull = {}
local skipped, failed = {}, {}
local scriptCount, withHits, totalHits, unresolvedCalls = 0, 0, 0, 0

local function getGroup(name)
    local g = groups[name]
    if not g then
        g = { name = name, instances = {}, uses = {}, ev = {} }
        groups[name] = g
    end
    return g
end

local function groupDesc(g)
    if #g.instances == 1 then
        return ("%s  [%s]"):format(g.instances[1].path, g.instances[1].class)
    elseif #g.instances > 1 then
        local p = {}
        for i, inst in ipairs(g.instances) do
            if i > 4 then
                p[#p + 1] = ("... +%d more"):format(#g.instances - 4)
                break
            end
            p[#p + 1] = inst.path
        end
        return ("%d remotes share this name: %s"):format(#g.instances, table.concat(p, " | "))
    end
    return "not in the game tree (made at runtime, or the name is only a guess)"
end

local function formatCall(c, idx)
    local out = {}
    out[#out + 1] = ("#%d  L%d  %s   (%s)"):format(idx, c.line, c.method, c.dir)
    if c.name and c.group then
        local cls = (#c.group.instances == 1) and ("  [" .. c.group.instances[1].class .. "]") or ""
        out[#out + 1] = "   remote : " .. c.name .. cls
        out[#out + 1] = "   path   : " .. groupDesc(c.group)
    else
        local r = (c.recv ~= "") and ("  (receiver: " .. c.recv:sub(1, 80) .. ")") or ""
        out[#out + 1] = "   remote : ? could not resolve" .. r
    end
    if c.via then out[#out + 1] = "   via    : " .. c.via end
    if c.args then
        if #c.args == 0 then
            out[#out + 1] = "   args   : none"
        else
            out[#out + 1] = ("   args   : %d%s"):format(#c.args, c.argsOpen and "  (call goes on in the next lines)" or "")
            for _, a in ipairs(c.argInfo) do out[#out + 1] = "      " .. a end
        end
    end
    if c.how then out[#out + 1] = "   mode   : " .. c.how end
    if c.params then
        out[#out + 1] = "   params : (" .. table.concat(c.params, ", ") .. ")"
    end
    if c.inside then
        out[#out + 1] = ("   inside : %s  (L%d)"):format(c.inside, c.insideLine)
    else
        out[#out + 1] = "   inside : top level of the script"
    end
    return table.concat(out, "\n")
end

local function entryText(e, unlimited)
    local out = { ("==== %s  [%s]  %d hits ===="):format(e.full, e.cls, e.hits) }

    local names, seen = {}, {}
    for _, c in ipairs(e.calls) do
        local nm = c.name or ("?" .. c.recv:sub(1, 30))
        if not seen[nm] then
            seen[nm] = true
            names[#names + 1] = nm
        end
    end
    if #names > 0 then out[#out + 1] = "remotes used: " .. table.concat(names, ", ") end

    if #e.calls > 0 then
        out[#out + 1] = ""
        out[#out + 1] = "---- CALLS ----"
        for i, c in ipairs(e.calls) do
            if not unlimited and i > MAX_CALLS_SHOWN then
                out[#out + 1] = ("... +%d more calls (Copy sel. or the saved report has them all)"):format(#e.calls - MAX_CALLS_SHOWN)
                break
            end
            out[#out + 1] = formatCall(c, i)
        end
    end

    if #e.live > 0 then
        out[#out + 1] = ""
        out[#out + 1] = "---- LIVE (deep scan, closures running in memory) ----"
        for _, l in ipairs(e.live) do
            local how = (l.how == "upvalue") and "holds the remote" or "name sits next to a remote call"
            out[#out + 1] = ("%s   %s   %s"):format(l.name, how, (l.methods ~= "") and l.methods or "no call seen")
            local g = groups[l.name]
            if g then out[#out + 1] = "   path : " .. groupDesc(g) end
        end
    end

    if e.code ~= "" then
        out[#out + 1] = ""
        out[#out + 1] = "---- CODE ( > marks the line with the remote call ) ----"
        out[#out + 1] = e.code
    end
    return table.concat(out, "\n")
end

local function groupText(g, unlimited)
    local out = { "==== remote: " .. g.name .. " ====" }
    out[#out + 1] = "class : " .. (g.class or "unknown")
    out[#out + 1] = "where : " .. groupDesc(g)
    out[#out + 1] = ""
    out[#out + 1] = ("client references from the text scan: %d"):format(#g.uses)
    for i, u in ipairs(g.uses) do
        if not unlimited and i > 60 then
            out[#out + 1] = ("  ... +%d more"):format(#g.uses - 60)
            break
        end
        local a = (u.argShort ~= "") and ("   (" .. u.argShort .. ")") or ""
        out[#out + 1] = ("  %-14s %s  L%d%s"):format(u.method, u.script, u.line, a)
    end
    if #g.uses == 0 then
        out[#out + 1] = "  none found (server fired, built at runtime, or the names are hidden in the decompile)"
    end
    if #g.ev > 0 then
        out[#out + 1] = ""
        out[#out + 1] = ("live evidence from the deep scan: %d"):format(#g.ev)
        for _, v in ipairs(g.ev) do
            local how = (v.how == "upvalue") and "holds it" or "name next to a call"
            out[#out + 1] = ("  %s   %s   %s"):format(v.script, how, (v.methods ~= "") and v.methods or "no call seen")
        end
    end
    return table.concat(out, "\n")
end

local function newEntry(full, label, cls, hits, calls, code)
    return { full = full, label = label, cls = cls, hits = hits, calls = calls, code = code, live = {} }
end

local function link(c, full)
    if not c.name then
        unresolvedCalls += 1
        return
    end
    local known = groups[c.name]
    if c.nameKind == "ident" and not (known and #known.instances > 0) then
        c.name = nil -- a bare variable name tells nothing about the remote
        unresolvedCalls += 1
        return
    end
    c.group = getGroup(c.name)
    c.group.uses[#c.group.uses + 1] = {
        script = full, line = c.line, method = c.method, argShort = c.argShort or "",
    }
end

-- ================================================================ ui

local C = {
    bg     = Color3.fromRGB(24, 24, 30),
    bar    = Color3.fromRGB(34, 34, 44),
    btn    = Color3.fromRGB(48, 48, 62),
    sel    = Color3.fromRGB(88, 70, 160),
    accent = Color3.fromRGB(140, 110, 255),
    text   = Color3.fromRGB(230, 230, 240),
    dim    = Color3.fromRGB(150, 150, 170),
    view   = Color3.fromRGB(16, 16, 20),
}

local function make(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    o.Parent = parent
    return o
end

local guiParent
if gethui then
    local ok, h = pcall(gethui)
    if ok and typeof(h) == "Instance" then guiParent = h end
end
guiParent = guiParent or Players.LocalPlayer:WaitForChild("PlayerGui")

for _, name in ipairs({ "RemoteScanUI" }) do
    local old = guiParent:FindFirstChild(name)
    if old then old:Destroy() end
end

local cam = workspace.CurrentCamera
local vp = cam and cam.ViewportSize or Vector2.new(800, 600)
local W = math.min(460, vp.X - 20)
local H = math.min(330, vp.Y - 20)

local gui = make("ScreenGui", {
    Name = "RemoteScanUI",
    ResetOnSpawn = false,
    DisplayOrder = 999,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, guiParent)

local main = make("Frame", {
    Size = UDim2.fromOffset(W, H),
    Position = UDim2.new(0.5, -W / 2, 0.5, -H / 2),
    BackgroundColor3 = C.bg,
    BorderSizePixel = 0,
    Active = true,
}, gui)
make("UICorner", { CornerRadius = UDim.new(0, 8) }, main)

local title = make("Frame", {
    Size = UDim2.new(1, 0, 0, 30),
    BackgroundColor3 = C.bar,
    BorderSizePixel = 0,
}, main)
make("UICorner", { CornerRadius = UDim.new(0, 8) }, title)
make("Frame", { -- squares off the bottom corners of the title bar
    Size = UDim2.new(1, 0, 0, 8),
    Position = UDim2.new(0, 0, 1, -8),
    BackgroundColor3 = C.bar,
    BorderSizePixel = 0,
}, title)
make("TextLabel", {
    Size = UDim2.new(1, -70, 1, 0),
    Position = UDim2.fromOffset(10, 0),
    BackgroundTransparency = 1,
    Text = "RemoteScan",
    TextXAlignment = Enum.TextXAlignment.Left,
    Font = Enum.Font.GothamBold,
    TextSize = 14,
    TextColor3 = C.text,
}, title)

local function titleButton(text, offset)
    return make("TextButton", {
        Size = UDim2.fromOffset(30, 30),
        Position = UDim2.new(1, offset, 0, 0),
        BackgroundTransparency = 1,
        Text = text,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        TextColor3 = C.dim,
    }, title)
end
local minBtn = titleButton("-", -60)
local closeBtn = titleButton("X", -30)

local body = make("Frame", {
    Size = UDim2.new(1, 0, 1, -30),
    Position = UDim2.fromOffset(0, 30),
    BackgroundTransparency = 1,
}, main)

local barBg = make("Frame", {
    Size = UDim2.new(1, -16, 0, 6),
    Position = UDim2.fromOffset(8, 6),
    BackgroundColor3 = C.btn,
    BorderSizePixel = 0,
}, body)
make("UICorner", { CornerRadius = UDim.new(1, 0) }, barBg)
local barFill = make("Frame", {
    Size = UDim2.fromScale(0, 1),
    BackgroundColor3 = C.accent,
    BorderSizePixel = 0,
}, barBg)
make("UICorner", { CornerRadius = UDim.new(1, 0) }, barFill)

local statusLabel = make("TextLabel", {
    Size = UDim2.new(1, -16, 0, 16),
    Position = UDim2.fromOffset(8, 14),
    BackgroundTransparency = 1,
    Text = "starting...",
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextColor3 = C.dim,
}, body)

local function tabButton(text, x)
    local b = make("TextButton", {
        Size = UDim2.fromOffset(72, 22),
        Position = UDim2.fromOffset(x, 32),
        BackgroundColor3 = C.btn,
        BorderSizePixel = 0,
        Text = text,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = C.text,
    }, body)
    make("UICorner", { CornerRadius = UDim.new(0, 5) }, b)
    return b
end
local tabScripts = tabButton("Scripts", 8)
local tabRemotes = tabButton("Remotes", 86)

local filterBox = make("TextBox", {
    Size = UDim2.new(1, -174, 0, 22),
    Position = UDim2.fromOffset(166, 32),
    BackgroundColor3 = C.view,
    BorderSizePixel = 0,
    Text = "",
    PlaceholderText = "filter: remote, arg, script...",
    PlaceholderColor3 = C.dim,
    ClearTextOnFocus = false,
    TextXAlignment = Enum.TextXAlignment.Left,
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextColor3 = C.text,
}, body)
make("UICorner", { CornerRadius = UDim.new(0, 5) }, filterBox)
make("UIPadding", { PaddingLeft = UDim.new(0, 6) }, filterBox)

local function makeList()
    local l = make("ScrollingFrame", {
        Size = UDim2.new(0, 150, 1, -98),
        Position = UDim2.fromOffset(8, 58),
        BackgroundColor3 = C.view,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
    }, body)
    make("UICorner", { CornerRadius = UDim.new(0, 5) }, l)
    make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2) }, l)
    make("UIPadding", { PaddingTop = UDim.new(0, 3), PaddingLeft = UDim.new(0, 3) }, l)
    return l
end
local listScripts = makeList()
local listRemotes = makeList()
listRemotes.Visible = false

local viewer = make("ScrollingFrame", {
    Size = UDim2.new(1, -174, 1, -98),
    Position = UDim2.fromOffset(166, 58),
    BackgroundColor3 = C.view,
    BorderSizePixel = 0,
    ScrollBarThickness = 4,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
}, body)
make("UICorner", { CornerRadius = UDim.new(0, 5) }, viewer)
local viewerText = make("TextLabel", {
    Size = UDim2.new(1, -8, 0, 0),
    Position = UDim2.fromOffset(4, 4),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1,
    Text = "scanning...\ntap a script on the left to see its remote calls",
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
    Font = Enum.Font.Code,
    TextSize = 11,
    TextColor3 = C.text,
}, viewer)

local btnRow = make("Frame", {
    Size = UDim2.new(1, -16, 0, 28),
    Position = UDim2.new(0, 8, 1, -34),
    BackgroundTransparency = 1,
}, body)
make("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    Padding = UDim.new(0, 6),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, btnRow)

local function rowButton(text, order)
    local b = make("TextButton", {
        Size = UDim2.new(0.2, -5, 1, 0),
        LayoutOrder = order,
        BackgroundColor3 = C.btn,
        BorderSizePixel = 0,
        Text = text,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextColor3 = C.text,
    }, btnRow)
    make("UICorner", { CornerRadius = UDim.new(0, 5) }, b)
    b:SetAttribute("base", text)
    return b
end
local stopBtn = rowButton("Stop", 1)
local deepBtn = rowButton("Deep scan", 2)
local copyAllBtn = rowButton("Copy all", 3)
local copySelBtn = rowButton("Copy sel.", 4)
local saveBtn = rowButton("Save", 5)

local function flash(btn, msg)
    btn.Text = msg
    task.delay(1.2, function()
        if btn.Parent then btn.Text = btn:GetAttribute("base") end
    end)
end

-- drag (mouse and touch)
local dragging, dragStart, startPos = false, nil, nil
title.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = main.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then dragging = false end
        end)
    end
end)
local dragConn = UIS.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local d = input.Position - dragStart
        main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
    end
end)

-- ================================================================ ui logic

local stopFlag, deepStop = false, false
local scanFinished, deepRunning = false, false
local scriptButtons, remoteButtons = {}, {}
local sel = { kind = nil, obj = nil, btn = nil }

local function setStatus(text)
    statusLabel.Text = text
end

local function showItem(kind, obj, btn)
    if sel.btn and sel.btn.Parent then sel.btn.BackgroundColor3 = C.btn end
    sel.kind, sel.obj, sel.btn = kind, obj, btn
    if btn then btn.BackgroundColor3 = C.sel end
    local t = (kind == "script") and entryText(obj, false) or groupText(obj, false)
    if #t > MAX_SHOWN then
        t = t:sub(1, MAX_SHOWN) .. "\n... (cut here, Copy sel. gives the whole thing)"
    end
    viewerText.Text = t
    viewer.CanvasPosition = Vector2.zero
end

local function selectedText()
    if sel.kind == "script" then return entryText(sel.obj, true) end
    if sel.kind == "remote" then return groupText(sel.obj, true) end
    return nil
end

local function entryLabel(e)
    local prefix = (e.hits > 0) and tostring(e.hits) or "live"
    if e.hits > 0 and #e.live > 0 then prefix = prefix .. "+" end
    return ("%s  %s"):format(prefix, e.label)
end

local function addEntry(e)
    entries[#entries + 1] = e
    entryByFull[e.full] = e
    local b = make("TextButton", {
        Size = UDim2.new(1, -6, 0, 24),
        LayoutOrder = (e.hits > 0) and -e.hits or 1000,
        BackgroundColor3 = C.btn,
        BorderSizePixel = 0,
        Text = entryLabel(e),
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextColor3 = C.text,
    }, listScripts)
    make("UICorner", { CornerRadius = UDim.new(0, 4) }, b)
    make("UIPadding", { PaddingLeft = UDim.new(0, 6) }, b)
    scriptButtons[e] = b
    b.MouseButton1Click:Connect(function() showItem("script", e, b) end)
    if not sel.kind then showItem("script", e, b) end
end

local function classTag(g)
    if g.class == "RemoteFunction" then return "RF" end
    if g.class == "UnreliableRemoteEvent" then return "UE" end
    if g.class == "RemoteEvent" then return "RE" end
    return "??"
end

local applyFilter

local function rebuildRemotes()
    for _, b in pairs(remoteButtons) do b:Destroy() end
    table.clear(remoteButtons)

    local arr = {}
    for _, g in pairs(groups) do arr[#arr + 1] = g end
    table.sort(arr, function(a, b)
        if #a.uses ~= #b.uses then return #a.uses > #b.uses end
        return a.name:lower() < b.name:lower()
    end)

    for i, g in ipairs(arr) do
        local refs = tostring(#g.uses) .. ((#g.ev > 0) and "+" or "")
        local b = make("TextButton", {
            Size = UDim2.new(1, -6, 0, 24),
            LayoutOrder = i,
            BackgroundColor3 = C.btn,
            BorderSizePixel = 0,
            Text = ("%s  %s  %s"):format(refs, g.name, classTag(g)),
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Font = Enum.Font.Gotham,
            TextSize = 11,
            TextColor3 = C.text,
        }, listRemotes)
        make("UICorner", { CornerRadius = UDim.new(0, 4) }, b)
        make("UIPadding", { PaddingLeft = UDim.new(0, 6) }, b)
        remoteButtons[g] = b
        b.MouseButton1Click:Connect(function() showItem("remote", g, b) end)
    end

    if sel.kind == "remote" then
        local b = remoteButtons[sel.obj]
        sel.btn = b
        if b then b.BackgroundColor3 = C.sel end
    end
    if applyFilter then applyFilter() end
end

applyFilter = function()
    local q = filterBox.Text:lower()
    for e, b in pairs(scriptButtons) do
        b.Visible = (q == "") or (entryText(e, true):lower():find(q, 1, true) ~= nil)
    end
    for g, b in pairs(remoteButtons) do
        b.Visible = (q == "") or (groupText(g, true):lower():find(q, 1, true) ~= nil)
    end
end

local filterToken = 0
filterBox:GetPropertyChangedSignal("Text"):Connect(function()
    filterToken += 1
    local mine = filterToken
    task.delay(0.3, function()
        if mine == filterToken and gui.Parent then applyFilter() end
    end)
end)

local function setTab(t)
    listScripts.Visible = (t == "scripts")
    listRemotes.Visible = (t == "remotes")
    tabScripts.BackgroundColor3 = (t == "scripts") and C.sel or C.btn
    tabRemotes.BackgroundColor3 = (t == "remotes") and C.sel or C.btn
    if t == "remotes" then rebuildRemotes() end
end
tabScripts.MouseButton1Click:Connect(function() setTab("scripts") end)
tabRemotes.MouseButton1Click:Connect(function() setTab("remotes") end)
setTab("scripts")

local function buildReport()
    local sorted = table.clone(entries)
    table.sort(sorted, function(a, b) return a.hits > b.hits end)

    local gs, remoteCount = {}, 0
    for _, g in pairs(groups) do
        gs[#gs + 1] = g
        if #g.instances > 0 then remoteCount += #g.instances end
    end
    table.sort(gs, function(a, b)
        if #a.uses ~= #b.uses then return #a.uses > #b.uses end
        return a.name:lower() < b.name:lower()
    end)

    local out = {}
    out[#out + 1] = ("RemoteScan | place %s | %d scripts | %d with remote calls | %d hits | %d remotes in the game | %d calls not resolved"):format(
        tostring(game.PlaceId), scriptCount, withHits, totalHits, remoteCount, unresolvedCalls)
    out[#out + 1] = ("decompile failed: %d | timed out: %d"):format(#failed, #skipped)
    out[#out + 1] = ""
    out[#out + 1] = "---- REMOTES (most client references first) ----"
    for _, g in ipairs(gs) do
        out[#out + 1] = ("%4d refs  %-3s %s   %s"):format(#g.uses, classTag(g), g.name, groupDesc(g))
    end
    out[#out + 1] = ""
    out[#out + 1] = "---- SCRIPTS (most hits first) ----"
    for _, e in ipairs(sorted) do
        out[#out + 1] = ("%4d hits  %s"):format(e.hits, e.full)
    end
    out[#out + 1] = ""
    out[#out + 1] = "---- SCRIPT DETAILS ----"
    out[#out + 1] = ""
    for _, e in ipairs(sorted) do
        out[#out + 1] = entryText(e, true)
        out[#out + 1] = ""
    end
    out[#out + 1] = "---- REMOTE DETAILS (remotes with references) ----"
    out[#out + 1] = ""
    for _, g in ipairs(gs) do
        if #g.uses > 0 or #g.ev > 0 then
            out[#out + 1] = groupText(g, true)
            out[#out + 1] = ""
        end
    end
    if #skipped > 0 then
        out[#out + 1] = "---- TIMED OUT (not scanned) ----"
        out[#out + 1] = table.concat(skipped, "\n")
        out[#out + 1] = ""
    end
    if #failed > 0 then
        out[#out + 1] = "---- DECOMPILE FAILED / EMPTY ----"
        out[#out + 1] = table.concat(failed, "\n")
    end
    return table.concat(out, "\n")
end

-- ================================================================ deep scan (closures in memory)

local function isLuaClosure(f)
    if not islclosure then return true end
    local ok, r = pcall(islclosure, f)
    return ok and r == true
end

local function isExecutorFn(f)
    if not isexecutorclosure then return false end
    local ok, r = pcall(isexecutorclosure, f)
    return ok and r == true
end

local function deepScan()
    if deepRunning then return end
    if not scanFinished then
        flash(deepBtn, "wait for scan")
        return
    end
    local getUp = (debug and debug.getupvalues) or getupvalues
    local getConst = (debug and debug.getconstants) or getconstants
    if not (getgc and getUp and getConst) then
        flash(deepBtn, "unsupported")
        return
    end

    deepRunning, deepStop = true, false
    deepBtn.Text = "Deep: running"
    stopBtn.Text = "Stop"

    task.spawn(function()
        local checked, found = 0, 0
        local ok, err = pcall(function()
            local okGc, gc = pcall(getgc, true)
            if not okGc or type(gc) ~= "table" then error("getgc failed") end
            local total = #gc
            local t0 = os.clock()
            local evid = {}

            for i = 1, total do
                if deepStop or not gui.Parent or os.clock() - t0 > GC_SECONDS then break end
                local f = gc[i]
                if type(f) == "function" and isLuaClosure(f) and not isExecutorFn(f) then
                    local okE, scr = pcall(function() return getfenv(f).script end)
                    if okE and typeof(scr) == "Instance" and (scr:IsA("LocalScript") or scr:IsA("ModuleScript")) and not engineOwned(scr) then
                        checked += 1
                        local methods, names, callSeen = {}, {}, false

                        local okC, consts = pcall(getConst, f)
                        if okC and type(consts) == "table" then
                            for _, c in pairs(consts) do
                                if type(c) == "string" then
                                    if METHOD_SET[c] then
                                        methods[c] = true
                                        callSeen = true
                                    elseif groups[c] and #groups[c].instances > 0 then
                                        names[c] = names[c] or "constant"
                                    end
                                end
                            end
                        end

                        local okU, ups = pcall(getUp, f)
                        if okU and type(ups) == "table" then
                            for _, u in pairs(ups) do
                                if typeof(u) == "Instance" and REMOTE_CLASS[u.ClassName] and not engineOwned(u) then
                                    names[u.Name] = "upvalue"
                                end
                            end
                        end

                        local full = nil
                        for name, how in pairs(names) do
                            if how == "upvalue" or callSeen then
                                full = full or scr:GetFullName()
                                local ev = evid[full]
                                if not ev then
                                    ev = { scr = scr, remotes = {} }
                                    evid[full] = ev
                                end
                                local rec = ev.remotes[name]
                                if not rec then
                                    rec = { how = how, methods = {} }
                                    ev.remotes[name] = rec
                                end
                                if how == "upvalue" then rec.how = "upvalue" end
                                for m in pairs(methods) do rec.methods[m] = true end
                            end
                        end
                    end
                end
                if i % 400 == 0 then
                    setStatus(("deep scan: %d / %d objects, %d script functions checked"):format(i, total, checked))
                    barFill.Size = UDim2.fromScale(i / total, 1)
                    task.wait()
                end
            end

            -- merge the evidence into the scripts and the remotes
            for _, g in pairs(groups) do g.ev = {} end
            for _, e in ipairs(entries) do e.live = {} end

            for full, ev in pairs(evid) do
                local e = entryByFull[full]
                if not e then
                    local scr = ev.scr
                    local label = (scr.Parent and (scr.Parent.Name .. ".") or "") .. scr.Name
                    e = newEntry(full, label, scr.ClassName, 0, {}, "")
                    addEntry(e)
                end
                found += 1
                for name, rec in pairs(ev.remotes) do
                    local ms = {}
                    for m in pairs(rec.methods) do ms[#ms + 1] = m end
                    table.sort(ms)
                    local joined = table.concat(ms, "/")
                    e.live[#e.live + 1] = { name = name, how = rec.how, methods = joined }
                    local g = groups[name]
                    if g then
                        g.ev[#g.ev + 1] = { script = full, how = rec.how, methods = joined }
                    end
                end
                table.sort(e.live, function(a, b) return a.name < b.name end)
            end
        end)

        deepRunning = false
        if not gui.Parent then return end

        if not ok then
            setStatus("deep scan error: " .. tostring(err))
            deepBtn.Text = "Deep scan"
        else
            for e, b in pairs(scriptButtons) do b.Text = entryLabel(e) end
            rebuildRemotes()
            if sel.obj then showItem(sel.kind, sel.obj, sel.btn) end
            setStatus(("deep scan done: %d script functions checked, live remote evidence in %d scripts"):format(checked, found))
            deepBtn.Text = "Deep: done"
            deepBtn:SetAttribute("base", "Deep scan")
        end
        stopBtn.Text = "Done"
    end)
end

-- ================================================================ buttons

stopBtn.MouseButton1Click:Connect(function()
    if deepRunning then
        deepStop = true
        stopBtn.Text = "Stopping"
    elseif not scanFinished and not stopFlag then
        stopFlag = true
        stopBtn.Text = "Stopping"
    end
end)

deepBtn.MouseButton1Click:Connect(deepScan)

copyAllBtn.MouseButton1Click:Connect(function()
    if setclipboard and pcall(setclipboard, buildReport()) then
        flash(copyAllBtn, "Copied")
    else
        flash(copyAllBtn, "no clipboard")
    end
end)

copySelBtn.MouseButton1Click:Connect(function()
    local t = selectedText()
    if not t then
        flash(copySelBtn, "nothing yet")
        return
    end
    if setclipboard and pcall(setclipboard, t) then
        flash(copySelBtn, "Copied")
    else
        flash(copySelBtn, "no clipboard")
    end
end)

saveBtn.MouseButton1Click:Connect(function()
    if writefile and pcall(writefile, OUTFILE, buildReport()) then
        flash(saveBtn, "Saved")
    else
        flash(saveBtn, "no writefile")
    end
end)

local folded = false
minBtn.MouseButton1Click:Connect(function()
    folded = not folded
    body.Visible = not folded
    main.Size = UDim2.fromOffset(W, folded and 30 or H)
    minBtn.Text = folded and "+" or "-"
end)

closeBtn.MouseButton1Click:Connect(function()
    stopFlag = true
    deepStop = true
    dragConn:Disconnect()
    gui:Destroy()
end)

-- ================================================================ static scan

local function decomp(s)
    local result, finished = nil, false
    task.spawn(function()
        local ok, src = pcall(decompile, s)
        result = ok and src or nil
        finished = true
    end)
    local t = os.clock()
    while not finished and os.clock() - t < TIMEOUT do task.wait() end
    return finished and result or nil, finished
end

local function runScan()
    local seenS, scripts, seenR = {}, {}, {}

    local function addScript(s)
        if typeof(s) ~= "Instance" or seenS[s] then return end
        if not (s:IsA("LocalScript") or s:IsA("ModuleScript")) then return end
        if engineOwned(s) then return end -- skip Roblox's own scripts
        seenS[s] = true
        scripts[#scripts + 1] = s
    end

    local function addRemote(inst)
        if typeof(inst) ~= "Instance" or seenR[inst] then return end
        if not REMOTE_CLASS[inst.ClassName] then return end
        if engineOwned(inst) then return end
        seenR[inst] = true
        local g = getGroup(inst.Name)
        g.instances[#g.instances + 1] = { path = inst:GetFullName(), class = inst.ClassName }
        g.class = g.class or inst.ClassName
    end

    setStatus("collecting scripts and remotes...")
    if getscripts then
        local ok, l = pcall(getscripts)
        if ok then for _, s in ipairs(l) do addScript(s) end end
    end
    if getloadedmodules then
        local ok, l = pcall(getloadedmodules)
        if ok then for _, s in ipairs(l) do addScript(s) end end
    end
    for _, d in ipairs(game:GetDescendants()) do
        addScript(d)
        addRemote(d)
    end
    if getnilinstances then
        local ok, l = pcall(getnilinstances)
        if ok then
            for _, d in ipairs(l) do
                addScript(d)
                addRemote(d)
            end
        end
    end

    scriptCount = #scripts
    print(("[RemoteScan] %d scripts to scan"):format(scriptCount))

    for i, s in ipairs(scripts) do
        if stopFlag then break end

        local full = s:GetFullName()
        local src, finished = decomp(s)

        if not finished then
            skipped[#skipped + 1] = full
        elseif not src or src == "" then
            failed[#failed + 1] = full
        else
            local lines = {}
            for line in (src .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end

            local hits, keep = {}, {}
            for n, line in ipairs(lines) do
                if hasPattern(line) then
                    hits[#hits + 1] = n
                    for k = math.max(1, n - CONTEXT), math.min(#lines, n + CONTEXT) do keep[k] = true end
                end
            end

            if #hits > 0 then
                withHits += 1
                totalHits += #hits

                local calls = {}
                for _, n in ipairs(hits) do
                    for _, c in ipairs(analyzeHit(lines, n)) do
                        link(c, full)
                        calls[#calls + 1] = c
                    end
                end

                local code = {}
                local last = 0
                for n = 1, #lines do
                    if keep[n] then
                        if last ~= 0 and n > last + 1 then code[#code + 1] = "   ..." end
                        local mark = hasPattern(lines[n]) and ">" or " "
                        code[#code + 1] = ("%s%5d | %s"):format(mark, n, lines[n])
                        last = n
                    end
                end

                local label = (s.Parent and (s.Parent.Name .. ".") or "") .. s.Name
                addEntry(newEntry(full, label, s.ClassName, #hits, calls, table.concat(code, "\n")))
            end
        end

        barFill.Size = UDim2.fromScale(i / scriptCount, 1)
        setStatus(("%d / %d   |   %d scripts with remotes   |   %d hits"):format(i, scriptCount, withHits, totalHits))
        if i % 10 == 0 then task.wait() end
    end

    scanFinished = true
    if not gui.Parent then return end -- window was closed

    rebuildRemotes()

    local saved = ""
    if writefile and pcall(writefile, OUTFILE, buildReport()) then
        saved = "   |   saved workspace/" .. OUTFILE
    end
    local state = stopFlag and "stopped" or "done"
    local remoteTotal = 0
    for _, g in pairs(groups) do remoteTotal += #g.instances end
    setStatus(("%s: %d hits in %d scripts, %d remotes in the game%s"):format(state, totalHits, withHits, remoteTotal, saved))
    stopBtn.Text = (state == "done") and "Done" or "Stopped"
    if #entries == 0 then
        viewerText.Text = "no remote calls found in the scripts that could be decompiled\ntry Deep scan, it reads the closures in memory"
    end
    print(("[RemoteScan] %s: %d hits in %d scripts"):format(state, totalHits, withHits))
end

task.spawn(function()
    local ok, err = pcall(runScan)
    if not ok then
        scanFinished = true
        warn("[RemoteScan] scan error: " .. tostring(err))
        if gui.Parent then setStatus("error: " .. tostring(err)) end
    end
end)
