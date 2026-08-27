# The single source for the GCP project id.
#
# Why this exists: three scripts under learn/ need to pass GOOGLE_CLOUD_PROJECT
# to docker, and each used to hardcode the same string. config/config.toml
# already holds that value and is gitignored, so the real id never reaches a
# public repository -- reading it from there is enough.
#
# Usage: callers have already cd'd to the repo root, so just
#          . learn/lib/project-id.sh
#        and use $GCP_PROJECT afterwards.
#
# The shape it takes in config.toml (a single-line inline table, note the
# spaces):
#   env = { ..., GOOGLE_CLOUD_PROJECT = "your-gcp-project-id", ... }

resolve_project_id() {
    # The environment variable wins: to run against a different project for a
    # moment, export it -- no need to edit any file.
    if [ -n "$GOOGLE_CLOUD_PROJECT" ]; then
        echo "$GOOGLE_CLOUD_PROJECT"
        return
    fi

    # Otherwise pull it out of config.toml. That is a single-line inline table
    # sharing the line with GOOGLE_CLOUD_LOCATION and other KEY = "value" pairs,
    # so the match has to include the equals sign and the quotes, and take only
    # the first hit.
    id=$(sed -n 's/.*GOOGLE_CLOUD_PROJECT[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
         config/config.toml 2>/dev/null | head -1)

    # Stop if it is missing. Each of these scripts makes a real Vertex call, and
    # an empty project id only ever surfaces as an unreadable API error.
    if [ -z "$id" ]; then
        echo "GCP project id not found." >&2
        echo "  Check that config/config.toml exists (copy config/config.toml.example)," >&2
        echo "  or export GOOGLE_CLOUD_PROJECT=<your project id> directly" >&2
        return 1
    fi

    echo "$id"
}

# A bare assignment would not be enough: the function runs inside a $( ) subshell,
# where its return cannot stop the caller. The assignment's own exit status has to
# do that explicitly.
GCP_PROJECT="$(resolve_project_id)" || exit 1
