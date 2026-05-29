{{ config(materialized='view') }}

with realtime as (
    select * from {{ ref('stg_vta_realtime') }}
),

trips as (
    select distinct trip_id, shape_id, direction_id 
    from {{ source('vta_raw', 'raw_gtfs_static_trips') }}
),

routes as (
    select * from {{ ref('stg_vta_routes') }}
),

joined as (
    select
        r.*,
        t.shape_id,
        t.direction_id,
        rt.route_short_name,
        rt.route_long_name,
        avg(r.vehicle_speed_mps) over(partition by r.route_id) as route_avg_speed_mps,
        stddev(r.vehicle_speed_mps) over(partition by r.route_id) as route_stddev_speed
    from realtime r
    left join trips t on r.trip_id = t.trip_id
    left join routes rt on r.route_id = rt.route_id -- ◄─── FIX: Join routes to get names!
),

metrics as (
    select
        *,
        case 
            when route_stddev_speed = 0 then 0
            else (vehicle_speed_mps - route_avg_speed_mps) / route_stddev_speed
        end as speed_z_score
    from joined
)

select
    *,
    case 
        when vehicle_speed_mps <= 2.2 and speed_z_score < -1.5 then true
        else false
    end as is_congestion_bottleneck
from metrics