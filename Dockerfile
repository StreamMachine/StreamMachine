FROM node:4.2.2

ENV HOME /streammachine

WORKDIR $HOME

COPY package.json $HOME/package.json

RUN cd $HOME; npm install

COPY . $HOME

RUN mkdir app && \
    mkdir app/shared

RUN addgroup --gid 1000 --system node && \
    adduser -u 1000 --system node --ingroup node

USER node

ENTRYPOINT ["./docker-entrypoint.sh"]
