import pandas as pd
from sklearn.ensemble import IsolationForest
from sklearn.preprocessing import StandardScaler
import joblib
import os

# 1. Load the Dataset
# Ensure you place your 'OBD2_panel_opel_2012.csv' in the same folder
DATA_FILE = "dataset.csv"

def train_system():
    print("Loading Opel 2012 telemetry data...")
    try:
        df = pd.read_csv(DATA_FILE)
    except FileNotFoundError:
        print(f"Error: Please place {DATA_FILE} in the backend folder.")
        return

    # 2. Data Preprocessing (Addressing Sir Yawar Abbas's Feedback)
    print("Executing Preprocessing Pipeline...")
    
    # Drop non-numeric columns like timestamps that the ML model can't process
    numeric_df = df.select_dtypes(include=['float64', 'int64'])
    
    # Missing Value Imputation: Fill dropped Bluetooth packets with the column median
    numeric_df = numeric_df.fillna(numeric_df.median())
    
    # Feature Scaling: Normalize metrics (RPM, Temp, Speed) so they carry equal mathematical weight
    scaler = StandardScaler()
    scaled_features = scaler.fit_transform(numeric_df)

    # 3. Model Initialization & Mathematical Intuition (Addressing Sir Abdul Mateen's Feedback)
    # Isolation Forest isolates anomalies by creating random decision trees. 
    # Anomalies have shorter path lengths. Contamination is the estimated % of anomalies in the data.
    print("Initializing Isolation Forest Model...")
    model = IsolationForest(n_estimators=100, contamination=0.05, random_state=42)

    # 4. Train the Model
    print("Training model on normal vehicle baselines...")
    model.fit(scaled_features)

    # 5. Save the Pipeline for FastAPI Deployment
    # We save both the model and the scaler so live data from the car can be scaled the exact same way
    os.makedirs("saved_models", exist_ok=True)
    joblib.dump(model, "saved_models/isolation_forest.pkl")
    joblib.dump(scaler, "saved_models/scaler.pkl")
    
    print("Success: Model and Scaler saved. Ready for FastAPI deployment.")

if __name__ == "__main__":
    train_system()