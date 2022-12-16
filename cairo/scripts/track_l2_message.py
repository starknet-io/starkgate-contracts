from starkware.cairo.lang.vm.crypto import pedersen_hash
from starkware.cairo.common.hash_state import compute_hash_on_elements
from starkware.crypto.signature.fast_pedersen_hash import pedersen_hash
from typing import List
from deploy_lib import int_16, CustomStarknetChainId


def calculate_transaction_hash_common(
    tx_hash_prefix,
    version,
    contract_address,
    entry_point_selector,
    calldata,
    max_fee,
    chain_id,
    additional_data,
    hash_function=pedersen_hash,
) -> int:
    calldata_hash = compute_hash_on_elements(data=calldata, hash_func=hash_function)
    data_to_hash = [
        tx_hash_prefix,
        version,
        contract_address,
        entry_point_selector,
        calldata_hash,
        max_fee,
        chain_id,
        *additional_data,
    ]

    return compute_hash_on_elements(
        data=data_to_hash,
        hash_func=hash_function,
    )


def tx_hash_from_message(
    from_address: str, to_address: str, selector: str, nonce: int, payload: List[int]
) -> str:
    int_hash = calculate_transaction_hash_common(
        tx_hash_prefix=int.from_bytes(b"l1_handler", "big"),    # int.from_bytes(b"l1_handler", "big")
        version=0,
        contract_address=int_16(to_address),
        entry_point_selector=int_16(selector),
        calldata=[int_16(from_address), *(int_16(element) for element in payload)],
        max_fee=0,
        chain_id=CustomStarknetChainId.PRIVATE_SN_TESTNET.value,  # StarknetChainId.TESTNET.value
        additional_data=[nonce],
    )
    return hex(int_hash)


print(
    tx_hash_from_message(
        from_address="0x000000000000000000000000bc5bf8f315b9d1eebd8062cadf113a05c5abb43e",
        to_address="0x00d256efe3d853cd5422f7dd6ddf4d8fb73a1c7ce61cce1c00142b4c156351bf",
        selector="0x02d757788a8d8d6f21d1cd40bce38a8222d70654214e96ff95d8086e684fbee5",
        nonce=1,
        payload=[
            "023a137ff67f2d70c5f87a86f5829af1d2bde86ae9efcedf050fe7a096cd6768",
            "000000000000000000000000000000000000000000000000000000174876e800",
            "0000000000000000000000000000000000000000000000000000000000000000",
        ],
    )
)
