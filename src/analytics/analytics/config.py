"""Analytics settings with transitional aliases for existing deployments."""
import os


def environment(environ=None):
    """Prefer explicit ANALYTICS_* values, including empty values, over aliases.

    Keep the legacy prefix at this boundary so old Container Apps revisions and
    local configuration can migrate without changing consumer or auth identities.
    The caller's mapping and the process environment are never modified.
    """
    source = os.environ if environ is None else environ
    result = dict(source)
    for name, value in source.items():
        if name.startswith("MATCHER_"):
            result.setdefault("ANALYTICS_" + name[len("MATCHER_"):], value)
    return result
