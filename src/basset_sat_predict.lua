#!/usr/bin/env th

require 'hdf5'

require 'convnet_io'
require 'postprocess'

----------------------------------------------------------------
-- parse arguments
----------------------------------------------------------------
cmd = torch.CmdLine()
cmd:text()
cmd:text('DNA ConvNet hidden layer visualizations')
cmd:text()
cmd:text('Arguments')
cmd:argument('model_file')
cmd:argument('data_file')
cmd:argument('out_file')
cmd:text()
cmd:text('Options:')
cmd:option('-batch_size', 300, 'Maximum batch size')
cmd:option('-center_nt', 0, 'Mutate only the center nucleotides')
cmd:option('-cuda', false, 'Run on GPGPU')
cmd:option('-pre_sigmoid', false, 'Measure changes pre-sigmoid')
cmd:option('-raw_prob', false, 'Measure raw probabilities')
opt = cmd:parse(arg)

-- fix seed
torch.manualSeed(1)

cuda = opt.cuda
require 'convnet'

----------------------------------------------------------------
-- load data
----------------------------------------------------------------
local convnet_params = torch.load(opt.model_file)
local convnet = ConvNet:__init()
convnet:load(convnet_params)
convnet:decuda()

-- open HDF5 and get test sequences
local data_open = hdf5.open(opt.data_file, 'r')
local test_seqs = data_open:read('test_in')

local num_seqs = test_seqs:dataspaceSize()[1]
local seq_len = test_seqs:dataspaceSize()[4]
local nts = {'A','C','G','T'}

-- final layer index
local fl = #convnet.model.modules - 1

----------------------------------------------------------------
-- predict
----------------------------------------------------------------
-- predict seqs
convnet.model:evaluate()
local preds, prepreds = convnet:predict(test_seqs, opt.batch_size)
local num_targets = (#preds)[2]

-- normalize predictions
local preds_means
if convnet.target_type == "binary" and not opt.raw_prob then
    preds_means = preds:mean(1):squeeze()
    preds = troy_norm(preds, preds_means)
end

-- compute pre-sigmoid distribution stats
local prepreds_means = prepreds:mean(1):squeeze()
local prepreds_stds = prepreds:std(1):squeeze()

-- determine where modifications should begin and end
local delta_len = seq_len
local delta_start = 1
if opt.center_nt > 0 then
	delta_len = math.min(delta_len, opt.center_nt)
	delta_start = 1 + torch.floor((seq_len - delta_len)/2)
end
local delta_end = delta_start + delta_len - 1
local num_mods = 3*delta_len

-- initialize a data structure for modified predictions
local seq_mod_preds = torch.DoubleTensor(num_seqs, 4, delta_len, num_targets)

-- pre-allocate a Tensor of modified sequnces
local seq_mods = torch.Tensor(num_mods, 4, 1, seq_len)

for si=1,num_seqs do
    print(string.format("Predicting sequence %d variants", si))

    local seq_1hot = test_seqs:partial({si,si},{1,4},{1,1},{1,seq_len})
    seq_1hot = seq_1hot:reshape(4, 1, seq_len)

	-- construct a batch of modified sequecnes
	local mi = 1
	for pos=delta_start,delta_end do
		for ni=1,4 do
			if nts[ni] ~= get_1hot(seq_1hot, pos) then
				-- copy the seq's one hot coding
				seq_mods[mi] = seq_1hot:clone()

				-- change the nt
				set_1hot(seq_mods[mi], pos, nts[ni])

				-- increment on to next mod
				mi = mi + 1
			end
		end
	end

	-- predict modified sequences
	local mod_preds, mod_prepreds = convnet:predict(seq_mods, opt.batch_size, true)

    -- normalize predictions
    if convnet.target_type == "binary" and not opt.raw_prob then
        mod_preds = troy_norm(mod_preds, preds_means)
    end

	-- copy into the full matrix
	mi = 1
	for pos=delta_start,delta_end do
		local pi = 1 + pos - delta_start
		local seq_nt = get_1hot(seq_1hot, pos)

		for ni=1,4 do
			if nts[ni] == seq_nt then
				for ti=1,num_targets do
                    if opt.pre_sigmoid then
                        seq_mod_preds[{si,ni,pi,ti}] = (prepreds[{si,ti}] - prepreds_means[ti]) / prepreds_stds[ti]
                    else
                        seq_mod_preds[{si,ni,pi,ti}] = preds[{si,ti}]
                    end
				end
			else
				for ti=1,num_targets do
					if opt.pre_sigmoid then
                        seq_mod_preds[{si,ni,pi,ti}] = (mod_prepreds[{mi,ti}] - prepreds_means[ti]) / prepreds_stds[ti]
                    else
                        seq_mod_preds[{si,ni,pi,ti}] = mod_preds[{mi,ti}]
                    end
				end
				mi = mi + 1
			end
		end
	end

end

----------------------------------------------------------------
-- dump to file, load into python
----------------------------------------------------------------
local hdf_out = hdf5.open(opt.out_file, 'w')
hdf_out:write("seq_mod_preds", seq_mod_preds)
hdf_out:close()
