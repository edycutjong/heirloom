#!/bin/sh
# Assemble the GitHub Pages site into _site/: the landing + deck + judge page (docs/) and the status card (status/).
# Every [data-release] link gets the latest release tag as its build-time text; the pages refresh it from the GitHub
# API at runtime and keep this text on any failure. RELEASE_TAG overrides the tag (pages.yml passes the published one).
set -eu
cd "$(dirname "$0")/.."
TAG=${RELEASE_TAG:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)}
rm -rf _site
mkdir -p _site
cp -R docs/. _site/
cp -R status _site/status
touch _site/.nojekyll
if [ -n "$TAG" ]; then
  find _site -name '*.html' -exec perl -0pi -e 's{(<a\b[^>]*\bdata-release\b[^>]*>)[^<]*(</a>)}{${1}'"$TAG"'${2}}g' {} +
fi
echo "site assembled in _site/ (release tag: ${TAG:-none yet})"
