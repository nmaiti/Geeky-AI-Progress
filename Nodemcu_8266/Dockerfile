FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    wget \
    curl \
    unzip \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Install PlatformIO
RUN pip install --no-cache-dir platformio

# Pre-install ESP8266 platform and libraries for caching
WORKDIR /workspace
COPY platformio.ini /workspace/
RUN pio platform install espressif8266 && \
    pio lib install fastled/FastLED@^3.6.0 && \
    pio lib install bblanchon/ArduinoJson@^7.0.4

# Copy project source
COPY src/ /workspace/src/

# Default to bash shell; actual build happens via docker run
CMD ["bash"]
