{{ config(materialized='view') }}

with realtime_localized as (
    select
        trip_id,
        route_id,
        current_stop_sequence as stop_sequence,
        -- Convert UTC ping to Local Transit Time (Pacific Time)
        (ping_timestamp at time zone 'UTC' at time zone 'America/Los_Angeles') as local_ping_timestamp,
        -- Safely extract the calendar service date
        cast(ping_timestamp at time zone 'UTC' at time zone 'America/Los_Angeles' as date) as service_date
    from {{ ref('stg_vta_realtime') }}
    where trip_id is not null
      and route_id is not null
      and current_stop_sequence is not null
),

realtime_arrivals as (
    select
        trip_id,
        route_id,
        stop_sequence,
        service_date,
        min(local_ping_timestamp) as actual_arrival_timestamp
    from realtime_localized
    -- Grouping by service_date isolates today's run from yesterday's run
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

        -- Construct a real timestamp by adding the GTFS scheduled interval to the start of the service date day
        (cast(r.service_date as timestamp) + s.scheduled_arrival_time) as scheduled_arrival_timestamp,

        -- Standard epoch subtraction between two full timestamps (avoids midnight wrap-arounds)
        extract(
            epoch from (r.actual_arrival_timestamp - (cast(r.service_date as timestamp) + s.scheduled_arrival_time))
        ) / 60.0 as delay_minutes

    from realtime_arrivals r
    inner join schedule s
        on r.trip_id = s.trip_id
        and r.stop_sequence = s.stop_sequence
),

headways as (
    select
        *,
        extract(
            epoch from (
                actual_arrival_timestamp - lag(actual_arrival_timestamp) over (
                    partition by route_id, stop_id, service_date
                    order by actual_arrival_timestamp
                )
            )
        ) / 60.0 as actual_headway_minutes
    from joined
),

stop_delay_iqr as (
    select
        stop_id,
        percentile_cont(0.75) within group (order by delay_minutes) as delay_p75,
        percentile_cont(0.25) within group (order by delay_minutes) as delay_p25,
        (percentile_cont(0.75) within group (order by delay_minutes) - percentile_cont(0.25) within group (order by delay_minutes)) as stop_delay_iqr
    from headways
    where delay_minutes is not null
    group by stop_id
)

select
    h.trip_id,
    h.route_id,
    h.stop_sequence,
    h.service_date,
    h.actual_arrival_timestamp,
    h.scheduled_arrival_timestamp,
    h.stop_id,
    h.delay_minutes,
    h.actual_headway_minutes,
    coalesce(i.stop_delay_iqr, 0) as stop_delay_iqr
from headways h
left join stop_delay_iqr i on h.stop_id = i.stop_id