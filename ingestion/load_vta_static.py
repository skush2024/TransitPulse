import os
import io
import requests
import zipfile
import pandas as pd
import geopandas as gpd
from shapely.geometry import Point, LineString
from sqlalchemy import create_engine
from dotenv import load_dotenv

load_dotenv()
DATABASE_URL = os.getenv("DATABASE_URL")
API_KEY = os.getenv("API_511_KEY")

# Official 511.org endpoint for bulk operator data downloads (operator_id=VT for VTA)
API_URL = "http://api.511.org/transit/datafeeds"

def download_vta_gtfs():
    print("⏳ Requesting active VTA (SC) GTFS package from 511.org API...")
    
    # Safely pull the API key from your environment
    api_key = os.environ.get("API_511_KEY") 
    
    params = {
        "api_key": api_key,
        "operator_id": "SC"  # <--- Crucial Fix: SC represents VTA
    }
    
    response = requests.get(API_URL, params=params, stream=True)
    
    if response.status_code == 200:
        print("✅ Download successful! Parsing zip archive...")
        return zipfile.ZipFile(io.BytesIO(response.content))
    else:
        print(f"Server Response Body: {response.text}")
        raise Exception(f"❌ 511 API Download failure. Status Code: {response.status_code}")

def build_and_load_network():
    engine = create_engine(DATABASE_URL)
    zip_file = download_vta_gtfs()
    
    # 1. READ RAW FILES FROM ZIP
    print("📦 Unpacking GTFS source files...")
    with zip_file.open("stops.txt") as f: stops_df = pd.read_csv(f)
    with zip_file.open("routes.txt") as f: routes_df = pd.read_csv(f)
    with zip_file.open("trips.txt") as f: trips_df = pd.read_csv(f)
    with zip_file.open("shapes.txt") as f: shapes_df = pd.read_csv(f)

    print("📍 Processing Stops with GeoPandas...")
    # Map stops into a GeoDataFrame to validate geographic bounds
    stops_gdf = gpd.GeoDataFrame(
        stops_df, 
        geometry=gpd.points_from_xy(stops_df.stop_lon, stops_df.stop_lat), 
        crs="EPSG:4326"
    )
    
    print("🛣️ Processing Route Corridors (Shapes) via GeoPandas...")
    # Sort shapes to ensure lines are drawn in correct sequence
    shapes_df = shapes_df.sort_values(by=["shape_id", "shape_pt_sequence"])
    
    # Group shape points into an array of tuples, then convert into LineStrings
    shape_lines = []
    for shape_id, group in shapes_df.groupby("shape_id"):
        if len(group) > 1:
            points = [Point(xy) for xy in zip(group.shape_pt_lon, group.shape_pt_lat)]
            line = LineString(points)
            shape_lines.append({
                "shape_id": str(shape_id),
                "geometry_wkt": line.wkt # Store as WKT text so Grafana map plugins can parse instantly
            })
    shapes_processed_df = pd.DataFrame(shape_lines)

    # 2. STANDARDIZE TYPES & ALIGN SCHEMAS
    stops_df["stop_id"] = stops_df["stop_id"].astype(str)
    routes_df["route_id"] = routes_df["route_id"].astype(str)
    trips_df["trip_id"] = trips_df["trip_id"].astype(str)
    trips_df["route_id"] = trips_df["route_id"].astype(str)
    trips_df["shape_id"] = trips_df["shape_id"].astype(str)

    # 3. WRITE TO CLOUD POSTGRESQL LAYER
    print("💾 Uploading complete spatial transit network to Cloud DB...")
    stops_df[['stop_id', 'stop_name', 'stop_lat', 'stop_lon']].to_sql('raw_gtfs_static_stops', engine, if_exists='replace', index=False)
    routes_df[['route_id', 'route_short_name', 'route_long_name', 'route_type']].to_sql('raw_gtfs_static_routes', engine, if_exists='replace', index=False)
    trips_df[['trip_id', 'route_id', 'shape_id', 'direction_id']].to_sql('raw_gtfs_static_trips', engine, if_exists='replace', index=False)
    shapes_processed_df.to_sql('raw_gtfs_static_shapes', engine, if_exists='replace', index=False)
    
    print("🚀 All base network assets loaded successfully. Core Network Infrastructure complete!")

if __name__ == "__main__":
    build_and_load_network()