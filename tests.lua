require 'optimize-nn'

local optest = torch.TestSuite()
local tester = torch.Tester()

local models = {}
models.basic1 = function()
  local m = nn.Sequential()
  local prl = nn.ParallelTable()
  prl:add(nn.Linear(2,2))
  prl:add(nn.Sequential():add(nn.Linear(2,1)):add(nn.Sigmoid()):add(nn.Linear(1,1)))
  m:add(prl)
  m:add(nn.JoinTable(2))
  m:add(nn.Linear(3,2))
  m:add(nn.ReLU(true))

  local input = {torch.rand(2,2), torch.rand(2,2)}
  return m, input
end
models.basic2 = function()
  local m = nn.Sequential()
  m:add(nn.SpatialConvolution(1,1,3,3,1,1,1,1))
  --  m:add(nn.ReLU(true))
  --  m:add(nn.SpatialConvolution(1,1,3,3,1,1,1,1))
  --  m:add(nn.ReLU(true))
  m:add(nn.View(32*32))
  m:add(nn.Linear(32*32,100))
  --  m:add(nn.ReLU(true))
  --  m:add(nn.Linear(100,10))
  local input = torch.rand(1,1,32,32)
  return m, input
end
models.alexnet = function()
  -- taken from soumith's imagenet-multiGPU
  -- https://github.com/soumith/imagenet-multiGPU.torch/blob/master/models/alexnet.lua
  local features = nn.Concat(2)
  local fb1 = nn.Sequential() -- branch 1
  fb1:add(nn.SpatialConvolution(3,48,11,11,4,4,2,2))       -- 224 -> 55
  fb1:add(nn.ReLU(true))
  fb1:add(nn.SpatialMaxPooling(3,3,2,2))                   -- 55 ->  27
  fb1:add(nn.SpatialConvolution(48,128,5,5,1,1,2,2))       --  27 -> 27
  fb1:add(nn.ReLU(true))
  fb1:add(nn.SpatialMaxPooling(3,3,2,2))                   --  27 ->  13
  fb1:add(nn.SpatialConvolution(128,192,3,3,1,1,1,1))      --  13 ->  13
  fb1:add(nn.ReLU(true))
  fb1:add(nn.SpatialConvolution(192,192,3,3,1,1,1,1))      --  13 ->  13
  fb1:add(nn.ReLU(true))
  fb1:add(nn.SpatialConvolution(192,128,3,3,1,1,1,1))      --  13 ->  13
  fb1:add(nn.ReLU(true))
  fb1:add(nn.SpatialMaxPooling(3,3,2,2))                   -- 13 -> 6

  local fb2 = fb1:clone() -- branch 2
  for k,v in ipairs(fb2:findModules('nn.SpatialConvolution')) do
    v:reset() -- reset branch 2's weights
  end

  features:add(fb1)
  features:add(fb2)

  -- 1.3. Create Classifier (fully connected layers)
  local classifier = nn.Sequential()
  classifier:add(nn.View(256*6*6))
  classifier:add(nn.Dropout(0.5))
  classifier:add(nn.Linear(256*6*6, 4096))
  classifier:add(nn.Threshold(0, 1e-6))
  classifier:add(nn.Dropout(0.5))
  classifier:add(nn.Linear(4096, 4096))
  classifier:add(nn.Threshold(0, 1e-6))
  classifier:add(nn.Linear(4096, 1000))
  classifier:add(nn.LogSoftMax())

  -- 1.4. Combine 1.1 and 1.3 to produce final model
  local model = nn.Sequential():add(features):add(classifier)
  model.imageSize = 256
  model.imageCrop = 224

  local input = torch.rand(1,3,model.imageCrop,model.imageCrop)

  return model, input
end

models.resnet = function(opt)

  local Convolution = nn.SpatialConvolution
  local Avg = nn.SpatialAveragePooling
  local ReLU = nn.ReLU
  local Max = nn.SpatialMaxPooling
  local SBatchNorm = nn.SpatialBatchNormalization

  local function createModel(opt)
    local depth = opt.depth
    local shortcutType = opt.shortcutType or 'B'
    local iChannels

    -- The shortcut layer is either identity or 1x1 convolution
    local function shortcut(nInputPlane, nOutputPlane, stride)
      local useConv = shortcutType == 'C' or
      (shortcutType == 'B' and nInputPlane ~= nOutputPlane)
      if useConv then
        -- 1x1 convolution
        return nn.Sequential()
        :add(Convolution(nInputPlane, nOutputPlane, 1, 1, stride, stride))
        :add(SBatchNorm(nOutputPlane))
      elseif nInputPlane ~= nOutputPlane then
        -- Strided, zero-padded identity shortcut
        return nn.Sequential()
        :add(nn.SpatialAveragePooling(1, 1, stride, stride))
        :add(nn.Concat(2)
        :add(nn.Identity())
        :add(nn.MulConstant(0)))
      else
        return nn.Identity()
      end
    end

    -- The basic residual layer block for 18 and 34 layer network, and the
    -- CIFAR networks
    local function basicblock(n, stride)
      local nInputPlane = iChannels
      iChannels = n

      local s = nn.Sequential()
      s:add(Convolution(nInputPlane,n,3,3,stride,stride,1,1))
      s:add(SBatchNorm(n))
      s:add(ReLU(true))
      s:add(Convolution(n,n,3,3,1,1,1,1))
      s:add(SBatchNorm(n))

      return nn.Sequential()
      :add(nn.ConcatTable()
      :add(s)
      :add(shortcut(nInputPlane, n, stride)))
      :add(nn.CAddTable(true))
      :add(ReLU(true))
    end

    -- The bottleneck residual layer for 50, 101, and 152 layer networks
    local function bottleneck(n, stride)
      local nInputPlane = iChannels
      iChannels = n * 4

      local s = nn.Sequential()
      s:add(Convolution(nInputPlane,n,1,1,1,1,0,0))
      s:add(SBatchNorm(n))
      s:add(ReLU(true))
      s:add(Convolution(n,n,3,3,stride,stride,1,1))
      s:add(SBatchNorm(n))
      s:add(ReLU(true))
      s:add(Convolution(n,n*4,1,1,1,1,0,0))
      s:add(SBatchNorm(n * 4))

      return nn.Sequential()
      :add(nn.ConcatTable()
      :add(s)
      :add(shortcut(nInputPlane, n * 4, stride)))
      :add(nn.CAddTable(true))
      :add(ReLU(true))
    end

    -- Creates count residual blocks with specified number of features
    local function layer(block, features, count, stride)
      local s = nn.Sequential()
      for i=1,count do
        s:add(block(features, i == 1 and stride or 1))
      end
      return s
    end

    local model = nn.Sequential()
    local input
    if opt.dataset == 'imagenet' then
      -- Configurations for ResNet:
      --  num. residual blocks, num features, residual block function
      local cfg = {
        [18]  = {{2, 2, 2, 2}, 512, basicblock},
        [34]  = {{3, 4, 6, 3}, 512, basicblock},
        [50]  = {{3, 4, 6, 3}, 2048, bottleneck},
        [101] = {{3, 4, 23, 3}, 2048, bottleneck},
        [152] = {{3, 8, 36, 3}, 2048, bottleneck},
      }

      assert(cfg[depth], 'Invalid depth: ' .. tostring(depth))
      local def, nFeatures, block = table.unpack(cfg[depth])
      iChannels = 64
      --print(' | ResNet-' .. depth .. ' ImageNet')

      -- The ResNet ImageNet model
      model:add(Convolution(3,64,7,7,2,2,3,3))
      model:add(SBatchNorm(64))
      model:add(ReLU(true))
      model:add(Max(3,3,2,2,1,1))
      model:add(layer(block, 64, def[1]))
      model:add(layer(block, 128, def[2], 2))
      model:add(layer(block, 256, def[3], 2))
      model:add(layer(block, 512, def[4], 2))
      model:add(Avg(7, 7, 1, 1))
      model:add(nn.View(nFeatures):setNumInputDims(3))
      model:add(nn.Linear(nFeatures, 1000))

      input = torch.rand(1,3,224,224)
    elseif opt.dataset == 'cifar10' then
      -- Model type specifies number of layers for CIFAR-10 model
      assert((depth - 2) % 6 == 0, 'depth should be one of 20, 32, 44, 56, 110, 1202')
      local n = (depth - 2) / 6
      iChannels = 16
      --print(' | ResNet-' .. depth .. ' CIFAR-10')

      -- The ResNet CIFAR-10 model
      model:add(Convolution(3,16,3,3,1,1,1,1))
      model:add(SBatchNorm(16))
      model:add(ReLU(true))
      model:add(layer(basicblock, 16, n))
      model:add(layer(basicblock, 32, n, 2))
      model:add(layer(basicblock, 64, n, 2))
      model:add(Avg(8, 8, 1, 1))
      model:add(nn.View(64):setNumInputDims(3))
      model:add(nn.Linear(64, 10))
      input = torch.rand(1,3,32,32)
    else
      error('invalid dataset: ' .. opt.dataset)
    end

    local function ConvInit(name)
      for k,v in pairs(model:findModules(name)) do
        local n = v.kW*v.kH*v.nOutputPlane
        v.weight:normal(0,math.sqrt(2/n))
        if false and cudnn.version >= 4000 then
          v.bias = nil
          v.gradBias = nil
        else
          v.bias:zero()
        end
      end
    end
    local function BNInit(name)
      for k,v in pairs(model:findModules(name)) do
        v.weight:fill(1)
        v.bias:zero()
      end
    end

    ConvInit('cudnn.SpatialConvolution')
    ConvInit('nn.SpatialConvolution')
    BNInit('fbnn.SpatialBatchNormalization')
    BNInit('cudnn.SpatialBatchNormalization')
    BNInit('nn.SpatialBatchNormalization')
    for k,v in pairs(model:findModules('nn.Linear')) do
      v.bias:zero()
    end
    --model:cuda()

    if opt.cudnn == 'deterministic' then
      model:apply(function(m)
        if m.setMode then m:setMode(1,1,1) end
      end)
    end

    --model:get(1).gradInput = nil
    --print(model)
    return model, input
  end

  return createModel(opt)
end

local function genericTestForward(model,opts)
  local net, input = models[model](opts)
  net:evaluate()
  local out_orig = net:forward(input):clone()

  local mem1 = usedMemory(net,input)

  optimizeMemory(net, input)

  local out = net:forward(input):clone()
  local mem2 = usedMemory(net,input)
  tester:eq(out_orig, out, 'Outputs differ after optimization of '..model)
  tester:assertle(mem2, mem1, 'Optimized model uses more memory! '..
  'Before: '.. mem1..' bytes, After: '..mem2..' bytes')
  print(mem1,mem2)
end

function optest.basic()
  genericTestForward('basic1')
end

function optest.basic_conv()
  genericTestForward('basic2')
end

function optest.alexnet()
  genericTestForward('alexnet')
end

function optest.resnet20()
  local opts = {dataset='cifar10',depth=20}
  genericTestForward('resnet', opts)
end

function optest.resnet32()
  local opts = {dataset='cifar10',depth=32}
  genericTestForward('resnet', opts)
end

function optest.resnet56()
  local opts = {dataset='cifar10',depth=56}
  genericTestForward('resnet', opts)
end

tester:add(optest)
tester:run()

