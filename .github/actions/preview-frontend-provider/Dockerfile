FROM alpine:3.17

RUN apk upgrade && apk update \
    && apk --no-cache add bash yq jq curl aws-cli

COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

ENTRYPOINT [ "/entrypoint.sh" ]
