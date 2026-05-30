-- models/marts/fct_pipeline_health.sql
{{ config(materialized='table') }}

with realtime as (
    select
        ping_timestamp as ping_timestamp_utc,  
        vehicle_id,
        trip_id,
        route_id,
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

per_minute as (
    select
        date_trunc('minute', ping_timestamp_utc) as ingestion_minute,
        count(*)                                 as records_ingested,
        count(distinct vehicle_id)               as active_reporting_vehicles,
        max(ping_timestamp_utc)                  as latest_ping_in_minute
    from realtime
    group by 1
)

select
    ingestion_minute,
    records_ingested,
    active_reporting_vehicles,

    -- Store the latest raw ping time so Grafana can compute freshness live
    -- against its own now(). Do NOT bake in now() here — this is a TABLE
    -- materialisation, so any now() is frozen at dbt run time and will be
    -- stale seconds after the run completes.
    latest_ping_in_minute,

    -- Gap between consecutive ingestion minutes (NULL on first row).
    -- Useful for detecting pipeline gaps without a live now() dependency.
    round(extract(epoch from (
        ingestion_minute - lag(ingestion_minute) over (order by ingestion_minute)
    )))::int as seconds_since_last_ingest,

    -- Flag minutes where a dbt run was expected (cron: 5 * * * *)
    case
        when extract(minute from ingestion_minute) = 5 then true
        else false
    end as dbt_run_expected

from per_minute
order by ingestion_minute