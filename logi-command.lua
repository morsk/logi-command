-- Morsk's /logi command: github.com/morsk/logi-command
-- A version of this code is available on github under a MIT license.
-- Other projects might have changed the code and/or license.

local ceil = math.ceil
local floor = math.floor
local max = math.max
local min = math.min
local math_huge = math.huge
local pairs = pairs
local next = next
local pcall = pcall
local error = error

local M = {} -- object for this module
local LOGISTICS_DEFAULT_MAX = 4294967295 -- 0xFFFFFFFF
local MAX_LOGI_SLOT = 1000

-- Encoding of the simplest blueprint json: {"blueprint":{"item":"blueprint"}}
-- Used to create empty blueprints for the cursor, because I couldn't find
-- another way.
local empty_blueprint_base64 = "0eNqrVkrKKU0tKMrMK1GyqlbKLEnNVbJCEqutBQDZSgyK"

local function request_slot_count(player)
  if player.character then
    return player.character.request_slot_count
  else
    -- The API provides no way to find the max slot of an offline player,
    -- except to search the whole thing.
    -- MAX_LOGI_SLOT is huge, and this spams temp objects.
    -- This only happens if an admin uses it on an offline player, so
    -- whatever; do it.
    for i = MAX_LOGI_SLOT,1,-1 do
      if player.get_personal_logistic_slot(i).name then
        return i
      end
    end
    return 0
  end
end

local function new_blank_combinator(x, y)
  local result = {
    name = "constant-combinator",
    position = {
      x = x + 0.5,
      y = y + 0.5,
    },
    control_behavior = {
      filters = {
      }
    }
  }
  return result
end

local function set_in_combinator(comb, i, name, value)
  local filters = comb.control_behavior.filters
  filters[#filters+1] = {
    signal = {
      type = "item",
      name = name,
    },
    count = value,
    index = i,
  }
end

local function export_to_blueprint(player)
  local n_logi = request_slot_count(player)
  local combinator_slots =
    game.entity_prototypes["constant-combinator"].item_slot_count

  -- Set values in combinators, constructing combinators as needed.
  local mins, maxes = {}, {}
  mins[1] = new_blank_combinator(0, 0) -- This always exists.
  for i = 1, n_logi do
    local slot = player.get_personal_logistic_slot(i)
    if slot.name then
      local comb_i = ceil(i / combinator_slots)
      local comb_slot = (i-1) % combinator_slots + 1

      if not mins[comb_i] then
        mins[comb_i] = new_blank_combinator(comb_i-1, 0)
      end
      set_in_combinator(mins[comb_i], comb_slot, slot.name, slot.min)

      if slot.max < LOGISTICS_DEFAULT_MAX then
        if not maxes[comb_i] then
          maxes[comb_i] = new_blank_combinator(comb_i-1, 4)
        end
        set_in_combinator(maxes[comb_i], comb_slot, slot.name, slot.max)
      end
    end
  end

  -- Add entity_number and collate into blueprint.
  -- I like both the array order, and the entity_number, to follow rows
  -- left-to-right, before going down to the next y row.
  local blueprint_entities = {}
  local n_combs = 0
  for _,comb in pairs(mins) do
    n_combs = n_combs + 1
    blueprint_entities[n_combs] = comb
    comb.entity_number = n_combs
  end
  for _,comb in pairs(maxes) do
    n_combs = n_combs + 1
    blueprint_entities[n_combs] = comb
    comb.entity_number = n_combs
  end
  return blueprint_entities
end

local function clear_all_logistic_slots(player)
  for i = 1, request_slot_count(player) do
    player.clear_personal_logistic_slot(i)
  end
end

-- I've always wanted to do this. It's O(N**2) and a mess of temporaries to
-- use string concatination in a loop, but O(N) to do it through recursion.
-- It's not worth it for this, of course.
local function list_requests(sep, t, i, req)
  if i then
    if req.max < LOGISTICS_DEFAULT_MAX then
      return sep..req.min.."-"..req.max.."[img=item."..req.name.."]"..
        list_requests(",  ", t, next(t, i))
    else
      return sep..req.min.."[img=item."..req.name.."]"..
        list_requests(",  ", t, next(t, i))
    end
  else
    return ""
  end
end

local function import_from_blueprint(player, bp_entities)
  if type(bp_entities) ~= "table" or #bp_entities < 1 then
    error("No entities in the blueprint?", 0)
  end

  -- Pass 1: Find minimums, so we can adjust coordinates around them.
  local min_x = math_huge
  local min_y = math_huge
  for i = 1, #bp_entities do
    local e = bp_entities[i]
    if e.name ~= "constant-combinator" then
      error("Weird entities. Should only be constant combinators.", 0)
    end
    min_x = min(min_x, e.position.x)
    min_y = min(min_y, e.position.y)
  end

  -- Pass 2: Adjust coordinates, sort combinators into tables.
  local mins, maxes = {}, {}
  for i = 1, #bp_entities do
    local e = bp_entities[i]
    local x = e.position.x - min_x
    local y = e.position.y - min_y
    e.position.x = x
    e.position.y = y
    if y == 0 then
      mins[x+1] = e
    elseif y == 4 then
      maxes[x+1] = e
    else
      error("Weird combinator rows. Only 0 and 4 should be used.", 0)
    end
  end

  -- Pass 3: Build a table of logi requests from the combinators, in order.
  local requests = {}
  -- Generic loop to call f(filter, offset).
  local function loop_combinator_filters(group, f)
    local combinator_slots =
      game.entity_prototypes["constant-combinator"].item_slot_count
    for comb_i, e in pairs(group) do
      if e.control_behavior and e.control_behavior.filters then
        local offset = (comb_i - 1) * combinator_slots
        for j = 1, #e.control_behavior.filters do
          local filter = e.control_behavior.filters[j]
          if filter.signal.type ~= "item" then
            error("Combinator has weird signals: "..
              filter.signal.type..", "..filter.signal.name, 0)
          end
          f(filter, offset)
        end
      end
    end
  end
  -- Loop on mins, detect duplicates.
  local items_seen_in_blueprint = {}
  loop_combinator_filters(mins, function(filter, offset)
    local logi_name = filter.signal.name
    if items_seen_in_blueprint[logi_name] then
      error("Item in blueprint more than once: " .. logi_name, 0)
    end
    items_seen_in_blueprint[logi_name] = true
    requests[filter.index + offset] = {
      name = logi_name,
      min = filter.count,
      max = LOGISTICS_DEFAULT_MAX,
    }
  end)
  -- Loop on maxes, detect mismatch.
  loop_combinator_filters(maxes, function(filter, offset)
    local i = filter.index + offset
    if not requests[i] or requests[i].name ~= filter.signal.name then
      error("Min/max mismatch. Items need to be in matching slots.", 0)
    end
    requests[i].max = filter.count
  end)

  -- Pass 4: Make actual changes.
  clear_all_logistic_slots(player)
  for i, request in pairs(requests) do
    player.set_personal_logistic_slot(i, request)
  end

  -- Return pretty string of imports.
  local ok, result = pcall(list_requests, "", requests, next(requests))
  if ok then
    return result
  else
    error("Import succeeded, but display failed:"..result, 0)
  end
end

local function logi_command_internal(event)
  local player = game.get_player(event.player_index)
  local stack = player.cursor_stack

  local target = player
  if event.parameter and player.admin then
    -- Admins can use the command on another player.
    target = game.get_player(event.parameter)
    if not target then
      error("Player "..event.parameter.." doesn't exist.", 0)
    end
  end

  if not target.force.character_logistic_requests then
    error("You need logistic robots researched before you can use this.", 0)
  end
  if stack.valid_for_read and not stack.is_blueprint then
    error("Only works with blueprints, or with a blank cursor.", 0)
  end

  -- If we aren't holding a blueprint, make one. It's not ideal to do it this
  -- early. The player could have 0 logistic requests, and we'd fail after
  -- creating a useless blueprint. But they shouldn't do that anyway.
  if not player.is_cursor_blueprint() then
    -- Clear the cursor, just to be sure. The API is weird and it's hard
    -- to tell if the cursor is truly empty.
    player.clear_cursor()
    stack.import_stack(empty_blueprint_base64)
  end

  local bp_entities = player.get_blueprint_entities()
  if bp_entities then
    -- We have entities, so try to import.
    local import_result = "Imported: "..import_from_blueprint(target, bp_entities)
    player.print(import_result)
    if target.index ~= player.index then
      target.print(import_result)
    end
    player.clear_cursor()
  else
    -- A blueprint without entities. We try to export.
    if stack.valid_for_read then
      local result = export_to_blueprint(target)
      stack.set_blueprint_entities(result)
      player.print("Exported.")
      if target.index ~= player.index then
        local tname = target.name
        local ends_s = tname:find("s$")
        stack.label = tname..(ends_s and "'" or "'s").." logistics"
      end
    else
      -- The player object says we have a blueprint, but the player's cursor
      -- stack says we have nothing. This means it's using the library.
      error("Can't export to the blueprint library. "..
            "Use an empty blueprint from your inventory, or a clear cursor.", 0)
    end
  end
end

function M.add_commands()
  commands.add_command(
    "logi",
    "- Convert logistic requests to/from blueprint.",
    function(event)
      local ok, result = pcall(logi_command_internal, event)
      if not ok then
        game.player.print(result)
      end
    end
  )
end

return M
