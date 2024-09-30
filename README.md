# FirstSpirit in a Container

THIS PROJECT IS NOT AN OFFICIAL PRODUCT BY [Crownpeak Technology GmbH](https://www.e-spirit.com/). It is maintained and
provided by [Monday Consulting](https://www.monday-consulting.com/) to the FirstSpirit Community

## What is FirstSpirit

> FirstSpirit ist ein kommerzielles Content-Management-System, das von der
> Dortmunder [Crownpeak Technology GmbH](https://www.e-spirit.com/), einem Tochterunternehmen der CrownPeak Inc., seit
> 1999 entwickelt wurde. Die erste stabile Version 0.9 wurde am 7. Juni 2000 herausgegeben. Das System ist in Java
> entwickelt und wird für GNU/Linux, Solaris (x86, Sparc), AIX und Windows angeboten.

## TL;DR

```console
docker run -d -v $(pwd)/config/fs-license.conf:/opt/firstspirit5/conf/fs-license.conf --name FirstSpirit firstspirit/firstspirit:[TAG]
```

You can find the available configuration options in the [Environment Variables](#environment-variables) section.

## Supported platforms

The following os architectures are tested by Monday Consulting:

- amd64
- arm64

## Usage examples

### with port mapping

```console
docker run -d -v $(pwd)/config/fs-license.conf:/opt/firstspirit5/conf/fs-license.conf -p 8000:8000 -p 1088:1088 --name CONTAINER_NAME --hostname=localhost YOUR_REG_HERE/firstspirit/firstspirit:[TAG]
```

### with overriding HOST and HTTP_PORT in fs-server.conf

```console
docker run -d -v $(pwd)/config/fs-license.conf:/opt/firstspirit5/conf/fs-license.conf -p 80:8000 -p 1088:1088 --name CONTAINER_NAME -e EXT_HOSTNAME=localhost -e EXT_PORT=80 YOUR_REG_HERE/firstspirit/firstspirit:[TAG]
```

## Creating your own images

The Dockerfiles are [multi-stage builds](https://docs.docker.com/build/building/multi-stage/). For creating your own
images you need a download url and credentials. **These are mandatory and must be provided by `build-arg`s** . In the
project **root folder** run

```console
docker build -f jdk17/Dockerfile --no-cache --build-arg FS_DOWNLOAD_SERVER=YOUR_URL_HERE --build-arg FS_DOWNLOAD_SERVER_USERNAME=YOUR_USERNAME --build-arg FS_DOWNLOAD_SERVER_PASSWORD=YOUR_PASSWORD --build-arg IMAGE_CREATED=$(date +%FT%T%Z) -t your-registry.local/firstspirit/firstspirit_debug:YOUR-TAG-jdk17 .
```

### Image flavours

Currently, there is one mayor flavor, as JDK 11 is not supported for FirstSpirit versions 2023.09 and newer.

- JDK 17

The mayor flavor is addressed by its respective `Dockerfile`. Choose your flavors by providing the `-f` flag to the
build command. E.g. for JDK 17

```console
docker build -f jdk17/Dockerfile ...
```

By default, the image is created with debug properties so a developer can remote debug the FirstSpirit server. If you
don't want this option you have to provide the `base` target to the docker build. E.g. for JDK 17

```console
docker build -f jdk17/Dockerfile --target base ...
```

For a complete set of images you have run 2 commands:

```console
docker build -f jdk17/Dockerfile --no-cache --build-arg FS_DOWNLOAD_SERVER=YOUR_URL_HERE --build-arg FS_DOWNLOAD_SERVER_USERNAME=YOUR_USERNAME --build-arg FS_DOWNLOAD_SERVER_PASSWORD=YOUR_PASSWORD --build-arg IMAGE_CREATED=$(date +%FT%T%Z) -t your-registry.local/firstspirit/firstspirit_debug:YOUR-TAG_GOES-HERE-jdk17 .
docker build -f jdk17/Dockerfile --target base --build-arg FS_DOWNLOAD_SERVER=YOUR_URL_HERE --build-arg FS_DOWNLOAD_SERVER_USERNAME=YOUR_USERNAME --build-arg FS_DOWNLOAD_SERVER_PASSWORD=YOUR_PASSWORD --build-arg IMAGE_CREATED=$(date +%FT%T%Z) -t your-registry.local/firstspirit/firstspirit:YOUR-TAG_GOES-HERE-jdk17 .
```

### Recommended tagging

The image tagging scheme should be

```
YOUR_REGISTRY/YOUR_PROJECT/firstspirit[_debug]:(FS-VERSION)-(JDK-VERSION)
```

A complete set would be:

- `your-registry.local/firstspirit/firstspirit_debug:5.2.241009-jdk17`
- `your-registry.local/firstspirit/firstspirit:5.2.241009-jdk17`

### Build multi-platform images

See the official documentation for more [details](https://docs.docker.com/build/building/multi-platform/).

1. Get the QEMU kernel images `docker run --privileged --rm tonistiigi/binfmt --install all`
2. Create a new builder and run it `docker buildx create --name <YOUR_BUILDER_NAME_HERE> --driver docker-container --bootstrap`
3. Use the builder `docker buildx use <YOUR_BUILDER_NAME_HERE>`
4. Run your build with `buildx` (BuildKit), pushes the image immediately `docker buildx build --platform linux/arm64,linux/amd64 -f jdk17/Dockerfile ... -t <YOUR_IMAGE_TAG_HERE> --push .`
5. Reset builder to default `docker buildx use default`
6. Remove builder `docker buildx rm <YOUR_BUILDER_NAME_HERE>`

## Running tests

### CST tests

To run the [Container Structure Tests](https://github.com/GoogleContainerTools/container-structure-test) you need to
install the CLI first. Then you can run the tests with

```console
container-structure-test test --image firstspirit/firstspirit_debug:[YOUR_TAG] --config unit-test.jdk17.yaml
```

for running test of a JDK 17 image

### InSpec integration tests

To run [Chef InSpec integration tests](https://docs.chef.io/inspec/) you need to install the CLI first. Then you can run
the tests with:

```console
docker run --rm ... # Start a container based on the to test image
docker ps -q # Get the running container id
inspec exec ./inspec-tests --input firstspirit_version='5.2.230411' -t docker://CONTAINER_ID # Run the tests
```

## Configuration

### Environment variables

The FirstSpirit instance can be customized by specifying environment variables on the first run. The following
environment values are provided to custom FirstSpirit:

- `EXT_HOSTNAME`: The external hostname, configured in `fs-server.conf`
- `EXT_PORT`: The port number, configured in `fs-server.conf`

### Build variables

The image build process can be customized by specifying the build-args at build time.

- `IMAGE_CREATED`: Image creation date, default `2023-04-14T09:15:59CEST`
- `IMAGE_VERSION`: Image version same as FirstSpirit version, default `5.2.230411`
- `IMAGE_VERSION_SHORT`: Image short version same as FirstSpirit version short name, default `2023.4`
- `FS_DOWNLOAD_SERVER`: Url to the FirstSpirit download server, **mandatory**
- `FS_DOWNLOAD_SERVER_USERNAME`: Username for the FirstSpirit download server, **mandatory**
- `FS_DOWNLOAD_SERVER_PASSWORD`: Password for the FirstSpirit download server, **mandatory**
- `FS_DOWNLOAD_SERVER_NAME`: Name of the server jar file to be downloaded, default `fs-isolated-server.jar`
- `FS_DOWNLOAD_INSTALL_NAME`: Name of the installation archive to be downloaded, default `fs-install-3.0.5.tar.gz`
- `FS_BASE_DIRECTORY`: FirstSpirit base directory, default `/opt/firstspirit5`
- `FS_INSTALL_DIRECTORY`: FirstSpirit install directory, default `/install/firstspirit5`
- `FS_DEBUG_PORT`: FirstSpirit debug port configuration, default `*:8585`

## Contributing

We'd love for you to contribute to those container images. You can request new features by creating
an [issue](https://github.com/monday-consulting/firstspirit-docker/issues/new), or submit
a [pull request](https://github.com/monday-consulting/firstspirit-docker/pulls) with your contribution.

## Legal Notices

FirstSpirit is a product of [Crownpeak Technology GmbH](https://www.e-spirit.com/), Dortmund, Germany.

## Disclaimer

This document is provided for information purposes only. Monday Consulting may change the contents hereof without
notice. This document is not warranted to be error-free, nor subject to any other warranties or conditions, whether
expressed orally or implied in law, including implied warranties and conditions of merchantability or fitness for a
particular purpose. Monday Consulting specifically disclaims any liability with respect to this document and no
contractual obligations are formed either directly or indirectly by this document. The technologies, functionality,
services, and processes described herein are subject to change without notice.
