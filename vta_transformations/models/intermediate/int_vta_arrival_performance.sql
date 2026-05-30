-- models/intermediate/int_vta_arrival_performance.sql
{{ config(materialized='view') }}

with realtime_localized as (
    select
        trip_id,
        route_id,
        current_stop_sequence as stop_sequence,
        ping_timestamp as ping_timestamp_utc,
        cast((ping_timestamp AT TIME ZONE 'America/Los_Angeles') as date) as service_date
    from {{ ref('stg_vta_realtime') }}
    where trip_id is not null
    and trip_id != ''
    and route_id is not null
    and current_stop_sequence is not null
),

realtime_arrivals as (
    select
        trip_id,
        route_id,
        stop_sequence,
        service_date,
        min(ping_timestamp_utc) as actual_arrival_timestamp
    from realtime_localized
    group by 1, 2, 3, 4
),

schedule as (
    select
        trip_id,
        stop_sequence,
        stop_id,
        scheduled_arrival_time
    from {{ ref('stg_vta_stop_times') }}
    where trip_id is not null
    and stop_sequence is not null
),

joined as (
    select
        r.trip_id,
        r.route_id,
        r.stop_sequence,
        r.service_date,
        r.actual_arrival_timestamp,
        s.stop_id,
        s.scheduled_arrival_time,

        -- FIX: GTFS static times are LA wall-clock values.
        -- Adding a bare interval to a DATE produces TIMESTAMP WITHOUT TIME ZONE,
        -- which Postgres would implicitly cast using the session timezone (UTC on Supabase).
        -- Explicitly tagging the result as America/Los_Angeles converts it to TIMESTAMPTZ
        -- correctly, including DST transitions.
        (r.service_date + s.scheduled_arrival_time::interval)AT TIME ZONE 'America/Los_Angeles'              as scheduled_arrival_timestamp,
        extract(
            epoch from (
                r.actual_arrival_timestamp
                - ((r.service_date + s.scheduled_arrival_time::interval) AT TIME ZONE 'America/Los_Angeles')
            )
        ) / 60.0                                            as delay_minutes

    from realtime_arrivals r
    inner join schedule s
        on  r.trip_id = s.trip_id
        and r.stop_sequence = s.stop_sequence
),

plausible as (
    select *
    from joined
    where delay_minutes between -30 and 120
),

headways as (
    select
        *,
        extract(
            epoch from (
                actual_arrival_timestamp
                - lag(actual_arrival_timestamp) over (
                    partition by route_id, stop_id, service_date
                    order by actual_arrival_timestamp
                )
            )
        ) / 60.0 as actual_headway_minutes
    from plausible
),

stop_delay_iqr as (
    select
        stop_id,
        percentile_cont(0.75) within group (order by delay_minutes)
            - percentile_cont(0.25) within group (order by delay_minutes)
            as stop_delay_iqr
    from headways
    where delay_minutes is not null
    group by stop_id
)

select
    h.trip_id,
    h.route_id,
    h.stop_sequence,
    h.service_date,
    h.actual_arrival_timestamp::timestamptz,
    h.scheduled_arrival_timestamp,
    h.stop_id,
    h.delay_minutes,
    h.actual_headway_minutes,
    coalesce(i.stop_delay_iqr, 0) as stop_delay_iqr
from headways h
left join stop_delay_iqr i on h.stop_id = i.stop_id