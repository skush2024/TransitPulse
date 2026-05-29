{{ config(materialized='view') }}

with source as (
    select * from {{ source('vta_raw', 'raw_gtfs_static_routes') }}
),

cleaned as (
    select
        cast(route_id as varchar) as route_id,
        cast(route_short_name as varchar) as route_short_name,
        cast(route_long_name as varchar) as route_long_name,
        cast(route_type as integer) as route_type
    from source
)

select * from cleaned