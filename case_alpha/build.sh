REPOSITORY="llm-gateway"
REGISTRY="docker-registry.yacodata.com"
AUTH=${REGISTRY_USER}:${REGISTRY_PASS}


TAG=0.12

docker build -t ${REGISTRY}/${REPOSITORY}:${TAG} case_alpha/fastapi-gateway/
docker tag ${REGISTRY}/${REPOSITORY}:${TAG} ${REGISTRY}/${REPOSITORY}:latest
docker push ${REGISTRY}/${REPOSITORY}:${TAG}
docker push ${REGISTRY}/${REPOSITORY}:latest

echo "New tag: ${TAG}"