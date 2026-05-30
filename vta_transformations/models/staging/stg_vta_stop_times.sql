-- models/staging/stg_vta_stop_times.sql
{{ config(materialized='view') }}

with source as (
    select * from {{ source('vta_raw', 'raw_gtfs_static_stop_times') }}
),

cleaned as (
    select
        cast(trip_id as varchar) as trip_id,
        cast(stop_id as varchar) as stop_id,
        cast(stop_sequence as integer) as stop_sequence,
        cast(arrival_time as interval) as scheduled_arrival_time,
        cast(departure_time as interval) as scheduled_departure_time
    from source
)

select * from cleaned