local ceil = math.ceil
local floor = math.floor
local max = math.max
local min = math.min
local math_huge = math.huge
local pcall = pcall
local error = error

local M = {} -- object for this module
local LOGISTICS_DEFAULT_MAX = 4294967295 -- 0xFFFFFFFF

-- Encoding of the simplest blueprint json: {"blueprint":{"item":"blueprint"}}
-- Used to create empty blueprints for the cursor, because I couldn't find
-- another way.
local empty_blueprint_base64 = "0eNqrVkrKKU0tKMrMK1GyqlbKLEnNVbJCEqutBQDZSgyK"

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

local function import_from_blueprint(player, bp_entities)

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
