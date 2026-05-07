# Updating R Package Dependencies

The pinned R dependencies are managed via [renv](https://rstudio.github.io/renv/).
`renv.lock` records the exact version of every package (direct and transitive).

To update it, spin up an ephemeral container from the same base image used by the
Dockerfile, mount this repository into it, and run the renv commands there.
The only file that needs to be committed afterwards is the updated `renv.lock`.

---

## Procedure

### 1. Build a local helper image with R and build dependencies

Run this once from the root of the repository (re-run whenever the base image
SHA in the `FROM` line of the Dockerfile changes):

```bash
docker build -t gdal-r-update - <<'EOF'
FROM ghcr.io/osgeo/gdal:ubuntu-small-3.11.3
RUN DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential \
      curl            \
      r-base          \
      r-cran-renv     \
      gfortran        \
      libblas-dev     \
      liblapack-dev   \
      libuv1-dev      \
      pandoc          \
      zlib1g-dev
EOF
```

This installs R and all build dependencies as root inside a throwaway image.

---

### 2. Launch an interactive container

```bash
docker run --rm -it \
  -v "$(pwd)":/work \
  -u "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  gdal-r-update \
  bash
```

Running as your own UID/GID (`-u`) ensures that any files written to the
mounted repository — including the updated `renv.lock` — are owned by you.
`-e HOME=/tmp` gives renv a writable home directory inside the container.

---

### 3. Restore the current state

```bash
cd /work
export RENV_PATHS_LIBRARY=/tmp/renv-lib   # keep packages out of the mounted volume
Rscript -e 'renv::restore()'
```

This installs all packages at the versions currently recorded in `renv.lock`.
It is required before updating so that renv knows what is installed.

Use `Rscript -e 'options(Ncpus = parallel::detectCores()); renv::restore()` to get some speedup by building the individual packages in parallel.

---

### 4. Update packages

**Update all packages to the latest CRAN versions:**

```bash
Rscript -e 'renv::update()'
```

**Update a single package:**

```bash
Rscript -e 'renv::update("echarts4r")'
```

**Install a new package and add it to the lockfile:**

```bash
Rscript -e 'install.packages("newpkg")'
```

---

### 5. Write the new versions to the lockfile

```bash
Rscript -e 'renv::snapshot()'
```

This overwrites `renv.lock` with the currently installed versions.
Because `/work` is a bind mount, the file is updated directly on your host.

---

### 6. Commit

```bash
git add renv.lock
git commit -m "renv: update R package dependencies"
```

---

## Notes

- The directly required packages are: `rmarkdown`, `echarts4r`, `snow`, `snowfall`, `getopt`.
  All other entries in `renv.lock` are their transitive dependencies.
- `snapshot.type` is set to `"all"` in `renv/settings.json`, so every installed
  package (including indirect dependencies) is captured in the lockfile.
- `renv/library/` is listed in `renv/.gitignore` and must not be committed.
- The `R.Version` field in `renv.lock` reflects the R version inside the container.
  Make sure the base image SHA in the `docker run` command matches the one in the
  `FROM` line of the Dockerfile to keep R versions consistent.
