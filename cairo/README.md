# Cairo L2 Bridge

## Get Started

### Local development

Most commands must be run from the same directory as this readme is in.

```bash
$ brew install python3.9 # i.e. ensure python3.9 is available
$ python3.9 -m venv dev # create Python 3.9 virtual env
$ source dev/bin/activate
(dev)$ pip install -r requirements.txt
```

> ⚠️ For macOS with Apple Silicon, you may need to do some handholding to
> be able to install, as `gmp` wheels are not available for you yet (last
> checked at 2022-07-15)

```bash
$ brew install gmp
$ source dev/bin/activate
(dev)$ CFLAGS="-I$(brew --prefix gmp)/include" LDFLAGS="-L$(brew --prefix gmp)/lib" pip install -r requirements.txt
```

### Compiling contracts

```bash
nile compile
```

### Running scripts

Each script has a set of environment variables required in order to run.

```bash
python3 scripts/<script_file>
```