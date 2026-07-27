# A static site needs a static server. nginx:alpine is about 10 MB and does
# nothing else, which is the whole requirement.
FROM nginx:1.27-alpine

COPY index.html /usr/share/nginx/html/index.html
COPY assets/ /usr/share/nginx/html/assets/
COPY nginx.conf.template /etc/nginx/templates/default.conf.template

# Railway assigns the port at run time; the image cannot bake it in.
ENV PORT=8080
EXPOSE 8080
