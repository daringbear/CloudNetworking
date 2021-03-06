classdef DispatchEventData < EventData
    %UNTITLED14 Summary of this class goes here
    %   Detailed explanation goes here
    
    properties
        event;          % Class Event
    end
    
    properties(Dependent)
        entity;
        Time;
    end
    
    methods
        function this = DispatchEventData(ev, userdata)
            if nargin <= 1
                userdata = [];
            end
            this@EventData(userdata);
            if nargin >= 1
                this.event = ev;
            end
        end
        function et = get.entity(this)
            et = this.event.Entity;
        end
        function t = get.Time(this)
            t = this.event.Time;
        end
    end
    
end

