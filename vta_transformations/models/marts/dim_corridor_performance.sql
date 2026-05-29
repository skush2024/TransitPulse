{{ config(materialized='table') }}

with congestion as (
    select * from {{ ref('int_vta_congestion_analysis') }}
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
        count(*) as total_tracked_pings,
        sum(case when is_congestion_bottleneck = true then 1 else 0 end) as bottleneck_incidents,
        avg(vehicle_speed_mps) as average_speed_mps
    from congestion
    group by 1, 2, 3, 4
)

select
    c.*,
    s.geometry_wkt
from corridor_summary c
join static_shapes s on c.shape_id = s.shape_id