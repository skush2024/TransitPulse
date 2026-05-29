import os
import requests
from dotenv import load_dotenv
# Import the official GTFS-RT parsing class
from google.transit import gtfs_realtime_pb2

load_dotenv()
API_KEY = os.getenv("API_511_KEY")

# 511.org GTFS-RT Vehicle Positions URL
URL = f"http://api.511.org/transit/vehiclepositions?api_key={API_KEY}&agency=SC"

def test_api_call():
    print("📡 Pinging 511.org VTA Realtime Feed (Protocol Buffers)...")
    
    try:
        # DO NOT enforce application/json headers; 511 sends binary bytes
        response = requests.get(URL)
        
        if response.status_code != 200:
            print(f"❌ Connection Failed! Status Code: {response.status_code}")
            return
            
        # Initialize the GTFS Realtime FeedMessage object
        feed = gtfs_realtime_pb2.FeedMessage()
        # Parse the raw binary string bytes directly
        feed.ParseFromString(response.content)
        
        print(f"✅ Connection Successful!")
        print(f"📊 Total Active VTA Vehicles in Feed Frame: {len(feed.entity)}")
        
        if len(feed.entity) > 0:
            print("\n🔍 Inspecting the first active vehicle entity:")
            
            # GTFS-RT entities are objects, accessed via dot notation, not dict keys
            entity = feed.entity[0]
            vehicle_data = entity.vehicle
            
            print(f"  • Vehicle ID: {vehicle_data.vehicle.id}")
            print(f"  • Route ID: {vehicle_data.trip.route_id}")
            print(f"  • Trip ID: {vehicle_data.trip.trip_id}")
            print(f"  • Coordinates: ({vehicle_data.position.latitude}, {vehicle_data.position.longitude})")
            
    except Exception as e:
        print(f"❌ An error occurred while testing the API: {e}")

if __name__ == "__main__":
    test_api_call()