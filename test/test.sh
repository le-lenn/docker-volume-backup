#!/bin/sh

set -e

MATCH_PATTERN=$1
IMAGE_TAG=${IMAGE_TAG:-canary}
ISOLATE_DOCKER_CONFIG=${ISOLATE_DOCKER_CONFIG:-}

sandbox="docker_volume_backup_test_sandbox"
tarball="$(mktemp -d)/image.tar.gz"
compose_profile="default"
compose_files="-f docker-compose.yml"

if [ -n "$ISOLATE_DOCKER_CONFIG" ]; then
  compose_files="$compose_files -f docker-compose.isolated.yml"
fi

trap finish EXIT INT TERM

finish () {
  rm -rf $(dirname $tarball)
  docker compose $compose_files --profile $compose_profile down
}

docker build -t offen/docker-volume-backup:test-sandbox .

if [ ! -z "$BUILD_IMAGE" ]; then
  docker build -t offen/docker-volume-backup:$IMAGE_TAG $(dirname $(pwd))
fi

docker save offen/docker-volume-backup:$IMAGE_TAG -o $tarball

find_args="-mindepth 1 -maxdepth 1 -type d"
if [ ! -z "$MATCH_PATTERN" ]; then
  find_args="$find_args -name $MATCH_PATTERN"
fi

for dir in $(find $find_args | sort); do
  dir=$(echo $dir | cut -c 3-)
  echo "################################################"
  echo "Now running ${dir}"
  echo "################################################"
  echo ""

  export TARBALL=$tarball
  export SOURCE=$(dirname $(pwd))

  if [ -f ${dir}/.multinode ]; then
    compose_profile="multinode"
  fi

  docker compose $compose_files --profile $compose_profile up -d --wait
  if [ -f "${dir}/.swarm" ]; then
    docker compose $compose_files --profile $compose_profile exec manager docker swarm init
  elif [ -f "${dir}/.multinode" ]; then
    docker compose $compose_files --profile $compose_profile exec manager docker swarm init
    manager_ip=$(docker compose $compose_files --profile $compose_profile exec manager docker node inspect $(docker compose $compose_files --profile $compose_profile exec manager docker node ls -q) --format '{{ .Status.Addr }}')
    token=$(docker compose $compose_files --profile $compose_profile exec manager docker swarm join-token -q worker)
    docker compose $compose_files --profile $compose_profile exec worker1 docker swarm join --token $token $manager_ip:2377
    docker compose $compose_files --profile $compose_profile exec worker2 docker swarm join --token $token $manager_ip:2377
  fi

  for svc in $(docker compose $compose_files --profile $compose_profile ps -q); do
    docker exec $svc /bin/sh -c "docker load -i /cache/image.tar.gz"
  done

  for executable in $(find $dir -type f -executable | sort); do
    context="manager"
    if [ -f "$executable.context" ]; then
        context=$(cat "$executable.context")
    fi
    docker compose $compose_files --profile $compose_profile exec -e TEST_VERSION=$IMAGE_TAG $context /bin/sh -c "/code/$executable"
  done

  docker compose $compose_files --profile $compose_profile down
  echo ""
  echo "$dir passed"
  echo ""
done
