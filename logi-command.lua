local ceil = math.ceil
local floor = math.floor
local max = math.max
local min = math.min
local math_huge = math.huge
local pcall = pcall
local error = error

local M = {} -- object for this module
local DEBUG = false

local LOGISTICS_DEFAULT_MAX = 4294967295 -- 0xFFFFFFFF
local MAX_REASONABLE_LOGI_ROWS = 20 -- our own value, to sanity-check data
                                    -- This isn't a limit of the game.
                                    -- The game allows 100 (!!) rows.

-- Encoding of the simplest blueprint json: {"blueprint":{"item":"blueprint"}}
-- Used to create empty blueprints for the cursor, because I couldn't find
-- another way.
local empty_blueprint_base64 = "0eNqrVkrKKU0tKMrMK1GyqlbKLEnNVbJCEqutBQDZSgyK"

local function debug_write(filename, obj)
  if DEBUG then
    game.write_file(filename, serpent.block(obj))
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
  filters = comb.control_behavior.filters
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
  local n_logi = player.character.request_slot_count
  local combinator_slots =
    game.entity_prototypes["constant-combinator"].item_slot_count

  -- Set values in combinators, constructing combinators as needed.
  local mins, maxes = {}, {}
  mins[1] = new_blank_combinator(0, 0) -- This always exists.
  for i = 1, n_logi do
    slot = player.get_personal_logistic_slot(i)
    if slot.name then
      comb_i = ceil(i / combinator_slots)
      comb_slot = (i-1) % combinator_slots + 1

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
  ::again::
  last = game.player.character.request_slot_count
  if last > 0 then
    player.clear_personal_logistic_slot(last)
    goto again
  end
end

-- This data comes from a blueprint, but it's just data to us now, and we
-- change it so it's easier to handle. It doesn't have to be consistant with
-- the blueprint, and the blueprint won't be updated to match the changes.
-- The data will be discarded when we're done with it.
local function simplify_entity_data(blueprint_entities)
  if type(blueprint_entities) ~= "table" or #blueprint_entities < 1 then
    error("No entities in the blueprint?", 0)
  end

  local items_seen_in_blueprint = {} -- remember items to detect duplicates

  -- Pass 1: Find minimums, so we can adjust coordinates around them.
  local min_x = math_huge
  local min_y = math_huge
  for i = 1,#blueprint_entities do
    local e = blueprint_entities[i]
    if e.name ~= "constant-combinator" then
      error("Weird entities. Should only be constant combinators.", 0)
    end
    e.name = nil -- don't need it anymore
    e.entity_number = nil -- don't need this at all

    min_x = min(min_x, e.position.x)
    min_y = min(min_y, e.position.y)
  end

  -- Pass 2: Convert many values to more useful forms.
  for i = 1,#blueprint_entities do
    local e = blueprint_entities[i]

    -- convert position from an (x,y) to a logistics slot number.
    -- no rounding or attempts to handle floating point imprecision. 0.5 will
    -- represent exactly.
    local x = e.position.x - min_x
    local y = e.position.y - min_y
    local logi_slot = 10*y + x + 1 -- the +1 is because the API's index starts
                                   -- at 1 not 0
    if x >= 10 then
      error("Blueprint is too wide. Limit to 10 columns.", 0)
    end
    if y >= MAX_REASONABLE_LOGI_ROWS then
      error("Combinator in row "..(y + 1)..
            ". Only "..MAX_REASONABLE_LOGI_ROWS.." are supported.", 0)
    end
    e.position = nil -- don't need it anymore
    e.logi_slot = logi_slot

    -- Convert the combinator's values (.control_behavior.filters)
    -- to our logi_ values.
    local logi_item
    local logi_min
    local logi_max = LOGISTICS_DEFAULT_MAX
    if not (e.control_behavior and e.control_behavior.filters) then
      error("A combinator is blank.", 0)
    end
    for j = 1,#e.control_behavior.filters do
      local filter = e.control_behavior.filters[j]
      if filter.index == 1 and filter.signal.type == "item" then
        -- An item in slot 1.
        logi_item = filter.signal.name
        logi_min = filter.count
      elseif filter.index == 2 and filter.signal.name == "signal-dot" then
        -- "Max" data in slot 2, encoded as the value of a "dot" signal.
        logi_max = filter.count
      else
        error("A combinator has weird settings.", 0)
      end
    end
    e.control_behavior = nil -- don't need it anymore
    if logi_item and logi_min then
      -- The data isn't missing either of the 2 required fields.
      -- So it's valid, unless it's a duplicate.
      if items_seen_in_blueprint[logi_item] then
        error("Item in blueprint more than once: " .. logi_item, 0)
      end
      items_seen_in_blueprint[logi_item] = true
    else
      -- Missing data is an error, unless it's a dummy combinator at 0,0.
      if logi_slot == 1 then
        e.logi_slot = nil -- This is how the calling function will know to
                          -- skip over it. It has no logi_slot.
        -- It would make cleaner data to remove it from the array entirely,
        -- since its data is useless. But I don't like to remove from a
        -- structure I'm iterating on.
      else
        error("Combinator missing settings.", 0)
      end
    end
    e.logi_params = {
      name = logi_item,
      min = logi_min,
      max = logi_max
    }
  end
end

-- I've always wanted to do this. It's O(N**2) and a mess of temporaries to
-- use string concatination in a loop, and O(N) to do it through recursion.
-- It's not worth it for this, of course.
local function list_imports(sep, player, bp_entities, i)
  if i > #bp_entities then
    return ""
  else
    local e = bp_entities[i]
    if not e.logi_slot then
      -- skip
      return list_imports(sep, player, bp_entities, i+1)
    else
      local p = e.logi_params
      if p.max < LOGISTICS_DEFAULT_MAX then
        return sep..p.min.."-"..p.max.."[img=item."..p.name.."]"..
          list_imports(",  ", player, bp_entities, i+1)
      else
        return sep..p.min.."[img=item."..p.name.."]"..
          list_imports(",  ", player, bp_entities, i+1)
      end
    end
  end
end

local function import_from_blueprint(player, bp_entities)
  debug_write("foo.txt", bp_entities)
  simplify_entity_data(bp_entities)
  debug_write("bar.txt", bp_entities)

  -- If we got this far, we can start making actual changes. We wait until
  -- now to give the previous functions chances to throw errors.
  clear_all_logistic_slots(player)

  for i = 1,#bp_entities do
    local e = bp_entities[i]
    if e.logi_slot then
      player.set_personal_logistic_slot(e.logi_slot, e.logi_params)
    end
  end
  ok, result = pcall(list_imports, "", player, bp_entities, 1)
  if ok then
    return result
  else
    error("Import succeeded, but display failed:"..result, 0)
  end
end

function logi_command_internal(event)
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
    player.print("Imported: "..import_from_blueprint(target, bp_entities))
    player.clear_cursor()
  else
    -- A blueprint without entities. We try to export.
    if stack.valid_for_read then
      result = export_to_blueprint(target)
      debug_write("foo.txt", result)
      stack.set_blueprint_entities(result)
      player.print("Exported.")
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
