FROM ghcr.io/getzola/zola:v0.21.0 AS local

WORKDIR /project
VOLUME /project
ENTRYPOINT ["zola", "serve", "--interface", "0.0.0.0", "--port", "1111", "--drafts"]
EXPOSE 1111

FROM ghcr.io/getzola/zola:v0.21.0 AS build

COPY . /project
WORKDIR /project
RUN ["zola", "check"]
RUN ["zola", "build"]

FROM ghcr.io/static-web-server/static-web-server:2 AS prod
WORKDIR /
COPY --from=build /project/public /public
EXPOSE 80
