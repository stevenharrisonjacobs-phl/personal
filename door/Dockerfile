FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
WORKDIR /app

COPY door/requirements.txt /app/door/requirements.txt
RUN pip install --no-cache-dir -r /app/door/requirements.txt

# queries/ ships with the image so saved_query runs the SAME vetted SQL the
# laptop runs through ./scripts/query.sh. Nothing else from the repo is copied —
# no .env, no .context, no projects/.
COPY queries /app/queries
# checkin_validate.py ships so record_checkin runs the SAME tested validator
# (tests/test_checkin_validate.py) that scripts/checkin-write.sh runs on the
# laptop. finance_write.py imports it via ../scripts relative to the door
# package, which resolves to /app/scripts here exactly as in the repo checkout.
COPY scripts/checkin_validate.py /app/scripts/checkin_validate.py
COPY door /app/door

CMD ["python", "-m", "door.main"]
