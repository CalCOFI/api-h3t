FROM rocker/r-ver:4.4.1

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-pip python3-venv \
      libcurl4-openssl-dev libssl-dev libxml2-dev \
 && rm -rf /var/lib/apt/lists/*

ENV RETICULATE_PYTHON=/opt/venv/bin/python3
RUN python3 -m venv /opt/venv
COPY requirements.txt /tmp/requirements.txt
RUN /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt

RUN R -e "install.packages(c('plumber','duckdb','DBI','glue','jsonlite','digest','reticulate','base64enc'), repos='https://cloud.r-project.org')"

WORKDIR /app
COPY . /app

ENV H3T_PORT=8889 H3T_HOST=0.0.0.0
EXPOSE 8889

CMD ["Rscript", "/app/run-api.R"]
