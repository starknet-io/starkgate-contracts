# Solidity L1 Bridge

## Get Started

### Local development

Most commands must be run from the same directory as this readme is in.

```bash
$ brew install python3.9 # i.e. ensure python3.9 is available
$ python3.9 -m venv dev # create Python 3.9 virtual env
$ source dev/bin/activate
(dev)$ pip install -r requirements.txt
```

```bash
python3 -m pip install --user pipx
python3 -m pipx ensurepath
```

You may need to restart your terminal after installing pipx.

```bash
pipx install eth-brownie
```

### Compiling contracts

```bash
brownie compile --all
```


### Running scripts

Each script has a set of environment variables required in order to run.

```bash
export WEB3_INFURA_PROJECT_ID=<infura_bridge_project_id>
brownie run scripts/<script_file> --network goerli
```


Mint to an account

```bash
export WEB3_INFURA_PROJECT_ID=<INFURA-BRIDGE-PROJECT-ID>
export PARACLEAR_L1_TOKEN_ADDRESS=<L1_USDC_ADDRESS>
export PARACLEAR_L1_ADMIN_PRIVATE_KEY=<L1_USDC_ADMIN_PRIVATE_KEY>
export PARACLEAR_L1_USER_ADDRESS=<L1_MINT_RECEPTOR_ADDRESS>
export AMOUNT=<AMOUNT_TO_BE_MINTED> #(Will get transformed to the decimal precision of the contract)
brownie run scripts/mint_tokens.py --network goerli
```