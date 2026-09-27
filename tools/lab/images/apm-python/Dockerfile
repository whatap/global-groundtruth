# jjsong-ggt-apm-python:1 — Python 3.12 venv + PyPI whatap-python==2.2.0 +
# flask/gunicorn, started by whatap-start-agent, uid 1500. whatap.conf is
# written by whatap-setting-config with the dummy license.
FROM python:3.12-bookworm
RUN apt-get update -qq && apt-get install -y -qq procps iproute2 >/dev/null && rm -rf /var/lib/apt/lists/*
RUN useradd -m -u 1500 app && mkdir -p /app/whatap && chown -R app /app
RUN python -m venv /opt/venv && /opt/venv/bin/pip install -q --no-cache-dir whatap-python==2.2.0 flask gunicorn
ENV PATH=/opt/venv/bin:$PATH WHATAP_HOME=/app/whatap
COPY --chown=app app.py /app/
USER app
WORKDIR /app
RUN whatap-setting-config --host 127.0.0.1 --license ggt-lab-dummy-license --app_name ggtpython --app_process_name gunicorn && cat /app/whatap/whatap.conf
CMD ["whatap-start-agent","gunicorn","-w","2","-b","0.0.0.0:8000","app:app"]
