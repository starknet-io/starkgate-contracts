<div align="center">

![starkgate](https://github.com/starkware-libs/starkgate/assets/88274280/45603468-0c91-4b3b-9864-f6859cb5ac35)
[![License: Apache2.0](https://img.shields.io/badge/License-Apache2.0-green.svg)](LICENSE)
</div>


<details open="open">
<summary>Table of Contents</summary>

- [:warning: Disclaimer](#warning-disclaimer)
- [About](#about)
- [Getting Started](#getting-started)
- [Security](#security)
- [License](#license)

</details>

---

## :warning: Disclaimer

:warning: :construction: `Starkgate` with the new cairo version is still a work in progress. Therefore, some parts of the code may be incomplete or undergoing changes, So use it at your own risk.:construction: :warning:

## About

`Starkgate` is the home for StarkNet's L1 bridges.

This repository contains the Cairo and Solidity code for the L1<>L2 bridges of StarkNet,
as well as StarkNet's ERC20 token contract implementation that interacts with the bridges.

You can find the L1 addresses and L2 addresses for the deployed bridges on StarkNet Alpha on Goerli and on Mainnet [here](https://github.com/starkware-libs/starknet-addresses).

Note: the frontend implementation of the bridges, can be found [here](https://github.com/starkware-libs/starkgate-frontend).

This project contains scripts written in Python 3.9.


## Getting Started

To run the scripts in this project, you'll need Python 3.9 installed on your system. It's recommended to use a virtual environment to manage your Python dependencies.

### Prerequisites

Make sure you have the following installed:

- Python 3.9: [Download Python](https://www.python.org/downloads/)

### Setting up the Virtual Environment

1. Clone the repository or download the source code.
2. Open a terminal or command prompt and navigate to the project directory.

```bash
cd project-directory
```

Create a virtual environment using venv:
```bash
python3.9 -m venv venv
```

Activate the virtual environment:

```bash
source venv/bin/activate
```

#### Installing Dependencies

Once you have activated the virtual environment, install the project dependencies using pip and the requirements.txt file:

```bash
pip install -r requirements.txt
```

#### Running the Setup Script
Before running the main scripts, you need to run the setup.sh script to perform additional setup steps. To run the script, use the following command:

```bash
scripts/setup.sh
```

#### Running the Scripts
With the virtual environment activated and the dependencies installed, you're ready to run the scripts. Use the following command:

```bash
# Build cairo contracts.
scripts/build-cairo.sh
# Build solidity contracts.
scripts/build-solidity.sh
# Running all the tests.
scripts/tests.sh
```


For more scripts, you can take a look in the scripts directory.


## Security

StarkGate follows good practices of security, but 100% security cannot be assured.
StarkGate is provided "as is" without any warranty. Use at your own risk.

_For more information and to report security issues, please refer to our [security documentation](SECURITY.md)._
## License

This project is licensed under the **Apache 2.0 license**.

See [LICENSE](LICENSE) for more information.

