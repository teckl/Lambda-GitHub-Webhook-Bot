FROM perl:5.32

RUN mkdir -p /opt/webapp
WORKDIR /opt/webapp
RUN cpanm -n Carton
RUN cpanm -n Plack Kossy

CMD ["bash", "-x", "entrypoint.sh"]
