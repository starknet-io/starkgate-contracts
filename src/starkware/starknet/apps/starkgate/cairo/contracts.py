import os.path

from starkware.starknet.services.api.contract_class import ContractClass

DIR = os.path.dirname(__file__)

bridge_contract_class = ContractClass.loads(
    data=open(os.path.join(DIR, "token_bridge.json")).read()
)
