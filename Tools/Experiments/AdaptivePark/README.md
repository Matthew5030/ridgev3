# Adaptive park loading experiment

Archived diagnostic view and dedicated Metal shader, kept outside the production
app's synchronized Xcode source group. The normal Ridge selection and expansion
flow does not use this view. Existing local changes were preserved when moving it.

The view depends on Ridge's core types and theme. To revive this lab, include these
two files alongside those dependencies in a development-only target; do not add
the folder to the shipping app. Large source packs remain on the external drive.
