-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local max = math.max
local min = math.min
local abs = math.abs

local rpmToAV = 0.10471971768
local avToRPM = 9.5493
local psiToPascal = 6894.757293178
local pascalToPSI = 1 / psiToPascal
local barToPascal = 100000

M.isExisting = true

local forcedInductionInfoStream = {
    rpm = 0,
    coef = 1,
    boost = 0,
    maxBoost = 0,
    pulses = 0,
    loss = 0
}

local dtSum = 0
local twoPi = 2 * math.pi

local assignedEngine = nil
local pressureSmoother = nil
local pulseCoefModifier = 1

local blowerRatio = 1
local maxPressure = 0
local blowerPressure = 0
local lastPressure = 0 --pressure at the highest defined blower RPM
local lostTorqueCoef = 0

local clutchEngageRPM = 0
local invClutchEngageRange = 0
local clutchDisengageRPM = 0
local invClutchDisengageRange = 0

local blowerRPM = 0
local blowerAV = 0
local blowerMaxAV = 0

local whineLoop = nil
local whinePitchPerAV
local whineVolumePerPascal
local whineVolumePerRPM
local fadeInStartRPM = 1200
local fadeInEndRPM = 2200

local damagePressureCoef = 1
local wearPressureCoef = 1

local bypassConditions = {
    minThrottle = 0.01,
    maxPressure = 9999 * psiToPascal
}

local function applyDeformGroupDamage(damageAmount)
    damagePressureCoef = clamp(damagePressureCoef - linearScale(damageAmount, 0, 0.01, 0, 1), -0.1, 1)
    damageTracker.setDamage("engine", "inductionSystemDamaged", true, true)
end

local function setPartCondition(odometer, integrity, visual)
    wearPressureCoef = linearScale(odometer, 30000000, 1000000000, 1, 0.5)
    local integrityState = integrity
    if type(integrity) == "number" then
        local integrityValue = integrity
        integrityState = {
            damageFrictionCoef = linearScale(integrityValue, 1, 0, 1, 0.5),
            damageExhaustPowerCoef = linearScale(integrityValue, 1, 0, 1, 0.2)
        }
    end

    damagePressureCoef = integrityState.damagePressureCoef or 1
end

local function getPartCondition()
    local integrityState = {
        damagePressureCoef = damagePressureCoef
    }

    local pressureIntegrityValue = linearScale(damagePressureCoef, 1, 0.5, 1, 0)

    local integrityValue = min(pressureIntegrityValue)
    return integrityValue, integrityState
end

local function setBypassPressure(pressurePSI)
    bypassConditions.maxPressure = pressurePSI * psiToPascal
end

local function updateSounds(dt)
    -- local volumeFadeIn = min(max((blowerRPM - fadeInStartRPM) / (fadeInEndRPM - fadeInStartRPM), 0), 1)
    local volumePressure = clamp(abs(blowerPressure) * whineVolumePerPascal, 0, 15)
    local volumeRPM = clamp(blowerRPM * whineVolumePerRPM, 0, 15)
    -- local volume = max(volumePressure, volumeRPM) * volumeFadeIn
    local volume = max(volumePressure, volumeRPM)
    local pitch = max(blowerAV * whinePitchPerAV, 0)
    whineLoop:setVolumePitch(volume, pitch)

    -- Audio Debug
    --print(string.format(" SUPRCH VOLRTPC (blowerPressure %7.0f / volumePressure %.2f / volumeRPM %.2f) RTPC = %.2f", blowerPressure, volumePressure, volumeRPM, volume))
    -- print(string.format(" SUPRCH PITRTPC (blowerRPM %7.0f / blowerAV %5.0f / volumeRPM %.2f) RTPC = %.2f", blowerRPM, blowerAV, volumeRPM, pitch))
    --print(string.format(" SUPRCH volume = %.2f * pitch = %.2f", volume, pitch))
    -- streams.drawGraph('SPCHGR blowerRPM', {value = blowerRPM, max = 1})
    -- streams.drawGraph('SPCHGR blowerAV', {value = blowerAV, max = 1})
    -- streams.drawGraph('SPCHGR volumeRPM', {value = volumeRPM, max = 1})
    -- streams.drawGraph('SPCHGR pitch', {value = pitch, max = 1})
end

local function updateFixedStep(dt)
    if assignedEngine.engineDisabled then
        M.updateGFX = nop
        M.updateFixedStep = nop
        return
    end
end
local function updateGFX(dt)

    -- Some verification stuff
    if assignedEngine.engineDisabled then
        M.updateGFX = nop
        M.updateFixedStep = nop
        return
    end

    local engAV = max(assignedEngine.outputAV1, 0)
    dtSum = dtSum + dt
    if dtSum >= twoPi then
        dtSum = dtSum - twoPi
    end

    local engage = min(max((engAV * avToRPM - clutchEngageRPM) * invClutchEngageRange, 0), 1)
    local disengage = min(max(-(engAV * avToRPM - clutchDisengageRPM) * invClutchDisengageRange + 1, 0), 1)
    local clutchRatio = min(engage, disengage)
    blowerAV = engAV * blowerRatio * clutchRatio
    blowerRPM = blowerAV * avToRPM

    local inductionPressure = assignedEngine.blowerPressure or -1
    blowerPressure = (inductionPressure - 1) * barToPascal * clutchRatio
    electrics.values.superchargerBoost = blowerPressure
end

local function resetSounds(jbeamData)
end

local function initSounds(jbeamData)
    local whineSample = jbeamData.whineLoopEvent or "event:>Vehicle>Forced_Induction>Supercharger_01>supercharger"
    whineLoop = sounds.createSoundObj(whineSample, "AudioDefaultLoop3D", "superchargerWhine", assignedEngine.engineNodeID)

    assignedEngine:setSoundLocation("superchargerwhine", "Supercharger Whine: " .. whineSample, {assignedEngine.engineNodeID})

    whinePitchPerAV = (jbeamData.whinePitchPer10kRPM or 0.65) * 0.01 * rpmToAV
    whineVolumePerPascal = (jbeamData.whineVolumePerPSI or 0.01) * pascalToPSI --note this will be almost silent by default
    whineVolumePerRPM = jbeamData.whineVolumePer10kRPM and (jbeamData.whineVolumePer10kRPM / 10000)
    if not whineVolumePerRPM then
        local maxPressureVolume = min(maxPressure * psiToPascal * whineVolumePerPascal, 15)
        whineVolumePerRPM = maxPressureVolume / (blowerMaxAV * avToRPM) * 0.5 --default to 50% of the volume we expect from pressure to not be louder than that
    end

    -- Audio Debug
    --print (string.format("SPCHGR Whine", jbeamData.whineLoopEvent).." "..jbeamData.whineLoopEvent)
    --print (string.format("whineVolumePerPSI = %.3f : whinePitchPer10kRPM = %.3f", jbeamData.whineVolumePerPSI, jbeamData.whinePitchPer10kRPM))
    --print (string.format("whineVolumePerRPM = %.3f", whineVolumePerRPM))
end

local function reset(jbeamData)
    pressureSmoother:reset()
    lastPressure = 0
    damagePressureCoef = 1
    wearPressureCoef = 1
    damageTracker.setDamage("engine", "superchargerDamaged", false)
end

local function init(device, jbeamData)
    if jbeamData == nil then
        M.updateGFX = nop
        return
    end

    pressureSmoother = newTemporalSmoothing(10 * barToPascal)

    assignedEngine = device
    damagePressureCoef = 1
    wearPressureCoef = 1

    blowerRatio = jbeamData.gearRatio or 1
    local maxBlowerRPM = math.ceil(assignedEngine.maxRPM * blowerRatio)

    pulseCoefModifier = 1
    lostTorqueCoef = 0
    clutchEngageRPM = jbeamData.clutchEngageRPM or 1000
    invClutchEngageRange = 1 / (jbeamData.clutchEngageRange or clutchEngageRPM * 0.2)
    clutchDisengageRPM = jbeamData.clutchDisengageRPM or assignedEngine.maxRPM * 2
    invClutchDisengageRange = 1 / (jbeamData.clutchDisengageRange or clutchDisengageRPM * 0.05)


    maxPressure = jbeamData.maxPressure * psiToPascal
    electrics.values.superchargerBoostMax = maxPressure

    blowerMaxAV = 0
    for i = 1, assignedEngine.maxAV, 5 do
        local engage = min(max((i * avToRPM - clutchEngageRPM) * invClutchEngageRange, 0), 1)
        local disengage = min(max(-(i * avToRPM - clutchDisengageRPM) * invClutchDisengageRange + 1, 0), 1)
        local clutchRatio = min(engage, disengage)
        local tempBlowerAV = i * blowerRatio * clutchRatio
        blowerMaxAV = max(tempBlowerAV, blowerAV)
    end

    damageTracker.setDamage("engine", "superchargerDamaged", false)

    M.updateGFX = updateGFX
    M.updateFixedStep = updateFixedStep
end

-- public interface
M.init = init
M.reset = reset
M.initSounds = initSounds
M.resetSounds = resetSounds
M.updateSounds = updateSounds
M.updateFixedStep = nop
M.updateGFX = nop
M.getTorqueCoefs = nop
M.setBypassPressure = setBypassPressure

M.applyDeformGroupDamage = applyDeformGroupDamage
M.setPartCondition = setPartCondition
M.getPartCondition = getPartCondition

return M



