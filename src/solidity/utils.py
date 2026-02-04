import json
import os

from starkware.cairo.lang.cairo_constants import DEFAULT_PRIME

# Point to the ROOT_DIRECTORY_OF_THE_PROJECT/artifacts.
ARTIFACTS = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "artifacts")
LEGACY_ARTIFACTS = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(__file__))),
    "starkware/solidity/test_contracts/legacy_artifacts",
)


def load_contract(name: str) -> dict:
    """
    Loads a contract json from the artifacts directory.
    """
    return json.load(open(f"{ARTIFACTS}/{name}.json"))


def load_legacy_contract(name: str) -> dict:
    """
    Loads a contract json from the artifacts directory.
    """
    return json.load(open(f"{LEGACY_ARTIFACTS}/legacy_{name}.json"))


def str_to_felt(short_text: str) -> int:
    felt = int.from_bytes(bytes(short_text, encoding="ascii"), "big")
    assert felt < DEFAULT_PRIME, f"{short_text} is too long"
    return felt


def felt_to_str(felt: int) -> str:
    BYTE_LEN = 8
    len_bits = felt.bit_length()
    # Find "real" length to truncate leading zeros.
    _len = ((-len_bits) % BYTE_LEN + len_bits) // 8
    return felt.to_bytes(_len, "big").decode(encoding="ascii")
