from fastapi.responses import FileResponse
from fastapi import FastAPI, WebSocket
from simulator import generate_sensor_data
from sensor_logic import detect_fall, analyze_heart_rate
import asyncio

app = FastAPI()
@app.get("/dashboard")
def dashboard():
    return FileResponse("static/index.html")
@app.get("/api/simulate-fall")
def simulate_fall():
    data = generate_sensor_data()

    data["acceleration"] = 3.5

    return {
        **data,
        "fall": True,
        "heart_status": analyze_heart_rate(data["heart_rate"])
    }

@app.get("/")
def home():
    return {"message": "IoT Sensor Project is running!"}


@app.get("/api/sensor")
def sensor():
    data = generate_sensor_data()

    return {
        **data,
        "fall": detect_fall(data["acceleration"]),
        "heart_status": analyze_heart_rate(data["heart_rate"])
    }


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()

    while True:
        data = generate_sensor_data()

        result = {
            **data,
            "fall": detect_fall(data["acceleration"]),
            "heart_status": analyze_heart_rate(data["heart_rate"])
        }

        await websocket.send_json(result)

        await asyncio.sleep(1)