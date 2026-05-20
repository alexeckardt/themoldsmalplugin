local fileName = ""

-- 全局设置
local boilSettings = {
    frameCount = 8.0,
    duration = 1.6,
    strength = 1.0,
    density = 2.0,
    perLayerSeed = false,
    preview = true,
    noiseFidelity = 12.0
}

-- Cache for fast hash grid
local hashCache = {}

-- Fast hash function (no bitwise operations)
local function fastHash(x, y)
    local h = math.sin(x * 12.9898 + y * 78.233) * 43758.5453
    return h - math.floor(h)
end

-- Get cached hash value for grid point
local function getCachedHash(x, y)
    local key = x .. "," .. y
    if not hashCache[key] then
        hashCache[key] = fastHash(x, y)
    end
    return hashCache[key]
end

-- Simpler, faster value noise
function valueNoise(px, py)
    local grid_x0 = math.floor(px)
    local grid_y0 = math.floor(py)
    local grid_x1 = grid_x0 + 1.0
    local grid_y1 = grid_y0 + 1.0

    local sx = px - grid_x0
    local sy = py - grid_y0
    
    -- Smoothstep interpolation
    local u = sx * sx * (3.0 - 2.0 * sx)
    local v = sy * sy * (3.0 - 2.0 * sy)

    local v00 = getCachedHash(grid_x0, grid_y0)
    local v10 = getCachedHash(grid_x1, grid_y0)
    local v01 = getCachedHash(grid_x0, grid_y1)
    local v11 = getCachedHash(grid_x1, grid_y1)

    local mix0 = v00 + u * (v10 - v00)
    local mix1 = v01 + u * (v11 - v01)
    return mix0 + v * (mix1 - mix0)
end

function createBoilImage(originalImage, boilStrength, boilDensity, seed, frameIndex, offsetX, offsetY, canvasWidth,
                         canvasHeight, noiseFidelity)
    local strengthCeil = math.ceil(boilStrength)
    local width = originalImage.width + 2 * strengthCeil
    local height = originalImage.height + 2 * strengthCeil
    seed = seed or 0.0
    frameIndex = frameIndex or 0
    noiseFidelity = math.max(1, noiseFidelity or 4)

    local newImage = Image(width, height)
    newImage:clear(0)

    local sp_x = (frameIndex * 73.0 + seed * 137.0) % 1024.0
    local sp_y = (frameIndex * 211.0 + seed * 293.0) % 1024.0
    local boilDensity = boilDensity / math.min(canvasWidth, canvasHeight)
    local boilStrength_4pi = boilStrength * 4.0 * math.pi

    -- Generate noise at lower fidelity for performance
    local noiseWidth = math.ceil(width / noiseFidelity) + 2
    local noiseHeight = math.ceil(height / noiseFidelity) + 2
    
    -- Pre-compute noise field at lower resolution
    local noiseField = {}
    for ny = 0, noiseHeight - 1 do
        noiseField[ny] = {}
        for nx = 0, noiseWidth - 1 do
            local noise_coord_x = boilDensity * (nx * noiseFidelity + offsetX + sp_x)
            local noise_coord_y = boilDensity * (ny * noiseFidelity + offsetY + sp_y)
            local noise = valueNoise(noise_coord_x, noise_coord_y) * boilStrength_4pi
            noiseField[ny][nx] = noise
        end
    end

    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local uvX = x - strengthCeil
            local uvY = y - strengthCeil

            -- Interpolate noise from lower-res field
            local noiseX = x / noiseFidelity
            local noiseY = y / noiseFidelity
            local nxBase = math.floor(noiseX)
            local nyBase = math.floor(noiseY)
            local nxFrac = noiseX - nxBase
            local nyFrac = noiseY - nyBase
            
            local n00 = noiseField[nyBase] and noiseField[nyBase][nxBase] or 0
            local n10 = noiseField[nyBase] and noiseField[nyBase][nxBase + 1] or 0
            local n01 = noiseField[nyBase + 1] and noiseField[nyBase + 1][nxBase] or 0
            local n11 = noiseField[nyBase + 1] and noiseField[nyBase + 1][nxBase + 1] or 0
            
            local nx0 = n00 + (n10 - n00) * nxFrac
            local nx1 = n01 + (n11 - n01) * nxFrac
            local noise = nx0 + (nx1 - nx0) * nyFrac

            local uvBiasX = math.cos(noise) * boilStrength
            local uvBiasY = math.sin(noise) * boilStrength

            local srcX = uvX + math.floor(uvBiasX + 0.5)
            local srcY = uvY + math.floor(uvBiasY + 0.5)

            local color
            if srcX >= 0 and srcX < originalImage.width and srcY >= 0 and srcY < originalImage.height then
                color = originalImage:getPixel(srcX, srcY)
            elseif uvX >= 0 and uvX < originalImage.width and uvY >= 0 and uvY < originalImage.height then
                color = originalImage:getPixel(uvX, uvY)
            else
                color = Color { r = 0, g = 0, b = 0, a = 0 }
            end

            newImage:drawPixel(x, y, color)
        end
    end

    return newImage
end

function applyBoilEffect(boilFrameCount, boilDuration, boilStrength, boilDensity, perLayerSeed, preview)
    local sprite = app.activeSprite

    if not sprite then
        return
    end

    local durationPerFrame = boilDuration / boilFrameCount
    
    -- Determine which frames to process
    local framesToProcess = {}
    if preview then
        -- Only process the first frame
        framesToProcess = { 1 }
    else
        -- Process all frames
        for frameNum = 1, #sprite.frames do
            table.insert(framesToProcess, frameNum)
        end
    end

    app.transaction("Boil Animation", function()
        local baseSeed = 12345  -- Fixed seed for consistency
        
        -- Process frames in reverse order to avoid index shifting issues
        for frameIdx = #framesToProcess, 1, -1 do
            local currentFrameIndex = framesToProcess[frameIdx]
            local insertFrameIndex = currentFrameIndex + 1

            local originalCels = {}
            local visibleCelCount = 0
            for i, layer in ipairs(sprite.layers) do
                if layer.isVisible then
                    local originalCel = layer:cel(currentFrameIndex)
                    if originalCel and originalCel.image then
                        originalCels[i] = { Point(originalCel.position.x, originalCel.position.y), originalCel.image:clone() }
                        visibleCelCount = visibleCelCount + 1
                    end
                end
            end

            for i = 1, boilFrameCount do
                local newFrame = sprite:newFrame(currentFrameIndex)
                newFrame = sprite.frames[insertFrameIndex]
                newFrame.duration = durationPerFrame

                for j, layer in ipairs(sprite.layers) do
                    if not layer.isVisible then
                        goto continue
                    end

                    local originalCel = originalCels[j]
                    if not originalCel then
                        goto continue
                    end
                    local newCel = layer:cel(insertFrameIndex)

                    if not newCel then
                        newCel = layer:newCel(insertFrameIndex)
                    end

                    local layerSeed = baseSeed
                    if perLayerSeed then
                        layerSeed = baseSeed + j
                    end

                    newCel.image = createBoilImage(originalCel[2], boilStrength, boilDensity, layerSeed, i,
                        originalCel[1].x, originalCel[1].y, app.activeSprite.width, app.activeSprite.height, boilSettings.noiseFidelity)
                    newCel.position = Point(originalCel[1].x - boilStrength, originalCel[1].y - boilStrength)

                    ::continue::
                end
            end

            local tag = sprite:newTag(insertFrameIndex, insertFrameIndex + boilFrameCount - 1)
            tag.name = "frame" .. currentFrameIndex
        end
    end)
end

function init(plugin)
    plugin:newCommand {
        id = "create_boil_effect_animation",
        title = "Boil Animation",
        group = "edit_fx",
        onclick = function()
            local dlg = Dialog("Boil Animation Settings")

            dlg:number {
                id = "frameCount",
                label = "Frame Count:",
                text = tostring(boilSettings.frameCount)
            }
            dlg:number {
                id = "duration",
                label = "Duration (seconds):",
                text = tostring(boilSettings.duration),
                decimals = 1
            }
            dlg:number {
                id = "strength",
                label = "Strength:",
                text = tostring(boilSettings.strength),
                decimals = 1
            }
            dlg:number {
                id = "density",
                label = "Density:",
                text = tostring(boilSettings.density),
                decimals = 1
            }
            dlg:check {
                id = "perLayerSeed",
                label = "Per Layer Seed:",
                selected = boilSettings.perLayerSeed
            }
            dlg:check {
                id = "preview",
                label = "Preview (First Frame Only):",
                selected = boilSettings.preview
            }
            dlg:number {
                id = "noiseFidelity",
                label = "Noise Fidelity (higher = faster):",
                text = tostring(boilSettings.noiseFidelity),
                decimals = 0
            }

            dlg:button { id = "ok", text = "OK" }
            dlg:button { id = "cancel", text = "Cancel" }

            dlg:show()

            if dlg.data.ok then
                boilSettings.frameCount = tonumber(dlg.data.frameCount) or 8
                boilSettings.duration = tonumber(dlg.data.duration) or 2
                boilSettings.strength = tonumber(dlg.data.strength) or 2
                boilSettings.density = tonumber(dlg.data.density) or 2
                boilSettings.perLayerSeed = dlg.data.perLayerSeed
                boilSettings.preview = dlg.data.preview
                boilSettings.noiseFidelity = math.max(1, tonumber(dlg.data.noiseFidelity) or 4)
                hashCache = {} -- Clear cache for new seed

                applyBoilEffect(
                    boilSettings.frameCount,
                    boilSettings.duration,
                    boilSettings.strength,
                    boilSettings.density,
                    boilSettings.perLayerSeed,
                    boilSettings.preview
                )
            end
        end,
    }
end

function exit(plugin)

end
