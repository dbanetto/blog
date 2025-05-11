FROM ghcr.io/getzola/zola:v0.19.2 as local

WORKDIR /project
VOLUME /project
ENTRYPOINT ["zola", "serve", "--interface", "0.0.0.0", "--port", "1111", "--drafts"]
EXPOSE 1111

FROM ghcr.io/getzola/zola:v0.19.2 as build

COPY . /project
WORKDIR /project
RUN ["zola", "check"]
RUN ["zola", "build"]

FROM ghcr.io/static-web-server/static-web-server:2 as prod
WORKDIR /
COPY --from=build /project/public /public
EXPOSE 80
