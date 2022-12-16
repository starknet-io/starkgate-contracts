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
brownie run scripts/<script_file> --network goerli
```