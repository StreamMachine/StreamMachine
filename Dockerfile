FROM node:4.2.2

ENV HOME /streammachine

WORKDIR $HOME

COPY package.json $HOME/package.json

RUN cd $HOME; npm install

COPY . $HOME

RUN mkdir app && \
    mkdir app/shared

ENTRYPOINT ["./docker-entrypoint.sh"]
