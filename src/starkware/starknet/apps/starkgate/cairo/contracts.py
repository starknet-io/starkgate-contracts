import os.path

from starkware.starknet.services.api.contract_definition import ContractDefinition

DIR = os.path.dirname(__file__)

erc20_contract_def = ContractDefinition.loads(open(os.path.join(DIR, "ERC20.json")).read())
bridge_contract_def = ContractDefinition.loads(open(os.path.join(DIR, "token_bridge.json")).read())
