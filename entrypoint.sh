#!/bin/bash

carton install
carton exec plackup -r -s Starlet  -p 8000 app.psgi
