-- models/marts/fct_transit_otp_hourly.sql
{{ config(materialized='table') }}

with performance as (
    select * from {{ ref('int_vta_arrival_performance') }}
),

routes as (
    select * from {{ ref('stg_vta_routes') }}
),

-- p75 delay anchored per stop AND per service_date so the anomaly threshold
-- does not drift as the rolling 48-hour window accumulates different history
-- across routes. A same-day baseline is the correct comparison period for OTP.
stop_stats as (
    select
        stop_id,
        service_date,
        percentile_cont(0.75) within group (order by delay_minutes) as p75_delay_minutes
    from performance
    group by 1, 2
),

congestion as (
    select
        -- local_ping_timestamp in int_vta_congestion_analysis is the raw UTC
        -- ping_timestamp (aliased misleadingly). date_trunc on a TIMESTAMPTZ
        -- truncates in UTC, matching how performance_hour is derived from
        -- actual_arrival_timestamp (also TIMESTAMPTZ / UTC-normalised).
        -- The join is therefore timezone-consistent.
        date_trunc('hour', local_ping_timestamp) as congestion_hour,
        route_id,
        count(*) as total_pings,
        sum(case when is_congestion_bottleneck then 1 else 0 end) as bottleneck_pings
    from {{ ref('int_vta_congestion_analysis') }}
    group by 1, 2
),

hourly_metrics as (
    select
        date_trunc('hour', p.actual_arrival_timestamp) as performance_hour,
        p.service_date,
        p.route_id,
        r.route_short_name,
        count(*) as total_arrivals,
        sum(case when p.delay_minutes between -1.0 and 5.0 then 1 else 0 end) as on_time_arrivals,
        sum(
            case
                -- FIX: join stop_stats on both stop_id AND service_date so the
                -- p75 baseline is same-day, not a cross-day rolling average.
                when p.delay_minutes > (s.p75_delay_minutes + (p.stop_delay_iqr * 1.5)) then 1
                else 0
            end
        ) as anomalous_delay_count,
        percentile_cont(0.5) within group (order by p.delay_minutes) as median_delay_minutes
    from performance p
    left join routes r on p.route_id = r.route_id
    -- FIX: add service_date to the stop_stats join
    left join stop_stats s
        on  p.stop_id     = s.stop_id
        and p.service_date = s.service_date
    group by 1, 2, 3, 4
),

final as (
    select
        h.*,
        coalesce(c.bottleneck_pings, 0) as bottleneck_pings,
        coalesce(c.total_pings, 0)      as total_pings
    from hourly_metrics h
    left join congestion c
        on  h.route_id        = c.route_id
        and h.performance_hour = c.congestion_hour
)

select
    performance_hour,
    service_date,
    route_id,
    route_short_name,
    total_arrivals,
    on_time_arrivals,
    anomalous_delay_count,
    round(median_delay_minutes::numeric, 2) as median_delay_minutes,
    round(
        (on_time_arrivals::numeric / nullif(total_arrivals, 0)) * 100,
        2
    ) as otp_percentage,
    round(
        (bottleneck_pings::numeric / nullif(total_pings, 0)) * 100,
        2
    ) as congestion_rate

from final