FROM ciimage/python:3.7 as base_image

RUN apt update
RUN apt -y -o Dpkg::Options::="--force-overwrite" install python3.7-dev
RUN apt install -y make libgmp3-dev g++ python3-pip npm unzip
# Installing cmake via apt doesn't bring the most up-to-date version.
RUN pip install cmake==3.22

# Install solc and ganache
RUN curl https://binaries.soliditylang.org/linux-amd64/solc-linux-amd64-v0.6.12+commit.27d51765 -o /usr/local/bin/solc-0.6.12
RUN echo 'f6cb519b01dabc61cab4c184a3db11aa591d18151e362fcae850e42cffdfb09a /usr/local/bin/solc-0.6.12' | sha256sum --check
RUN chmod +x /usr/local/bin/solc-0.6.12
RUN npm install -g --unsafe-perm ganache-cli@6.12.2

COPY . /app/

# Build.
WORKDIR /app/
RUN rm -rf build
RUN ./build.sh

FROM base_image

# Run tests.
WORKDIR /app/build/Release
RUN ctest -V

WORKDIR /app/
