import os.path

from starkware.starknet.services.api.contract_class import ContractClass

DIR = os.path.dirname(__file__)

proxy_contract_class = ContractClass.loads(data=open(os.path.join(DIR, "proxy.json")).read())
governance_contract_class = ContractClass.loads(
    data=open(os.path.join(DIR, "governance.json")).read()
)
