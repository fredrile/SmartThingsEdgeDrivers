-- Copyright 2021 SmartThings
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local capabilities = require "st.capabilities"
--- @type st.zwave.CommandClass
local cc = require "st.zwave.CommandClass"
--- @type st.zwave.Driver
local ZwaveDriver = require "st.zwave.driver"
--- @type st.zwave.defaults
local defaults = require "st.zwave.defaults"
--- @type st.zwave.CommandClass.Configuration
local Configuration = (require "st.zwave.CommandClass.Configuration")({ version=4 })
local preferencesMap = require "preferences"

local function update_preferences(driver, device, args)
  local preferences = preferencesMap.get_device_parameters(device)
  for id, value in pairs(device.preferences) do
    if not (args and args.old_st_store) or (args.old_st_store.preferences[id] ~= value and preferences and preferences[id]) then
      local new_parameter_value = preferencesMap.to_numeric_value(device.preferences[id])
      device:send(Configuration:Set({parameter_number = preferences[id].parameter_number, size = preferences[id].size, configuration_value = new_parameter_value}))
    end
  end
end

--- Handle preference changes
---
--- @param driver st.zwave.Driver
--- @param device st.zwave.Device
--- @param event table
--- @param args
local function info_changed(self, device, event, args)
  if not device:is_cc_supported(cc.WAKE_UP) then
    update_preferences(self, device, args)
  end
end

local function device_init(self, device)
  device:set_update_preferences_fn(update_preferences)
end

local function do_configure(driver, device)
  device:refresh()
  if not device:is_cc_supported(cc.WAKE_UP) then
    update_preferences(driver, device)
  end
end

local function added_handler(self, device)
  if device:supports_capability_by_id(capabilities.tamperAlert.ID) then
    device:emit_event(capabilities.tamperAlert.tamper.clear())
  end
  if device:supports_capability_by_id(capabilities.waterSensor.ID) then
    device:emit_event(capabilities.waterSensor.water.dry())
  end
end

local driver_template = {
  supported_capabilities = {
    capabilities.waterSensor,
    capabilities.colorControl,
    capabilities.contactSensor,
    capabilities.motionSensor,
    capabilities.relativeHumidityMeasurement,
    capabilities.illuminanceMeasurement,
    capabilities.battery,
    capabilities.tamperAlert,
    capabilities.temperatureAlarm,
    capabilities.temperatureMeasurement,
    capabilities.switch
  },
  sub_drivers = {
    require("zooz-4-in-1-sensor"),
    require("zwave-motion-temp-light-sensor"),
    require("vision-motion-detector"),
    require("fibaro-flood-sensor"),
    require("zwave-water-temp-humidity-sensor"),
    require("everspring-ST814"),
    require("everspring-illuminance-sensor"),
    require("glentronics-water-leak-sensor"),
    require("homeseer-multi-sensor"),
    require("fibaro-door-window-sensor")
  },
  lifecycle_handlers = {
    added = added_handler,
    init = device_init,
    infoChanged = info_changed,
    doConfigure = do_configure
  },
}

defaults.register_for_default_handlers(driver_template, driver_template.supported_capabilities)
--- @type st.zwave.Driver
local sensor = ZwaveDriver("zwave_sensor", driver_template)
sensor:run()
