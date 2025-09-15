-- modifiable variables

local targetStrength = 50
local maxTemperature = 8000
local safeTemperature = 3000
local lowestFieldPercent = 15

local autoBalanceGain = 0.6 -- proportional gain for field error correction (0 disables)
local autoIntegralGain = 0.2 -- integral gain scales how quickly long-term error is corrected
local autoIntegralLimit = 1000000 -- absolute cap for the accumulated integral term (0 disables)
local autoStepMin = 1000 -- rf/t increase allowed even when drain is tiny
local autoStepMax = 250000 -- rf/t maximum increase per update to avoid spikes
local autoStepDownMax = 0 -- rf/t maximum decrease per update (0 disables the cap)

local activateOnCharged = 1

-- please leave things untouched from here on
os.loadAPI("lib/f")

local version = "0.25"
-- toggleable via the monitor, use our algorithm to achieve our target field strength or let the user tweak it
local autoInputGate = 1
local curInputGate = 222000
local lastAutoFlow = curInputGate
local autoIntegral = 0

local mon, monitor, monX, monY

-- peripherals
local reactor
local fluxgate, fluxgateSide
local inputfluxgate, inputfluxgateSide

-- allow user to pick which flux gates to use
local function chooseFluxGate(prompt, exclude)
  local gates = {}
  for _, name in pairs(peripheral.getNames()) do
    local pType = peripheral.getType(name)
    if name ~= exclude and (
      pType == "flux_gate" or
      pType == "flow_gate" or
      name:match("^flow_gate_%d+") or
      name:match("^flow_gates_%d+")
    ) then
      table.insert(gates, name)
    end
  end
  if #gates == 0 then
    return nil, nil
  end
  print(prompt)
  for i, n in ipairs(gates) do
    print(i .. ": " .. n)
  end
  local choice
  repeat
    write("> ")
    choice = tonumber(read())
  until choice ~= nil and gates[choice] ~= nil
  return peripheral.wrap(gates[choice]), gates[choice]
end

-- reactor information
local ri

-- last performed action
local action = "None since reboot"
local emergencyCharge = false
local emergencyTemp = false

monitor = f.periphSearch("monitor")
reactor = f.periphSearch("draconic_reactor")
if reactor == nil then
  reactor = f.periphSearch("reactor")
end
fluxgate, fluxgateSide = chooseFluxGate("Select output flux gate:")
inputfluxgate, inputfluxgateSide = chooseFluxGate("Select input flux gate:", fluxgateSide)

if monitor == nil then
        error("No valid monitor was found")
end

if reactor == nil then
        error("No valid reactor was found")
end

if fluxgate == nil then
        error("No valid flux gate was found")
end


if inputfluxgate == nil then
        error("No valid flux gate was found")
end

monX, monY = monitor.getSize()
mon = {}
mon.monitor,mon.X, mon.Y = monitor, monX, monY
mon = f.init_monitor(monitor, 29, 19)

--write settings to config file
function save_config()
  sw = fs.open("config.txt", "w")
  sw.writeLine(version)
  sw.writeLine(autoInputGate)
  sw.writeLine(curInputGate)
  sw.close()
end

--read settings from file
function load_config()
  sr = fs.open("config.txt", "r")
  version = sr.readLine()
  autoInputGate = tonumber(sr.readLine())
  curInputGate = tonumber(sr.readLine())
  lastAutoFlow = curInputGate
  autoIntegral = 0
  sr.close()
end



-- 1st time? save our settings, if not, load our settings
if fs.exists("config.txt") == false then
  save_config()
else
  load_config()
end

inputfluxgate.setSignalLowFlow(curInputGate)
lastAutoFlow = curInputGate

function buttons()

  while true do
    -- button handler
    local event, side, xPos, yPos = os.pullEvent("monitor_touch")

  -- output gate controls
    -- 2-4 = -1000, 6-9 = -10000, 10-12,8 = -100000
    -- 17-19 = +1000, 21-23 = +10000, 25-27 = +100000
    if yPos == 8 then
      local cFlow = fluxgate.getSignalLowFlow()
      if xPos >= 2 and xPos <= 4 then
        cFlow = cFlow - 1000
      elseif xPos >= 6 and xPos <= 9 then
        cFlow = cFlow - 10000
      elseif xPos >= 10 and xPos <= 12 then
        cFlow = cFlow - 100000
      elseif xPos >= 17 and xPos <= 19 then
        cFlow = cFlow + 100000
      elseif xPos >= 21 and xPos <= 23 then
        cFlow = cFlow + 10000
      elseif xPos >= 25 and xPos <= 27 then
        cFlow = cFlow + 1000
      end
      fluxgate.setSignalLowFlow(cFlow)

    elseif yPos == 10 then
      if xPos >= 14 and xPos <= 15 then
        if autoInputGate == 1 then
          autoInputGate = 0
          autoIntegral = 0
          inputfluxgate.setSignalLowFlow(curInputGate)
          lastAutoFlow = curInputGate
        else
          autoInputGate = 1
          autoIntegral = 0
          lastAutoFlow = inputfluxgate.getSignalLowFlow() or curInputGate
        end
        save_config()
      elseif autoInputGate == 0 then
        local cFlow = curInputGate
        if xPos >= 2 and xPos <= 4 then
          cFlow = cFlow - 1000
        elseif xPos >= 6 and xPos <= 9 then
          cFlow = cFlow - 10000
        elseif xPos >= 10 and xPos <= 12 then
          cFlow = cFlow - 100000
        elseif xPos >= 17 and xPos <= 19 then
          cFlow = cFlow + 100000
        elseif xPos >= 21 and xPos <= 23 then
          cFlow = cFlow + 10000
        elseif xPos >= 25 and xPos <= 27 then
          cFlow = cFlow + 1000
        end
        curInputGate = cFlow
        inputfluxgate.setSignalLowFlow(curInputGate)
        lastAutoFlow = curInputGate
        save_config()
      end
    end
  end

function drawButtons(y)

f.draw_text(mon, 6, y, " <<", colors.white, colors.gray)
  f.draw_text(mon, 10, y, "<<<", colors.white, colors.gray)

  f.draw_text(mon, 17, y, ">>>", colors.white, colors.gray)
  f.draw_text(mon, 21, y, ">> ", colors.white, colors.gray)
  f.draw_text(mon, 25, y, " > ", colors.white, colors.gray)
end



local function regulateInputGate(info)
  if not info then
    return
  end

  local drain = math.max(info.fieldDrainRate or 0, 0)
  local targetRatio = targetStrength / 100

  if targetRatio <= 0 then
    targetRatio = 0.01
  elseif targetRatio >= 1 then
    targetRatio = 0.99
  end

  local denom = 1 - targetRatio
  local baseFlow = drain

  if denom > 0 then
    -- replicate the drmon ratio: keep the field at the target percentage by
    -- compensating for the output drain scaled by the remaining headroom
    baseFlow = drain / denom
  end

  local fieldRatio = 0
  if info.maxFieldStrength and info.maxFieldStrength > 0 then
    fieldRatio = (info.fieldStrength or 0) / info.maxFieldStrength
  end

  if fieldRatio ~= fieldRatio or fieldRatio == math.huge or fieldRatio == -math.huge then
    fieldRatio = 0
  end

  if fieldRatio < 0 then
    fieldRatio = 0
  elseif fieldRatio > 1 then
    fieldRatio = 1
  end

  local ratioError = targetRatio - fieldRatio
  local proportional = 0

  if autoBalanceGain ~= 0 then
    proportional = baseFlow * ratioError * autoBalanceGain
  end

  if autoIntegralGain ~= 0 then
    local integralStep = ratioError * baseFlow * autoIntegralGain
    if integralStep ~= integralStep or integralStep == math.huge or integralStep == -math.huge then
      integralStep = 0
    end
    autoIntegral = autoIntegral + integralStep
    if autoIntegralLimit > 0 then
      if autoIntegral > autoIntegralLimit then
        autoIntegral = autoIntegralLimit
      elseif autoIntegral < -autoIntegralLimit then
        autoIntegral = -autoIntegralLimit
      end
    end
  else
    autoIntegral = 0
  end

  local desiredFlow = baseFlow + proportional + autoIntegral

  if desiredFlow ~= desiredFlow or desiredFlow == math.huge or desiredFlow == -math.huge then
    desiredFlow = drain
    autoIntegral = 0
  end

  local currentFlow = inputfluxgate.getSignalLowFlow() or 0
  local delta = desiredFlow - currentFlow

  local stepUpLimit = autoStepMin

  if drain > 0 then
    stepUpLimit = math.max(stepUpLimit, drain * 0.25)
  end

  if autoStepMax > 0 then
    stepUpLimit = math.min(stepUpLimit, autoStepMax)
  end

  if delta > 0 and stepUpLimit > 0 then
    if delta > stepUpLimit then
      desiredFlow = currentFlow + stepUpLimit
    end
  elseif delta < 0 and autoStepDownMax > 0 then
    local stepDownLimit = autoStepDownMax
    if -delta > stepDownLimit then
      desiredFlow = currentFlow - stepDownLimit
    end
  end

  if desiredFlow < 0 then
    desiredFlow = 0
    autoIntegral = 0
  end

  desiredFlow = math.floor(desiredFlow + 0.5)

  if desiredFlow ~= lastAutoFlow then
    print("Target Gate: " .. desiredFlow)
    lastAutoFlow = desiredFlow
  end

  inputfluxgate.setSignalLowFlow(desiredFlow)
end

function update()

  while true do
    local function clear_line(y)
      f.draw_line(mon, 1, y, mon.X, colors.black)
    end

    mon.monitor.setVisible(false)

      ri = reactor.getReactorInfo()

      -- print out all the infos from .getReactorInfo() to term

      if ri == nil then
        error("reactor has an invalid setup")
      end

      for k, v in pairs (ri) do
        print(k .. ": " .. tostring(v))
      end
      print("Output Gate: ", fluxgate.getSignalLowFlow())
      print("Input Gate: ", inputfluxgate.getSignalLowFlow())

      -- monitor output

      local statusColor
      statusColor = colors.red

      if ri.status == "online" or ri.status == "charged" then
        statusColor = colors.green
      elseif ri.status == "offline" then
        statusColor = colors.gray
      elseif ri.status == "charging" then
        statusColor = colors.orange
      end

      clear_line(2)
      f.draw_text_lr(mon, 2, 2, 1, "Reactor Status", string.upper(ri.status), colors.white, statusColor, colors.black)

      clear_line(4)
      f.draw_text_lr(mon, 2, 4, 1, "Generation", f.format_int(ri.generationRate) .. " rf/t", colors.white, colors.lime, colors.black)

      local tempColor = colors.red
      if ri.temperature <= 5000 then tempColor = colors.green end
      if ri.temperature >= 5000 and ri.temperature <= 6500 then tempColor = colors.orange end
      clear_line(6)
      f.draw_text_lr(mon, 2, 6, 1, "Temperature", f.format_int(ri.temperature) .. "C", colors.white, tempColor, colors.black)

      clear_line(7)
      f.draw_text_lr(mon, 2, 7, 1, "Output Gate", f.format_int(fluxgate.getSignalLowFlow()) .. " rf/t", colors.white, colors.blue, colors.black)

      -- buttons
      drawButtons(8)

      clear_line(9)
      f.draw_text_lr(mon, 2, 9, 1, "Input Gate", f.format_int(inputfluxgate.getSignalLowFlow()) .. " rf/t", colors.white,colors.blue, colors.black)

      clear_line(10)
      if autoInputGate == 1 then
        f.draw_text(mon, 14, 10, "AU", colors.white, colors.gray)
      else
        f.draw_text(mon, 14, 10, "MA", colors.white, colors.gray)
        drawButtons(10)
      end

      local satPercent
      satPercent = math.ceil(ri.energySaturation / ri.maxEnergySaturation * 10000)*.01

      clear_line(11)
      f.draw_text_lr(mon, 2, 11, 1, "Energy Saturation", satPercent .. "%", colors.white, colors.white, colors.black)
      f.progress_bar(mon, 2, 12, mon.X-2, satPercent, 100, colors.blue, colors.gray)

      local fieldPercent, fieldColor
      fieldPercent = math.ceil(ri.fieldStrength / ri.maxFieldStrength * 10000)*.01

      fieldColor = colors.red
      if fieldPercent >= 50 then fieldColor = colors.green end
      if fieldPercent < 50 and fieldPercent > 30 then fieldColor = colors.orange end

      clear_line(14)
      if autoInputGate == 1 then
        f.draw_text_lr(mon, 2, 14, 1, "Field Strength T:" .. targetStrength, fieldPercent .. "%", colors.white, fieldColor, colors.black)
      else
        f.draw_text_lr(mon, 2, 14, 1, "Field Strength", fieldPercent .. "%", colors.white, fieldColor, colors.black)
      end
      f.progress_bar(mon, 2, 15, mon.X-2, fieldPercent, 100, fieldColor, colors.gray)

      local fuelPercent, fuelColor

      fuelPercent = 100 - math.ceil(ri.fuelConversion / ri.maxFuelConversion * 10000)*.01

      fuelColor = colors.red

      if fuelPercent >= 70 then fuelColor = colors.green end
      if fuelPercent < 70 and fuelPercent > 30 then fuelColor = colors.orange end

      clear_line(17)
      f.draw_text_lr(mon, 2, 17, 1, "Fuel ", fuelPercent .. "%", colors.white, fuelColor, colors.black)
      f.progress_bar(mon, 2, 18, mon.X-2, fuelPercent, 100, fuelColor, colors.gray)

      clear_line(19)
      f.draw_text_lr(mon, 2, 19, 1, "Action", action, colors.gray, colors.gray, colors.black)

      -- actual reactor interaction
      --
      if emergencyCharge == true then
        reactor.chargeReactor()
     end

      -- are we charging? open the floodgates
      if ri.status == "charging" then
        inputfluxgate.setSignalLowFlow(900000)
        emergencyCharge = false
      end

      -- are we stopping from a shutdown and our temp is better? activate
      if emergencyTemp == true and ri.status == "stopping" and ri.temperature < safeTemperature then
        reactor.activateReactor()
        emergencyTemp = false
      end

      -- are we charged? lets activate
      if ri.status == "charged" and activateOnCharged == 1 then
        reactor.activateReactor()
      end

      -- are we on? regulate the input fludgate to our target field strength
      -- or set it to our saved setting since we are on manual
      if ri.status == "online" then
        if autoInputGate == 1 then
          regulateInputGate(ri)
        else
          autoIntegral = 0
          inputfluxgate.setSignalLowFlow(curInputGate)
          lastAutoFlow = curInputGate
        end
      else
        autoIntegral = 0
      end

      -- safeguards
      --

      -- out of fuel, kill it
      if fuelPercent <= 10 then
        reactor.stopReactor()
        action = "Fuel below 10%, refuel"
      end

      -- field strength is too dangerous, kill and it try and charge it before it blows
      if fieldPercent <= lowestFieldPercent and ri.status == "online" then
        action = "Field Str < " ..lowestFieldPercent.."%"
        reactor.stopReactor()
        reactor.chargeReactor()
        emergencyCharge = true
      end

      -- temperature too high, kill it and activate it when its cool
      if ri.temperature > maxTemperature then
        reactor.stopReactor()
        action = "Temp > " .. maxTemperature
        emergencyTemp = true
      end
    
parallel.waitForAny(buttons, update)
    end
  end
