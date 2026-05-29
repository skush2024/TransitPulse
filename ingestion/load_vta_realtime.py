import os
import requests
import pandas as pd
import geopandas as gpd
from datetime import datetime, timedelta, timezone
from sqlalchemy import create_engine, text
from dotenv import load_dotenv

# Import the official GTFS-RT protobuf structure
from google.transit import gtfs_realtime_pb2

load_dotenv()
DATABASE_URL = os.getenv("DATABASE_URL")
API_KEY = os.getenv("API_511_KEY")

# 511.org GTFS-RT Vehicle Positions URL
REALTIME_URL = f"http://api.511.org/transit/vehiclepositions?api_key={API_KEY}&agency=SC"

def fetch_live_positions():
    print(f"⏳ Fetching binary GTFS-RT feed from 511.org at {datetime.now(timezone.utc)}...")
    
    response = requests.get(REALTIME_URL)
    if response.status_code != 200:
        print(f"❌ API Error: Status Code {response.status_code}")
        return None
        
    feed = gtfs_realtime_pb2.FeedMessage()
    feed.ParseFromString(response.content)
    
    entities = feed.entity
    if not entities:
        print("⚠️ Feed frame received, but contains 0 active vehicle entities.")
        return None

    parsed_rows = []
    # FIX: Use modern timezone-aware UTC datetime format to clear the deprecation warning
    fetch_time = datetime.now(timezone.utc) 

    for entity in entities:
        if not entity.HasField('vehicle'):
            continue
            
        vehicle_data = entity.vehicle
        trip = vehicle_data.trip
        position = vehicle_data.position
        
        # Extract native fields that actually exist in the official VehiclePosition spec
        lat = position.latitude if position.HasField('latitude') else None
        lon = position.longitude if position.HasField('longitude') else None
        
        # Optional fields according to the official spec
        bearing = position.bearing if position.HasField('bearing') else None
        speed = position.speed if position.HasField('speed') else None
        
        parsed_rows.append({
            "timestamp": fetch_time,
            "vehicle_id": str(vehicle_data.vehicle.id),
            "trip_id": str(trip.trip_id),
            "route_id": str(trip.route_id),
            "latitude": lat,
            "longitude": lon,
            "bearing": bearing,
            "speed": speed,
            "current_stop_sequence": vehicle_data.current_stop_sequence if vehicle_data.HasField('current_stop_sequence') else None
        })
        
    return pd.DataFrame(parsed_rows)

def clean_and_load_realtime():
    df = fetch_live_positions()
    if df is None or df.empty:
        return
        
    engine = create_engine(DATABASE_URL)
    
    # Drop rows without valid coordinates
    df = df.dropna(subset=["latitude", "longitude"])
    df = df[(df["latitude"] != 0) & (df["longitude"] != 0)]
    
    if df.empty:
        print("⚠️ All positions in this frame failed coordinate checks.")
        return

    # Use GeoPandas to guarantee spatial coordinate structure correctness
    gdf = gpd.GeoDataFrame(df, geometry=gpd.points_from_xy(df.longitude, df.latitude), crs="EPSG:4326")
    
    # Flatten it back to a standard DataFrame for database upload
    clean_df = pd.DataFrame(gdf.drop(columns=["geometry"]))

    # 1. Append live data into our raw tracking table
    print(f"💾 Appending {len(clean_df)} active records to raw_gtfs_realtime_pings...")
    clean_df.to_sql("raw_gtfs_realtime_pings", engine, if_exists="append", index=False)
    
    # 2. HOUSEKEEPING: Purge data older than 48 hours to maintain our 2-day limit
    print("🧹 Running sliding window maintenance (purging logs older than 48 hours)...")
    cutoff_time = datetime.now(timezone.utc) - timedelta(days=2)
    
    with engine.connect() as conn:
        with conn.begin():
            query = text("DELETE FROM raw_gtfs_realtime_pings WHERE timestamp < :cutoff")
            conn.execute(query, {"cutoff": cutoff_time})
            
    print("✅ Ingestion phase and rolling window maintenance complete.")

if __name__ == "__main__":
    clean_and_load_realtime()