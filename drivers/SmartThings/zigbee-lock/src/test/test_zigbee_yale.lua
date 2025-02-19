-- Mock out globals
local test = require "integration_test"
local t_utils = require "integration_test.utils"
local zigbee_test_utils = require "integration_test.zigbee_test_utils"

local clusters = require "st.zigbee.zcl.clusters"
local capabilities = require "st.capabilities"
local json = require "dkjson"

local PowerConfiguration = clusters.PowerConfiguration
local DoorLock = clusters.DoorLock
local Alarm = clusters.Alarms

local DoorLock = clusters.DoorLock
local DoorLockUserStatus = DoorLock.types.DrlkUserStatus
local DoorLockUserType = DoorLock.types.DrlkUserType

local mock_device = test.mock_device.build_test_zigbee_device({ 
  profile = t_utils.get_profile_definition("base-lock.yml"), 
  zigbee_endpoints ={ 
    [1] = {id = 1, manufacturer ="Yale", server_clusters = {0x0001}} 
  } 
})

zigbee_test_utils.prepare_zigbee_env_info()
local function test_init()
  test.mock_device.add_test_device(mock_device)
  zigbee_test_utils.init_noop_health_check_timer()
end

test.set_test_init_function(test_init)

local expect_reload_all_codes_messages = function()
  test.socket.zigbee:__expect_send({ mock_device.id, DoorLock.attributes.SendPINOverTheAir:write(mock_device,
                                                                                                           true) })
  test.socket.zigbee:__expect_send({ mock_device.id, DoorLock.attributes.MaxPINCodeLength:read(mock_device) })
  test.socket.zigbee:__expect_send({ mock_device.id, DoorLock.attributes.MinPINCodeLength:read(mock_device) })
  test.socket.zigbee:__expect_send({ mock_device.id, DoorLock.attributes.NumberOfPINUsersSupported:read(mock_device) })
  test.socket.capability:__expect_send(mock_device:generate_test_message("main", capabilities.lockCodes.scanCodes("Scanning")))
  test.socket.zigbee:__expect_send({ mock_device.id, DoorLock.server.commands.GetPINCode(mock_device, 1) })
end

test.register_coroutine_test(
    "Reloading all codes of an unconfigured lock should generate correct attribute checks",
    function()
      test.socket.capability:__queue_receive({ mock_device.id, { capability = capabilities.lockCodes.ID, command = "reloadAllCodes", args = {} } })
      expect_reload_all_codes_messages()
    end
)

test.register_coroutine_test(
  "Configure should configure all necessary attributes and begin reading codes",
  function()
    test.timer.__create_and_queue_test_time_advance_timer(2, "oneshot")
    test.wait_for_events()

    test.socket.zigbee:__set_channel_ordering("relaxed")
    test.socket.device_lifecycle:__queue_receive({ mock_device.id, "doConfigure" })
    test.socket.zigbee:__expect_send({ mock_device.id, zigbee_test_utils.build_bind_request(mock_device,
                                                                                               zigbee_test_utils.mock_hub_eui,
                                                                                               PowerConfiguration.ID) })
    test.socket.zigbee:__expect_send({ mock_device.id, PowerConfiguration.attributes.BatteryPercentageRemaining:configure_reporting(mock_device,
                                                                                                                                       600,
                                                                                                                                       21600,
                                                                                                                                       1) })
    test.socket.zigbee:__expect_send({ mock_device.id, zigbee_test_utils.build_bind_request(mock_device,
                                                                                               zigbee_test_utils.mock_hub_eui,
                                                                                               DoorLock.ID) })
    test.socket.zigbee:__expect_send({ mock_device.id, DoorLock.attributes.LockState:configure_reporting(mock_device,
                                                                                                                   0,
                                                                                                                   3600,
                                                                                                                   0) })
    test.socket.zigbee:__expect_send({ mock_device.id, zigbee_test_utils.build_bind_request(mock_device,
                                                                                               zigbee_test_utils.mock_hub_eui,
                                                                                               Alarm.ID) })
    test.socket.zigbee:__expect_send({ mock_device.id, Alarm.attributes.AlarmCount:configure_reporting(mock_device,
                                                                                                                 0,
                                                                                                                 21600,
                                                                                                                 0) })
    test.socket.zigbee:__expect_send({mock_device.id, PowerConfiguration.attributes.BatteryPercentageRemaining:read(mock_device)})
    test.socket.zigbee:__expect_send({mock_device.id, DoorLock.attributes.LockState:read(mock_device)})
    test.socket.zigbee:__expect_send({mock_device.id, Alarm.attributes.AlarmCount:read(mock_device)})

    mock_device:expect_metadata_update({ provisioning_state = "PROVISIONED" })
    test.wait_for_events()

    test.mock_time.advance_time(2)
    expect_reload_all_codes_messages()

  end
)

test.register_coroutine_test(
    "Setting a user code should result in the named code changed event firing",
    function()
      test.timer.__create_and_queue_test_time_advance_timer(4, "oneshot")
      test.socket.capability:__queue_receive({ mock_device.id, { capability = capabilities.lockCodes.ID, command = "setCode", args = { 1, "1234", "test" } } })
      test.socket.zigbee:__expect_send(
          {
            mock_device.id,
            DoorLock.server.commands.SetPINCode(mock_device,
                                                   1,
                                                   DoorLockUserStatus.OCCUPIED_ENABLED,
                                                   DoorLockUserType.UNRESTRICTED,
                                                   "1234"
            )
          }
      )
      test.wait_for_events()

      test.mock_time.advance_time(4)
      test.socket.zigbee:__expect_send(
          {
            mock_device.id,
            DoorLock.server.commands.GetPINCode(mock_device, 1)
          }
      )
      test.wait_for_events()

      test.socket.zigbee:__queue_receive(
          {
            mock_device.id,
            DoorLock.client.commands.GetPINCodeResponse.build_test_rx(
                mock_device,
                0x01,
                DoorLockUserStatus.OCCUPIED_ENABLED,
                DoorLockUserType.UNRESTRICTED,
                "1234"
            )
          }
      )
      test.socket.capability:__expect_send(mock_device:generate_test_message("main",
          capabilities.lockCodes.codeChanged("1 set", { data = { codeName = "test"} }))
      )
      test.socket.capability:__expect_send(mock_device:generate_test_message("main",
        capabilities.lockCodes.lockCodes(json.encode({["1"] = "test"}))))
    end
)

test.register_message_test(
    "Setting all user codes should result in a code set event for each",
    {
      {
        channel = "capability",
        direction = "receive",
        message = {
          mock_device.id,
          {
            capability = capabilities.lockCodes.ID,
            command = "updateCodes",
            args = {
              {
                code1 = "1234",
                code2 = "2345",
                code3 = "3456"
              }
            }
          }
        }
      },
      {
        channel = "zigbee",
        direction = "send",
        message = {
          mock_device.id,
          DoorLock.server.commands.SetPINCode(mock_device,
                                                 1,
                                                 DoorLockUserStatus.OCCUPIED_ENABLED,
                                                 DoorLockUserType.UNRESTRICTED,
                                                 "1234"
          )
        }
      },
      {
        channel = "zigbee",
        direction = "send",
        message = {
          mock_device.id,
          DoorLock.server.commands.GetPINCode(mock_device,
                                                 1)
        }
      },
      {
        channel = "zigbee",
        direction = "send",
        message = {
          mock_device.id,
          DoorLock.server.commands.SetPINCode(mock_device,
                                                 2,
                                                 DoorLockUserStatus.OCCUPIED_ENABLED,
                                                 DoorLockUserType.UNRESTRICTED,
                                                 "2345"
          )
        }
      },
      {
        channel = "zigbee",
        direction = "send",
        message = {
          mock_device.id,
          DoorLock.server.commands.GetPINCode(mock_device,
                                                 2)
        }
      },
      {
        channel = "zigbee",
        direction = "send",
        message = {
          mock_device.id,
          DoorLock.server.commands.SetPINCode(mock_device,
                                                 3,
                                                 DoorLockUserStatus.OCCUPIED_ENABLED,
                                                 DoorLockUserType.UNRESTRICTED,
                                                 "3456"
          )
        }
      },
      {
        channel = "zigbee",
        direction = "send",
        message = {
          mock_device.id,
          DoorLock.server.commands.GetPINCode(mock_device,
                                                 3)
        }
      }
    },
    {
      inner_block_ordering = "relaxed"
    }
)

test.register_message_test(
    "Pin response reporting should be handled when the Lock User status is disabled",
    {
      {
        channel = "zigbee",
        direction = "receive",
        message = { mock_device.id,
                    DoorLock.client.commands.GetPINCodeResponse.build_test_rx(
                        mock_device,
                        nil,
                        DoorLockUserStatus.OCCUPIED_DISABLED,
                        DoorLockUserType.UNRESTRICTED,
                        "1234"
                    )
        }
      },
      {
        channel = "capability",
        direction = "send",
        message = mock_device:generate_test_message("main", capabilities.lockCodes.codeChanged("0 unset",
                                                                                       { data = { codeName = "Code 0" } }))
      }
    }
)

local function init_code_slot(slot_number, name, device)
  test.timer.__create_and_queue_test_time_advance_timer(4, "oneshot")
  test.socket.capability:__queue_receive({ device.id, { capability = capabilities.lockCodes.ID, command = "setCode", args = { slot_number, "1234", name } } })
  test.socket.zigbee:__expect_send(
      {
        device.id,
        DoorLock.server.commands.SetPINCode(device,
                                               slot_number,
                                               DoorLockUserStatus.OCCUPIED_ENABLED,
                                               DoorLockUserType.UNRESTRICTED,
                                               "1234"
        )
      }
  )
  test.wait_for_events()
  test.mock_time.advance_time(4)
  test.socket.zigbee:__expect_send(
      {
        device.id,
        DoorLock.server.commands.GetPINCode(device, slot_number)
      }
  )
  test.wait_for_events()
  test.socket.zigbee:__queue_receive(
      {
        device.id,
        DoorLock.client.commands.GetPINCodeResponse.build_test_rx(
            device,
            slot_number,
            DoorLockUserStatus.OCCUPIED_ENABLED,
            DoorLockUserType.UNRESTRICTED,
            "1234"
        )
      }
  )
  test.socket.capability:__expect_send(device:generate_test_message("main",
      capabilities.lockCodes.codeChanged(slot_number .. " set", { data = { codeName = name } }))
  )
end

test.register_coroutine_test(
    "Setting a user code name should be handled",
    function()
      init_code_slot(1, "initialName", mock_device)
      test.socket.capability:__expect_send(mock_device:generate_test_message("main",
        capabilities.lockCodes.lockCodes(json.encode({["1"] = "initialName"}))))
      test.wait_for_events()  

      test.socket.capability:__queue_receive({ mock_device.id, { capability = capabilities.lockCodes.ID, command = "nameSlot", args = { 1, "foo" } } })
      test.socket.capability:__expect_send(mock_device:generate_test_message("main", capabilities.lockCodes.codeChanged("1 renamed", {})))
      test.socket.capability:__expect_send(mock_device:generate_test_message("main",
        capabilities.lockCodes.lockCodes(json.encode({["1"] = "foo"}))))
    end
)

test.register_coroutine_test(
  "Setting a user code and getting an incorrect code in response should indicate failure",
  function()
    test.timer.__create_and_queue_test_time_advance_timer(4, "oneshot")
    test.socket.capability:__queue_receive({ mock_device.id, { capability = capabilities.lockCodes.ID, command = "setCode", args = { 1, "1234", "test" } } })
    test.socket.zigbee:__expect_send(
        {
          mock_device.id,
          DoorLock.server.commands.SetPINCode(mock_device,
                                                 1,
                                                 DoorLockUserStatus.OCCUPIED_ENABLED,
                                                 DoorLockUserType.UNRESTRICTED,
                                                 "1234"
          )
        }
    )
    test.wait_for_events()
    test.mock_time.advance_time(4)
    test.socket.zigbee:__expect_send(
        {
          mock_device.id,
          DoorLock.server.commands.GetPINCode(mock_device, 1)
        }
    )
    test.wait_for_events()
    test.socket.zigbee:__queue_receive(
        {
          mock_device.id,
          DoorLock.client.commands.GetPINCodeResponse.build_test_rx(
              mock_device,
              1,
              DoorLockUserStatus.OCCUPIED_ENABLED,
              DoorLockUserType.UNRESTRICTED,
              "5678"
          )
        }
    )
    test.socket.capability:__expect_send(mock_device:generate_test_message("main",
      capabilities.lockCodes.codeChanged("1 failed", { })))
  end
)

test.run_registered_tests()
