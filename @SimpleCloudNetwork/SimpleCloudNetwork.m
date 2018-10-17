%% Cloud Network
% Enable network resource allocation, by mechanisms such as pricing.
%
% In the network, forwarding nodes only take charge of packet processing. Forwarding nodes
% may connect to Data Center, and then VNF instances can be created in data center. The
% connection between forwarding nodes and data centers are assumed with infinity bandwidth
% and zero latency.
%
% The topology of CloudNetwork is predefined.
%%
classdef SimpleCloudNetwork < PhysicalNetwork
	
	properties (Dependent)
		NumberPaths;         % Number of candidate paths of all slices
	end
	methods
		%%
		% * *options*:
		%       _PricingFactor_ is used for <singleSliceOptimization> and <staticSlicing>.
		%       _Threshold_ is used for resource pricing.
		%       _Method_ is used for selecting method to solve sub-problem.
		%
		% NOTE: only put common options ('SlicingMethod', 'Form', etc.)in the constructor. Put
		% those method-specific options to the correspongding method.
		function this = SimpleCloudNetwork(varargin)
			this@PhysicalNetwork(varargin{:});
			this.Topology.Edges{:,'Price'} = 0;
			this.DataCenters{:,'Price'} = 0;
			

			if nargin >= 4
				new_opts = varargin{4};
			else
				new_opts = struct;
			end
			this.options = structmerge(...
				getstructfields(new_opts, ...
				{'SlicingMethod', 'Form', 'ConstraintTolerance', ...
				'NonzeroTolerance', 'Threshold', 'PostProcessing'}, ...
				'default',...
				{SlicingMethod.AdjustPricing, 'compact', 10^-3, 10^-3, 'min', 'round'}),...
				getstructfields(new_opts, 'PricingPolicy', 'ignore'));
			if this.options.SlicingMethod.IsFactorPricing
					% specified for _pricingFactorAjustment_ and .....
					% the pricing factor can be specified by <CloudNetwork.SetOptions>.
					this.options = structmerge(this.options, ...
						getstructfields(new_opts, 'PricingFactor'));
			end
			if this.options.SlicingMethod == SlicingMethod.StaticPricing
				this.options = structmerge(this.options, ...
					getstructfields(new_opts, 'AdmitPolicy'));
			end
		end
	end
	
	methods 
		function n = get.NumberPaths(this)
			n = 0;
			for i = 1:this.NumberSlices
				n = n + this.slices{i}.NumberPaths;
			end
		end
	end
	
	methods
		function sl = AddSlice(this, slice_opt, varargin)
			slice_opt = this.preAddingSlice(slice_opt);
			sl = AddSlice@PhysicalNetwork(this, slice_opt, varargin);
		end
		
		function V = totalNodeCapacity(this)
			V = sum(this.readDataCenter('Capacity'));
		end
		
		function C = totalLinkCapacity(this)
			C = sum(this.readLink('Capacity'));
		end
		
		function [r_mean, r_max, r_min, r_std] = nodeUtilization(this)
			node_load = this.readDataCenter('Load');
			node_capacity = this.readDataCenter('Capacity');
			% 			node_index = node_load > 1;
			%%%
			% Another method: ratio = sum(node_load)/sum(node_capacity);
			ratio = node_load ./ node_capacity;
			r_mean = mean(ratio);
			%%%
			% The range of node utilization may large, since the load of nodes depends on
			% the flow's location, the node's cost, and our objective is not to balancing
			% the node load.
			if nargout >= 2
				r_max = max(ratio);
			end
			if nargout >= 3
				r_min = min(ratio);
			end
			if nargout >= 4
				r_std = std(ratio);
			end
		end
		
		function [r_mean, r_max, r_min, r_std] = linkUtilization(this)
			link_load = this.readLink('Load');
			link_capacity = this.readLink('Capacity');
			% link_index = link_load > 1;
			ratio = link_load ./ link_capacity;
			r_mean = mean(ratio);
			if nargout >= 2
				r_max = max(ratio);
			end
			if nargout >= 3
				r_min = min(ratio);
			end
			if nargout >= 4
				r_std = std(ratio);
			end
		end
		
		%%% compute the total link cost.
		function c = getTotalLinkCost(this, link_load)
			if nargin == 1
				c = dot(this.readLink('Load'), this.getLinkCost);
			else
				c = dot(link_load, this.getLinkCost);
			end
		end
		
		%%% compute the total node cost.
		function c = getTotalNodeCost(this, node_load)
			if nargin == 1
				c = dot(this.DataCenters.Load, this.getNodeCost);
			else
				c = dot(node_load, this.getNodeCost);
			end
		end
		
		%%%
		% * *Network Operation Cost*:
		% There are two methods to calculate network cost,
		%
		% # Calculate with the approximate model, where the static node cost is computed
		% by the approximate formula.
		% # Calculate with the accurate model, where the static node cost is computed by
		% the solution of VNF deployment.
		%
		% When the network only include a single slice, this method equals to
		% _getSliceCost_ .
		%         function c = getNetworkCost(this, node_load, link_load, model)
		function c = getNetworkCost(this, node_load, link_load)
			if nargin <=1 || isempty(node_load)
				node_load = this.readDataCenter('Load');
			end
			if nargin <= 2 || isempty(link_load)
				link_load = this.readLink('Load');
			end
			
			c = this.getTotalNodeCost(node_load) + this.getTotalLinkCost(link_load);
		end
		
		function theta = utilizationRatio(this, node_load, link_load)
			if nargin == 1
				node_load = this.readDataCenter('Load');
				link_load = this.readLink('Load');
			end
			theta_v = sum(node_load)/this.totalNodeCapacity;
			theta_l = sum(link_load)/this.totalLinkCapacity;
			theta = 0.5*(theta_v + theta_l);
		end
		
		%% statistics of the output
		% type_index is a scalar.
		function [p,r] = statSlice(this, type_index, profit)
			s_index = this.findSlice(type_index);
			if isempty(s_index)
				p = [0, 0, 0, 0];
				if nargout >= 2
					r = [0, 0, 0, 0];
				end
			else
				%%%
				% Only the statistics of the admitted slices are counted.
				p = [mean(profit(s_index)), max(profit(s_index)), min(profit(s_index)), ...
					std(profit(s_index))];
				if nargout >= 2
					rate = zeros(this.NumberFlows,1);
					i = 0;
					for s = s_index     % s_index is a row vector
						num_flow = this.slices{s}.NumberFlows;
						rate(i + (1:num_flow)) = this.slices{s}.FlowTable.Rate;
						i = i +num_flow;
					end
					rate = rate(1:i);
					r = [mean(rate), max(rate), min(rate), std(rate)];
				end
			end
		end
		
		%%% compute link cost. Subclass may override this to provide cost.
		function link_uc = getLinkCost(this, link_id)
			if nargin == 1
				link_uc = this.readLink('UnitCost');
			else
				link_uc = this.readLink('UnitCost', link_id);
			end
		end
		
		%%% compute node cost. Subclass may override this to provide cost.
		% * *dc_id*: data center index (not the node index of the substrate physical node).
		function node_uc = getNodeCost(this, dc_id)
			if nargin == 1
				node_uc = this.readDataCenter('UnitCost');
			else
				node_uc = this.readDataCenter('UnitCost', dc_id);
			end
		end
		
		function setOptions(this, opt_name, opt_value)
			if ischar(opt_name)
				opt_name = string(opt_name);
			elseif iscell(opt_name)
			elseif ~isstring(opt_name)
				error('[%s]error: %s', calledby(0), ...
					'''opt_name'' must be specified as character array, string array',...
					'or cell array with characters');
			end
			
			if isnumeric(opt_value)
				opt_value = num2cell(opt_value);
			end
			% string type can be indexed by {} operator, returning char array.
			for i = 1:length(opt_name)
				switch opt_name{i}
					case {'SlicingMethod', 'PricingFactor'}
						this.options.(opt_name{i})= opt_value{i};
				end
			end
		end
	end
	
	methods
		%%%
		% * *getSliceProviderProfit*
		% |slices|: if |slices| is provided, only calsulate the revenue and
		%						cost of the specified |slices|.
		% |prices|: if |prices| are not provided, the stored price are used.
		% |options|: |PricingPolicy| must be specified.
		%
		% Reconfiguration cost does not influence the profit of Slice Provider,
		% see also <optimizeResourcePriceNew>.
		function [profit, revenue] = getSliceProviderProfit(this, slices, prices, options)
			defaultopts = struct(...
				'PricingPolicy', 'quadratic');  % {linear|quadratic}
			if nargin <= 3
				options = defaultopts;
			else
				options = structupdate(defaultopts, options);
			end
			options.Stage = 'temp';			
			
			if nargin <= 1 || isempty(slices)
				slices = this.slices;
			end
			if nargin <= 2 || isempty(prices)
				prices.Node = this.readDataCenter('Price');
				prices.Link = this.readLink('Price');
			end
			load = this.getNetworkLoad(slices, options);
			revenue = 0;
			switch options.PricingPolicy
				case {'quadratic-price', 'quadratic'}
					for s = 1:length(options.Slices)
						sl = options.Slices{s};
						link_id = sl.VirtualLinks.PhysicalLink;
						dc_id = sl.getDCPI;
						% To get the revenue of slice provider, we need to how much
						% resource the slices occupy.
						revenue = revenue + ...
							sl.fcnLinkPricing(prices.Link(link_id), sl.getLinkCapacity(false)) + ...
							sl.fcnNodePricing(price.Node(dc_id), sl.getNodeCapacity(false));
					end
				case 'linear'
					revenue = dot(load.Node, prices.Node) + dot(load.Link, prices.Link);
				otherwise
					error('%s: invalid pricing policy', calledby);
			end
			profit = revenue - this.getNetworkCost(load);
		end
		
		%%%
		% * *Finalize substrate network*
		%
		% # Record the resource allocation variables, flow rate, virtual node/link load of
		%   each slice.
		% # Virtual Nodes/Links' capacity is derived from node/link load;
		% # Calculate and announce the resource prices to each slice.
		% # Record/update the substrate network's node/link load, price.
		%
		% Usually, this function should be provided with 3 arguments, except that it is
		% called by
		% <file:///E:/workspace/MATLAB/Projects/Documents/CloudNetworking/singleSliceOptimization.html singleSliceOptimization>.
		% NOTE: the price here might be only prcing parameters (for varing pricing
		% policy). To calculate the payment, using _fcnLinkPricing_ and _fcnNodePricing_
		% function.
		function finalize(this, prices, slices)
			if nargin <= 3
				slices = this.slices;
			end
			num_slices = length(slices);
			for i = 1:num_slices
				slices{i}.finalize(prices);
			end
			load = this.getNetworkLoad;
			this.writeLink('Load', load.Link);
			this.writeDataCenter('Load', load.Node);
			if nargin >= 3
				% NOTE: prices in the substrate network is updated, while the
				% links/nodes that are not involved in the update procedure, do not
				% change their prices.
				% See also <DynamicCloudNetwork>.<optimizeResourcePriceNew>.
				pre_link_idx = prices.Link==0;
				prices.Link(pre_link_idx) = this.readLink('Price', pre_link_idx);
				this.writeLink('Price', prices.Link);
				pre_node_idx = prices.Link==0;
				prices.Link(pre_node_idx) = this.readDataCenter('Price', pre_node_idx);
				this.writeDataCenter('Price', prices.Link);
			end
		end
		argout = calculateOutput(this, argin, new_opts);
	end
	
	methods (Access=protected)
		function graph = residualgraph(this, slice_opt)
			if slice_opt.SlicingMethod.IsStatic
				% If a link's residual capacity is zero, then this link should be removed
				% from the grpah.
				% If a node's residual capacity is zero, then this node and the adjacent
				% links should be removed from the graph.
				link_capacity = this.readLink('ResidualCapacity');
				node_capacity = this.readDataCenter('ResidualCapacity');
				link_capacity(link_capacity<1) = 0;
				node_capacity(node_capacity<1) = 0;
				A = spalloc(this.NumberNodes, this.NumberNodes, this.NumberLinks);
				C = spalloc(this.NumberNodes, this.NumberNodes, this.NumberLinks);
				for i = 1:this.NumberLinks
					if link_capacity(i) <= 0
						continue;
					end
					h = this.graph.Head(i);
					dc_h = this.Topology.Nodes.DataCenter(h);
					if dc_h && node_capacity(dc_h) <= 0
						continue;
					end
					t = this.graph.Tail(i);
					dc_t = this.Topology.Nodes.DataCenter(t);
					if dc_t && node_capacity(dc_t) <= 0
						continue;
					end
					A(h, t) = this.graph.Adjacent(h, t); %#ok<SPRIX>
					C(h, t) = link_capacity(i); %#ok<SPRIX>
				end
				graph = DirectedGraph(A, C);
			else
				graph = this.graph;
			end
		end
		
		% Implement the abstract function.
		% By default, the options including 'SlicingMethod' and 'AdmitPolicy' is inherited from
		% the network. But slice can use its own options in the configuration file.
		function slice_opt = preAddingSlice(this, slice_opt)
			global DEBUG;
			if ~exist('DEBUG' ,'var')
				DEBUG = false;
			end
			if ~isfield(slice_opt,'Weight') || isempty(slice_opt.Weight) ...
					|| slice_opt.Weight == 0
				error('error: invalid slice weight.'); %     slice_opt.Weight = 1;
			end
			
			slice_opt = structmerge(slice_opt,...
				getstructfields(slice_opt, 'SlicingMethod', 'default', this.options.SlicingMethod));
			%% pricing policy
			% each slice can specify their own pricing, but the network determines whether
			% to adopt this polocy or use the network specified pricing policy.
			% (currently, we assume that network's setting override the slice setting.)
			slice_opt = structmerge(slice_opt,...
				getstructfields(this.options, 'PricingPolicy', 'ignore'));
			
			if this.options.SlicingMethod.IsStatic
				if ~isfield(slice_opt, 'AdmitPolicy') || isempty(slice_opt.AdmitPolicy)
					slice_opt = structmerge(slice_opt, this.options.AdmitPolicy);
				end
			end
		end
		
		function sl = createslice(this, slice_opt, varargin)
			this.slices{end+1} = SimpleSlice(slice_opt);
			sl = this.slices{end};
		end
		%%%
		% Calculate the profit ratio of slices and network.
		% No matter whether all slices are reconfigured, the profit ratio of all slices
		% will be checked to ensure the profit of ratio of network higher than the
		% threshold.
		%
		% |options|: 'PricingPolicy','Epsilon'.
		%
		% NOTE: _checkProfitRatio_ is a stop condition, which is not directly related to
		% the optimization problem.
		function [b, profit_gap] = checkProfitRatio(this, prices, options)
			global DEBUG;
			
			slice_profit_ratio = zeros(this.NumberSlices,1);
			for s = 1:this.NumberSlices
				sl = this.slices{s};
				revenue = sl.getRevenue;        % get utility
				% Prices announced to each slice.
				options.bFinal = sl.isFinal();
				if ~options.bFinal
					sl.prices.Link = prices.Link(sl.VirtualLinks.PhysicalLink);
					sl.prices.Node = prices.Node(sl.getDCPI);
				end
				slice_profit_ratio(s) = sl.getProfit(options)/revenue;
			end
			clear revenue;
			
			[sp_profit, sp_revenue] = this.getSliceProviderProfit([], prices, options);
			network_profit_ratio = sp_profit/sp_revenue;
			% a = 1;        % {0.5|0.75|1}
			switch this.options.Threshold
				case 'min'
					profit_threshold = min(slice_profit_ratio);
				case 'average'
					profit_threshold = mean(slice_profit_ratio);
				case 'max'
					profit_threshold = max(slice_profit_ratio);
				otherwise
					error('error: invalid option (Threshold = %s)', this.options.Threshold);
			end
			if nargin == 4  && isfield(options, 'Epsilon')
				if abs(network_profit_ratio - profit_threshold) < options.Epsilon
					b = true;
				else
					b = false;
				end
			else
				if network_profit_ratio >= profit_threshold
					b = true;
				else
					b = false;
				end
			end
			if nargout == 2
				profit_gap = network_profit_ratio - profit_threshold;
			end
			if ~isempty(DEBUG) && DEBUG
				disp('Profit ratio {slices|network}:'); 
				disp([slice_profit_ratio; network_profit_ratio]);
			end
		end
		
		function info = updateDemandInfo(this, slice_opt)
			switch slice_opt.FlowPattern
				case FlowPattern.RandomInterDataCenter
					info.NumberFlows = this.NumberDataCenters*(this.NumberDataCenters-1);
					if isfield(slice_opt, 'NodeSet')
						info.NodeSet = slice_opt.NodeSet;
					else
						info.NodeSet = this.DataCenters.Node;
					end
					info.NumberNodes = length(info.NodeSet);
				otherwise
					info = updateDemandInfo@PhysicalNetwork(this, slice_opt);
			end
		end
		
		function end_points = generateEndPoints(this, info, slice_opt)
			switch slice_opt.FlowPattern
				case FlowPattern.RandomInterDataCenter
					id = unique_randi(info.NumberNodes, 2, 'stable');
					end_points = info.NodeSet(id);
				otherwise
					end_points = generateEndPoints@PhysicalNetwork(this, info, slice_opt);
			end
		end
		
		function options = updatePathConstraints(this, slice_opt)
			options = this.updatePathConstraints@PhysicalNetwork(slice_opt);
			if this.NumberDataCenters < this.NumberNodes
				% if only part of the forwarding nodes is VNF-capable, we should make sure that the
				% path at least transit one VNF-capable node.
				% no matter when, the DataCenters is the middle nodes. However, if the MiddleNodes
				% option is not provided, the route calculation will be performed in a different way.
				options.MiddleNodes = this.DataCenters.Node;
			end
		end
		
		function allocatepathid(this, slice)
			for j = 1:height(slice.FlowTable)
				path_list = slice.FlowTable.Paths(j).paths;
				for k = 1:length(path_list)
					path_list{k}.id = this.path_identifier_generator.next;
				end
			end
		end
		%% ISSUE: VNFlist is not conmmonly shared.
		function slice_data = updateSliceData(this, slice_data, options)
			defaultopts = struct('SlicingMethod', SlicingMethod.SingleNormal);
			if nargin <= 2
				options = defaultopts;
			else
				options = structupdate(defaultopts, options);
			end
			options.Stage = 'temp';
			if options.SlicingMethod == SlicingMethod.SingleNormal
				if options.bCompact
					b_vnf = false(this.NumberVNFs, 1);
					for s = 1:this.NumberSlices
						b_vnf(this.slices{s}.VNFList) = true;
						if isempty(find(b_vnf==false,1))
							break;
						end
					end
					slice_data.VNFList = find(b_vnf);
				else
					slice_data.VNFList = 1:this.NumberVNFs;
				end
			end
		end
		
		%% This function use intermediate results.
		function output = calculateOptimalOutput(this, ss)
			global DEBUG;
			if ~exist('DEBUG', 'var')
				DEBUG = false;
			end
			
			load = this.getNetworkLoad(ss, struct('Stage', 'temp'));
			output.WelfareOptimal = sum(...
				ss.FlowTable.Weight.*fcnUtility(ss.getFlowRate(ss.temp_vars.x))) ...
				- this.getNetworkCost(load);
			if DEBUG
				cprintf('Comments','Info: [%s] The optimal net social welfare of the network: %G.\n', ...
					calledby, output.WelfareOptimal);
			end
		end
		
		% Now the same as <PhysicalNetwork>, subclasses might override it.
		%         function [flow_table, phy_adjacent, flag] = ...
		%                 generateFlowTable(this, graph, slice_opt)
		%             [flow_table, phy_adjacent, flag] = ...
		%                 this.generateFlowTable@PhysicalNetwork(graph, slice_opt);
		%         end
	end
	
	methods (Access = private)
		[prices, runtime] = pricingFactorAdjustment(this, new_opts);
		function runtime = priceIteration(this, prices, options)
			if nargout == 1
				slice_runtime = 0;
				runtime.Serial = 0;
			end
			for s = 1:this.NumberSlices
				sl = this.slices{s};
				link_id = sl.VirtualLinks.PhysicalLink;
				dc_id = sl.getDCPI;
				sl.prices.Link = prices.Link(link_id);
				sl.prices.Node = prices.Link(dc_id);
				%%%
				% optimize each slice with price and resource constraints.
				if nargout == 1
					tic;
				end
				sl.optimalFlowRate(options);
				if nargout == 1
					t = toc;
					slice_runtime = max(slice_runtime, t);
					runtime.Serial = runtime.Serial + t;
				end
				sl.prices.Link = [];
				sl.prices.Node = [];
			end
			if nargout == 1
				runtime.Parallel = slice_runtime;
			end
		end
	end
	
	methods (Static, Access=protected)
		function flag = assert_path_list(end_points, path_list, slice_opt)
			global DEBUG;
			if ~exist('DEBUG', 'var')
				DEBUG = false;
			end
			
			if isempty(path_list)
				if slice_opt.SlicingMethod.IsStatic
					% two choice: reject the slice or reject the flow.
					if isfield(slice_opt, 'AdmitPolicy') && ...
							strcmp(slice_opt.AdmitPolicy, 'reject-slice')
						message = 'Reject the slice request.';
						flag = 2;
					else
						% slice_opt.AdmitPolicy = 'reject-slice', the actual number
						% of generated flow may less than |number_flow|
						message = sprintf('Reject the flow (%d,%d) in the slice request.',...
							end_points(1), end_points(2));
						flag = 1;
					end
					if DEBUG
						warning(message);
					else
						cprintf('SystemCommands', 'Warning: %s\n', message);
					end
				else
					flag = -1;
				end
			else
				flag = 0;
			end
		end
		
	end
	
	methods
		[output, runtime] = optimizeResourcePrice(this, init_price);
		[output, runtime] = optimizeResourcePriceNew(this, init_price, sub_slices);
		[output, runtime] = singleSliceOptimization(this, new_opts);
		output = StaticSlicing(this, slice);
		[tb, stbs] = saveStatTable(PN, output, rt, slice_types, method);
	end
	
	methods (Static)
		[stat, slice_stat] = createStatTable(num_point, num_type, type);
	end
end