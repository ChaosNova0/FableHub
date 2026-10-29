-- Professions tab: who has each profession, who can craft what, and whose
-- profession cooldowns are ready.

local _, ns = ...
local UI = ns.UI

------------------------------------------------------------------------
-- Recipe names (recipe IDs are spell IDs; names may need to load first)
------------------------------------------------------------------------
local nameCache, requested = {}, {}

local function SpellName(id)
  if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
  if GetSpellInfo then return (GetSpellInfo(id)) end
end

function ns.RecipeName(id)
  local cached = nameCache[id]
  if cached then return cached, true end
  local ok, name = pcall(SpellName, id)
  if ok and name and name ~= "" then
    nameCache[id] = name
    return name, true
  end
  if not requested[id] and C_Spell and C_Spell.RequestLoadSpellData then
    requested[id] = true
    pcall(C_Spell.RequestLoadSpellData, id)
  end
  return "Recipe #" .. id, false
end

function ns.RecipeLink(id)
  local fn = (C_Spell and C_Spell.GetSpellLink) or GetSpellLink
  if not fn then return nil end
  local ok, link = pcall(fn, id)
  return ok and link or nil
end

local loadPending = false
ns.RegisterEvent("SPELL_DATA_LOAD_RESULT", function(id, success)
  if success and requested[id] then
    nameCache[id] = nil
    if not loadPending then
      loadPending = true
      C_Timer.After(0.5, function() loadPending = false; ns.Fire("DATA_CHANGED") end)
    end
  end
end)

------------------------------------------------------------------------
-- Aggregate everyone's professions
------------------------------------------------------------------------
-- Profession groups. Anything not listed (e.g. a new Forever profession) counts as crafting.
ns.PROF_CATEGORY = {
  [182] = "gather", [186] = "gather", [393] = "gather",                       -- Herbalism, Mining, Skinning
  [185] = "secondary", [356] = "secondary", [129] = "secondary", [794] = "secondary", -- Cooking, Fishing, First Aid, Archaeology
}
ns.PROF_CATEGORY_NAMES = { craft = "CRAFTING", gather = "GATHERING", secondary = "SECONDARY" }
function ns.ProfCategory(skillLine) return ns.PROF_CATEGORY[skillLine] or "craft" end

-- professions that make gear: these get the Slot and Armor filters
local GEAR = { [164] = true, [165] = true, [197] = true, [202] = true } -- Blacksmithing, Leatherworking, Tailoring, Engineering

function ns.Crafting()
  local profs = {}
  for _, m in ipairs(ns.AllMembers()) do
    local rec = m.rec
    if rec and rec.profs then
      local online = (m.roster and m.roster.online) or m.key == ns.MyKey()
      for skillLine, p in pairs(rec.profs) do
        local agg = profs[skillLine]
        if not agg then
          agg = { skillLine = skillLine, name = p.name, crafters = {}, recipes = {}, outputs = {} }
          profs[skillLine] = agg
        end
        local recipeCount = ns.CountRecipes(p)
        table.insert(agg.crafters, {
          key = m.key, class = rec.class or (m.roster and m.roster.class), online = online, rec = rec,
          rank = p.rank or 0, max = p.max or 0, recipeCount = recipeCount, ts = p.scanned or rec.ts,
        })
        for id in pairs(p.recipes or {}) do
          local r = agg.recipes[id]
          if not r then r = {}; agg.recipes[id] = r end
          table.insert(r, agg.crafters[#agg.crafters])
          local out = rec.outputs and rec.outputs[id]
          if out and not agg.outputs[id] then agg.outputs[id] = out end
        end
      end
    end
  end
  return profs
end

local function CrafterNames(crafters, limit)
  table.sort(crafters, function(a, b)
    if a.online ~= b.online then return a.online end
    return a.rank > b.rank
  end)
  local out = {}
  for i, c in ipairs(crafters) do
    if i > limit then
      out[#out + 1] = UI.Dim(("+%d more"):format(#crafters - limit), 0.45)
      break
    end
    local name = ns.ShortName(c.key)
    out[#out + 1] = c.online and UI.Colorize(name, ns.ClassColor(c.class)) or UI.Dim(name, 0.45)
  end
  return table.concat(out, ", ")
end

-- cooldown icons for one profession of a character: "  [icon] Ready"
local function CooldownBits(rec, skillLine, size)
  local out = ""
  for _, cd in ipairs(ns.COOLDOWNS) do
    if cd.skillLine == skillLine then
      local badge = ns.Cooldowns.Badge(rec, cd, size)
      if badge ~= "" then out = out .. "  " .. badge end
    end
  end
  return out
end

------------------------------------------------------------------------
ns.RegisterNavGroup("profgroup", "Professions", "Interface\\Icons\\Trade_BlackSmithing", { "professions", "requests", "campgroup" })

ns.RegisterPanel("professions", "Recipes", nil, function(panel)
  local T = ns.Theme
  local CD, RF = ns.Cooldowns, ns.RecipeFacts
  local selected = "all"     -- skillLine or "all"
  local mode = "recipes"     -- "recipes" | "crafters"
  local filterText = ""
  local cdMode, readyOnly = false, false -- "Cooldown crafts" view, and only who's ready
  local filt, statAll = { slot = {}, armor = {}, stat = {} }, true
  local cdExpanded = { transmute = true }
  local lastProfs = {}

  -- left: profession picker
  local left = UI.CreateList(panel, {
    { title = "Profession", flex = true },
    { title = "#", width = 24, justify = "RIGHT", defaultAsc = false },
  }, 26)
  left:SetPoint("TOPLEFT", 0, -34)
  left:SetPoint("BOTTOMLEFT", 0, 56)
  left:SetWidth(210)
  left.sortable = false

  local S = FableHubDB.settings
  local gatherToggle = T.Toggle(panel, "Show gathering", function(v) S.profShowGather = v; panel:Refresh() end)
  gatherToggle:SetPoint("BOTTOMLEFT", 4, 28)
  gatherToggle:SetChecked(S.profShowGather)
  local secondaryToggle = T.Toggle(panel, "Show secondary", function(v) S.profShowSecondary = v; panel:Refresh() end)
  secondaryToggle:SetPoint("BOTTOMLEFT", 4, 4)
  secondaryToggle:SetChecked(S.profShowSecondary)

  local function Visible(skillLine)
    local cat = ns.ProfCategory(skillLine)
    if cat == "gather" then return S.profShowGather and true or false end
    if cat == "secondary" then return S.profShowSecondary and true or false end
    return true
  end
  -- is this profession part of what's being looked at?
  local function InScope(skillLine)
    if selected == "all" then return Visible(skillLine) end
    return selected == skillLine
  end
  local function ScopeHas(test)
    if selected ~= "all" then return test(selected) and true or false end
    for skillLine in pairs(lastProfs) do
      if Visible(skillLine) and test(skillLine) then return true end
    end
    return false
  end

  local divider = panel:CreateTexture(nil, "ARTWORK")
  divider:SetColorTexture(1, 1, 1, T.border)
  divider:SetPoint("TOPLEFT", panel, "TOPLEFT", 220, 0)
  divider:SetPoint("BOTTOMLEFT", left, "BOTTOMRIGHT", 10, -56)
  divider:SetWidth(1)

  local leftLabel = T.Text(panel, 11, T.section)
  leftLabel:SetPoint("TOPLEFT", 8, -6)
  leftLabel:SetText("PICK A PROFESSION")

  -- right: mode buttons + search
  local recipesBtn = T.Button(panel, "Recipes", 90, 22)
  recipesBtn:SetPoint("TOPLEFT", 232, 0)
  local craftersBtn = T.Button(panel, "Crafters", 90, 22)
  craftersBtn:SetPoint("LEFT", recipesBtn, "RIGHT", 6, 0)

  local search = T.SearchBox(panel, 200, "Search recipes", function(t) filterText = t; panel:Refresh() end)
  search:SetPoint("LEFT", craftersBtn, "RIGHT", 14, 0)

  local info = T.Text(panel, 11, 0.4)

  local expandBtn = T.Button(panel, "Expand all", 90, 22)
  expandBtn:SetPoint("LEFT", search, "RIGHT", 8, 0)
  local sortBtn = T.Button(panel, "Highest level first", 140, 22)
  sortBtn:SetPoint("LEFT", expandBtn, "RIGHT", 4, 0)
  local function ByLevel() return FableHubDB.settings.recipeSortAZ ~= true end
  sortBtn:SetScript("OnClick", function()
    FableHubDB.settings.recipeSortAZ = ByLevel() -- flip
    panel:Refresh()
  end)

  -- filter row
  local filterLabel = T.Text(panel, 11, T.section)
  filterLabel:SetText("FILTER")
  local cdBtn = T.Button(panel, "Cooldown crafts", 120, 22)
  local readyBtn = T.Button(panel, "Ready now only", 110, 22)
  local slotBtn = T.Button(panel, "Slot", 60, 22)
  local armorBtn = T.Button(panel, "Armor", 60, 22)
  local statBtn = T.Button(panel, "Stat", 60, 22)
  local clearBtn = T.Button(panel, "Clear filters", 96, 22)
  local function FitButton(b)
    local fs = b:GetFontString()
    b:SetWidth(math.max(56, math.floor((fs and fs:GetStringWidth() or 40) + 24)))
  end

  local recipeList = UI.CreateList(panel, {
    { title = "Character / recipe", flex = true },
    { title = "Profession", width = 300 },
    { title = "Also crafted by", width = 170 },
  }, 24)
  recipeList.sortable = false
  local expanded = {}
  recipeList:SetPoint("TOPLEFT", 232, -34)
  recipeList:SetPoint("BOTTOMRIGHT", 0, 0)

  local cdList = UI.CreateList(panel, {
    { title = "Cooldown", flex = true },
    { title = "Ready now", width = 190 },
    { title = "Cooling down", width = 250 },
  }, 24)
  cdList.sortable = false
  cdList:SetPoint("TOPLEFT", 232, -34)
  cdList:SetPoint("BOTTOMRIGHT", 0, 0)

  local crafterList = UI.CreateList(panel, {
    { title = "Name", flex = true },
    { title = "Profession", width = 150 },
    { title = "Skill", width = 110, defaultAsc = false, bar = true },
    { title = "Recipes", width = 56, justify = "RIGHT", defaultAsc = false },
    { title = "Cooldowns", width = 120, defaultAsc = false },
    { title = "Updated", width = 64, justify = "RIGHT" },
  }, 24)
  crafterList:SetPoint("TOPLEFT", 232, -34)
  crafterList:SetPoint("BOTTOMRIGHT", 0, 0)
  crafterList.sortCol, crafterList.sortAsc = 3, false

  -- toolbar: Recipes | Crafters on top, search and buttons on the row below,
  -- then the filters (more rows when the window is narrow); the profession
  -- picker narrows too
  local leftW = 210
  local bar = UI.Toolbar(panel, {
    left = function() return leftW + 22 end,
    before = function(w)
      leftW = (w > 0 and w < 640) and 160 or 210
      left:SetWidth(leftW)
      divider:SetPoint("TOPLEFT", panel, "TOPLEFT", leftW + 10, 0)
    end,
  })
  bar:Add(recipesBtn)
  bar:Add(craftersBtn, { gap = 6 })
  bar:Add(search, { newRow = true, grow = true, min = 140 })
  bar:Add(expandBtn, { right = true, gap = 8 })
  bar:Add(sortBtn, { gap = 4 })
  bar:Add(filterLabel, { newRow = true })
  bar:Add(cdBtn, { gap = 8 })
  bar:Add(readyBtn, { gap = 4 })
  bar:Add(slotBtn, { gap = 12 })
  bar:Add(armorBtn, { gap = 4 })
  bar:Add(statBtn, { gap = 4 })
  bar:Add(clearBtn, { right = true, gap = 8 })
  bar:Status(info)
  bar:Below(recipeList)
  bar:Below(cdList)
  bar:Below(crafterList)
  bar:Below(left, { x = 0 })

  ----------------------------------------------------------------------
  -- Filters
  ----------------------------------------------------------------------
  local function HasCooldown(skillLine)
    for _, cd in ipairs(ns.COOLDOWNS) do if cd.skillLine == skillLine then return true end end
    return false
  end
  local ChipVisible
  ChipVisible = function(name)
    if mode ~= "recipes" then return false end
    if name == "cd" then return ScopeHas(HasCooldown) end
    if cdMode and ChipVisible("cd") then return false end
    if name == "slot" or name == "armor" then return ScopeHas(function(s) return GEAR[s] end) end
    return true -- stat
  end
  local function Active(name) return ChipVisible(name) and next(filt[name]) ~= nil end
  local function Filtering() return Active("slot") or Active("armor") or Active("stat") end
  local function CdView() return cdMode and ChipVisible("cd") end

  -- does a recipe pass Slot, Armor and Stat (all but `except`, for the menu counts)?
  local function PassesFilters(id, itemID, except)
    local slot = except ~= "slot" and Active("slot")
    local armor = except ~= "armor" and Active("armor")
    local stat = except ~= "stat" and Active("stat")
    if not (slot or armor or stat) then return true end
    local f = RF.Get(id, itemID)
    if not f then return false end -- still loading; the list refreshes when it arrives
    if slot and not filt.slot[f.slot or ""] then return false end
    if armor and not filt.armor[f.armor or ""] then return false end
    if stat then
      local any, all = false, true
      for s in pairs(filt.stat) do
        if f.stats[s] then any = true else all = false end
      end
      if statAll and not all then return false end
      if not statAll and not any then return false end
    end
    return true
  end

  local function SearchHit(name, itemID)
    if filterText == "" then return true end
    if name:lower():find(filterText, 1, true) then return true end
    local itemInfo = itemID and ns.Loot.ItemInfo(itemID)
    return itemInfo and itemInfo.name:lower():find(filterText, 1, true) and true or false
  end

  -- every recipe in view once: [id] = { name, itemID } (worked out once per refresh)
  local scopeCache
  local function ScopeRecipes()
    if scopeCache then return scopeCache end
    local out = {}
    for skillLine, agg in pairs(lastProfs) do
      if InScope(skillLine) then
        for id in pairs(agg.recipes) do
          if not out[id] then
            local name = ns.RecipeName(id)
            out[id] = { name = name, itemID = agg.outputs[id] or ns.Loot.FindItemByName(name) }
          end
        end
      end
    end
    scopeCache = out
    return out
  end

  -- does a recipe give every ticked stat? (Stat "All" menu counts)
  local function HasAllTicked(stats)
    for s in pairs(filt.stat) do if not stats[s] then return false end end
    return true
  end

  local function MenuOptions(name)
    local counts = {}
    -- Stat "All": the count for X is how many recipes give every ticked stat and X,
    -- i.e. what the list would show if you ticked X too
    local needAll = name == "stat" and statAll and Active("stat")
    for id, r in pairs(ScopeRecipes()) do
      if SearchHit(r.name, r.itemID) and PassesFilters(id, r.itemID, name) then
        local f = RF.Get(id, r.itemID)
        if f then
          if name == "stat" then
            if not needAll or HasAllTicked(f.stats) then
              for s in pairs(f.stats) do counts[s] = (counts[s] or 0) + 1 end
            end
          else
            local v = name == "slot" and f.slot or f.armor
            if v then counts[v] = (counts[v] or 0) + 1 end
          end
        end
      end
    end
    local out = {}
    if name == "stat" then
      for _, s in ipairs(RF.STATS) do
        out[#out + 1] = s and { value = s[1], text = s[2], count = counts[s[1]] or 0, checked = filt.stat[s[1]] } or false
      end
    else
      for _, v in ipairs(name == "slot" and RF.SLOTS or RF.ARMORS) do
        out[#out + 1] = { value = v, text = v, count = counts[v] or 0, checked = filt[name][v] }
      end
    end
    return out
  end

  local menus = {}
  for name, title in pairs({ slot = "Slot", armor = "Armor type", stat = "Must have" }) do
    menus[name] = {
      title = title, width = name == "stat" and 230 or 200,
      options = function() return MenuOptions(name) end,
      onToggle = function(v) filt[name][v] = (not filt[name][v]) or nil; panel:Refresh() end,
      onClear = function() filt[name] = {}; panel:Refresh() end,
    }
  end
  menus.stat.mode = {
    labels = { "All", "Any" },
    get = function() return statAll and 1 or 2 end,
    set = function(i) statAll = i == 1; panel:Refresh() end,
  }
  slotBtn:SetScript("OnClick", function(self) T.CheckMenu(self, menus.slot) end)
  armorBtn:SetScript("OnClick", function(self) T.CheckMenu(self, menus.armor) end)
  statBtn:SetScript("OnClick", function(self) T.CheckMenu(self, menus.stat) end)
  cdBtn:SetScript("OnClick", function()
    cdMode = not cdMode
    if not cdMode then readyOnly = false end
    T.CloseCheckMenu()
    panel:Refresh()
  end)
  readyBtn:SetScript("OnClick", function() readyOnly = not readyOnly; panel:Refresh() end)
  clearBtn:SetScript("OnClick", function()
    filt = { slot = {}, armor = {}, stat = {} }
    cdMode, readyOnly = false, false
    T.CloseCheckMenu()
    panel:Refresh()
  end)
  panel:HookScript("OnHide", T.CloseCheckMenu)

  -- "Stat: Agility, Stamina +1"
  local function ChipText(name, base)
    if not Active(name) then return base end
    local vals = {}
    if name == "stat" then
      for _, s in ipairs(RF.STATS) do if s and filt.stat[s[1]] then vals[#vals + 1] = s[2] end end
    else
      for _, v in ipairs(name == "slot" and RF.SLOTS or RF.ARMORS) do if filt[name][v] then vals[#vals + 1] = v end end
    end
    local shown = #vals > 2 and (vals[1] .. ", " .. vals[2] .. " +" .. (#vals - 2)) or table.concat(vals, ", ")
    return base .. ": " .. shown
  end

  local function PaintFilters()
    filterLabel:SetShown(mode == "recipes")
    cdBtn:SetShown(ChipVisible("cd"))
    cdBtn:SetSelected(cdMode)
    readyBtn:SetShown(CdView())
    readyBtn:SetSelected(readyOnly)
    for name, b in pairs({ slot = slotBtn, armor = armorBtn, stat = statBtn }) do
      b:SetShown(ChipVisible(name))
      b:SetText(ChipText(name, ({ slot = "Slot", armor = "Armor", stat = "Stat" })[name]))
      b:SetSelected(Active(name))
      FitButton(b)
    end
    clearBtn:SetShown(CdView() or Filtering())
    if not ChipVisible("slot") and not ChipVisible("stat") then T.CloseCheckMenu() end
  end

  local function SetMode(m)
    mode = m
    recipesBtn:SetSelected(m == "recipes")
    craftersBtn:SetSelected(m == "crafters")
    T.CloseCheckMenu()
    panel:Refresh()
  end
  recipesBtn:SetScript("OnClick", function() SetMode("recipes") end)
  expandBtn:SetScript("OnClick", function()
    if CdView() then
      local anyClosed = false
      for _, cd in ipairs(ns.COOLDOWNS) do if not cdExpanded[cd.id] then anyClosed = true end end
      for _, cd in ipairs(ns.COOLDOWNS) do cdExpanded[cd.id] = anyClosed end
      panel:Refresh()
      return
    end
    local anyClosed = false
    local keys = {}
    for skillLine, agg in pairs(ns.Crafting()) do
      if InScope(skillLine) then
        for _, c in ipairs(agg.crafters) do
          if c.recipeCount > 0 then keys[c.key] = true; if not expanded[c.key] then anyClosed = true end end
        end
      end
    end
    for k in pairs(keys) do expanded[k] = anyClosed end
    panel:Refresh()
  end)
  craftersBtn:SetScript("OnClick", function() SetMode("crafters") end)

  ----------------------------------------------------------------------
  -- Tooltips and clicks
  ----------------------------------------------------------------------
  local function RecipeTooltip(tt, item)
    local ok = pcall(tt.SetSpellByID, tt, item.id)
    if not ok then tt:AddLine(item.name) end
    tt:AddLine(" ")
    tt:AddLine("Can craft", 1, 0.82, 0)
    for _, c in ipairs(item.crafters) do
      local right = c.rank .. "/" .. c.max
      local cdInfo = item.cd and c.rec and CD.Info(c.rec, item.cd.id)
      if cdInfo then right = CD.Text(cdInfo) end
      tt:AddDoubleLine(ns.Icons.Dot(c.online) .. " " .. UI.ClassName(c.key, c.class), right, 1, 1, 1, 0.7, 0.7, 0.7)
    end
    if item.cd and item.cd.note then tt:AddLine(item.cd.note, 0.7, 0.7, 0.7, true) end
    tt:AddLine(" ")
    tt:AddLine("Shift-click to link. Right-click to request it or whisper a crafter.", 0.6, 0.6, 0.6, true)
  end

  local function RecipeClick(item, button)
    if IsShiftKeyDown() then
      UI.InsertLink(ns.RecipeLink(item.id))
    elseif button == "RightButton" then
      local menu = {
        { text = "Request this from the guild", onClick = function()
            if ns.Requests and ns.Requests.OpenNew then ns.Requests.OpenNew(item.id, item.skillLine, item.itemID) end
          end },
      }
      for _, c in ipairs(item.crafters) do
        local cdInfo = item.cd and c.rec and CD.Info(c.rec, item.cd.id)
        -- for a cooldown craft, whisper someone whose cooldown is ready
        if c.online and c.key ~= ns.MyKey() and (not item.cd or (cdInfo and cdInfo.state == "ready")) then
          menu[#menu + 1] = { text = "Whisper " .. ns.ShortName(c.key), onClick = function()
            local link = ns.RecipeLink(item.id) or item.name
            UI.Whisper(c.key, "Hi! Could you craft " .. link .. " for me?")
          end }
          break
        end
      end
      T.Menu(recipeList, menu, 220)
    end
  end

  local function CrafterTooltip(tt, item)
    local c = item.crafter
    tt:AddLine(ns.Icons.Class(c.class, 16) .. " " .. ns.ShortName(c.key), ns.ClassColor(c.class))
    tt:AddLine(("%s %s  %d/%d"):format(ns.Icons.Prof(item.skillLine, 14), item.profName, c.rank, c.max), 1, 1, 1)
    if c.recipeCount == 0 then
      tt:AddLine("Hasn't opened this profession since installing FableHub, so recipes aren't listed yet.", 0.7, 0.7, 0.7, true)
    end
    for _, cd in ipairs(ns.COOLDOWNS) do
      if cd.skillLine == item.skillLine then CD.AddTooltip(tt, c.rec, cd) end
    end
    tt:AddLine(c.online and "|cff40d66eOnline|r" or "|cff999999Offline|r")
    tt:AddLine("Right-click to whisper", 0.6, 0.6, 0.6)
  end

  local function CooldownTooltip(tt, item)
    local cd = item.cd
    tt:AddLine(CD.Icon(cd, "ready", 16) .. " " .. cd.name, 1, 1, 1)
    local profName = lastProfs[cd.skillLine] and lastProfs[cd.skillLine].name
    if profName then tt:AddLine(profName, 0.7, 0.7, 0.7) end
    if cd.note then tt:AddLine(cd.note, 0.7, 0.7, 0.7, true) end
    tt:AddLine(" ")
    for _, h in ipairs(item.holders) do
      local info = h.info
      local right
      if info.state == "ready" then right = "|cff40d66eReady|r"
      elseif info.state == "unknown" then right = "|cff999999Unknown|r"
      else right = CD.FormatLeft(info.left, true) .. "  (" .. date("%a %H:%M", info.ready) .. ")" end
      tt:AddDoubleLine(ns.Icons.Dot(h.online) .. " " .. UI.ClassName(h.key, h.class), right, 1, 1, 1, 0.8, 0.8, 0.8)
    end
    local stale = false
    for _, h in ipairs(item.holders) do if h.info.state == "unknown" then stale = true end end
    if stale then
      tt:AddLine("Unknown: not seen for over two weeks, so it may have been used.", 0.6, 0.6, 0.6, true)
    end
    tt:AddLine(" ")
    tt:AddLine((item.canOpen and "Click to show or hide its recipes. " or "") .. "Right-click to whisper someone who's ready.", 0.6, 0.6, 0.6, true)
  end

  local function CooldownClick(item, button)
    if button == "RightButton" then
      local menu = {}
      for _, h in ipairs(item.holders) do
        if h.info.state == "ready" and h.online and h.key ~= ns.MyKey() then
          menu[#menu + 1] = { text = "Whisper " .. ns.ShortName(h.key), onClick = function()
            UI.Whisper(h.key, ("Hi! Is your %s free? Could you make one for me?"):format(item.cd.name))
          end }
        end
      end
      if #menu == 0 then menu[1] = { text = "Nobody online has it ready" } end
      T.Menu(cdList, menu, 220)
    elseif item.canOpen then
      cdExpanded[item.cd.id] = not cdExpanded[item.cd.id]
      panel:Refresh()
    end
  end

  ----------------------------------------------------------------------
  -- Views
  ----------------------------------------------------------------------
  local ar, ag, ab

  local function RecipesView(profs)
    local filtering = filterText ~= "" or Filtering()
    local statFilter = Active("stat") and filt.stat or nil
    -- tree: character header rows, recipes underneath when expanded
    local chars, order = {}, {}
    for skillLine, agg in pairs(profs) do
      if InScope(skillLine) then
        for _, c in ipairs(agg.crafters) do
          local ch = chars[c.key]
          if not ch then
            ch = { key = c.key, class = c.class, online = c.online, rec = c.rec, profs = {}, recipes = {} }
            chars[c.key] = ch
            order[#order + 1] = ch
          end
          table.insert(ch.profs, { skillLine = skillLine, name = agg.name, rank = c.rank, max = c.max, count = c.recipeCount })
        end
        for id, crafters in pairs(agg.recipes) do
          local name = ns.RecipeName(id)
          local itemID = agg.outputs[id] or ns.Loot.FindItemByName(name)
          local itemInfo = itemID and ns.Loot.ItemInfo(itemID)
          if SearchHit(name, itemID) and PassesFilters(id, itemID) then
            local cdId = CD.OfRecipe(id, skillLine)
            local facts = statFilter and RF.Get(id, itemID)
            for _, c in ipairs(crafters) do
              table.insert(chars[c.key].recipes, { id = id, name = (itemInfo and itemInfo.name) or name, itemID = itemID,
                skillLine = skillLine, profName = agg.name, crafters = crafters, self = c.key,
                cd = cdId and ns.COOLDOWN_BY_ID[cdId], facts = facts })
            end
          end
        end
      end
    end
    table.sort(order, function(x, y)
      if x.online ~= y.online then return x.online end
      return ns.ShortName(x.key):lower() < ns.ShortName(y.key):lower()
    end)

    local items, shownChars, readyN = {}, 0, 0
    for _, ch in ipairs(order) do
      for _, cd in ipairs(ns.COOLDOWNS) do
        local cdInfo = InScope(cd.skillLine) and CD.Info(ch.rec, cd.id)
        if cdInfo and cdInfo.state == "ready" then readyN = readyN + 1 end
      end
      if not filtering or #ch.recipes > 0 then
        shownChars = shownChars + 1
        local total = 0
        for _, p in ipairs(ch.profs) do total = total + p.count end
        local open = filtering or expanded[ch.key]
        local canOpen = total > 0
        local arrow = canOpen and UI.Colorize(open and "-" or "+", ar, ag, ab) or UI.Dim("·", 0.3)
        local profBits = {}
        for _, p in ipairs(ch.profs) do
          profBits[#profBits + 1] = ns.Icons.Prof(p.skillLine, 13) .. " " .. UI.Dim(p.name .. " " .. p.rank, 0.6)
            .. CooldownBits(ch.rec, p.skillLine, 13)
        end
        local countText
        if filtering then countText = UI.Dim(#ch.recipes .. (#ch.recipes == 1 and " match" or " matches"), 0.6)
        elseif canOpen then countText = UI.Dim(total .. " recipes", 0.6)
        else countText = UI.Dim("recipes not shared yet", 0.35) end
        items[#items + 1] = {
          header = true, char = ch,
          cols = { arrow .. "  " .. UI.NameCell(ch.key, ch.class, ch.online), table.concat(profBits, "   "), countText },
          tooltip = function(tt, it)
            tt:AddLine(ns.Icons.Class(it.char.class, 16) .. " " .. ns.ShortName(it.char.key), ns.ClassColor(it.char.class))
            for _, p in ipairs(it.char.profs) do
              tt:AddDoubleLine(ns.Icons.Prof(p.skillLine, 14) .. " " .. p.name .. "  " .. p.rank .. "/" .. p.max,
                p.count > 0 and (p.count .. " recipes") or "|cff999999not shared yet|r", 1, 1, 1, 0.7, 0.7, 0.7)
            end
            local cds = CD.Of(it.char.rec)
            if #cds > 0 then
              tt:AddLine(" ")
              tt:AddLine("Cooldowns", 1, 0.82, 0)
              for _, cd in ipairs(cds) do CD.AddTooltip(tt, it.char.rec, cd) end
            end
            tt:AddLine(" ")
            tt:AddLine(canOpen and "Click to show or hide recipes. Right-click to whisper." or "Right-click to whisper.", 0.6, 0.6, 0.6, true)
          end,
          onClick = function(it, button)
            if button == "RightButton" then
              if it.char.key ~= ns.MyKey() then UI.Whisper(it.char.key) end
            elseif canOpen and not filtering then
              expanded[it.char.key] = not expanded[it.char.key]
              panel:Refresh()
            end
          end,
        }
        if open then
          -- each recipe's crafted item level (recipes that make no item sort last)
          for _, r in ipairs(ch.recipes) do
            local inf = r.itemID and ns.Loot.ItemInfo(r.itemID)
            r.ilvl = inf and inf.ilvl or -1
            r.req = inf and inf.req or -1
          end
          local byLevel = ByLevel()
          table.sort(ch.recipes, function(x, y)
            if x.profName ~= y.profName then return x.profName < y.profName end
            if byLevel and x.ilvl ~= y.ilvl then return x.ilvl > y.ilvl end
            if byLevel and x.req ~= y.req then return x.req > y.req end
            return x.name:lower() < y.name:lower()
          end)
          for _, r in ipairs(ch.recipes) do
            local others = {}
            for _, c in ipairs(r.crafters) do if c.key ~= r.self then others[#others + 1] = c end end
            local nameText = r.itemID and ns.Loot.ItemText(r.itemID, 14) or r.name
            if r.cd then nameText = nameText .. "  " .. CD.Badge(ch.rec, r.cd, 12) end
            if r.facts then
              local tags = {}
              for _, s in ipairs(RF.STATS) do
                if s and statFilter[s[1]] and r.facts.stats[s[1]] then tags[#tags + 1] = s[2] end
              end
              if #tags > 0 then nameText = nameText .. "  " .. UI.Colorize(table.concat(tags, " · "), ar, ag, ab) end
            end
            items[#items + 1] = {
              id = r.id, name = r.name, crafters = r.crafters, skillLine = r.skillLine, itemID = r.itemID, cd = r.cd,
              cols = { "        " .. nameText, ns.Icons.Prof(r.skillLine, 13) .. " " .. UI.Dim(r.profName, 0.5)
                       .. (r.ilvl and r.ilvl > 0 and UI.Dim("  ilvl " .. r.ilvl, 0.4) or ""),
                       #others > 0 and CrafterNames(others, 3) or "" },
              tooltip = RecipeTooltip, onClick = RecipeClick,
            }
          end
        end
      end
    end
    local recipeCount = 0
    for skillLine, agg in pairs(profs) do
      if InScope(skillLine) then for _ in pairs(agg.recipes) do recipeCount = recipeCount + 1 end end
    end
    local text = ("%d characters  ·  %d recipes"):format(shownChars, recipeCount)
    if readyN > 0 then text = text .. ("  ·  %d cooldown%s ready"):format(readyN, readyN == 1 and "" or "s") end
    info:SetText(text)
    local empty
    if recipeCount == 0 and #order == 0 then
      empty = "No recipes shared yet. Each member needs FableHub installed and to open their profession windows once."
    elseif Filtering() then
      empty = "No recipes match these filters. Try Any in the Stat menu, or clear a filter."
    else
      empty = "No recipes match your search"
    end
    recipeList:SetItems(items, empty)
  end

  local function CooldownView()
    local items, groups, readyN = {}, 0, 0
    local members = ns.AllMembers()
    for _, cd in ipairs(ns.COOLDOWNS) do
      if InScope(cd.skillLine) then
        local holders, ready = {}, 0
        local nameHit = filterText == "" or cd.name:lower():find(filterText, 1, true)
        for _, m in ipairs(members) do
          local cdInfo = m.rec and CD.Info(m.rec, cd.id)
          if cdInfo and (nameHit or ns.ShortName(m.key):lower():find(filterText, 1, true)) then
            local online = (m.roster and m.roster.online) or m.key == ns.MyKey()
            holders[#holders + 1] = { key = m.key, rec = m.rec, class = m.rec.class or (m.roster and m.roster.class),
                                      online = online and true or false, info = cdInfo }
            if cdInfo.state == "ready" then ready = ready + 1 end
          end
        end
        if #holders > 0 and not (readyOnly and ready == 0) then
          groups, readyN = groups + 1, readyN + ready
          local RANK = { ready = 1, soon = 2, cooling = 2, unknown = 3 }
          table.sort(holders, function(a, b)
            local ra, rb = RANK[a.info.state], RANK[b.info.state]
            if ra ~= rb then return ra < rb end
            if ra == 2 and a.info.left ~= b.info.left then return a.info.left < b.info.left end
            if a.online ~= b.online then return a.online end
            return ns.ShortName(a.key) < ns.ShortName(b.key)
          end)
          local readyNames, later = {}, {}
          for _, h in ipairs(holders) do
            local name = UI.NameCell(h.key, h.class, h.online)
            if h.info.state == "ready" then readyNames[#readyNames + 1] = name
            elseif not readyOnly then later[#later + 1] = name .. " " .. CD.Text(h.info) end
          end
          -- recipes that use this cooldown, known by someone listed
          local recipes = {}
          if not cd.item then
            local seen = {}
            for _, h in ipairs(holders) do
              local p = h.rec.profs and h.rec.profs[cd.skillLine]
              for id in pairs(p and p.recipes or {}) do
                if not seen[id] and CD.OfRecipe(id, cd.skillLine) == cd.id then
                  seen[id] = true
                  recipes[#recipes + 1] = id
                end
              end
            end
            table.sort(recipes, function(a, b) return ns.RecipeName(a) < ns.RecipeName(b) end)
          end
          local canOpen = #recipes > 0
          local open = canOpen and cdExpanded[cd.id]
          local arrow = canOpen and UI.Colorize(open and "-" or "+", ar, ag, ab) or UI.Dim("·", 0.3)
          local profName = lastProfs[cd.skillLine] and lastProfs[cd.skillLine].name or ""
          items[#items + 1] = {
            header = true, cd = cd, holders = holders, canOpen = canOpen,
            cols = { arrow .. "  " .. CD.Icon(cd, ready > 0 and "ready" or "cooling", 16) .. "  " .. cd.name .. "  " .. UI.Dim(profName, 0.45),
                     #readyNames > 0 and table.concat(readyNames, ", ") or UI.Dim("nobody", 0.35),
                     table.concat(later, ",  ") },
            tooltip = CooldownTooltip, onClick = CooldownClick,
          }
          if open then
            for _, id in ipairs(recipes) do
              local rd, cl = {}, {}
              for _, h in ipairs(holders) do
                local p = h.rec.profs and h.rec.profs[cd.skillLine]
                if p and p.recipes and p.recipes[id] then
                  local name = UI.NameCell(h.key, h.class, h.online)
                  if h.info.state == "ready" then rd[#rd + 1] = name
                  elseif not readyOnly then cl[#cl + 1] = name .. " " .. CD.Text(h.info) end
                end
              end
              if #rd > 0 or not readyOnly then
                local crafters = {}
                for _, c in ipairs(lastProfs[cd.skillLine] and lastProfs[cd.skillLine].recipes[id] or {}) do crafters[#crafters + 1] = c end
                local name = ns.RecipeName(id)
                items[#items + 1] = {
                  id = id, name = name, crafters = crafters, skillLine = cd.skillLine, cd = cd,
                  cols = { "              " .. name, table.concat(rd, ", "), table.concat(cl, ",  ") },
                  tooltip = RecipeTooltip, onClick = RecipeClick,
                }
              end
            end
          end
        end
      end
    end
    info:SetText(("%d cooldown%s  ·  %d ready across the guild"):format(groups, groups == 1 and "" or "s", readyN))
    cdList:SetItems(items, readyOnly
      and "Nobody has one of these ready right now. Turn off Ready now only to see when they come up."
      or "No cooldowns to show yet. A character's cooldowns appear once they log in with FableHub 0.22 or later.")
  end

  local function CraftersView(profs)
    local items = {}
    for skillLine, agg in pairs(profs) do
      if InScope(skillLine) then
        for _, c in ipairs(agg.crafters) do
          local name = ns.ShortName(c.key)
          if filterText == "" or name:lower():find(filterText, 1, true) then
            local cdText, readyCount = "", 0
            for _, cd in ipairs(ns.COOLDOWNS) do
              if cd.skillLine == skillLine then
                local cdInfo = CD.Info(c.rec, cd.id)
                if cdInfo then
                  cdText = cdText .. (cdText ~= "" and "  " or "") .. CD.Icon(cd, cdInfo.state, 13) .. " " .. CD.Text(cdInfo)
                  if cdInfo.state == "ready" then readyCount = readyCount + 1 end
                end
              end
            end
            items[#items + 1] = {
              crafter = c, profName = agg.name, skillLine = skillLine,
              cols = {
                UI.NameCell(c.key, c.class, c.online),
                ns.Icons.Prof(skillLine, 13) .. " " .. UI.Dim(agg.name, 0.6),
                UI.Colorize(tostring(c.rank), 1, 1, 1) .. UI.Dim(" / " .. c.max, 0.4),
                c.recipeCount > 0 and tostring(c.recipeCount) or UI.Dim("?", 0.4),
                cdText,
                UI.Dim(UI.TimeAgo(c.ts), 0.5),
              },
              bars = { [3] = (c.max or 0) > 0 and c.rank / c.max or nil },
              sort = { name:lower(), agg.name:lower(), c.rank, c.recipeCount, readyCount, -(c.ts or 0) },
              tooltip = CrafterTooltip,
              onClick = function(it, button)
                if button == "RightButton" and it.crafter.key ~= ns.MyKey() then UI.Whisper(it.crafter.key) end
              end,
            }
          end
        end
      end
    end
    info:SetText("")
    crafterList:SetItems(items, "No crafters found")
  end

  ----------------------------------------------------------------------
  function panel:Refresh()
    ar, ag, ab = T.Accent()
    local profs = ns.Crafting()
    lastProfs, scopeCache = profs, nil
    if selected ~= "all" and (not profs[selected] or not Visible(selected)) then selected = "all" end

    local cdView = CdView()
    recipeList:SetShown(mode == "recipes" and not cdView)
    cdList:SetShown(cdView)
    crafterList:SetShown(mode == "crafters")
    expandBtn:SetShown(mode == "recipes")
    sortBtn:SetShown(mode == "recipes" and not cdView)
    sortBtn:SetText(ByLevel() and "Highest level first" or "A to Z")
    PaintFilters()
    if mode == "crafters" then UI.SetHint("Right-click a crafter to whisper them.")
    elseif cdView then UI.SetHint("Click a cooldown to see its recipes. Right-click to whisper someone who's ready.")
    else UI.SetHint("Click a character to show their recipes. Hover a name to see their cooldowns; right-click to whisper.") end

    -- left list: All, then each group (crafting / gathering / secondary)
    local leftItems = {}
    leftItems[1] = {
      cols = { "|TInterface\\Icons\\INV_Misc_Book_09:16:16:0:0:64:64:5:59:5:59|t  "
        .. (selected == "all" and UI.Colorize("All professions", ar, ag, ab) or "All professions"), "" },
      onClick = function() selected = "all"; panel:Refresh() end,
    }
    for _, cat in ipairs({ "craft", "gather", "secondary" }) do
      local group = {}
      for skillLine, agg in pairs(profs) do
        if ns.ProfCategory(skillLine) == cat and Visible(skillLine) then group[#group + 1] = agg end
      end
      table.sort(group, function(a, b) return a.name < b.name end)
      if #group > 0 then
        leftItems[#leftItems + 1] = { header = true, cols = { UI.Dim(ns.PROF_CATEGORY_NAMES[cat], 0.45), "" } }
        for _, agg in ipairs(group) do
          local skillLine = agg.skillLine
          local isSel = selected == skillLine
          leftItems[#leftItems + 1] = {
            cols = { ns.Icons.Prof(skillLine, 16) .. "  " .. (isSel and UI.Colorize(agg.name, ar, ag, ab) or agg.name),
                     UI.Dim(tostring(#agg.crafters), 0.5) },
            onClick = function() selected = skillLine; panel:Refresh() end,
          }
        end
      end
    end
    left:SetItems(leftItems, "No profession data yet")

    if mode == "crafters" then CraftersView(profs)
    elseif cdView then CooldownView()
    else RecipesView(profs) end

    UI.LayoutToolbars(panel)
    if T.CheckMenuOpen() then T.PaintCheckMenu() end
  end

  -- keep the cooldown timers counting down while the page is open
  C_Timer.NewTicker(60, function()
    if panel:IsVisible() then panel:Refresh() end
  end)

  SetMode("recipes")
end, "profgroup")
