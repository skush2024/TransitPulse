-- models/intermediate/int_vta_congestion_analysis.sql
{{ config(materialized='view') }}

with realtime as (
    select
        ping_timestamp as local_ping_timestamp,
        trip_id,
        route_id,
        vehicle_id,
        vehicle_lat,
        vehicle_lon,
        vehicle_bearing,
        vehicle_speed_mps,
        current_stop_sequence
    from {{ ref('stg_vta_realtime') }}
    where trip_id is not null
    and trip_id != ''
    and route_id is not null
    and current_stop_sequence is not null
),

trips as (
    select distinct trip_id, shape_id, direction_id
    from {{ source('vta_raw', 'raw_gtfs_static_trips') }}
    where trip_id != ''
    and trip_id is not null
    and shape_id is not null
),

routes as (
    select * from {{ ref('stg_vta_routes') }}
    where route_id != '' and route_id is not null
),

joined as (
    select
        r.*,
        t.shape_id,
        t.direction_id,
        rt.route_short_name,
        rt.route_long_name,

        avg(r.vehicle_speed_mps) over(
            partition by r.route_id, t.direction_id, r.current_stop_sequence
        ) as segment_avg_speed_mps,

        stddev(r.vehicle_speed_mps) over(
            partition by r.route_id, t.direction_id, r.current_stop_sequence
        ) as segment_stddev_speed

    from realtime r
    left join trips t on r.trip_id = t.trip_id
    left join routes rt on r.route_id = rt.route_id
),

metrics as (
    select
        *,
        case
            when segment_stddev_speed = 0 or segment_stddev_speed is null then 0
            else (vehicle_speed_mps - segment_avg_speed_mps) / segment_stddev_speed
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