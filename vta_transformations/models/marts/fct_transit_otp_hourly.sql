-- models/marts/fct_transit_otp_hourly.sql
{{ config(materialized='table') }}

with performance as (
    select * from {{ ref('int_vta_arrival_performance') }}
),

routes as (
    select * from {{ ref('stg_vta_routes') }}
),

hourly_metrics as (
    select
        date_trunc('hour', p.actual_arrival_timestamp) as performance_hour,
        p.route_id,
        r.route_short_name,
        count(*) as total_arrivals,
        
        -- On-Time Performance definition: Late less than 5 mins, early less than 1 min
        sum(case when p.delay_minutes between -1.0 and 5.0 then 1 else 0 end) as on_time_arrivals,
        
        -- High Delay Counts (Using IQR rule for stop level anomalies)
        sum(case when p.delay_minutes > (p.stop_delay_iqr * 1.5) then 1 else 0 end) as anomalous_delay_count,
        
        avg(p.delay_minutes) as avg_delay_minutes
    from performance p
    left join routes r on p.route_id = r.route_id
    group by 1, 2, 3
)

select
    *,
    round((on_time_arrivals::numeric / total_arrivals::numeric) * 100, 2) as otp_percentage
from hourly_metrics