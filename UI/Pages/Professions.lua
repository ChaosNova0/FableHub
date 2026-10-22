-- Professions tab: who has each profession, and who can craft what.

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
          key = m.key, class = rec.class or (m.roster and m.roster.class), online = online,
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

------------------------------------------------------------------------
ns.RegisterNavGroup("profgroup", "Professions", "Interface\\Icons\\Trade_BlackSmithing", { "professions", "requests", "campgroup" })

ns.RegisterPanel("professions", "Recipes", nil, function(panel)
  local T = ns.Theme
  local selected = "all"     -- skillLine or "all"
  local mode = "recipes"     -- "recipes" | "crafters"
  local filterText = ""

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

  local recipeList = UI.CreateList(panel, {
    { title = "Character / recipe", flex = true },
    { title = "Profession", width = 200 },
    { title = "Also crafted by", width = 170 },
  }, 24)
  recipeList.sortable = false
  local expanded = {}
  recipeList:SetPoint("TOPLEFT", 232, -34)
  recipeList:SetPoint("BOTTOMRIGHT", 0, 0)

  local crafterList = UI.CreateList(panel, {
    { title = "Name", flex = true },
    { title = "Profession", width = 150 },
    { title = "Skill", width = 110, defaultAsc = false, bar = true },
    { title = "Recipes", width = 56, justify = "RIGHT", defaultAsc = false },
    { title = "Updated", width = 64, justify = "RIGHT" },
  }, 24)
  crafterList:SetPoint("TOPLEFT", 232, -34)
  crafterList:SetPoint("BOTTOMRIGHT", 0, 0)
  crafterList.sortCol, crafterList.sortAsc = 3, false

  -- toolbar: Recipes | Crafters on top, search and buttons on the row below
  -- (more rows when the window is narrow); the profession picker narrows too
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
  bar:Status(info)
  bar:Below(recipeList)
  bar:Below(crafterList)
  bar:Below(left, { x = 0 })

  local function SetMode(m)
    mode = m
    recipesBtn:SetSelected(m == "recipes")
    craftersBtn:SetSelected(m == "crafters")
    recipeList:SetShown(m == "recipes")
    expandBtn:SetShown(m == "recipes")
    sortBtn:SetShown(m == "recipes")
    crafterList:SetShown(m == "crafters")
    panel:Refresh()
  end
  recipesBtn:SetScript("OnClick", function() SetMode("recipes") end)
  expandBtn:SetScript("OnClick", function()
    local anyClosed = false
    local profs = ns.Crafting()
    local keys = {}
    for skillLine, agg in pairs(profs) do
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

  local function RecipeTooltip(tt, item)
    local ok = pcall(tt.SetSpellByID, tt, item.id)
    if not ok then tt:AddLine(item.name) end
    tt:AddLine(" ")
    tt:AddLine("Can craft", 1, 0.82, 0)
    for _, c in ipairs(item.crafters) do
      tt:AddDoubleLine(ns.Icons.Dot(c.online) .. " " .. UI.ClassName(c.key, c.class), c.rank .. "/" .. c.max, 1, 1, 1, 0.7, 0.7, 0.7)
    end
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
        if c.online and c.key ~= ns.MyKey() then
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
    tt:AddLine(c.online and "|cff40d66eOnline|r" or "|cff999999Offline|r")
    tt:AddLine("Right-click to whisper", 0.6, 0.6, 0.6)
  end

  function panel:Refresh()
    sortBtn:SetText(ByLevel() and "Highest level first" or "A to Z")
    UI.SetHint(mode == "recipes" and "Click a character to show their recipes. Names show the crafted item's rarity; hover for the recipe."
      or "Right-click a crafter to whisper them.")
    local profs = ns.Crafting()

    -- left list: All, then each group (crafting / gathering / secondary)
    local leftItems, totalRecipes = {}, 0
    local allIds = {}
    if selected ~= "all" and (not profs[selected] or not Visible(selected)) then selected = "all" end
    local ar, ag, ab = T.Accent()
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
          if InScope(skillLine) then for id in pairs(agg.recipes) do allIds[id] = true end end
          local isSel = selected == skillLine
          leftItems[#leftItems + 1] = {
            cols = { ns.Icons.Prof(skillLine, 16) .. "  " .. (isSel and UI.Colorize(agg.name, ar, ag, ab) or agg.name),
                     UI.Dim(tostring(#agg.crafters), 0.5) },
            onClick = function() selected = skillLine; panel:Refresh() end,
          }
        end
      end
    end
    for _ in pairs(allIds) do totalRecipes = totalRecipes + 1 end
    left:SetItems(leftItems, "No profession data yet")

    if mode == "recipes" then
      -- tree: character header rows, recipes underneath when expanded
      local chars, order = {}, {}
      for skillLine, agg in pairs(profs) do
        if InScope(skillLine) then
          for _, c in ipairs(agg.crafters) do
            local ch = chars[c.key]
            if not ch then
              ch = { key = c.key, class = c.class, online = c.online, profs = {}, recipes = {} }
              chars[c.key] = ch
              order[#order + 1] = ch
            end
            table.insert(ch.profs, { skillLine = skillLine, name = agg.name, rank = c.rank, max = c.max, count = c.recipeCount })
          end
          for id, crafters in pairs(agg.recipes) do
            local name = ns.RecipeName(id)
            local itemID = agg.outputs[id] or ns.Loot.FindItemByName(name)
            local itemInfo = itemID and ns.Loot.ItemInfo(itemID)
            local match = filterText == "" or name:lower():find(filterText, 1, true)
              or (itemInfo and itemInfo.name:lower():find(filterText, 1, true))
            if match then
              for _, c in ipairs(crafters) do
                table.insert(chars[c.key].recipes, { id = id, name = (itemInfo and itemInfo.name) or name, itemID = itemID,
                  skillLine = skillLine, profName = agg.name, crafters = crafters, self = c.key })
              end
            end
          end
        end
      end
      table.sort(order, function(x, y)
        if x.online ~= y.online then return x.online end
        return ns.ShortName(x.key):lower() < ns.ShortName(y.key):lower()
      end)

      local items = {}
      local searching = filterText ~= ""
      for _, ch in ipairs(order) do
        if not searching or #ch.recipes > 0 then
          local total = 0
          for _, p in ipairs(ch.profs) do total = total + p.count end
          local open = searching or expanded[ch.key]
          local canOpen = total > 0
          local arrow = canOpen and UI.Colorize(open and "-" or "+", ar, ag, ab) or UI.Dim("·", 0.3)
          local profBits = {}
          for _, p in ipairs(ch.profs) do
            profBits[#profBits + 1] = ns.Icons.Prof(p.skillLine, 13) .. " " .. UI.Dim(p.name .. " " .. p.rank, 0.6)
          end
          local countText
          if searching then countText = UI.Dim(#ch.recipes .. (#ch.recipes == 1 and " match" or " matches"), 0.6)
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
              tt:AddLine(" ")
              tt:AddLine(canOpen and "Click to show or hide recipes. Right-click to whisper." or "Right-click to whisper.", 0.6, 0.6, 0.6, true)
            end,
            onClick = function(it, button)
              if button == "RightButton" then
                if it.char.key ~= ns.MyKey() then UI.Whisper(it.char.key) end
              elseif canOpen and not searching then
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
              items[#items + 1] = {
                id = r.id, name = r.name, crafters = r.crafters, skillLine = r.skillLine, itemID = r.itemID,
                cols = { "        " .. (r.itemID and ns.Loot.ItemText(r.itemID, 14) or r.name), ns.Icons.Prof(r.skillLine, 13) .. " " .. UI.Dim(r.profName, 0.5)
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
      info:SetText(("%d characters  ·  %d recipes"):format(#order, recipeCount))
      recipeList:SetItems(items, totalRecipes == 0 and #order == 0
        and "No recipes shared yet. Each member needs FableHub installed and to open their profession windows once."
        or "No recipes match your search")
    else
      local items = {}
      for skillLine, agg in pairs(profs) do
        if InScope(skillLine) then
          for _, c in ipairs(agg.crafters) do
            local name = ns.ShortName(c.key)
            if filterText == "" or name:lower():find(filterText, 1, true) then
              items[#items + 1] = {
                crafter = c, profName = agg.name, skillLine = skillLine,
                cols = {
                  UI.NameCell(c.key, c.class, c.online),
                  ns.Icons.Prof(skillLine, 13) .. " " .. UI.Dim(agg.name, 0.6),
                  UI.Colorize(tostring(c.rank), 1, 1, 1) .. UI.Dim(" / " .. c.max, 0.4),
                  c.recipeCount > 0 and tostring(c.recipeCount) or UI.Dim("?", 0.4),
                  UI.Dim(UI.TimeAgo(c.ts), 0.5),
                },
                bars = { [3] = (c.max or 0) > 0 and c.rank / c.max or nil },
                sort = { name:lower(), agg.name:lower(), c.rank, c.recipeCount, -(c.ts or 0) },
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
  end

  SetMode("recipes")
end, "profgroup")
