import json
import os

# Point to the ROOT_DIRECTORY_OF_THE_PROJECT/artifacts.
ARTIFACTS = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "artifacts")


def load_contract(name: str) -> dict:
    """
    Loads a contract json from the artifacts directory.
    """
    return json.load(open(f"{ARTIFACTS}/{name}.json"))
