-- TNS|BB Erase|TNE
-- Erase the Betaflight blackbox flash from the radio.
-- Talks MSP over CRSF (ExpressLRS / Crossfire), telemetry must be on.
-- Install to /SCRIPTS/TOOLS/bberase.lua, run from SYS -> Tools -> BB Erase.
--
-- Betaflight executes MSP_DATAFLASH_ERASE without checking the arm state,
-- so this script refuses to send it unless a fresh MSP_STATUS says DISARMED.

local CRSF_ADDR_FC    = 0xC8
local CRSF_ADDR_RADIO = 0xEA
local CRSF_MSP_REQ    = 0x7A
local CRSF_MSP_RESP   = 0x7B
local CRSF_MSP_WRITE  = 0x7C

local MSP_DATAFLASH_SUMMARY = 70
local MSP_DATAFLASH_ERASE   = 72
local MSP_STATUS            = 101

local FLASH_READY     = 1
local FLASH_SUPPORTED = 2

-- getTime() ticks are 10 ms
local REPLY_TIMEOUT = 100    -- drop an unanswered request after 1 s
local FRESH_AGE     = 200    -- arm state older than 2 s is not trusted
local POLL_GAP      = 25     -- pause between requests while idle
local START_TIMEOUT = 500    -- erase must show up as busy within 5 s
local ERASE_TIMEOUT = 30000  -- give up waiting after 300 s

local txSeq = 0
local pendingCmd = nil
local sentAt = 0
local lastSent = 0

local rx = { active = false, cmd = 0, size = 0, seq = 0, buf = {} }

local armed = nil
local armedAt = -10000
local fsFlags = nil
local fsTotal = 0
local fsUsed = 0
local fsAt = -10000
local pollToggle = false

-- idle, confirm, starting, erasing, done, failed
local state = "idle"
local stateAt = 0
local eraseRequestSent = false
local failText = ""

local function setState(s)
  state = s
  stateAt = getTime()
end

local function u32(b, i)
  return b[i] + b[i + 1] * 256 + b[i + 2] * 65536 + b[i + 3] * 16777216
end

-- Requests carry no payload, so every one fits in a single MSP chunk:
-- status, size, cmd, crc (crc = size xor cmd xor payload).
local function mspSend(frameType, cmd)
  if not crossfireTelemetryPush() then
    return false
  end
  local status = 0x30 + txSeq -- MSP v1 over CRSF (0x20) + start flag (0x10)
  local frame = { CRSF_ADDR_FC, CRSF_ADDR_RADIO, status, 0, cmd, cmd }
  if not crossfireTelemetryPush(frameType, frame) then
    return false
  end
  txSeq = bit32.band(txSeq + 1, 0x0F)
  pendingCmd = cmd
  sentAt = getTime()
  lastSent = sentAt
  return true
end

local function onReply(cmd, buf)
  if cmd == MSP_STATUS and #buf >= 7 then
    -- flight mode flags start at byte 7, bit 0 is ARM
    armed = bit32.band(buf[7], 1) == 1
    armedAt = getTime()
  elseif cmd == MSP_DATAFLASH_SUMMARY and #buf >= 13 then
    fsFlags = buf[1]
    fsTotal = u32(buf, 6)
    fsUsed = u32(buf, 10)
    fsAt = getTime()
  end
  if cmd == pendingCmd then
    pendingCmd = nil
  end
end

-- Reassemble chunked MSP replies (same framing as betaflight-tx-lua-scripts).
local function onChunk(data)
  local status = data[3]
  if status == nil then
    return
  end
  local version = bit32.rshift(bit32.band(status, 0x60), 5)
  local seq = bit32.band(status, 0x0F)
  local idx = 4
  if bit32.btest(status, 0x10) then
    rx.active = true
    rx.buf = {}
    rx.size = data[idx] or 0
    idx = idx + 1
    if version == 1 then
      rx.cmd = data[idx] or 0
      idx = idx + 1
    else
      rx.cmd = pendingCmd or 0
    end
  elseif not rx.active or bit32.band(rx.seq + 1, 0x0F) ~= seq then
    rx.active = false
    return
  end
  rx.seq = seq
  while idx <= #data and #rx.buf < rx.size do
    rx.buf[#rx.buf + 1] = data[idx]
    idx = idx + 1
  end
  if #rx.buf >= rx.size then
    rx.active = false
    onReply(rx.cmd, rx.buf)
  end
end

local function pollReplies()
  for _ = 1, 20 do
    local cmd, data = crossfireTelemetryPop()
    if cmd == nil then
      return
    end
    if cmd == CRSF_MSP_RESP and data[1] == CRSF_ADDR_RADIO and data[2] == CRSF_ADDR_FC then
      onChunk(data)
    end
  end
end

local function isFresh(t)
  return getTime() - t < FRESH_AGE
end

local function safeToErase()
  return armed == false and isFresh(armedAt)
    and fsFlags ~= nil and isFresh(fsAt)
    and bit32.btest(fsFlags, FLASH_SUPPORTED)
    and bit32.btest(fsFlags, FLASH_READY)
end

local function pump()
  pollReplies()
  local now = getTime()
  if pendingCmd ~= nil and now - sentAt > REPLY_TIMEOUT then
    pendingCmd = nil
  end
  if pendingCmd ~= nil then
    return
  end
  if state == "starting" and not eraseRequestSent then
    -- re-check right before sending: arm state must still be fresh and false
    if safeToErase() then
      if mspSend(CRSF_MSP_WRITE, MSP_DATAFLASH_ERASE) then
        eraseRequestSent = true
        stateAt = getTime()
      end
    else
      failText = "Not safe: armed or no link"
      setState("failed")
    end
    return
  end
  if now - lastSent < POLL_GAP and state ~= "starting" and state ~= "erasing" then
    return
  end
  pollToggle = not pollToggle
  if pollToggle then
    mspSend(CRSF_MSP_REQ, MSP_STATUS)
  else
    mspSend(CRSF_MSP_REQ, MSP_DATAFLASH_SUMMARY)
  end
end

local function updateErase()
  local now = getTime()
  if state == "starting" and eraseRequestSent then
    if fsFlags ~= nil and fsAt > stateAt and not bit32.btest(fsFlags, FLASH_READY) then
      setState("erasing")
    elseif fsFlags ~= nil and fsAt > stateAt + 100 and fsUsed == 0 then
      -- tiny or already empty flash may finish before we see it busy
      setState("done")
    elseif now - stateAt > START_TIMEOUT then
      failText = "FC did not start erase"
      setState("failed")
    end
  elseif state == "erasing" then
    if fsFlags ~= nil and fsAt > stateAt and bit32.btest(fsFlags, FLASH_READY) and fsUsed == 0 then
      setState("done")
    elseif now - stateAt > ERASE_TIMEOUT then
      failText = "Timeout, check in Configurator"
      setState("failed")
    end
  end
end

local function mb(bytes)
  return string.format("%.1f", bytes / 1048576)
end

local function draw()
  lcd.clear()
  lcd.drawText(1, 0, "Blackbox erase", INVERS)
  local linked = isFresh(fsAt) or isFresh(armedAt)
  local y = 12
  if not linked then
    lcd.drawText(1, y, "No MSP reply from FC", SMLSIZE)
    lcd.drawText(1, y + 10, "Check link + telemetry", SMLSIZE)
    lcd.drawText(1, y + 20, "(ELRS telem ratio on)", SMLSIZE)
  else
    local armText = "?"
    if isFresh(armedAt) then
      armText = armed and "ARMED" or "disarmed"
    end
    lcd.drawText(1, y, "FC: " .. armText, SMLSIZE)
    if fsFlags ~= nil and not bit32.btest(fsFlags, FLASH_SUPPORTED) then
      lcd.drawText(1, y + 10, "No onboard flash log", SMLSIZE)
    elseif fsFlags ~= nil then
      lcd.drawText(1, y + 10, "Used " .. mb(fsUsed) .. " / " .. mb(fsTotal) .. " MB", SMLSIZE)
    end
  end

  y = 44
  if state == "idle" then
    if safeToErase() then
      lcd.drawText(1, y, "Hold ENTER to erase", SMLSIZE)
    elseif isFresh(armedAt) and armed then
      lcd.drawText(1, y, "Disarm first", SMLSIZE + BLINK)
    end
  elseif state == "confirm" then
    lcd.drawText(1, y, "Erase ALL logs?", SMLSIZE + INVERS)
    lcd.drawText(1, y + 10, "ENTER=yes  RTN=no", SMLSIZE)
  elseif state == "starting" or state == "erasing" then
    local secs = math.floor((getTime() - stateAt) / 100)
    lcd.drawText(1, y, "Erasing... " .. secs .. " s", SMLSIZE + BLINK)
    lcd.drawText(1, y + 10, "Do not power off", SMLSIZE)
  elseif state == "done" then
    lcd.drawText(1, y, "Erased", SMLSIZE + INVERS)
    lcd.drawText(1, y + 10, "RTN to exit", SMLSIZE)
  elseif state == "failed" then
    lcd.drawText(1, y, failText, SMLSIZE + INVERS)
    lcd.drawText(1, y + 10, "ENTER=back RTN=exit", SMLSIZE)
  end
end

local function init()
  setState("idle")
end

local function run(event)
  pump()
  updateErase()

  if state == "idle" then
    if event == EVT_VIRTUAL_ENTER_LONG and safeToErase() then
      setState("confirm")
    elseif event == EVT_VIRTUAL_EXIT then
      return 1
    end
  elseif state == "confirm" then
    -- ignore the key release that follows the long press
    if event == EVT_VIRTUAL_ENTER and getTime() - stateAt > 50 then
      eraseRequestSent = false
      setState("starting")
    elseif event == EVT_VIRTUAL_EXIT then
      setState("idle")
    end
  elseif state == "failed" then
    if event == EVT_VIRTUAL_ENTER then
      setState("idle")
    elseif event == EVT_VIRTUAL_EXIT then
      return 1
    end
  elseif event == EVT_VIRTUAL_EXIT and state ~= "starting" then
    -- leaving during "erasing" is fine, the FC finishes on its own
    return 1
  end

  draw()
  return 0
end

return { init = init, run = run }
