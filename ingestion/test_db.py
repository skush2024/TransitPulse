import os
import requests
import pandas as pd
from sqlalchemy import create_engine
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

DATABASE_URL = os.getenv("DATABASE_URL")
API_KEY = os.getenv("API_511_KEY")

# 511.org API endpoint for VTA GTFS Static Feed
STATIC_FEED_URL = f"http://api.511.org/transit/gtfsoperators?api_key={API_KEY}" 

def test_db_connection():
    """Validates that our script can securely talk to the cloud database."""
    try:
        engine = create_engine(DATABASE_URL)
        with engine.connect() as conn:
            print("🚀 Successfully connected to the Cloud PostgreSQL Database!")
            return engine
    except Exception as e:
        print(f"❌ Database connection failed: {e}")
        return None

if __name__ == "__main__":
    test_db_connection()