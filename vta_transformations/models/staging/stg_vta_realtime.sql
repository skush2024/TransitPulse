{{ config(materialized='view') }}

with source as (
    select * from {{ source('vta_raw', 'raw_gtfs_realtime_pings') }}
),

cleaned as (
    select
        cast(timestamp as timestamp) as ping_timestamp,
        cast(vehicle_id as varchar) as vehicle_id,
        cast(trip_id as varchar) as trip_id,
        cast(route_id as varchar) as route_id,
        cast(latitude as numeric) as vehicle_lat,
        cast(longitude as numeric) as vehicle_lon,
        cast(bearing as numeric) as vehicle_bearing,
        cast(speed as numeric) as vehicle_speed_mps, -- speed in meters per second
        cast(current_stop_sequence as integer) as current_stop_sequence
    from source
)

select * from cleaned