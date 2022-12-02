import os.path

from starkware.starknet.services.api.contract_class import ContractClass

DIR = os.path.dirname(__file__)

contract_a_class = ContractClass.loads(data=open(os.path.join(DIR, "impl_contract_a.json")).read())
contract_b_class = ContractClass.loads(data=open(os.path.join(DIR, "impl_contract_b.json")).read())
test_eic_class = ContractClass.loads(data=open(os.path.join(DIR, "test_eic.json")).read())
