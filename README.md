# FirstSpirit in a Container

THIS PROJECT IS NOT AN OFFICIAL PRODUCT BY [Crownpeak Technology GmbH](https://www.e-spirit.com/). It is maintained and provided by [Monday Consulting](https://www.monday-consultig.com/) to the FirstSpirit Community

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
docker build -f jdk11/Dockerfile --no-cache --build-arg FS_DOWNLOAD_SERVER=YOUR_URL_HERE --build-arg FS_DOWNLOAD_SERVER_USERNAME=YOUR_USERNAME --build-arg FS_DOWNLOAD_SERVER_PASSWORD=YOUR_PASSWORD --build-arg IMAGE_CREATED=$(date +%FT%T%Z) -t registry.my-monday-consulting.com/firstspirit/firstspirit_debug:YOUR-TAG-jdk11 .   
```

### Image flavours

Currently, there are two mayor flavors, depending on the base java version

* JDK 11
* JDK 17

The mayor flavors are addressed by their respective `Dockerfile`. Choose your flavors by providing the `-f` flag to the
build command. E.g. for JDK 11

```console
docker build -f jdk11/Dockerfile ...
```

By default, the image is created with debug properties so a developer can remote debug the FirstSpirit server. If you
don't want this option you have to provide the `base` target to the docker build. E.g. for JDK 17

```console
docker build -f jdk17/Dockerfile --target base ...
```

For a complete set of images you have run 4 commands:

```console
docker build -f jdk11/Dockerfile --no-cache --build-arg FS_DOWNLOAD_SERVER=YOUR_URL_HERE --build-arg FS_DOWNLOAD_SERVER_USERNAME=YOUR_USERNAME --build-arg FS_DOWNLOAD_SERVER_PASSWORD=YOUR_PASSWORD --build-arg IMAGE_CREATED=$(date +%FT%T%Z) -t registry.my-monday-consulting.com/firstspirit/firstspirit_debug:YOUR-TAG_GOES-HERE-jdk11 .
docker build -f jdk11/Dockerfile --target base --build-arg FS_DOWNLOAD_SERVER=YOUR_URL_HERE --build-arg FS_DOWNLOAD_SERVER_USERNAME=YOUR_USERNAME --build-arg FS_DOWNLOAD_SERVER_PASSWORD=YOUR_PASSWORD --build-arg IMAGE_CREATED=$(date +%FT%T%Z) -t registry.my-monday-consulting.com/firstspirit/firstspirit:YOUR-TAG_GOES-HERE-jdk11 .   
docker build -f jdk17/Dockerfile --no-cache --build-arg FS_DOWNLOAD_SERVER=YOUR_URL_HERE --build-arg FS_DOWNLOAD_SERVER_USERNAME=YOUR_USERNAME --build-arg FS_DOWNLOAD_SERVER_PASSWORD=YOUR_PASSWORD --build-arg IMAGE_CREATED=$(date +%FT%T%Z) -t registry.my-monday-consulting.com/firstspirit/firstspirit_debug:YOUR-TAG_GOES-HERE-jdk17 .
docker build -f jdk17/Dockerfile --target base --build-arg FS_DOWNLOAD_SERVER=YOUR_URL_HERE --build-arg FS_DOWNLOAD_SERVER_USERNAME=YOUR_USERNAME --build-arg FS_DOWNLOAD_SERVER_PASSWORD=YOUR_PASSWORD --build-arg IMAGE_CREATED=$(date +%FT%T%Z) -t registry.my-monday-consulting.com/firstspirit/firstspirit:YOUR-TAG_GOES-HERE-jdk17 . 
```
### Recommended tagging
The image tagging scheme should be

``` 
YOUR_REGISTRY/YOUR_PROJECT/firstspirit[_debug]:(FS-VERSION)-(JDK-VERSION)
```
A complete set would be:
* `registry.my-monday-consulting.com/firstspirit/firstspirit_debug:5.2.230411-jdk11`
* `registry.my-monday-consulting.com/firstspirit/firstspirit:5.2.230411-jdk11`
* `registry.my-monday-consulting.com/firstspirit/firstspirit_debug:5.2.230411-jdk17`
* `registry.my-monday-consulting.com/firstspirit/firstspirit:5.2.230411-jdk17`

## Running tests
### CST tests
To run the [Container Structure Tests](https://github.com/GoogleContainerTools/container-structure-test) you need to install the CLI first. Then you can run the tests with
```console
container-structure-test test --image firstspirit/firstspirit_debug:[YOUR_TAG] --config unit-test.jdk17.yaml
```
for running test of a JDK 17 image or
```console
container-structure-test test --image firstspirit/firstspirit_debug:[YOUR_TAG] --config unit-test.jdk11.yaml
```
for running test of a JDK 11 image.

## Configuration

### Environment variables

The FirstSpirit instance can be customized by specifying environment variables on the first run. The following
environment values are provided to custom FirstSpirit:

* `EXT_HOSTNAME`: The external hostname, configured in `fs-server.conf`
* `EXT_PORT`: The port number, configured in `fs-server.conf`

### Build variables
The image build process can be customized by specifying the build-args at build time.

* `IMAGE_CREATED`: Image creation date, default `2023-04-14T09:15:59CEST`
* `IMAGE_VERSION`: Image version same as FirstSpirit version, default `5.2.230411`
* `IMAGE_VERSION_SHORT`: Image short version same as FirstSpirit version short name, default `2023.4`
* `FS_DOWNLOAD_SERVER`: Url to the FirstSpirit download server, **mandatory**
* `FS_DOWNLOAD_SERVER_USERNAME`: Username for the FirstSpirit download server, **mandatory**
* `FS_DOWNLOAD_SERVER_PASSWORD`: Password for the FirstSpirit download server, **mandatory**
* `FS_DOWNLOAD_SERVER_NAME`: Name of the server jar file to be downloaded, default `fs-isolated-server.jar`
* `FS_DOWNLOAD_INSTALL_NAME`: Name of the installation archive to be downloaded, default `fs-install-3.0.5.tar.gz`
* `FS_BASE_DIRECTORY`: FirstSpirit base directory, default `/opt/firstspirit5`
* `FS_INSTALL_DIRECTORY`: FirstSpirit install directory, default `/install/firstspirit5`
* `FS_DEBUG_PORT`: FirstSpirit debug port configuration, default `*:8585`
