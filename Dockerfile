FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN groupadd --gid 10001 bot \
    && useradd --uid 10001 --gid bot --create-home bot

WORKDIR /app

COPY requirements.txt ./
RUN python -m pip install --no-cache-dir -r requirements.txt

COPY --chown=bot:bot app.py ./

RUN install -d -o bot -g bot -m 700 /data

USER bot

CMD ["python", "app.py"]
