% Optimize resource price
% * *TODO* Resource Cost Model: linear, convex (quatratic)
% DATE: 2017-04-23
%% Display option
% iter-final.
function [output, runtime] = optimizeResourcePriceNew(this, init_price, options)
if nargin <= 2
    options.Display = 'final';
end
options.PricingPolicy = 'quadratic-price';
if ~isfield(options, 'Threshold') || isempty(options.Threshold)
    options.Threshold = 'average';
end
% options.Threshold = '';
switch options.Threshold
    case {'min', 'average', 'max'}
        b_profit_ratio = true;
    otherwise
        b_profit_ratio = false;
end
global DEBUG; %#ok<NUSED>
% this.clearStates;
if nargout == 2
    slice_runtime = 0;
    runtime.Serial = 0;
    runtime.Parallel = 0;
    options.CountTime = true;
else
    options.CountTime = false;
end

% network data
NC = this.NumberDataCenters;
NS = this.NumberSlices;
NL = this.NumberLinks;
node_capacity = this.getDataCenterField('Capacity');
link_capacity = this.getLinkField('Capacity');
link_uc = this.getLinkField('UnitCost');
node_uc = this.getDataCenterField('UnitCost');
% link_uc = this.getLinkField('UnitCost') + this.phis_l;
% node_uc = this.getDataCenterField('UnitCost') + this.phis_n;

%% Social-welfare aware price adjustment
% Initial Price
t1 = 1;           % {0.1|0.8|1}
if nargin >=2 && ~isempty(init_price)
    link_price = t1 * init_price.link;
    node_price = t1 * init_price.node;
else
    init_price.link = t1* link_uc;
    link_price = init_price.link;
    init_price.node = t1* node_uc;
    node_price = init_price.node;
end
t0 = 10^-1;     % {1|0.1|0.01}
delta_link_price = t0 * link_uc;  % init_price.link
delta_node_price = t0 * node_uc;

number_iter = 1;
sp_profit = -inf;
link_price_prev = [link_price, link_price];
node_price_prev = [node_price, node_price];
if b_profit_ratio
    b_forced_break = false;
end
while true
    SolveSCP(node_price, link_price);
    sp_profit_new = this.getSliceProviderProfit(node_price, link_price, ...
        options.PricingPolicy);
    %% Stop condtion 
    % if the profit of SP is non-increasing, or the profit ratio reaches the predefined
    % threshold, then no need to further increase the resource prices.
    if sp_profit >= sp_profit_new
        break;
    else
        sp_profit = sp_profit_new;
    end
    if b_profit_ratio && this.checkProfitRatio(node_price, link_price, options)
        b_forced_break = true;
        break;
    end
    [node_load, link_load] = this.getNetworkLoad;
    %%%
    % Adjust the step according to how much the capacity constraints have been violated.
    % If the resource is over provisioned, the multiplier is larger than 2.
    % Resources with high utilization ratio are likely to be bottleneck. Therefore
    % the increase amount of those resources is larger. Thus we let the increase amount
    % associated with the utilization ratio.  
    %
    % If the capacity tends to infinity, |delta_link_price| and |delta_node_price| stay
    % the same, while |link_price| and |node_price| still increases in a constant rate.
    delta_link_price = delta_link_price.*(1+min(1,link_load./link_capacity));
    delta_node_price = delta_node_price.*(1+min(1,node_load./node_capacity));
    %%%
    % we only increase the price of those resources that are utilized (resource
    % utilization ��>0), since increasing the price of idle resources will not increase the
    % profit of SP.   
    node_id = node_load>0;
    link_id = link_load>0;
    link_price(link_id) = link_price(link_id) + delta_link_price(link_id);
    node_price(node_id) = node_price(node_id) + delta_node_price(node_id);
    link_price_prev(:,1) = link_price_prev(:,2);
    link_price_prev(:,2) = link_price;
    node_price_prev(:,1) = node_price_prev(:,2);
    node_price_prev(:,2) = node_price;
    number_iter = number_iter + 1;
end
%%
% If the last step is not stopped by the profit ratio, we need to further search the
% optimal price.
if ~b_profit_ratio || ~b_forced_break
    link_price_prev(:,2) = link_price;
    node_price_prev(:,2) = node_price;
    sp_profit_new = [1 0];
    epsilon = 10^-3;
    while true  %|| (h-l) > 0.05
        number_iter = number_iter + 1;
        node_price_middle = [(2/3)*node_price_prev(:,1)+(1/3)*node_price_prev(:,2), ...
            (1/3)*node_price_prev(:,1)+(2/3)*node_price_prev(:,2)];
        link_price_middle = [(2/3)*link_price_prev(:,1)+(1/3)*link_price_prev(:,2), ...
            (1/3)*link_price_prev(:,1)+(2/3)*link_price_prev(:,2)];
        for i = 1:2
            SolveSCP(node_price_middle(:,i), link_price_middle(:,i));
            sp_profit_new(i) = this.getSliceProviderProfit(node_price_middle(:,i), ...
                link_price_middle(:,i), options.PricingPolicy);
        end
        if sp_profit_new(1) > sp_profit_new(2)
            node_price_prev(:,2) = node_price_middle(:,2);
            link_price_prev(:,2) = link_price_middle(:,2);
        else
            node_price_prev(:,1) = node_price_middle(:,1);
            link_price_prev(:,1) = link_price_middle(:,1);
        end
        %%%
        % the stop condition can also be set as the difference of price.
        if abs((max(sp_profit_new)-sp_profit)/sp_profit) < epsilon
            break;
        else
            sp_profit = max(sp_profit_new);
        end
    end
    node_price = node_price_prev(:,1);       % temp_node_price
    link_price = link_price_prev(:,1);       % temp_link_price
end
%%
% |delta_link_price| and |delta_node_price| of the first step can still be used, to
% improve the convergence rate. Alternatively, one can reset the two vectors as follows
%
%    delta_link_price = t0 * link_uc;         % init_price.link
%    delta_node_price = t0 * node_uc;
k = 1;
while true
    %%% Compute the new resource price according to the resource consumption
    [node_load, link_load] = this.getNetworkLoad;
    b_link_violate = (link_capacity-link_load) < 1;
    b_node_violate = (node_capacity-node_load) < 1;
    if isempty(find(b_link_violate==1,1)) && isempty(find(b_node_violate==1,1))
        break;
    end
    link_price(b_link_violate)  = link_price(b_link_violate) + delta_link_price(b_link_violate);
    delta_link_price(b_link_violate) = delta_link_price(b_link_violate) .* ...
        (link_load(b_link_violate)./link_capacity(b_link_violate));     % {2|(k+1)/k}
    node_price(b_node_violate) = node_price(b_node_violate) + delta_node_price(b_node_violate);
    delta_node_price(b_node_violate) = delta_node_price(b_node_violate) .* ...
        (node_load(b_node_violate)./node_capacity(b_node_violate));     % {2|(k+1)/k}
    % Slices solve P1 with $��_k$, return the node (link) load v(y);
    % announce the resource price and optimize each network slice
    number_iter = number_iter + 1;
    SolveSCP(node_price, link_price);
    k = k+1;
end
if strncmp(options.Display, 'notify', 6)
    fprintf('\tFirst stage objective value: %d.\n', new_net_welfare);
end

if k>1
    delta_link_price = t0 * link_price;  % 0.01 * init_price.link
    delta_node_price = t0 * node_price;
    min_delta_link_price = delta_link_price;
    min_delta_node_price = delta_node_price;
    d0 = 10^-1;
    d1 = 10^-0;
    stop_cond1 = ~isempty(find(delta_link_price > d0 * link_uc, 1));
    stop_cond2 = ~isempty(find(delta_node_price > d0 * node_uc, 1));
    if b_profit_ratio
        stop_cond3 = this.checkProfitRatio(node_price, link_price, options);
    else
        sp_profit = this.getSliceProviderProfit(node_price, link_price, options.PricingPolicy);
        stop_cond3 = true;
    end
    partial_link_violate = false(NL, 1);
    partial_node_violate = false(NC, 1);
    b_first = true;
    while stop_cond1 && stop_cond2 && stop_cond3
        number_iter = number_iter + 1;
        if strncmp(options.Display, 'iter', 4)
            disp('----link price    delta link price----')
            disp([link_price delta_link_price]);
        end
        b_link = link_price > delta_link_price;
        link_price(b_link) = link_price(b_link) - delta_link_price(b_link);
        if strncmp(options.Display, 'iter', 4)
            disp('----node price    delta node price----')
            disp([node_price delta_node_price]);
        end
        b_node = node_price > delta_node_price;
        node_price(b_node) = node_price(b_node) - delta_node_price(b_node);
        SolveSCP(node_price, link_price);
        [node_load, link_load] = this.getNetworkLoad;
        
        if b_profit_ratio
            % the profit ratio of SP should not less than the predefined threshold.
            stop_cond3 = this.checkProfitRatio(node_price, link_price, options);
        else
            % we decrease the price, the profit of SP should increase.
            sp_profit_new = this.getSliceProviderProfit(node_price, link_price, ...
                options.PricingPolicy);
            stop_cond3 = sp_profit_new >= sp_profit;
        end
        b_link_violate = (link_capacity - link_load)<0;
        b_node_violate = (node_capacity - node_load)<0;
        assert_link_1 = isempty(find(b_link_violate==1,1));			% no violate link
        assert_node_1 = isempty(find(b_node_violate==1,1));			% no violate node
        if assert_link_1 && assert_node_1 && stop_cond3
            if b_first
                delta_link_price = delta_link_price * 2;
                delta_node_price = delta_node_price * 2;
            else
                delta_link_price = delta_link_price + min_delta_link_price;
                delta_node_price = delta_node_price + min_delta_node_price;
            end
            partial_link_violate = false(NL, 1);
            partial_node_violate = false(NC, 1);
        else
            b_first = false;
            link_price(b_link) = link_price(b_link) + delta_link_price(b_link);
            node_price(b_node) = node_price(b_node) + delta_node_price(b_node);
            if ~stop_cond3 && assert_link_1 && assert_node_1
                SolveSCP(node_price, link_price);
                break;
            end
            %%%
            %  If $\Delta_\rho$ has been smaller than the initial step, then only those
            %  resources with residual capacity will continue reduce their price, i.e. the
            %  components of step $\Delta_\rho$ corresponding to those overloaded
            %  resources is set to 0.   
            assert_link_2 = isempty(find(delta_link_price > d1 * link_uc, 1));		% the vector is less than a threshold
            assert_node_2 = isempty(find(delta_node_price > d1 * node_uc, 1));		% the vector is less than a threshold
            if assert_link_2
                partial_link_violate = partial_link_violate | b_link_violate;
                delta_link_price(partial_link_violate) = 0;
            else
                partial_link_violate = false(NL, 1);
            end
            delta_link_price = delta_link_price / 2;
            min_delta_link_price = min(delta_link_price/4, min_delta_link_price);
            if assert_node_2
                partial_node_violate = partial_node_violate | b_node_violate;
                delta_node_price(partial_node_violate) = 0;
            else
                partial_node_violate = false(NC, 1);
            end
            delta_node_price = delta_node_price / 2;
            min_delta_node_price = min(delta_node_price/4, min_delta_node_price);
        end
        %     stop_cond1 = norm(delta_link_price) > norm(10^-4 * link_uc);
        %     stop_cond2 = norm(delta_node_price) > norm(10^-4 * node_uc);
        stop_cond1 = ~isempty(find(delta_link_price > d0 * link_uc, 1));
        stop_cond2 = ~isempty(find(delta_node_price > d0 * node_uc, 1));
    end
end

%% Finalize substrate network
% # The resource allocation variables, virtual node/link load, and flow rate of each
% slice.
% # After the optimization, each network slice has record the final prices.
% # Record the substrate network's node/link load, price.
this.finalize(node_price, link_price);

% Calculate the output
output = this.calculateOutput([], options);

% output the optimization results
if strncmp(options.Display, 'notify', 6) || strncmp(options.Display, 'final', 5)
    fprintf('Optimization results:\n');
    fprintf('\tThe optimization procedure contains %d iterations.\n', number_iter);
    fprintf('\tOptimal objective value: %d.\n', output_optimal.welfare_accurate);
    fprintf('\tNormalized network utilization is %G.\n', this.utilizationRatio);
end

%%
    function SolveSCP(node_price_t, link_price_t)
        for s = 1:NS
            sl = this.slices{s};
            options.LinkPrice = link_price_t(sl.VirtualLinks.PhysicalLink);
            % |node_price| only contain the price of data center nodes.
            dc_id = sl.getDCPI;
            options.NodePrice = node_price_t(dc_id);  
            if options.CountTime
                tic;
            end
            this.slices{s}.priceOptimalFlowRate([], options);
            if options.CountTime
                t = toc;
                slice_runtime = max(slice_runtime, t);
                runtime.Serial = runtime.Serial + t;
            end
        end
        if options.CountTime
            runtime.Parallel = runtime.Parallel + slice_runtime;
        end
    end
end