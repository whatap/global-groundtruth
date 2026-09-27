# jjsong-ggt-apm-python-op:1 — Python 3.12 + /whatap-agent from the public
# apm-init-python image (2.1.2 at reconstruction), PYTHONPATH bootstrap as the
# operator injects it. Dummy license in whatap.conf.
ARG AGENT_IMAGE=public.ecr.aws/whatap/apm-init-python:latest
FROM ${AGENT_IMAGE} AS agent
FROM python:3.12-bookworm
RUN apt-get update -qq && apt-get install -y -qq procps iproute2 >/dev/null && rm -rf /var/lib/apt/lists/*
RUN useradd -m -u 1500 app && pip install -q --no-cache-dir flask gunicorn
COPY --from=agent /opt/whatap-agent-dist/ /whatap-agent/
COPY whatap.conf /whatap-agent/whatap.conf
COPY app.py /app/app.py
RUN chown -R app /whatap-agent /app
ENV WHATAP_HOME=/whatap-agent PYTHONPATH=/whatap-agent:/whatap-agent/whatap/bootstrap
USER app
WORKDIR /app
CMD ["gunicorn","-w","2","-b","0.0.0.0:8000","app:app"]
