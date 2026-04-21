FROM rocker/r-ver:4.4.1

# system libs:
#   libsodium-dev — required by the `sodium` R pkg (plumber -> sodium)
#   libcurl/ssl/xml — httr2, duckdb, etc.
#   zlib1g-dev     — sometimes pulled in by source builds
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-dev python3-pip python3-venv \
      libcurl4-openssl-dev libssl-dev libxml2-dev libsodium-dev \
      libpng-dev zlib1g-dev \
      curl \
 && rm -rf /var/lib/apt/lists/*

ENV RETICULATE_PYTHON=/opt/venv/bin/python3
RUN python3 -m venv /opt/venv
COPY requirements.txt /tmp/requirements.txt
RUN /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt

# install2.r (from littler, shipped by rocker) fails the build if any package
# fails to install — unlike install.packages() which only warns and keeps going.
# Uses the rocker PPM binary repo by default (fast), falling back to source.
RUN install2.r --error --skipinstalled --ncpus=-1 \
      plumber DBI glue jsonlite digest reticulate base64enc

# duckdb: pin-free, pull from PPM "latest" so the storage version matches
# whatever calcofi4db / calcofi4r are currently releasing (>= 1.5.1). The
# default rocker PPM snapshot (2024-10-30) only has duckdb 1.1.3, which fails
# at runtime with: "Trying to read a database file with version number 68,
# but we can only read version 64."
RUN install2.r --error --ncpus=-1 \
      -r https://packagemanager.posit.co/cran/__linux__/jammy/latest \
      duckdb

# belt & suspenders: fail the build if any of these can't load, and print
# the duckdb version so a future mismatch is visible in the build log.
RUN R -e 'for (p in c("plumber","duckdb","DBI","glue","jsonlite","digest","reticulate","base64enc")) suppressPackageStartupMessages(library(p, character.only=TRUE)); cat("duckdb R pkg version:", as.character(packageVersion("duckdb")), "\n")'

WORKDIR /app
COPY . /app

ENV H3T_PORT=8889 H3T_HOST=0.0.0.0
EXPOSE 8889

HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=5 \
  CMD curl -fsS http://localhost:8889/h3t/health || exit 1

CMD ["Rscript", "/app/run-api.R"]
