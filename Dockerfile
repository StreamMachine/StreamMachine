FROM node:10.13.0

ENV HOME=/streammachine

ENV FFMPEG_SRC=$HOME/ffmpeg_sources \
    FFMPEG_BIN_DIR=$HOME/bin

WORKDIR $HOME

COPY package.json $HOME/package.json

RUN mkdir app && \
    mkdir app/shared && \
    mkdir -p $FFMPEG_SRC

RUN cd $FFMPEG_SRC && \
wget https://www.nasm.us/pub/nasm/releasebuilds/2.14.02/nasm-2.14.02.tar.bz2 && \
tar xjvf nasm-2.14.02.tar.bz2 && \
cd nasm-2.14.02 && \
./autogen.sh && \
PATH="$HOME/bin:$PATH" ./configure --prefix="$HOME/ffmpeg_build" --bindir="$HOME/bin" && \
make && \
make install

RUN cd $FFMPEG_SRC && \
    wget -O yasm-1.3.0.tar.gz https://www.tortall.net/projects/yasm/releases/yasm-1.3.0.tar.gz && \
    tar xzvf yasm-1.3.0.tar.gz && \
    cd yasm-1.3.0 && \
    ./configure --prefix="$HOME/ffmpeg_build" --bindir=$FFMPEG_BIN_DIR && \
    make && \
    make install

RUN cd $FFMPEG_SRC && \
    git -C fdk-aac pull 2> /dev/null || git clone --depth 1 https://github.com/mstorsjo/fdk-aac && \
    cd fdk-aac && \
    autoreconf -fiv && \
    ./configure --prefix="$HOME/ffmpeg_build" --disable-shared && \
    make && \
    make install

RUN cd $FFMPEG_SRC && \
    wget -O lame-3.100.tar.gz https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz && \
    tar xzvf lame-3.100.tar.gz && \
    cd lame-3.100 && \
    PATH="$HOME/bin:$PATH" ./configure --prefix="$HOME/ffmpeg_build" --bindir="$HOME/bin" --disable-shared --enable-nasm && \
    PATH="$HOME/bin:$PATH" make && \
    make install

RUN cd $FFMPEG_SRC && \
wget -O ffmpeg-snapshot.tar.bz2 https://ffmpeg.org/releases/ffmpeg-snapshot.tar.bz2 && \
tar xjvf ffmpeg-snapshot.tar.bz2 && \
cd ffmpeg && \
PATH="$HOME/bin:$PATH" PKG_CONFIG_PATH="$HOME/ffmpeg_build/lib/pkgconfig" ./configure \
  --prefix="$HOME/ffmpeg_build" \
  --pkg-config-flags="--static" \
  --extra-cflags="-I$HOME/ffmpeg_build/include" \
  --extra-ldflags="-L$HOME/ffmpeg_build/lib" \
  --extra-libs="-lpthread -lm" \
  --bindir="$HOME/bin" \
  --enable-gpl \
  --enable-libfdk-aac \
  --enable-libmp3lame \
  --enable-nonfree && \
PATH="$HOME/bin:$PATH" make && \
make install && \
hash -r

# Cleanup all the messy ffmpeg build stuff
RUN rm -rf $FFMPEG_SRC && rm -rf $HOME/ffmpeg_build

RUN cd $HOME; npm install

COPY . $HOME

RUN ln -s ~/bin/ffmpeg /usr/bin/ffmpeg

USER node

