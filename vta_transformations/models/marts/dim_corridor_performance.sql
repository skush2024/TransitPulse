{{ config(materialized='table') }}

with congestion as (
    select * from {{ ref('int_vta_congestion_analysis') }}
    where current_stop_sequence > 1
),

static_shapes as (
    select * from {{ source('vta_raw', 'raw_gtfs_static_shapes') }}
),

corridor_summary as (
    select
        route_id,
        route_short_name,
        route_long_name,
        shape_id,
        direction_id, -- It's best practice to explicitly separate Inbound vs Outbound
        
        count(*) as total_tracked_pings,
        
        sum(case when is_congestion_bottleneck = true then 1 else 0 end) as bottleneck_incidents,
        
        -- LOGICAL FIX: Calculate a comparable rate
        round(
            (sum(case when is_congestion_bottleneck = true then 1 else 0 end)::numeric / count(*)) * 100, 
            2
        ) as bottleneck_rate_percentage,
        
        -- LOGICAL FIX: Use median speed to get the true "typical" speed of the corridor
        percentile_cont(0.5) within group (order by vehicle_speed_mps) as median_speed_mps,
        
        -- PRO TIP: Track the 15th percentile speed to see how bad the corridor gets at its worst!
        percentile_cont(0.15) within group (order by vehicle_speed_mps) as worst_case_speed_mps
        
    from congestion
    group by 1, 2, 3, 4,5
)

select
    c.*,
    s.geometry_wkt
from corridor_summary c
join static_shapes s on c.shape_id = s.shape_id