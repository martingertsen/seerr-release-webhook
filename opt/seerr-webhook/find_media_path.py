#!/usr/bin/env python3

import json
import os
import sys
from urllib import request


RADARR_URL = os.environ["RADARR_URL"]
RADARR_API_KEY = os.environ["RADARR_API_KEY"]

SONARR_URL = os.environ["SONARR_URL"]
SONARR_API_KEY = os.environ["SONARR_API_KEY"]

RADARR_PATH_PREFIX = os.environ.get("RADARR_PATH_PREFIX", "/movies")
RADARR_LOCAL_PREFIX = os.environ.get("RADARR_LOCAL_PREFIX", "/mnt/nas/Media/Movies")

SONARR_PATH_PREFIX = os.environ.get("SONARR_PATH_PREFIX", "/tv")
SONARR_LOCAL_PREFIX = os.environ.get("SONARR_LOCAL_PREFIX", "/mnt/nas/Media/TV")


def map_path(path, remote_prefix, local_prefix):
    if path == remote_prefix:
        return local_prefix

    if path.startswith(remote_prefix + "/"):
        return local_prefix + path[len(remote_prefix):]

    return path


def get_json(url, api_key):
    req = request.Request(url)
    req.add_header("X-Api-Key", api_key)

    with request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def main():
    if len(sys.argv) != 3:
        print(
            "Usage: find_media_path.py movie <tmdbId> | tv <tvdbId>",
            file=sys.stderr,
        )
        return 1

    media_type = sys.argv[1]
    media_id = str(sys.argv[2])

    if media_type == "movie":
        movies = get_json(
            f"{RADARR_URL}/api/v3/movie",
            RADARR_API_KEY,
        )

        for movie in movies:
            if str(movie.get("tmdbId")) == media_id:
                print(map_path(movie["path"], RADARR_PATH_PREFIX, RADARR_LOCAL_PREFIX))
                return 0

    elif media_type == "tv":
        series = get_json(
            f"{SONARR_URL}/api/v3/series",
            SONARR_API_KEY,
        )

        for item in series:
            if str(item.get("tvdbId")) == media_id:
                print(map_path(item["path"], SONARR_PATH_PREFIX, SONARR_LOCAL_PREFIX))
                return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
